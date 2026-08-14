import Foundation
import XCTest
@testable import LidMuteCore

final class RecordingObservationFileSystem: ObservationFileSystem, @unchecked Sendable {
    var operations: [String] = []
    var failFileSync = false
    var ensureDirectoryError: Error?
    var failNextDedupWrite = false
    var failNextDirectorySync = false
    var rejectFullInboxReads = false
    var tailReadError: Error?
    private var files: [URL: Data] = [:]

    func read(_ url: URL) throws -> Data {
        operations.append("read:\(url.lastPathComponent)")
        if rejectFullInboxReads, url.lastPathComponent == "chrome-inbox.jsonl" {
            throw CocoaError(.fileReadTooLarge)
        }
        return files[url] ?? Data()
    }

    func readLastCompleteLines(_ url: URL, maximumCount: Int, maximumLineBytes: Int) throws -> [Data] {
        operations.append("read-tail:\(url.lastPathComponent):\(maximumCount)")
        if let tailReadError { throw tailReadError }
        let data = files[url] ?? Data()
        guard !data.isEmpty else { return [] }
        guard data.last == 0x0A else { throw CocoaError(.fileReadCorruptFile) }
        let allLines: [ArraySlice<UInt8>] = [UInt8](data).split(separator: 0x0A)
        let lines: [Data] = allLines.suffix(maximumCount).map { Data($0) }
        guard lines.allSatisfy({ $0.count <= maximumLineBytes }) else {
            throw CocoaError(.fileReadTooLarge)
        }
        return lines
    }

    func coordinatedAppend(_ data: Data, to url: URL) throws {
        operations.append("write:\(url.lastPathComponent)")
        files[url, default: Data()].append(data)
    }

    func atomicWrite(_ data: Data, to url: URL, permissions: Int16) throws {
        operations.append("atomic:\(url.lastPathComponent)")
        if failNextDedupWrite, url.lastPathComponent == "chrome-dedup.json" {
            failNextDedupWrite = false
            throw CocoaError(.fileWriteOutOfSpace)
        }
        files[url] = data
    }

    func syncFile(_ url: URL) throws {
        operations.append("fsync:\(url.lastPathComponent)")
        if failFileSync { throw CocoaError(.fileWriteOutOfSpace) }
    }

    func syncDirectory(_ url: URL) throws {
        operations.append("fsync-dir:\(url.lastPathComponent)")
        if failNextDirectorySync {
            failNextDirectorySync = false
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }

    func ensurePrivateDirectory(_ url: URL) throws {
        operations.append("mkdir:\(url.lastPathComponent)")
        if let ensureDirectoryError { throw ensureDirectoryError }
    }

    func truncate(_ url: URL) throws {
        operations.append("truncate:\(url.lastPathComponent)")
        files[url] = Data()
    }

    func removeIfPresent(_ url: URL) throws {
        operations.append("remove:\(url.lastPathComponent)")
        files[url] = nil
    }

    func seed(_ data: Data, at url: URL) {
        files[url] = data
    }
}

final class ObservationStoreAcceptanceTests: XCTestCase {
    private let eventID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let sessionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    func testAcceptedOccursOnlyAfterRecordAndMetadataAreSynced() throws {
        let fs = RecordingObservationFileSystem()
        let paths = ObservationPaths(root: URL(fileURLWithPath: "/tmp/lidmute-store-test"))
        let store = ObservationStore(paths: paths, fileSystem: fs, lock: InProcessObservationLock())

        XCTAssertEqual(try store.accept(normalFrame()), .accepted(eventID))
        XCTAssertLessThan(index(of: "write:chrome-inbox.jsonl", in: fs), index(of: "fsync:chrome-inbox.jsonl", in: fs))
        XCTAssertLessThan(index(of: "fsync:chrome-inbox.jsonl", in: fs), index(of: "atomic:chrome-dedup.json", in: fs))
        XCTAssertLessThan(index(of: "atomic:chrome-dedup.json", in: fs), index(of: "fsync:chrome-dedup.json", in: fs))
        XCTAssertLessThan(index(of: "fsync:chrome-dedup.json", in: fs), index(of: "fsync-dir:lidmute-store-test", in: fs))
    }

    func testFsyncFailureIsRetryableAndDoesNotPublishAcceptedMetadata() throws {
        let fs = RecordingObservationFileSystem()
        fs.failFileSync = true
        let paths = ObservationPaths(root: URL(fileURLWithPath: "/tmp/lidmute-store-retry"))
        let store = ObservationStore(paths: paths, fileSystem: fs, lock: InProcessObservationLock())

        XCTAssertThrowsError(try store.accept(normalFrame())) { error in
            XCTAssertEqual(error as? ObservationStoreError, .retryablePersistenceFailure)
        }
        XCTAssertFalse(fs.operations.contains("atomic:chrome-dedup.json"))
        XCTAssertTrue(try store.acceptedEventIDs().isEmpty)
    }

    func testRetryAfterDedupWriteFailureDoesNotAppendASecondInboxRecord() throws {
        let fs = RecordingObservationFileSystem()
        fs.failNextDedupWrite = true
        let paths = ObservationPaths(root: URL(fileURLWithPath: "/tmp/lidmute-store-recover-inbox"))
        let store = ObservationStore(paths: paths, fileSystem: fs, lock: InProcessObservationLock())

        XCTAssertThrowsError(try store.accept(normalFrame())) { error in
            XCTAssertEqual(error as? ObservationStoreError, .retryablePersistenceFailure)
        }
        XCTAssertEqual(try store.accept(normalFrame()), .duplicate(eventID))
        XCTAssertEqual(try store.readInboxRecords().map(\.eventID), [eventID])
        XCTAssertEqual(try store.acceptedEventIDs(), [eventID])
        XCTAssertEqual(fs.operations.filter { $0 == "write:chrome-inbox.jsonl" }.count, 1)
    }

    func testRetryAfterDirectorySyncFailureRedrivesDurabilityBeforeDuplicate() throws {
        let fs = RecordingObservationFileSystem()
        fs.failNextDirectorySync = true
        let paths = ObservationPaths(root: URL(fileURLWithPath: "/tmp/lidmute-store-recover-directory"))
        let store = ObservationStore(paths: paths, fileSystem: fs, lock: InProcessObservationLock())

        XCTAssertThrowsError(try store.accept(normalFrame())) { error in
            XCTAssertEqual(error as? ObservationStoreError, .retryablePersistenceFailure)
        }
        XCTAssertEqual(try store.accept(normalFrame()), .duplicate(eventID))
        XCTAssertEqual(fs.operations.filter { $0 == "fsync:chrome-inbox.jsonl" }.count, 2)
        XCTAssertEqual(fs.operations.filter { $0 == "fsync:chrome-dedup.json" }.count, 2)
        XCTAssertEqual(fs.operations.filter { $0 == "fsync-dir:lidmute-store-recover-directory" }.count, 2)
        XCTAssertEqual(fs.operations.filter { $0 == "write:chrome-inbox.jsonl" }.count, 1)
    }

    func testDirectoryPermissionFailureIsExplicitlyRetryable() {
        let fs = RecordingObservationFileSystem()
        fs.ensureDirectoryError = CocoaError(.fileWriteNoPermission)
        let store = ObservationStore(
            paths: .init(root: URL(fileURLWithPath: "/tmp/lidmute-store-permission")),
            fileSystem: fs,
            lock: InProcessObservationLock()
        )

        XCTAssertThrowsError(try store.accept(normalFrame())) { error in
            XCTAssertEqual(error as? ObservationStoreError, .retryablePersistenceFailure)
        }
    }

    func testDuplicateAfterRestartIsTerminalWithoutSecondInboxRecord() throws {
        let fixture = try ObservationStoreFixture()
        let frame = normalFrame()

        XCTAssertEqual(try fixture.store.accept(frame), .accepted(eventID))
        let restarted = ObservationStore(paths: fixture.paths)
        XCTAssertEqual(try restarted.accept(frame), .duplicate(eventID))
        XCTAssertEqual(try restarted.readInboxRecords().map(\.eventID), [eventID])
    }

    func testIncognitoIsTerminalWithZeroObservationPersistence() throws {
        let fixture = try ObservationStoreFixture()
        let frame = incognitoFrame()

        XCTAssertEqual(try fixture.store.accept(frame), .ignoredIncognito(eventID))
        XCTAssertTrue(try fixture.store.readInboxRecords().isEmpty)
        XCTAssertTrue(try fixture.store.acceptedEventIDs().isEmpty)
        XCTAssertFalse(try fixture.persistedBytes().contains(Data("secret".utf8)))
        XCTAssertFalse(try fixture.persistedBytes().contains(Data("搜索".utf8)))
    }

    func testInboxRecordCarriesTheGenerationReadUnderAcceptance() throws {
        let fs = RecordingObservationFileSystem()
        let paths = ObservationPaths(root: URL(fileURLWithPath: "/tmp/lidmute-store-generation"))
        fs.seed(Data("7".utf8), at: paths.generation)
        let store = ObservationStore(paths: paths, fileSystem: fs, lock: InProcessObservationLock())

        XCTAssertEqual(try store.currentGeneration(), 7)
        XCTAssertEqual(try store.accept(normalFrame()), .accepted(eventID))
        XCTAssertEqual(try store.readInboxRecords().map(\.generation), [7])
    }

    func testCorruptGenerationAndDedupMetadataAreReportedWithoutOverwrite() throws {
        let fs = RecordingObservationFileSystem()
        let paths = ObservationPaths(root: URL(fileURLWithPath: "/tmp/lidmute-store-corrupt"))
        fs.seed(Data("not-a-generation".utf8), at: paths.generation)
        let store = ObservationStore(paths: paths, fileSystem: fs, lock: InProcessObservationLock())

        XCTAssertThrowsError(try store.currentGeneration()) { error in
            XCTAssertEqual(error as? ObservationStoreError, .corruptMetadata("observation-generation"))
        }

        fs.seed(Data("0".utf8), at: paths.generation)
        fs.seed(Data("not-json".utf8), at: paths.dedup)
        XCTAssertThrowsError(try store.accept(normalFrame())) { error in
            XCTAssertEqual(error as? ObservationStoreError, .corruptMetadata("chrome-dedup.json"))
        }
        XCTAssertFalse(fs.operations.contains("write:chrome-inbox.jsonl"))
    }

    func testPartialInboxTailIsExplicitCorruptionWithoutAppend() {
        let fs = RecordingObservationFileSystem()
        let paths = ObservationPaths(root: URL(fileURLWithPath: "/tmp/lidmute-store-partial-tail"))
        fs.seed(Data("{\"partial\":true}".utf8), at: paths.inbox)
        let store = ObservationStore(paths: paths, fileSystem: fs, lock: InProcessObservationLock())

        XCTAssertThrowsError(try store.accept(normalFrame())) { error in
            XCTAssertEqual(error as? ObservationStoreError, .corruptMetadata("chrome-inbox.jsonl"))
        }
        XCTAssertFalse(fs.operations.contains("write:chrome-inbox.jsonl"))
    }

    func testOversizedInboxLineIsExplicitCorruptionWithoutAppend() {
        let fs = RecordingObservationFileSystem()
        let paths = ObservationPaths(root: URL(fileURLWithPath: "/tmp/lidmute-store-oversized-tail"))
        var oversizedLine = Data(repeating: 0x61, count: 262_145)
        oversizedLine.append(0x0A)
        fs.seed(oversizedLine, at: paths.inbox)
        let store = ObservationStore(paths: paths, fileSystem: fs, lock: InProcessObservationLock())

        XCTAssertThrowsError(try store.accept(normalFrame())) { error in
            XCTAssertEqual(error as? ObservationStoreError, .corruptMetadata("chrome-inbox.jsonl"))
        }
        XCTAssertFalse(fs.operations.contains("write:chrome-inbox.jsonl"))
    }

    func testInboxTailIOFailureRemainsRetryable() {
        let fs = RecordingObservationFileSystem()
        fs.tailReadError = CocoaError(.fileReadNoPermission)
        let paths = ObservationPaths(root: URL(fileURLWithPath: "/tmp/lidmute-store-tail-io"))
        let store = ObservationStore(paths: paths, fileSystem: fs, lock: InProcessObservationLock())

        XCTAssertThrowsError(try store.accept(normalFrame())) { error in
            XCTAssertEqual(error as? ObservationStoreError, .retryablePersistenceFailure)
        }
        XCTAssertFalse(fs.operations.contains("write:chrome-inbox.jsonl"))
    }

    func testDedupKeepsTheMostRecent4096IDsInAcceptanceOrder() throws {
        let fs = RecordingObservationFileSystem()
        let paths = ObservationPaths(root: URL(fileURLWithPath: "/tmp/lidmute-store-dedup-order"))
        let existing = (0..<4_096).map(orderedUUID)
        try seedAcceptedState(existing, fileSystem: fs, paths: paths)
        let store = ObservationStore(paths: paths, fileSystem: fs, lock: InProcessObservationLock())
        let nextID = orderedUUID(4_096)

        XCTAssertEqual(try store.accept(frame(eventID: nextID, incognito: false)), .accepted(nextID))
        let retained = try store.acceptedEventIDs()
        XCTAssertEqual(retained.count, 4_096)
        XCTAssertEqual(retained.first, existing[1])
        XCTAssertEqual(retained.last, nextID)
    }

    func testReplayOlderThanDedupWindowIsAcceptedAsTheNewestEventWithoutFullInboxRead() throws {
        let fs = RecordingObservationFileSystem()
        let paths = ObservationPaths(root: URL(fileURLWithPath: "/tmp/lidmute-store-old-replay"))
        let store = ObservationStore(paths: paths, fileSystem: fs, lock: InProcessObservationLock())
        let accepted = (0...4_096).map(orderedUUID)
        try seedAcceptedState(accepted, fileSystem: fs, paths: paths)
        let expectedRecent = Array(accepted.suffix(4_096))
        XCTAssertEqual(try store.acceptedEventIDs(), expectedRecent)

        fs.rejectFullInboxReads = true
        XCTAssertEqual(try store.accept(frame(eventID: accepted[0], incognito: false)), .accepted(accepted[0]))
        XCTAssertEqual(try store.acceptedEventIDs(), Array((accepted + [accepted[0]]).suffix(4_096)))
        XCTAssertEqual(fs.operations.filter { $0 == "write:chrome-inbox.jsonl" }.count, 1)
    }

    func testRestartRebuildsRecentDedupFromActualInboxSuffixBeforeAcceptingAnotherEvent() throws {
        let fs = RecordingObservationFileSystem()
        let paths = ObservationPaths(root: URL(fileURLWithPath: "/tmp/lidmute-store-restart-suffix"))
        let existing = (0...4_096).map(orderedUUID)
        try seedAcceptedState(existing, fileSystem: fs, paths: paths)
        let failedEventID = orderedUUID(4_097)
        let nextEventID = orderedUUID(4_098)
        let firstStore = ObservationStore(paths: paths, fileSystem: fs, lock: InProcessObservationLock())

        fs.failNextDedupWrite = true
        XCTAssertThrowsError(try firstStore.accept(frame(eventID: failedEventID, incognito: false))) { error in
            XCTAssertEqual(error as? ObservationStoreError, .retryablePersistenceFailure)
        }

        fs.rejectFullInboxReads = true
        let restarted = ObservationStore(paths: paths, fileSystem: fs, lock: InProcessObservationLock())
        XCTAssertEqual(try restarted.accept(frame(eventID: nextEventID, incognito: false)), .accepted(nextEventID))
        XCTAssertEqual(
            try restarted.acceptedEventIDs(),
            Array((existing + [failedEventID, nextEventID]).suffix(4_096))
        )
        XCTAssertEqual(try restarted.accept(frame(eventID: failedEventID, incognito: false)), .duplicate(failedEventID))
        XCTAssertEqual(
            try restarted.acceptedEventIDs(),
            Array((existing + [failedEventID, nextEventID]).suffix(4_096))
        )
    }

    func testPOSIXFileSystemUsesPrivateDirectoryAndFileModes() throws {
        let fixture = try ObservationStoreFixture()

        XCTAssertEqual(try fixture.store.accept(normalFrame()), .accepted(eventID))
        XCTAssertEqual(try permissions(of: fixture.paths.root), 0o700)
        XCTAssertEqual(try permissions(of: fixture.paths.lock), 0o600)
        XCTAssertEqual(try permissions(of: fixture.paths.inbox), 0o600)
        XCTAssertEqual(try permissions(of: fixture.paths.dedup), 0o600)
    }

    func testPOSIXLockIsRecursiveForOneSharedInstance() throws {
        let fixture = try ObservationStoreFixture()
        var enteredNestedSection = false

        try fixture.store.withExclusiveLock {
            try fixture.store.withExclusiveLock {
                enteredNestedSection = true
            }
        }

        XCTAssertTrue(enteredNestedSection)
    }

    private func normalFrame() -> ChromeValidatedFrame {
        frame(eventID: eventID, incognito: false)
    }

    private func incognitoFrame() -> ChromeValidatedFrame {
        frame(eventID: eventID, incognito: true)
    }

    private func frame(eventID: UUID, incognito: Bool) -> ChromeValidatedFrame {
        ChromeValidatedFrame(
            eventID: eventID,
            extensionSessionID: sessionID,
            evidence: ChromeTabEvidence(
                sessionID: sessionID.uuidString,
                windowID: 1,
                tabID: 2,
                index: 0,
                title: "搜索",
                url: "https://example.com/watch?q=secret#chapter",
                audible: true,
                muted: false,
                isActive: true,
                isPinned: false,
                isIncognito: incognito
            ),
            privacy: incognito ? .ignoreIncognito : .persist
        )
    }

    private func orderedUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", value))!
    }

    private func seedAcceptedState(
        _ eventIDs: [UUID],
        fileSystem: RecordingObservationFileSystem,
        paths: ObservationPaths
    ) throws {
        var inbox = Data()
        for eventID in eventIDs {
            let record = ChromeInboxRecord(
                generation: 0,
                eventID: eventID,
                acceptedAt: Date(timeIntervalSinceReferenceDate: 0),
                evidence: frame(eventID: eventID, incognito: false).evidence
            )
            inbox.append(try JSONEncoder().encode(record))
            inbox.append(0x0A)
        }
        fileSystem.seed(inbox, at: paths.inbox)
        fileSystem.seed(try JSONEncoder().encode(Array(eventIDs.suffix(4_096))), at: paths.dedup)
    }

    private func index(of operation: String, in fileSystem: RecordingObservationFileSystem) -> Int {
        fileSystem.operations.firstIndex(of: operation) ?? Int.max
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private final class ObservationStoreFixture {
    let root: URL
    let paths: ObservationPaths
    let store: ObservationStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "lidmute-observation-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        paths = ObservationPaths(root: root)
        store = ObservationStore(paths: paths)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func persistedBytes() throws -> Data {
        guard FileManager.default.fileExists(atPath: root.path) else { return Data() }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys
        ) else { return Data() }

        var result = Data()
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: Set(keys)).isRegularFile == true else { continue }
            result.append(try Data(contentsOf: url))
        }
        return result
    }
}

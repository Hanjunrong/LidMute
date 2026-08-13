import Foundation
import XCTest
@testable import LidMuteCore

private final class SaveResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<UUID, Error>] = []

    func append(_ result: Result<UUID, Error>) {
        lock.lock()
        values.append(result)
        lock.unlock()
    }

    func snapshot() -> [Result<UUID, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class SpeakerRecoveryStoreTests: XCTestCase {
    // This fails if a saved recovery record loses protected state or permissions.
    func testRoundTripPreservesProtectedSnapshotAndPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lidmute-recovery-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let journalURL = root.appending(path: "speaker-recovery.json")
        let store = FileSpeakerRecoveryStore(url: journalURL)
        let snapshot = SpeakerRecoverySnapshot.fixture(stage: .protected)

        try store.saveBeforeMutation(snapshot)

        XCTAssertEqual(try store.load(), .snapshot(snapshot))
        let directoryMode = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue)
        let fileMode = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: journalURL.path)[.posixPermissions] as? NSNumber)?.intValue)
        let lockMode = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: root.appending(path: ".speaker-recovery.json.lock").path)[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(fileMode & 0o777, 0o600)
        XCTAssertEqual(lockMode & 0o777, 0o600)
    }

    // This fails if unreadable journal data escapes as an untyped decoding error.
    func testCorruptAndUnsupportedSnapshotsAreTypedResults() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lidmute-recovery-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "speaker-recovery.json")

        try Data("not-json".utf8).write(to: url)
        XCTAssertEqual(try FileSpeakerRecoveryStore(url: url).load(), .corrupt)

        try Data(#"{"schemaVersion":999}"#.utf8).write(to: url)
        XCTAssertEqual(try FileSpeakerRecoveryStore(url: url).load(), .unsupportedSchema(999))
    }

    // This fails if a stale or unrelated transaction can finalize or remove another recovery record.
    func testOnlyMatchingTransactionCanFinalizeAndRemoveRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lidmute-recovery-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSpeakerRecoveryStore(url: root.appending(path: "speaker-recovery.json"))
        let snapshot = SpeakerRecoverySnapshot.fixture()

        try store.saveBeforeMutation(snapshot)
        try store.markFinalizingRestore(transactionID: snapshot.transactionID)

        guard case let .snapshot(finalizing) = try store.load() else {
            return XCTFail("missing snapshot")
        }
        XCTAssertEqual(finalizing.stage, .finalizingRestore)
        XCTAssertThrowsError(try store.removeCompleted(transactionID: UUID()))
        try store.removeCompleted(transactionID: snapshot.transactionID)
        XCTAssertEqual(try store.load(), .none)
    }

    // This fails if a newer save can overwrite a still-pending transaction.
    func testSaveRejectsDifferentPendingTransaction() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lidmute-recovery-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSpeakerRecoveryStore(url: root.appending(path: "speaker-recovery.json"))

        try store.saveBeforeMutation(SpeakerRecoverySnapshot.fixture(transactionID: UUID()))
        XCTAssertThrowsError(try store.saveBeforeMutation(SpeakerRecoverySnapshot.fixture(transactionID: UUID())))
    }

    // This fails if separate store instances race past an empty journal and overwrite each other.
    func testConcurrentStoresSaveOnlyOnePendingTransaction() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lidmute-recovery-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let journalURL = root.appending(path: "speaker-recovery.json")
        let first = SpeakerRecoverySnapshot.fixture(transactionID: UUID())
        let second = SpeakerRecoverySnapshot.fixture(transactionID: UUID())
        let start = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let results = SaveResults()

        for snapshot in [first, second] {
            finished.enter()
            DispatchQueue.global().async {
                start.wait()
                let result = Result {
                    try FileSpeakerRecoveryStore(url: journalURL).saveBeforeMutation(snapshot)
                    return snapshot.transactionID
                }
                results.append(result)
                finished.leave()
            }
        }

        start.signal()
        start.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        let savedResults = results.snapshot()
        XCTAssertEqual(savedResults.compactMap { try? $0.get() }.count, 1)
        let errors = savedResults.compactMap { result -> SpeakerRecoveryStoreError? in
            guard case let .failure(error) = result else { return nil }
            return error as? SpeakerRecoveryStoreError
        }
        XCTAssertEqual(errors.count, 1)
        guard case let .snapshot(saved) = try FileSpeakerRecoveryStore(url: journalURL).load() else {
            return XCTFail("missing saved transaction")
        }
        XCTAssertEqual(errors, [.pendingTransaction(saved.transactionID)])
        XCTAssertTrue([first.transactionID, second.transactionID].contains(saved.transactionID))
    }
}

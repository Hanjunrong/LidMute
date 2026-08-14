import Foundation
import Testing
@testable import LidMuteCore

private final class CursorFailingFileSystem: ObservationFileSystem, @unchecked Sendable {
    private let base = POSIXObservationFileSystem()
    private let cursorURL: URL
    var failNextCursorWrite = false
    private(set) var rangeReadOffsets: [UInt64] = []

    init(cursorURL: URL) {
        self.cursorURL = cursorURL
    }

    func read(_ url: URL) throws -> Data { try base.read(url) }

    func read(_ url: URL, fromOffset offset: UInt64) throws -> Data {
        rangeReadOffsets.append(offset)
        let data = try base.read(url)
        guard offset < UInt64(data.count) else { return Data() }
        return Data(data[Int(offset)...])
    }

    func readLastCompleteLines(
        _ url: URL,
        maximumCount: Int,
        maximumLineBytes: Int
    ) throws -> [Data] {
        try base.readLastCompleteLines(
            url,
            maximumCount: maximumCount,
            maximumLineBytes: maximumLineBytes
        )
    }

    func coordinatedAppend(_ data: Data, to url: URL) throws {
        try base.coordinatedAppend(data, to: url)
    }

    func atomicWrite(_ data: Data, to url: URL, permissions: Int16) throws {
        if url == cursorURL, failNextCursorWrite {
            failNextCursorWrite = false
            throw CocoaError(.fileWriteUnknown)
        }
        try base.atomicWrite(data, to: url, permissions: permissions)
    }

    func syncFile(_ url: URL) throws { try base.syncFile(url) }
    func syncDirectory(_ url: URL) throws { try base.syncDirectory(url) }
    func ensurePrivateDirectory(_ url: URL) throws { try base.ensurePrivateDirectory(url) }
    func truncate(_ url: URL) throws { try base.truncate(url) }
    func removeIfPresent(_ url: URL) throws { try base.removeIfPresent(url) }
}

private final class ConsumerFixture {
    let root: URL
    let paths: ObservationPaths
    let fileSystem: CursorFailingFileSystem
    let observations: ObservationStore
    let events: BoundedJSONLineEventStore
    let consumer: ChromeInboxConsumer

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "lidmute-consumer-\(UUID().uuidString)", directoryHint: .isDirectory)
        paths = ObservationPaths(root: root)
        fileSystem = CursorFailingFileSystem(cursorURL: paths.cursor)
        let lock = InProcessObservationLock()
        observations = ObservationStore(paths: paths, fileSystem: fileSystem, lock: lock)
        events = BoundedJSONLineEventStore(
            url: paths.events,
            maximumCount: 5_000,
            fileSystem: fileSystem,
            lock: lock
        )
        consumer = ChromeInboxConsumer(
            paths: paths,
            observationStore: observations,
            eventStore: events,
            fileSystem: fileSystem
        )
        try fileSystem.ensurePrivateDirectory(root)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func makeConsumer() -> ChromeInboxConsumer {
        ChromeInboxConsumer(
            paths: paths,
            observationStore: observations,
            eventStore: events,
            fileSystem: fileSystem
        )
    }

    func record(eventID: UUID, generation: UInt64, title: String = "Audible tab") -> ChromeInboxRecord {
        ChromeInboxRecord(
            generation: generation,
            eventID: eventID,
            acceptedAt: Date(timeIntervalSince1970: 1_725_000_000),
            evidence: ChromeTabEvidence(
                sessionID: "session-1",
                windowID: 3,
                tabID: 7,
                index: 0,
                title: title,
                url: "https://example.com/watch?v=full-url",
                audible: true,
                muted: false,
                isActive: true,
                isPinned: false,
                isIncognito: false
            )
        )
    }

    func encoded(_ records: [ChromeInboxRecord]) throws -> Data {
        var data = Data()
        for record in records {
            data.append(try JSONEncoder().encode(record))
            data.append(0x0A)
        }
        return data
    }

    func appendRecord(_ record: ChromeInboxRecord) throws {
        try fileSystem.coordinatedAppend(try encoded([record]), to: paths.inbox)
        try fileSystem.syncFile(paths.inbox)
    }

    func replaceInbox(with records: [ChromeInboxRecord]) throws {
        try fileSystem.atomicWrite(try encoded(records), to: paths.inbox, permissions: Int16(0o600))
        try fileSystem.syncFile(paths.inbox)
        try fileSystem.syncDirectory(root)
    }
}

private func withConsumerFixture<T>(_ body: (ConsumerFixture) throws -> T) throws -> T {
    try body(ConsumerFixture())
}

@Test
func consumerDoesNotCommitHalfLine() throws {
    try withConsumerFixture { fixture in
        let record = fixture.record(eventID: UUID(), generation: 0)
        let encoded = try fixture.encoded([record])
        let prefixCount = encoded.count - 3
        try Data(encoded.prefix(prefixCount)).write(to: fixture.paths.inbox)

        let first = try fixture.consumer.consumeAvailable()
        #expect(first.records.isEmpty)
        #expect(first.committedOffset == 0)
        #expect(fixture.fileSystem.rangeReadOffsets == [0])

        try fixture.fileSystem.coordinatedAppend(Data(encoded.suffix(3)), to: fixture.paths.inbox)
        let second = try fixture.consumer.consumeAvailable()
        #expect(second.records == [record])
        #expect(second.committedOffset == UInt64(encoded.count))
        #expect(fixture.fileSystem.rangeReadOffsets.last == UInt64(prefixCount))
    }
}

@Test
func cursorCommitFailureReplaysWithoutTimelineDuplicateAfterRestart() throws {
    try withConsumerFixture { fixture in
        let record = fixture.record(eventID: UUID(), generation: 0)
        try fixture.appendRecord(record)
        fixture.fileSystem.failNextCursorWrite = true

        #expect(throws: ChromeConsumeError.cursorCommitFailure) {
            try fixture.consumer.consumeAvailable()
        }
        #expect(try fixture.events.recent(limit: 10).count == 1)

        let restarted = fixture.makeConsumer()
        #expect(try restarted.consumeAvailable().records.isEmpty)
        #expect(try fixture.events.recent(limit: 10).count == 1)
    }
}

@Test
func inboxReplacementResetsOffsetAndUsesEventIDIdempotency() throws {
    try withConsumerFixture { fixture in
        let old = fixture.record(eventID: UUID(), generation: 0, title: "old")
        try fixture.appendRecord(old)
        _ = try fixture.consumer.consumeAvailable()

        let new = fixture.record(eventID: UUID(), generation: 0, title: "new")
        try fixture.replaceInbox(with: [old, new])
        let batch = try fixture.consumer.consumeAvailable()

        #expect(batch.records == [new])
        #expect(try fixture.events.recent(limit: 10).map(\.observationEventID) == [old.eventID, new.eventID])
    }
}

@Test
func completeCorruptInboxRecordIsReported() throws {
    try withConsumerFixture { fixture in
        try Data("not-json\n".utf8).write(to: fixture.paths.inbox)

        #expect(throws: ChromeConsumeError.corruptRecord(line: 1)) {
            try fixture.consumer.consumeAvailable()
        }
    }
}

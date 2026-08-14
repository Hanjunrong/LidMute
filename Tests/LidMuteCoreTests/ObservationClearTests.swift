import Foundation
import Testing
@testable import LidMuteCore

private enum ClearTestError: Error {
    case injectedFailure
    case timeout
}

private final class TrackingObservationLock: ObservationLocking, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let stateLock = NSLock()
    private var _attemptCount = 0

    var attemptCount: Int {
        stateLock.withLock { _attemptCount }
    }

    func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        stateLock.withLock { _attemptCount += 1 }
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private final class ControllableClearFileSystem: ObservationFileSystem, @unchecked Sendable {
    private let base = POSIXObservationFileSystem()
    private let condition = NSCondition()
    private let paths: ObservationPaths
    private var pauseGenerationRead = false
    private var generationReadPaused = false
    private var resumeGenerationRead = false
    private var pauseCursorWrite = false
    private var cursorWritePaused = false
    private var resumeCursorWrite = false
    private var _generationReadCount = 0
    var failTruncationFor: Set<URL> = []

    init(paths: ObservationPaths) {
        self.paths = paths
    }

    var isGenerationReadPaused: Bool {
        condition.withLock { generationReadPaused }
    }

    var isCursorWritePaused: Bool {
        condition.withLock { cursorWritePaused }
    }

    var generationReadCount: Int {
        condition.withLock { _generationReadCount }
    }

    func pauseNextGenerationRead() {
        condition.withLock {
            pauseGenerationRead = true
            generationReadPaused = false
            resumeGenerationRead = false
        }
    }

    func resumePausedGenerationRead() {
        condition.withLock {
            resumeGenerationRead = true
            condition.broadcast()
        }
    }

    func pauseNextCursorCommit() {
        condition.withLock {
            pauseCursorWrite = true
            cursorWritePaused = false
            resumeCursorWrite = false
        }
    }

    func resumePausedCursorCommit() {
        condition.withLock {
            resumeCursorWrite = true
            condition.broadcast()
        }
    }

    func read(_ url: URL) throws -> Data {
        if url == paths.generation {
            condition.lock()
            _generationReadCount += 1
            if pauseGenerationRead {
                pauseGenerationRead = false
                generationReadPaused = true
                condition.broadcast()
                while !resumeGenerationRead { condition.wait() }
                generationReadPaused = false
            }
            condition.unlock()
        }
        return try base.read(url)
    }

    func read(_ url: URL, fromOffset offset: UInt64) throws -> Data {
        try base.read(url, fromOffset: offset)
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
        if url == paths.cursor {
            condition.lock()
            if pauseCursorWrite {
                pauseCursorWrite = false
                cursorWritePaused = true
                condition.broadcast()
                while !resumeCursorWrite { condition.wait() }
                cursorWritePaused = false
            }
            condition.unlock()
        }
        try base.atomicWrite(data, to: url, permissions: permissions)
    }

    func syncFile(_ url: URL) throws { try base.syncFile(url) }
    func syncDirectory(_ url: URL) throws { try base.syncDirectory(url) }
    func ensurePrivateDirectory(_ url: URL) throws { try base.ensurePrivateDirectory(url) }

    func truncate(_ url: URL) throws {
        if failTruncationFor.contains(url) { throw ClearTestError.injectedFailure }
        try base.truncate(url)
    }

    func removeIfPresent(_ url: URL) throws { try base.removeIfPresent(url) }
}

private final class ClearMemoryState: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [LidMuteEvent] = []
    private var _evidence: ChromeTabEvidence?

    var events: [LidMuteEvent] { lock.withLock { _events } }
    var evidence: ChromeTabEvidence? { lock.withLock { _evidence } }

    func seed(event: LidMuteEvent, evidence: ChromeTabEvidence) {
        lock.withLock {
            _events = [event]
            _evidence = evidence
        }
    }

    func reset() {
        lock.withLock {
            _events.removeAll()
            _evidence = nil
        }
    }
}

private final class ClearFixture: @unchecked Sendable {
    let root: URL
    let paths: ObservationPaths
    let fileSystem: ControllableClearFileSystem
    let sharedLock = TrackingObservationLock()
    let observations: ObservationStore
    let events: BoundedJSONLineEventStore
    let consumer: ChromeInboxConsumer
    let memory = ClearMemoryState()
    let originURL: URL
    let manifestURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "lidmute-clear-\(UUID().uuidString)", directoryHint: .isDirectory)
        paths = ObservationPaths(root: root)
        fileSystem = ControllableClearFileSystem(paths: paths)
        observations = ObservationStore(paths: paths, fileSystem: fileSystem, lock: sharedLock)
        events = BoundedJSONLineEventStore(
            url: paths.events,
            maximumCount: 5_000,
            fileSystem: fileSystem,
            lock: sharedLock
        )
        consumer = ChromeInboxConsumer(
            paths: paths,
            observationStore: observations,
            eventStore: events,
            fileSystem: fileSystem
        )
        originURL = root.appending(path: "chrome-origin.txt")
        manifestURL = root.appending(path: "native-messaging-manifest.json")
        try fileSystem.ensurePrivateDirectory(root)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func frame(eventID: UUID = UUID()) -> ChromeValidatedFrame {
        ChromeValidatedFrame(
            eventID: eventID,
            extensionSessionID: UUID(),
            evidence: ChromeTabEvidence(
                sessionID: "session",
                windowID: 1,
                tabID: 2,
                index: 0,
                title: "完整标题",
                url: "https://example.com/full/path?token=value",
                audible: true,
                muted: false,
                isActive: true,
                isPinned: false,
                isIncognito: false
            ),
            privacy: .persist
        )
    }
}

private func withClearFixture<T>(_ body: (ClearFixture) throws -> T) throws -> T {
    try body(ClearFixture())
}

private func eventually(_ predicate: @escaping @Sendable () -> Bool) async throws {
    for _ in 0..<400 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw ClearTestError.timeout
}

@Test
func clearAdvancesGenerationAndRemovesPersistedAndInMemoryEvidence() throws {
    try withClearFixture { fixture in
        let frame = fixture.frame()
        #expect(try fixture.observations.accept(frame) == .accepted(frame.eventID))
        _ = try fixture.consumer.consumeAvailable()
        fixture.memory.seed(
            event: try #require(fixture.events.recent(limit: 1).first),
            evidence: frame.evidence
        )

        let report = try fixture.observations.clearObservationData {
            fixture.consumer.resetInMemoryState()
            fixture.memory.reset()
        }

        #expect(report.oldGeneration == 0)
        #expect(report.newGeneration == 1)
        #expect(report.isComplete)
        #expect(try fixture.events.recent(limit: 5_000).isEmpty)
        #expect(try fixture.consumer.consumeAvailable().records.isEmpty)
        #expect(try fixture.observations.acceptedEventIDs().isEmpty)
        #expect(fixture.memory.events.isEmpty)
        #expect(fixture.memory.evidence == nil)
    }
}

@Test
func clearPreservesChromeRegistrationFiles() throws {
    try withClearFixture { fixture in
        let origin = "chrome-extension://abcdefghijklmnop/"
        try Data(origin.utf8).write(to: fixture.originURL)
        try Data("manifest".utf8).write(to: fixture.manifestURL)

        _ = try fixture.observations.clearObservationData(inMemoryReset: {})

        #expect(String(decoding: try Data(contentsOf: fixture.originURL), as: UTF8.self) == origin)
        #expect(String(decoding: try Data(contentsOf: fixture.manifestURL), as: UTF8.self) == "manifest")
    }
}

@Test
func partialClearFailureNamesUnclearedInbox() throws {
    try withClearFixture { fixture in
        fixture.fileSystem.failTruncationFor = [fixture.paths.inbox]

        let report = try fixture.observations.clearObservationData(inMemoryReset: {})

        #expect(report.failures == [.inbox])
        #expect(!report.isComplete)
        #expect(report.newGeneration == 1)
    }
}

@Test
func clearWaitsForAcceptInsideOldGenerationThenRemovesIt() async throws {
    let fixture = try ClearFixture()
    let frame = fixture.frame()
    fixture.fileSystem.pauseNextGenerationRead()
    let acceptance = Task.detached { try fixture.observations.accept(frame) }
    try await eventually { fixture.fileSystem.isGenerationReadPaused }

    let attemptsBeforeClear = fixture.sharedLock.attemptCount
    let clear = Task.detached {
        try fixture.observations.clearObservationData(inMemoryReset: {})
    }
    try await eventually { fixture.sharedLock.attemptCount > attemptsBeforeClear }
    #expect(fixture.fileSystem.generationReadCount == 1)

    fixture.fileSystem.resumePausedGenerationRead()
    #expect(try await acceptance.value == .accepted(frame.eventID))
    #expect(try await clear.value.newGeneration == 1)
    #expect(try fixture.consumer.consumeAvailable().records.isEmpty)
    #expect(try fixture.events.recent(limit: 5_000).isEmpty)
}

@Test
func clearWaitsForConsumeBetweenEventAppendAndCursorCommit() async throws {
    let fixture = try ClearFixture()
    let frame = fixture.frame()
    _ = try fixture.observations.accept(frame)
    fixture.fileSystem.pauseNextCursorCommit()
    let consume = Task.detached { try fixture.consumer.consumeAvailable() }
    try await eventually { fixture.fileSystem.isCursorWritePaused }
    #expect(!(try fixture.fileSystem.read(fixture.paths.events)).isEmpty)

    let generationReadsBeforeClear = fixture.fileSystem.generationReadCount
    let attemptsBeforeClear = fixture.sharedLock.attemptCount
    let clear = Task.detached {
        try fixture.observations.clearObservationData {
            fixture.consumer.resetInMemoryState()
            fixture.memory.reset()
        }
    }
    try await eventually { fixture.sharedLock.attemptCount > attemptsBeforeClear }
    #expect(fixture.fileSystem.generationReadCount == generationReadsBeforeClear)

    fixture.fileSystem.resumePausedCursorCommit()
    _ = try await consume.value
    #expect(try await clear.value.newGeneration == 1)
    #expect(try fixture.events.recent(limit: 5_000).isEmpty)
    #expect(try fixture.consumer.consumeAvailable().records.isEmpty)
}

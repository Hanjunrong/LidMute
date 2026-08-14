import Foundation
import Testing
@testable import LidMuteApp
@testable import LidMuteCore

private final class CountingEventStore: EventStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [LidMuteEvent]
    private var _recentCallCount = 0

    init(events: [LidMuteEvent] = []) {
        storedEvents = events
    }

    var recentCallCount: Int { lock.withLock { _recentCallCount } }

    func append(_ event: LidMuteEvent) throws {
        lock.withLock { storedEvents.append(event) }
    }

    func load() throws -> [LidMuteEvent] {
        lock.withLock { storedEvents }
    }

    func recent(limit: Int) throws -> [LidMuteEvent] {
        lock.withLock {
            _recentCallCount += 1
            return Array(storedEvents.suffix(limit))
        }
    }

    func clear() throws {
        lock.withLock { storedEvents.removeAll() }
    }
}

private final class CountingInboxConsumer: ChromeInboxConsuming, @unchecked Sendable {
    private let lock = NSLock()
    private var nextRecords: [ChromeInboxRecord]
    private var _consumeCount = 0
    private var _resetCount = 0

    init(records: [ChromeInboxRecord] = []) {
        nextRecords = records
    }

    var consumeCount: Int { lock.withLock { _consumeCount } }
    var resetCount: Int { lock.withLock { _resetCount } }

    func consumeAvailable() throws -> ChromeConsumeBatch {
        lock.withLock {
            _consumeCount += 1
            let records = nextRecords
            nextRecords = []
            return ChromeConsumeBatch(records: records, committedOffset: 0, health: .healthy)
        }
    }

    func resetInMemoryState() {
        lock.withLock { _resetCount += 1 }
    }
}

private final class PausingInboxConsumer: ChromeInboxConsuming, @unchecked Sendable {
    private let condition = NSCondition()
    private let record: ChromeInboxRecord
    private var waiting = false
    private var resumed = false

    init(record: ChromeInboxRecord) {
        self.record = record
    }

    var isWaiting: Bool { condition.withLock { waiting } }

    func consumeAvailable() throws -> ChromeConsumeBatch {
        condition.lock()
        waiting = true
        condition.broadcast()
        let deadline = Date().addingTimeInterval(0.25)
        while !resumed, condition.wait(until: deadline) {}
        waiting = false
        condition.unlock()
        return ChromeConsumeBatch(records: [record], committedOffset: 0, health: .healthy)
    }

    func resume() {
        condition.withLock {
            resumed = true
            condition.broadcast()
        }
    }

    func resetInMemoryState() {}
}

private final class RecordingObservationClearer: ObservationClearing, @unchecked Sendable {
    private let report: ObservationClearReport
    private let lock = NSLock()
    private var _clearCount = 0

    init(failures: [ObservationClearCategory] = []) {
        report = ObservationClearReport(oldGeneration: 0, newGeneration: 1, failures: failures)
    }

    var clearCount: Int { lock.withLock { _clearCount } }

    func clearObservationData(inMemoryReset: () throws -> Void) throws -> ObservationClearReport {
        lock.withLock { _clearCount += 1 }
        try inMemoryReset()
        return report
    }
}

private actor AppPausingRouteProtectionApplying: SpeakerProtectionApplying {
    private var shouldPauseRoute = false
    private var routeStarted = false
    private var routeContinuation: CheckedContinuation<Void, Never>?
    private var routeCount = 0

    func pauseNextRouteChange() {
        shouldPauseRoute = true
        routeStarted = false
    }

    func apply(_ action: SpeakerProtectionAction) async -> SpeakerRecoveryOutcome {
        if case .routeChangedWhileProtectionRequired = action {
            routeCount += 1
            if shouldPauseRoute {
                shouldPauseRoute = false
                routeStarted = true
                await withCheckedContinuation { routeContinuation = $0 }
            }
        }
        return action == .end ? .restored : .noPendingRecovery
    }

    func waitUntilRouteChangeStarts() async {
        while !routeStarted { await Task.yield() }
    }

    func resumeRouteChange() {
        let continuation = routeContinuation
        routeContinuation = nil
        continuation?.resume()
    }

    func routeChangeCount() -> Int { routeCount }
}

private final class AppPipelineEventStore: EventStoring, ObservationClearing, @unchecked Sendable {
    private let condition = NSCondition()
    private var events: [LidMuteEvent] = []
    private var pauseKind: LidMuteEventKind?
    private var appendPaused = false
    private var resumeAppend = false
    private var clearCount = 0

    var isAppendPaused: Bool { condition.withLock { appendPaused } }
    var observationClearCount: Int { condition.withLock { clearCount } }

    func pauseNextAppend(of kind: LidMuteEventKind) {
        condition.withLock {
            pauseKind = kind
            appendPaused = false
            resumeAppend = false
        }
    }

    func append(_ event: LidMuteEvent) throws {
        condition.lock()
        events.append(event)
        if pauseKind == event.kind {
            pauseKind = nil
            appendPaused = true
            condition.broadcast()
            let deadline = Date().addingTimeInterval(0.5)
            while !resumeAppend, condition.wait(until: deadline) {}
            appendPaused = false
        }
        condition.unlock()
    }

    func load() throws -> [LidMuteEvent] {
        condition.withLock { events }
    }

    func clear() throws {
        condition.withLock { events.removeAll() }
    }

    func clearObservationData(inMemoryReset: () throws -> Void) throws -> ObservationClearReport {
        condition.withLock {
            clearCount += 1
            events.removeAll()
        }
        try inMemoryReset()
        return ObservationClearReport(oldGeneration: 0, newGeneration: 1, failures: [])
    }

    func resumePausedAppend() {
        condition.withLock {
            resumeAppend = true
            condition.broadcast()
        }
    }
}

@MainActor
private final class PausingChromeEvidenceCoordinator: ObservationPipelineCoordinating {
    private(set) var receiveCount = 0
    private(set) var flushCount = 0
    private(set) var firstDeliveryStarted = false
    private var firstDeliveryContinuation: CheckedContinuation<Void, Never>?

    func receiveChromeEvidence(_ evidence: ChromeTabEvidence) async {
        receiveCount += 1
        guard receiveCount == 1 else { return }
        firstDeliveryStarted = true
        await withCheckedContinuation { firstDeliveryContinuation = $0 }
    }

    func receiveAudioRouteChanged() async {}

    func flushObservationLogging() async {
        flushCount += 1
    }

    func resumeFirstDelivery() {
        let continuation = firstDeliveryContinuation
        firstDeliveryContinuation = nil
        continuation?.resume()
    }

}

@MainActor
private final class MutableLifecycleState: LifecycleStateProviding {
    var state: AppLifecycleState

    init(_ state: AppLifecycleState) {
        self.state = state
    }

    func receiveAudioRouteChanged() async {}
}

@MainActor
private final class AppViewModelHarness {
    let root: URL
    let store: CountingEventStore
    let consumer: CountingInboxConsumer
    let clearer: RecordingObservationClearer
    let lifecycle: MutableLifecycleState
    let model: AppViewModel
    let registeredExtensionID = "abcdefghijklmnop"

    init(
        lifecycle state: AppLifecycleState,
        events: [LidMuteEvent] = [],
        records: [ChromeInboxRecord] = [],
        clearFailures: [ObservationClearCategory] = [],
        inboxConsumer: (any ChromeInboxConsuming)? = nil,
        observationPipelineCoordinator: (any ObservationPipelineCoordinating)? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "lidmute-app-observation-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifestURL = root.appending(path: "com.lidmute.nativehost.json")
        try Data("{}".utf8).write(to: manifestURL)
        try Data("chrome-extension://\(registeredExtensionID)/".utf8)
            .write(to: root.appending(path: "chrome-origin.txt"))

        store = CountingEventStore(events: events)
        consumer = CountingInboxConsumer(records: records)
        clearer = RecordingObservationClearer(failures: clearFailures)
        lifecycle = MutableLifecycleState(state)
        model = AppViewModel(
            applicationSupport: root,
            eventStore: store,
            inboxConsumer: inboxConsumer ?? consumer,
            observationStore: clearer,
            lifecycle: lifecycle,
            chromeManifestURL: manifestURL,
            observationPipelineCoordinator: observationPipelineCoordinator
        )
        model.chromeExtensionId = registeredExtensionID
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private func appEvent(_ sequence: UInt64, chromeTab: ChromeTabEvidence? = nil) -> LidMuteEvent {
    LidMuteEvent(
        timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
        sequence: sequence,
        kind: chromeTab == nil ? .muteEnforced : .chromeTabAudible,
        detail: "event-\(sequence)",
        observationEventID: chromeTab == nil ? nil : UUID(),
        chromeTab: chromeTab,
        correlation: chromeTab == nil ? .notApplicable : .browserObservedOnly
    )
}

private func appRecord() -> ChromeInboxRecord {
    ChromeInboxRecord(
        generation: 0,
        eventID: UUID(),
        acceptedAt: Date(timeIntervalSince1970: 1_725_000_000),
        evidence: ChromeTabEvidence(
            sessionID: "session",
            windowID: 1,
            tabID: 2,
            index: 0,
            title: "Chrome tab",
            url: "https://example.com/full/path?key=value",
            audible: true,
            muted: false,
            isActive: true,
            isPinned: false,
            isIncognito: false
        )
    )
}

@MainActor
@Test
func chromeConsumptionWaitsForReadyLifecycle() async throws {
    let harness = try AppViewModelHarness(lifecycle: .recovering)

    await harness.model.pollChromeInbox()
    #expect(harness.consumer.consumeCount == 0)

    harness.lifecycle.state = .ready
    await harness.model.pollChromeInbox()
    #expect(harness.consumer.consumeCount == 1)
}

@MainActor
@Test
func chromeConsumptionRunsOffMainActorAndPublishesOnlyAfterCompletion() async throws {
    let record = appRecord()
    let consumer = PausingInboxConsumer(record: record)
    let harness = try AppViewModelHarness(
        lifecycle: .ready,
        inboxConsumer: consumer
    )

    let poll = Task { @MainActor in await harness.model.pollChromeInbox() }
    for _ in 0..<100 where !consumer.isWaiting {
        await Task.yield()
    }

    #expect(consumer.isWaiting)
    var mainActorProbeRan = false
    await Task { @MainActor in mainActorProbeRan = true }.value
    #expect(mainActorProbeRan)
    #expect(harness.model.events.isEmpty)

    consumer.resume()
    await poll.value
    #expect(harness.model.events.first?.observationEventID == record.eventID)
}

@MainActor
@Test
func eventCallbackAppendsWithoutReloadingHistory() throws {
    let harness = try AppViewModelHarness(lifecycle: .ready)
    #expect(harness.store.recentCallCount == 1)

    harness.model.receiveCoordinatorEvent(appEvent(7))

    #expect(harness.model.events.first?.sequence == 7)
    #expect(harness.store.recentCallCount == 1)
}

@MainActor
@Test
func cursorRetryBatchRecordIsDeliveredToLiveAppPresentation() async throws {
    let record = appRecord()
    let harness = try AppViewModelHarness(lifecycle: .ready, records: [record])

    await harness.model.pollChromeInbox()

    #expect(harness.model.events.first?.observationEventID == record.eventID)
    #expect(harness.model.events.first?.chromeTab?.url == record.evidence.url)
}

@MainActor
@Test
func incrementalEventInsertionRetainsOnlyNewestFiveThousand() throws {
    let existing = (0..<5_000).map { appEvent(UInt64($0)) }
    let harness = try AppViewModelHarness(lifecycle: .ready, events: existing)

    harness.model.receiveCoordinatorEvent(appEvent(5_000))

    #expect(harness.model.events.count == 5_000)
    #expect(harness.model.events.first?.sequence == 5_000)
    #expect(harness.model.events.last?.sequence == 1)
}

@MainActor
@Test
func clearRemovesChromePresentationButKeepsRegistration() async throws {
    let record = appRecord()
    let harness = try AppViewModelHarness(
        lifecycle: .ready,
        events: [appEvent(1, chromeTab: record.evidence)],
        records: [record]
    )
    await harness.model.pollChromeInbox()
    #expect(harness.model.chromeBridgeStatus == "已接收 Chrome 标签页事件")

    await harness.model.clearObservationData()

    #expect(harness.model.events.isEmpty)
    #expect(harness.model.currentAudioSources.allSatisfy { $0.chromeTab == nil })
    #expect(harness.model.chromeBridgeStatus == "等待 Chrome 扩展连接")
    #expect(harness.model.chromeExtensionId == harness.registeredExtensionID)
    #expect(harness.consumer.resetCount == 1)
    #expect(harness.clearer.clearCount == 1)
}

@MainActor
@Test
func clearInvalidatesQueuedChromeDeliveryAndWaitsForInFlightDelivery() async throws {
    let firstRecord = appRecord()
    let secondRecord = appRecord()
    let chromeCoordinator = PausingChromeEvidenceCoordinator()
    let harness = try AppViewModelHarness(
        lifecycle: .ready,
        records: [firstRecord, secondRecord],
        observationPipelineCoordinator: chromeCoordinator
    )
    await harness.model.pollChromeInbox()
    for _ in 0..<100 where !chromeCoordinator.firstDeliveryStarted {
        await Task.yield()
    }
    #expect(chromeCoordinator.firstDeliveryStarted)
    #expect(harness.model.events.count == 2)

    let clear = Task { @MainActor in await harness.model.clearObservationData() }
    for _ in 0..<100 where !harness.model.isClearingObservationData {
        await Task.yield()
    }
    #expect(harness.model.isClearingObservationData)

    chromeCoordinator.resumeFirstDelivery()
    await clear.value

    #expect(chromeCoordinator.receiveCount == 1)
    #expect(chromeCoordinator.flushCount == 1)
    #expect(harness.model.events.isEmpty)
    #expect(harness.model.currentAudioSources.allSatisfy { $0.chromeTab == nil })
}

@MainActor
@Test
func clearWaitsForInFlightRouteProducerAndRejectsRouteDuringClear() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "lidmute-app-route-clear-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifestURL = root.appending(path: "com.lidmute.nativehost.json")
    try Data("{}".utf8).write(to: manifestURL)

    let record = appRecord()
    let protection = AppPausingRouteProtectionApplying()
    let store = AppPipelineEventStore()
    let pipeline = ProtectionCoordinator(
        protection: protection,
        processEvidence: ScriptedAudioController(),
        store: store
    )
    await pipeline.setEnabled(true)
    await pipeline.receivePhysicalLid(closed: true)
    await pipeline.flushObservationLogging()
    try store.clear()

    let lifecycle = MutableLifecycleState(.ready)
    let consumer = CountingInboxConsumer(records: [record])
    let model = AppViewModel(
        applicationSupport: root,
        eventStore: store,
        inboxConsumer: consumer,
        observationStore: store,
        lifecycle: lifecycle,
        chromeManifestURL: manifestURL,
        observationPipelineCoordinator: pipeline
    )
    pipeline.onEvent = { event in model.receiveCoordinatorEvent(event) }
    await model.pollChromeInbox()
    for _ in 0..<100 {
        if try store.load().contains(where: { $0.kind == .chromeTabAudible }) { break }
        await Task.yield()
    }
    await pipeline.flushObservationLogging()
    #expect(model.chromeBridgeStatus == "已接收 Chrome 标签页事件")

    store.pauseNextAppend(of: .muteEnforced)
    await protection.pauseNextRouteChange()
    model.receiveAudioRouteChanged()
    await protection.waitUntilRouteChangeStarts()

    let clear = Task { @MainActor in await model.clearObservationData() }
    for _ in 0..<100 where !model.isClearingObservationData { await Task.yield() }
    for _ in 0..<20 { await Task.yield() }
    #expect(store.observationClearCount == 0)

    model.receiveAudioRouteChanged()
    await protection.resumeRouteChange()
    for _ in 0..<100 where !store.isAppendPaused {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(store.isAppendPaused)
    #expect(store.observationClearCount == 0)

    store.resumePausedAppend()
    await clear.value

    #expect(await protection.routeChangeCount() == 1)
    #expect(store.observationClearCount == 1)
    #expect(try store.load().isEmpty)
    #expect(model.events.isEmpty)
    #expect(model.currentAudioSources.allSatisfy { $0.chromeTab == nil })
    #expect(model.chromeBridgeStatus == "等待 Chrome 扩展连接")
}

@MainActor
@Test
func partialClearFailureIsPresentedExplicitly() async throws {
    let harness = try AppViewModelHarness(
        lifecycle: .ready,
        clearFailures: [.inbox, .cursor]
    )

    await harness.model.clearObservationData()

    #expect(harness.model.storageStatusText == "部分数据未清空：inbox、cursor")
}

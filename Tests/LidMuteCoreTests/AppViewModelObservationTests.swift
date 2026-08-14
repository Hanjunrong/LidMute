import Foundation
import Testing
@testable import LidMuteApp
@testable import LidMuteCore

private enum AppObservationClearTestError: Error {
    case injectedFailure
}

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

private final class RecoveringAppEventStore: EventStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var nextError: EventStoreError? = .permissionFailure
    private var events: [LidMuteEvent] = []

    func append(_ event: LidMuteEvent) throws {
        try lock.withLock {
            if let error = nextError {
                nextError = nil
                throw error
            }
            events.append(event)
        }
    }

    func load() throws -> [LidMuteEvent] { lock.withLock { events } }
    func recent(limit: Int) throws -> [LidMuteEvent] {
        lock.withLock { Array(events.suffix(limit)) }
    }
    func clear() throws { lock.withLock { events.removeAll() } }
}

private final class StartupFailingEventStore: EventStoring, @unchecked Sendable {
    func append(_: LidMuteEvent) throws {}
    func load() throws -> [LidMuteEvent] { [] }
    func recent(limit _: Int) throws -> [LidMuteEvent] {
        throw EventStoreError.permissionFailure
    }
    func clear() throws {}
}

private final class CountingInboxConsumer: ChromeInboxConsuming, @unchecked Sendable {
    private let lock = NSLock()
    private var nextRecords: [ChromeInboxRecord]
    private var _consumeCount = 0
    private var _resetCount = 0
    private var _acknowledgedDeliveryIDs: [UUID] = []
    private let deliveryID: UUID?

    init(records: [ChromeInboxRecord] = [], deliveryID: UUID? = nil) {
        nextRecords = records
        self.deliveryID = deliveryID ?? (records.isEmpty ? nil : UUID())
    }

    var consumeCount: Int { lock.withLock { _consumeCount } }
    var resetCount: Int { lock.withLock { _resetCount } }
    var acknowledgedDeliveryIDs: [UUID] { lock.withLock { _acknowledgedDeliveryIDs } }

    func consumeAvailable() throws -> ChromeConsumeBatch {
        lock.withLock {
            _consumeCount += 1
            let records = nextRecords
            nextRecords = []
            return ChromeConsumeBatch(
                records: records,
                deliveryID: records.isEmpty ? nil : deliveryID,
                committedOffset: 0,
                health: .healthy
            )
        }
    }

    func acknowledgeDelivery(_ deliveryID: UUID) throws {
        lock.withLock { _acknowledgedDeliveryIDs.append(deliveryID) }
    }

    func resetInMemoryState() {
        lock.withLock { _resetCount += 1 }
    }
}

private final class ReplayUntilAcknowledgedInboxConsumer: ChromeInboxConsuming, @unchecked Sendable {
    private let lock = NSLock()
    private let batch: ChromeConsumeBatch
    private var isAcknowledged = false
    private var _consumeCount = 0
    private var _acknowledgedDeliveryIDs: [UUID] = []

    init(record: ChromeInboxRecord, deliveryID: UUID) {
        batch = ChromeConsumeBatch(
            records: [record],
            deliveryID: deliveryID,
            committedOffset: 0,
            health: .healthy
        )
    }

    var consumeCount: Int { lock.withLock { _consumeCount } }
    var acknowledgedDeliveryIDs: [UUID] { lock.withLock { _acknowledgedDeliveryIDs } }

    func consumeAvailable() throws -> ChromeConsumeBatch {
        lock.withLock {
            _consumeCount += 1
            return isAcknowledged
                ? ChromeConsumeBatch(records: [], deliveryID: nil, committedOffset: 0, health: .healthy)
                : batch
        }
    }

    func acknowledgeDelivery(_ deliveryID: UUID) throws {
        lock.withLock {
            isAcknowledged = true
            _acknowledgedDeliveryIDs.append(deliveryID)
        }
    }

    func resetInMemoryState() {}
}

private enum ScriptedConsumeOutcome {
    case batch(ChromeConsumeBatch)
    case failure(ChromeConsumeError)
}

private enum ScriptedAcknowledgeOutcome {
    case success
    case failure(ChromeConsumeError)
}

private final class ScriptedHealthInboxConsumer: ChromeInboxConsuming, @unchecked Sendable {
    private let lock = NSLock()
    private var consumeOutcomes: [ScriptedConsumeOutcome]
    private var acknowledgeOutcomes: [ScriptedAcknowledgeOutcome]

    init(
        consumeOutcomes: [ScriptedConsumeOutcome],
        acknowledgeOutcomes: [ScriptedAcknowledgeOutcome]
    ) {
        self.consumeOutcomes = consumeOutcomes
        self.acknowledgeOutcomes = acknowledgeOutcomes
    }

    func consumeAvailable() throws -> ChromeConsumeBatch {
        let outcome = lock.withLock { consumeOutcomes.removeFirst() }
        switch outcome {
        case let .batch(batch):
            return batch
        case let .failure(error):
            throw error
        }
    }

    func acknowledgeDelivery(_: UUID) throws {
        let outcome = lock.withLock { acknowledgeOutcomes.removeFirst() }
        if case let .failure(error) = outcome {
            throw error
        }
    }

    func resetInMemoryState() {}
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
        return ChromeConsumeBatch(
            records: [record],
            deliveryID: UUID(),
            committedOffset: 0,
            health: .healthy
        )
    }

    func acknowledgeDelivery(_: UUID) throws {}

    func resume() {
        condition.withLock {
            resumed = true
            condition.broadcast()
        }
    }

    func resetInMemoryState() {}
}

private final class RecordingObservationClearer: ObservationClearing, @unchecked Sendable {
    private let lock = NSLock()
    private var _clearCount = 0
    private var failures: [ObservationClearCategory]

    init(failures: [ObservationClearCategory] = []) {
        self.failures = failures
    }

    var clearCount: Int { lock.withLock { _clearCount } }

    func clearObservationData(inMemoryReset: () throws -> Void) throws -> ObservationClearReport {
        let currentFailures = lock.withLock {
            _clearCount += 1
            return failures
        }
        try inMemoryReset()
        return ObservationClearReport(
            oldGeneration: 0,
            newGeneration: 1,
            failures: currentFailures
        )
    }

    func setFailures(_ failures: [ObservationClearCategory]) {
        lock.withLock { self.failures = failures }
    }
}

private actor AppPausingRouteProtectionApplying: SpeakerProtectionApplying {
    private let timeline: SharedOperationTimeline
    private var shouldPauseRoute = false
    private var routeStarted = false
    private var routeContinuation: CheckedContinuation<Void, Never>?
    private var routeCount = 0
    private var beginCount = 0

    init(timeline: SharedOperationTimeline = SharedOperationTimeline()) {
        self.timeline = timeline
    }

    func pauseNextRouteChange() {
        shouldPauseRoute = true
        routeStarted = false
    }

    func apply(_ action: SpeakerProtectionAction) async -> SpeakerRecoveryOutcome {
        if case .begin = action {
            beginCount += 1
            timeline.append("protection.begin")
        }
        if case .routeChangedWhileProtectionRequired = action {
            routeCount += 1
            timeline.append("protection.route")
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
    func beginActionCount() -> Int { beginCount }
}

private final class AppPipelineEventStore: EventStoring, ObservationClearing, @unchecked Sendable {
    private let condition = NSCondition()
    private let timeline: SharedOperationTimeline
    private var events: [LidMuteEvent] = []
    private var pauseKind: LidMuteEventKind?
    private var appendPaused = false
    private var resumeAppend = false
    private var clearCount = 0
    private var pauseClear = false
    private var clearPaused = false
    private var clearReleased = false
    private var failClear = false

    init(timeline: SharedOperationTimeline = SharedOperationTimeline()) {
        self.timeline = timeline
    }

    var isAppendPaused: Bool { condition.withLock { appendPaused } }
    var observationClearCount: Int { condition.withLock { clearCount } }
    var isClearPaused: Bool { condition.withLock { clearPaused } }
    var hasClearReleased: Bool { condition.withLock { clearReleased } }

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
        condition.lock()
        clearCount += 1
        timeline.append("clear.started")
        if pauseClear {
            pauseClear = false
            clearPaused = true
            condition.broadcast()
            let deadline = Date().addingTimeInterval(0.2)
            while !clearReleased, condition.wait(until: deadline) {}
            clearPaused = false
        }
        clearReleased = true
        timeline.append("clear.released")
        let shouldFail = failClear
        failClear = false
        if shouldFail {
            condition.unlock()
            throw AppObservationClearTestError.injectedFailure
        }
        events.removeAll()
        condition.unlock()
        try inMemoryReset()
        return ObservationClearReport(oldGeneration: 0, newGeneration: 1, failures: [])
    }

    func pauseNextClear() {
        condition.withLock {
            pauseClear = true
            clearPaused = false
            clearReleased = false
        }
    }

    func resumePausedClear() {
        condition.withLock {
            clearReleased = true
            condition.broadcast()
        }
    }

    func failNextClear() {
        condition.withLock { failClear = true }
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

    func ensureProtected(for evidence: ChromeTabEvidence) async -> ChromeSafetyDeliveryResult {
        receiveCount += 1
        guard receiveCount == 1 else { return .protected }
        firstDeliveryStarted = true
        await withCheckedContinuation { firstDeliveryContinuation = $0 }
        return .protected
    }

    func receiveAudioRouteChanged() async {}

    func receivePhysicalLid(closed _: Bool) async {}

    func flushObservationLogging() async {
        flushCount += 1
    }

    func beginObservationClear() async -> ObservationClearBoundary {
        flushCount += 1
        return ObservationClearBoundary(generation: 0)
    }

    func endObservationClear(_: ObservationClearBoundary, report _: ObservationClearReport?) {}

    func resumeFirstDelivery() {
        let continuation = firstDeliveryContinuation
        firstDeliveryContinuation = nil
        continuation?.resume()
    }

}

@MainActor
private final class OutcomeChromeEvidenceCoordinator: ObservationPipelineCoordinating {
    private var results: [ChromeSafetyDeliveryResult]
    private(set) var receiveCount = 0
    private(set) var endedClearReports: [ObservationClearReport?] = []

    init(result: ChromeSafetyDeliveryResult) {
        results = [result]
    }

    init(results: [ChromeSafetyDeliveryResult]) {
        self.results = results
    }

    func ensureProtected(for _: ChromeTabEvidence) async -> ChromeSafetyDeliveryResult {
        receiveCount += 1
        return results.count > 1 ? results.removeFirst() : results[0]
    }

    func receiveAudioRouteChanged() async {}
    func receivePhysicalLid(closed _: Bool) async {}
    func flushObservationLogging() async {}
    func beginObservationClear() async -> ObservationClearBoundary {
        ObservationClearBoundary(generation: 0)
    }
    func endObservationClear(_: ObservationClearBoundary, report: ObservationClearReport?) {
        endedClearReports.append(report)
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
        deliveryID: UUID? = nil,
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
        consumer = CountingInboxConsumer(records: records, deliveryID: deliveryID)
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
func clearStartsChromePollingWhenLifecycleBecomesReadyDuringClear() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "lidmute-app-clear-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifestURL = root.appending(path: "com.lidmute.nativehost.json")
    try Data("{}".utf8).write(to: manifestURL)

    let store = AppPipelineEventStore()
    let consumer = CountingInboxConsumer()
    let lifecycle = MutableLifecycleState(.recovering)
    let model = AppViewModel(
        applicationSupport: root,
        eventStore: store,
        inboxConsumer: consumer,
        observationStore: store,
        lifecycle: lifecycle,
        chromeManifestURL: manifestURL
    )

    store.pauseNextClear()
    let clear = Task { @MainActor in await model.clearObservationData() }
    for _ in 0..<100 where !store.isClearPaused { await Task.yield() }
    #expect(store.isClearPaused)
    #expect(consumer.consumeCount == 0)

    lifecycle.state = .ready
    model.receiveAudioRouteChanged()
    for _ in 0..<100 where model.lifecycleState != .ready { await Task.yield() }
    #expect(model.lifecycleState == .ready)
    #expect(consumer.consumeCount == 0)

    store.resumePausedClear()
    await clear.value
    for _ in 0..<100 where consumer.consumeCount == 0 { await Task.yield() }

    #expect(consumer.consumeCount == 1)
    model.stopAll()
}

@MainActor
@Test
func clearDoesNotStartChromePollingWhileLifecycleRemainsRecovering() async throws {
    let harness = try AppViewModelHarness(lifecycle: .recovering)

    await harness.model.clearObservationData()
    for _ in 0..<100 { await Task.yield() }

    #expect(harness.consumer.consumeCount == 0)
}

@MainActor
@Test
func clearDoesNotStartChromePollingAfterShutdown() async throws {
    let harness = try AppViewModelHarness(lifecycle: .ready)

    _ = await harness.model.shutdownAndRestore()
    await harness.model.clearObservationData()
    for _ in 0..<100 { await Task.yield() }

    #expect(harness.consumer.consumeCount == 0)
}

@MainActor
@Test
func repeatedReadyRouteChangesKeepOneChromePollingTimer() async throws {
    let harness = try AppViewModelHarness(lifecycle: .ready)

    harness.model.receiveAudioRouteChanged()
    for _ in 0..<100 where harness.consumer.consumeCount == 0 { await Task.yield() }
    #expect(harness.consumer.consumeCount == 1)

    harness.model.receiveAudioRouteChanged()
    harness.model.receiveAudioRouteChanged()
    for _ in 0..<100 { await Task.yield() }

    #expect(harness.consumer.consumeCount == 1)
    harness.model.stopAll()
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
func successfulChromeSafetyAcknowledgesDurablePendingDelivery() async throws {
    let record = appRecord()
    let deliveryID = UUID()
    let coordinator = OutcomeChromeEvidenceCoordinator(result: .protected)
    let harness = try AppViewModelHarness(
        lifecycle: .ready,
        records: [record],
        deliveryID: deliveryID,
        observationPipelineCoordinator: coordinator
    )

    await harness.model.pollChromeInbox()
    for _ in 0..<100 where harness.consumer.acknowledgedDeliveryIDs.isEmpty {
        await Task.yield()
    }

    #expect(coordinator.receiveCount == 1)
    #expect(harness.consumer.acknowledgedDeliveryIDs == [deliveryID])
}

@MainActor
@Test
func unsafeChromeOutcomeLeavesPendingDeliveryForRetry() async throws {
    let record = appRecord()
    let deliveryID = UUID()
    let coordinator = OutcomeChromeEvidenceCoordinator(result: .unsafe)
    let harness = try AppViewModelHarness(
        lifecycle: .ready,
        records: [record],
        deliveryID: deliveryID,
        observationPipelineCoordinator: coordinator
    )

    await harness.model.pollChromeInbox()
    for _ in 0..<100 where coordinator.receiveCount == 0 { await Task.yield() }
    for _ in 0..<20 { await Task.yield() }

    #expect(coordinator.receiveCount == 1)
    #expect(harness.consumer.acknowledgedDeliveryIDs.isEmpty)
}

@MainActor
@Test
func unsafeChromeSafetyDeliveryIsRetriedUntilProtectionIsVerified() async throws {
    let record = appRecord()
    let deliveryID = UUID()
    let consumer = ReplayUntilAcknowledgedInboxConsumer(record: record, deliveryID: deliveryID)
    let coordinator = OutcomeChromeEvidenceCoordinator(results: [.unsafe, .protected])
    let harness = try AppViewModelHarness(
        lifecycle: .ready,
        inboxConsumer: consumer,
        observationPipelineCoordinator: coordinator
    )

    await harness.model.pollChromeInbox()
    for _ in 0..<100 where coordinator.receiveCount < 1 { await Task.yield() }

    #expect(consumer.consumeCount == 1)
    #expect(coordinator.receiveCount == 1)
    #expect(consumer.acknowledgedDeliveryIDs.isEmpty)

    await harness.model.pollChromeInbox()
    for _ in 0..<100 where coordinator.receiveCount < 2 { await Task.yield() }
    for _ in 0..<100 where consumer.acknowledgedDeliveryIDs.isEmpty { await Task.yield() }

    #expect(consumer.consumeCount == 2)
    #expect(coordinator.receiveCount == 2)
    #expect(consumer.acknowledgedDeliveryIDs == [deliveryID])
}

@MainActor
@Test
func chromePollSingleFlightCoversSafetyDeliveryAndDurableAcknowledgement() async throws {
    let record = appRecord()
    let deliveryID = UUID()
    let consumer = ReplayUntilAcknowledgedInboxConsumer(record: record, deliveryID: deliveryID)
    let coordinator = PausingChromeEvidenceCoordinator()
    let harness = try AppViewModelHarness(
        lifecycle: .ready,
        inboxConsumer: consumer,
        observationPipelineCoordinator: coordinator
    )

    let firstPoll = Task { @MainActor in await harness.model.pollChromeInbox() }
    for _ in 0..<100 where !coordinator.firstDeliveryStarted { await Task.yield() }
    #expect(coordinator.firstDeliveryStarted)

    try await Task.sleep(for: .milliseconds(700))
    await harness.model.pollChromeInbox()

    #expect(consumer.consumeCount == 1)
    #expect(coordinator.receiveCount == 1)
    #expect(consumer.acknowledgedDeliveryIDs.isEmpty)

    coordinator.resumeFirstDelivery()
    await firstPoll.value

    #expect(consumer.acknowledgedDeliveryIDs == [deliveryID])
}

@MainActor
@Test
func replayedPendingDeliveryDoesNotDuplicatePersistedChromeTimelinePresentation() async throws {
    let record = appRecord()
    let persisted = LidMuteEvent(
        timestamp: record.acceptedAt,
        kind: .chromeTabAudible,
        detail: "persisted",
        observationEventID: record.eventID,
        chromeTab: record.evidence,
        correlation: .browserObservedOnly
    )
    let harness = try AppViewModelHarness(
        lifecycle: .ready,
        events: [persisted],
        records: [record],
        deliveryID: UUID(),
        observationPipelineCoordinator: OutcomeChromeEvidenceCoordinator(result: .protected)
    )

    await harness.model.pollChromeInbox()

    #expect(harness.model.events.filter { $0.observationEventID == record.eventID }.count == 1)
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
    let poll = Task { @MainActor in await harness.model.pollChromeInbox() }
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
    #expect(harness.clearer.clearCount == 0)

    chromeCoordinator.resumeFirstDelivery()
    await poll.value
    await clear.value

    #expect(chromeCoordinator.receiveCount == 1)
    #expect(chromeCoordinator.flushCount == 1)
    #expect(harness.model.events.isEmpty)
    #expect(harness.model.currentAudioSources.allSatisfy { $0.chromeTab == nil })
}

@MainActor
@Test
func staleChromePollCannotRepublishPresentationWhileClearOwnsTheEpoch() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "lidmute-app-poll-clear-presentation-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifestURL = root.appending(path: "com.lidmute.nativehost.json")
    try Data("{}".utf8).write(to: manifestURL)
    let store = AppPipelineEventStore()
    let coordinator = PausingChromeEvidenceCoordinator()
    let model = AppViewModel(
        applicationSupport: root,
        eventStore: store,
        inboxConsumer: CountingInboxConsumer(records: [appRecord()]),
        observationStore: store,
        lifecycle: MutableLifecycleState(.ready),
        chromeManifestURL: manifestURL,
        observationPipelineCoordinator: coordinator
    )

    let poll = Task { @MainActor in await model.pollChromeInbox() }
    for _ in 0..<100 where !coordinator.firstDeliveryStarted { await Task.yield() }
    #expect(coordinator.firstDeliveryStarted)

    store.pauseNextClear()
    let clear = Task { @MainActor in await model.clearObservationData() }
    for _ in 0..<100 where !model.isClearingObservationData { await Task.yield() }
    coordinator.resumeFirstDelivery()
    for _ in 0..<200 where !store.isClearPaused { await Task.yield() }

    #expect(store.isClearPaused)
    #expect(model.chromeBridgeStatus == "等待 Chrome 扩展连接")

    store.resumePausedClear()
    await poll.value
    await clear.value
}

@MainActor
@Test
func routeProtectionContinuesDuringSlowObservationClearWithoutDuplicateAction() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "lidmute-app-route-clear-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifestURL = root.appending(path: "com.lidmute.nativehost.json")
    try Data("{}".utf8).write(to: manifestURL)

    let timeline = SharedOperationTimeline()
    let protection = AppPausingRouteProtectionApplying(timeline: timeline)
    let store = AppPipelineEventStore(timeline: timeline)
    let pipeline = ProtectionCoordinator(
        protection: protection,
        processEvidence: ScriptedAudioController(),
        store: store
    )
    await pipeline.setEnabled(true)
    await pipeline.receivePhysicalLid(closed: true)
    await pipeline.flushObservationLogging()

    let lifecycle = MutableLifecycleState(.ready)
    let consumer = CountingInboxConsumer(records: [])
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

    store.pauseNextClear()
    let clear = Task { @MainActor in await model.clearObservationData() }
    for _ in 0..<100 where !store.isClearPaused { await Task.yield() }

    model.receiveAudioRouteChanged()
    for _ in 0..<100 where await protection.routeChangeCount() == 0 {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await protection.routeChangeCount() == 1)
    #expect(!store.hasClearReleased)

    store.resumePausedClear()
    await clear.value
    await pipeline.flushObservationLogging()

    #expect(await protection.routeChangeCount() == 1)
    #expect(store.observationClearCount == 1)
    #expect(pipeline.state == .protecting)
    let finalTimeline = timeline.snapshot()
    #expect(finalTimeline.firstIndex(of: "protection.route")! < finalTimeline.firstIndex(of: "clear.released")!)
}

@MainActor
@Test
func physicalLidProtectionContinuesDuringSlowObservationClearAndPublishesAfterBoundary() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "lidmute-app-lid-clear-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifestURL = root.appending(path: "com.lidmute.nativehost.json")
    try Data("{}".utf8).write(to: manifestURL)

    let timeline = SharedOperationTimeline()
    let protection = AppPausingRouteProtectionApplying(timeline: timeline)
    let store = AppPipelineEventStore(timeline: timeline)
    let pipeline = ProtectionCoordinator(
        protection: protection,
        processEvidence: ScriptedAudioController(),
        store: store
    )
    await pipeline.setEnabled(true)
    await pipeline.flushObservationLogging()

    let model = AppViewModel(
        applicationSupport: root,
        eventStore: store,
        inboxConsumer: CountingInboxConsumer(records: []),
        observationStore: store,
        lifecycle: MutableLifecycleState(.ready),
        chromeManifestURL: manifestURL,
        observationPipelineCoordinator: pipeline
    )
    pipeline.onEvent = { event in model.receiveCoordinatorEvent(event) }
    model.receiveAudioRouteChanged()
    for _ in 0..<100 where model.lifecycleState != .ready { await Task.yield() }
    #expect(model.lifecycleState == .ready)

    store.pauseNextClear()
    let clear = Task { @MainActor in await model.clearObservationData() }
    for _ in 0..<100 where !store.isClearPaused { await Task.yield() }

    model.receiveSystemLidState(true)
    for _ in 0..<100 where await protection.beginActionCount() == 0 {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await protection.beginActionCount() == 1)
    #expect(!store.hasClearReleased)

    store.resumePausedClear()
    await clear.value
    await pipeline.flushObservationLogging()

    #expect(await protection.beginActionCount() == 1)
    #expect(pipeline.state == .protecting)
    #expect(try store.load().map(\.kind) == [.lidClosed, .muteEnforced])
    #expect(model.events.map(\.kind) == [.muteEnforced, .lidClosed])
    let finalTimeline = timeline.snapshot()
    let beginIndex = try #require(finalTimeline.firstIndex(of: "protection.begin"))
    let releaseIndex = try #require(finalTimeline.firstIndex(of: "clear.released"))
    #expect(beginIndex < releaseIndex)
}

@MainActor
@Test
func failedObservationClearStillReleasesDeferredSafetyLogging() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "lidmute-app-failed-clear-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifestURL = root.appending(path: "com.lidmute.nativehost.json")
    try Data("{}".utf8).write(to: manifestURL)

    let protection = AppPausingRouteProtectionApplying()
    let store = AppPipelineEventStore()
    let pipeline = ProtectionCoordinator(
        protection: protection,
        processEvidence: ScriptedAudioController(),
        store: store
    )
    await pipeline.setEnabled(true)
    await pipeline.flushObservationLogging()

    let model = AppViewModel(
        applicationSupport: root,
        eventStore: store,
        inboxConsumer: CountingInboxConsumer(records: []),
        observationStore: store,
        lifecycle: MutableLifecycleState(.ready),
        chromeManifestURL: manifestURL,
        observationPipelineCoordinator: pipeline
    )
    pipeline.onEvent = { event in model.receiveCoordinatorEvent(event) }
    model.receiveAudioRouteChanged()
    for _ in 0..<100 where model.lifecycleState != .ready { await Task.yield() }

    store.failNextClear()
    store.pauseNextClear()
    let clear = Task { @MainActor in await model.clearObservationData() }
    for _ in 0..<100 where !store.isClearPaused { await Task.yield() }
    model.receiveSystemLidState(true)
    for _ in 0..<100 where await protection.beginActionCount() == 0 {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await protection.beginActionCount() == 1)
    #expect(!store.hasClearReleased)

    store.resumePausedClear()
    await clear.value
    await pipeline.flushObservationLogging()

    #expect(pipeline.state == .protecting)
    #expect(try store.load().map(\.kind) == [.protectionEnabled, .lidClosed, .muteEnforced])
    #expect(model.events.map(\.kind) == [.muteEnforced, .lidClosed, .protectionEnabled])
    #expect(!model.storageStatusText.isEmpty)
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

@MainActor
@Test
func partialClearReportIsPassedToCoordinatorClearBoundary() async throws {
    let coordinator = OutcomeChromeEvidenceCoordinator(result: .notRequired)
    let harness = try AppViewModelHarness(
        lifecycle: .ready,
        clearFailures: [.inbox],
        observationPipelineCoordinator: coordinator
    )

    await harness.model.clearObservationData()

    #expect(coordinator.endedClearReports.count == 1)
    #expect(coordinator.endedClearReports[0]?.failures == [.inbox])
}

@MainActor
@Test
func partialInboxClearKeepsExistingChromePresentation() async throws {
    let record = appRecord()
    let harness = try AppViewModelHarness(
        lifecycle: .ready,
        records: [record],
        clearFailures: [.inbox],
        observationPipelineCoordinator: OutcomeChromeEvidenceCoordinator(result: .protected)
    )
    await harness.model.pollChromeInbox()
    #expect(harness.model.chromeBridgeStatus == "已接收 Chrome 标签页事件")

    harness.lifecycle.state = .recovering
    await harness.model.clearObservationData()

    #expect(harness.model.chromeBridgeStatus == "已接收 Chrome 标签页事件")
}

@MainActor
@Test
func eventsClearFailureKeepsTimelineVisibleAndConsistentAfterRestart() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "lidmute-app-events-clear-failure-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifestURL = root.appending(path: "com.lidmute.nativehost.json")
    try Data("{}".utf8).write(to: manifestURL)
    let persisted = [appEvent(1), appEvent(2)]
    let store = CountingEventStore(events: persisted)
    let consumer = CountingInboxConsumer()
    let clearer = RecordingObservationClearer(failures: [.events])
    let lifecycle = MutableLifecycleState(.ready)
    let model = AppViewModel(
        applicationSupport: root,
        eventStore: store,
        inboxConsumer: consumer,
        observationStore: clearer,
        lifecycle: lifecycle,
        chromeManifestURL: manifestURL,
        observationPipelineCoordinator: OutcomeChromeEvidenceCoordinator(result: .protected)
    )
    let timelineBeforeClear = model.events

    await model.clearObservationData()

    #expect(model.events == timelineBeforeClear)
    #expect(model.chromeBridgeStatus == "等待 Chrome 扩展连接")
    #expect(model.currentAudioSources.allSatisfy { $0.chromeTab == nil })
    #expect(consumer.resetCount == 1)
    #expect(model.storageStatusText == "部分数据未清空：events")
    model.stopAll()

    let restarted = AppViewModel(
        applicationSupport: root,
        eventStore: store,
        inboxConsumer: CountingInboxConsumer(),
        observationStore: clearer,
        lifecycle: MutableLifecycleState(.recovering),
        chromeManifestURL: manifestURL
    )
    #expect(restarted.events == Array(persisted.reversed()))
}

@MainActor
@Test
func consumeAcknowledgementAndClearHealthRecoverWithoutMaskingEachOther() async throws {
    let firstRecord = appRecord()
    let secondRecord = appRecord()
    let firstDeliveryID = UUID()
    let secondDeliveryID = UUID()
    let emptyBatch = ChromeConsumeBatch(
        records: [],
        deliveryID: nil,
        committedOffset: 0,
        health: .healthy
    )
    let consumer = ScriptedHealthInboxConsumer(
        consumeOutcomes: [
            .batch(ChromeConsumeBatch(
                records: [firstRecord],
                deliveryID: firstDeliveryID,
                committedOffset: 0,
                health: .healthy
            )),
            .failure(.permissionFailure),
            .batch(emptyBatch),
            .batch(ChromeConsumeBatch(
                records: [secondRecord],
                deliveryID: secondDeliveryID,
                committedOffset: 0,
                health: .healthy
            )),
        ],
        acknowledgeOutcomes: [.failure(.capacityFailure), .success]
    )
    let harness = try AppViewModelHarness(
        lifecycle: .ready,
        clearFailures: [.events],
        inboxConsumer: consumer,
        observationPipelineCoordinator: OutcomeChromeEvidenceCoordinator(result: .protected)
    )

    await harness.model.pollChromeInbox()
    #expect(harness.model.storageStatusText == "观察存储空间不足")

    await harness.model.pollChromeInbox()
    #expect(
        harness.model.storageStatusText ==
            "观察存储权限不足\n观察存储空间不足"
    )

    harness.lifecycle.state = .recovering
    await harness.model.clearObservationData()
    #expect(
        harness.model.storageStatusText ==
            "观察存储权限不足\n观察存储空间不足\n部分数据未清空：events"
    )
    #expect(harness.model.storageStatusSeverity == .error)

    harness.lifecycle.state = .ready
    await harness.model.pollChromeInbox()
    #expect(
        harness.model.storageStatusText ==
            "观察存储空间不足\n部分数据未清空：events"
    )
    #expect(harness.model.storageStatusSeverity == .error)

    await harness.model.pollChromeInbox()
    #expect(harness.model.storageStatusText == "部分数据未清空：events")
    #expect(harness.model.storageStatusSeverity == .warning)

    harness.lifecycle.state = .recovering
    harness.clearer.setFailures([])
    await harness.model.clearObservationData()
    #expect(harness.model.storageStatusText.isEmpty)
    #expect(harness.model.storageStatusSeverity == .none)
}

@MainActor
@Test
func successfulClearDoesNotHideStartupHistoryFailure() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "lidmute-app-startup-health-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifestURL = root.appending(path: "com.lidmute.nativehost.json")
    try Data("{}".utf8).write(to: manifestURL)
    let model = AppViewModel(
        applicationSupport: root,
        eventStore: StartupFailingEventStore(),
        inboxConsumer: CountingInboxConsumer(),
        observationStore: RecordingObservationClearer(),
        lifecycle: MutableLifecycleState(.recovering),
        chromeManifestURL: manifestURL,
        observationPipelineCoordinator: OutcomeChromeEvidenceCoordinator(result: .notRequired)
    )
    #expect(model.storageStatusText == "观察存储权限不足")

    await model.clearObservationData()

    #expect(model.storageStatusText == "观察存储权限不足")
    #expect(model.storageStatusSeverity == .error)
}

@MainActor
@Test
func coordinatorStorageHealthUpdatesAppAndClearsOnlyAfterPersistenceRecovers() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "lidmute-app-coordinator-health-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifestURL = root.appending(path: "com.lidmute.nativehost.json")
    try Data("{}".utf8).write(to: manifestURL)
    let model = AppViewModel(
        applicationSupport: root,
        eventStore: RecoveringAppEventStore(),
        inboxConsumer: CountingInboxConsumer(),
        observationStore: RecordingObservationClearer(),
        lifecycle: MutableLifecycleState(.ready),
        chromeManifestURL: manifestURL
    )
    model.receiveAudioRouteChanged()
    for _ in 0..<100 where model.lifecycleState != .ready { await Task.yield() }

    model.setEnabled(true)
    for _ in 0..<200 where model.storageStatusText.isEmpty { await Task.yield() }
    #expect(model.storageStatusText == "观察存储权限不足")

    model.setEnabled(false)
    for _ in 0..<200 where !model.storageStatusText.isEmpty { await Task.yield() }
    #expect(model.storageStatusText.isEmpty)
    model.stopAll()
}

@MainActor
@Test
func coordinatorHealthyRecoveryDoesNotHideAnUnrelatedPartialClearStatus() async throws {
    let harness = try AppViewModelHarness(
        lifecycle: .ready,
        clearFailures: [.events]
    )

    await harness.model.clearObservationData()
    harness.model.receiveCoordinatorStorageHealth(.healthy)

    #expect(harness.model.storageStatusText == "部分数据未清空：events")
    harness.model.stopAll()
}

@MainActor
@Test
func coordinatorAndOperationalStorageHealthRecoverIndependentlyInBothOrders() async throws {
    let coordinatorFirst = try AppViewModelHarness(
        lifecycle: .ready,
        clearFailures: [.events]
    )
    coordinatorFirst.model.receiveCoordinatorStorageHealth(.permissionFailure)
    await coordinatorFirst.model.clearObservationData()

    #expect(
        coordinatorFirst.model.storageStatusText ==
            "观察存储权限不足\n部分数据未清空：events"
    )
    #expect(coordinatorFirst.model.storageStatusSeverity == .error)

    coordinatorFirst.clearer.setFailures([])
    await coordinatorFirst.model.clearObservationData()

    #expect(coordinatorFirst.model.storageStatusText == "观察存储权限不足")
    #expect(coordinatorFirst.model.storageStatusSeverity == .error)
    coordinatorFirst.model.stopAll()

    let operationalFirst = try AppViewModelHarness(
        lifecycle: .ready,
        clearFailures: [.events]
    )
    await operationalFirst.model.clearObservationData()
    #expect(operationalFirst.model.storageStatusText == "部分数据未清空：events")
    #expect(operationalFirst.model.storageStatusSeverity == .warning)

    operationalFirst.model.receiveCoordinatorStorageHealth(.capacityFailure)
    #expect(
        operationalFirst.model.storageStatusText ==
            "观察存储空间不足\n部分数据未清空：events"
    )
    #expect(operationalFirst.model.storageStatusSeverity == .error)

    operationalFirst.model.receiveCoordinatorStorageHealth(.healthy)
    #expect(operationalFirst.model.storageStatusText == "部分数据未清空：events")
    #expect(operationalFirst.model.storageStatusSeverity == .warning)
    operationalFirst.model.stopAll()
}

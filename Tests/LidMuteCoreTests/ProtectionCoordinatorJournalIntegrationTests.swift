import XCTest
@testable import LidMuteCore

private actor TimelineProtectionApplying: SpeakerProtectionApplying {
    private let timeline: SharedOperationTimeline

    init(timeline: SharedOperationTimeline) {
        self.timeline = timeline
    }

    func apply(_ action: SpeakerProtectionAction) async -> SpeakerRecoveryOutcome {
        switch action {
        case .begin:
            timeline.append("protection.begin")
            return .noPendingRecovery
        case .end:
            timeline.append("protection.end")
            return .restored
        case .reinforce:
            timeline.append("protection.reinforce")
            return .noPendingRecovery
        case .routeChangedWhileProtectionRequired:
            timeline.append("protection.routeChanged")
            return .noPendingRecovery
        }
    }
}

private actor PausingRouteProtectionApplying: SpeakerProtectionApplying {
    private var shouldPauseRoute = false
    private var routeStarted = false
    private var routeContinuation: CheckedContinuation<Void, Never>?

    func pauseNextRouteChange() {
        shouldPauseRoute = true
        routeStarted = false
    }

    func apply(_ action: SpeakerProtectionAction) async -> SpeakerRecoveryOutcome {
        if case .routeChangedWhileProtectionRequired = action, shouldPauseRoute {
            shouldPauseRoute = false
            routeStarted = true
            await withCheckedContinuation { routeContinuation = $0 }
        }
        switch action {
        case .end:
            return .restored
        case .begin, .reinforce, .routeChangedWhileProtectionRequired:
            return .noPendingRecovery
        }
    }

    func waitUntilRouteChangeStarts() async {
        while !routeStarted { await Task.yield() }
    }

    func resumeRouteChange() {
        let continuation = routeContinuation
        routeContinuation = nil
        continuation?.resume()
    }
}

private actor UnavailableThenMatchingChromeProtectionApplying: SpeakerProtectionApplying {
    private var actions: [SpeakerProtectionAction] = []
    private var routeOutcomes: [SpeakerRecoveryOutcome] = [
        .waitingForMatchingDevice,
        .noPendingRecovery,
    ]

    func apply(_ action: SpeakerProtectionAction) async -> SpeakerRecoveryOutcome {
        actions.append(action)
        switch action {
        case .begin:
            return .waitingForMatchingDevice
        case .routeChangedWhileProtectionRequired:
            return routeOutcomes.removeFirst()
        case .reinforce:
            return .failedSafetyUnknown
        case .end:
            return .restored
        }
    }

    func appliedActions() -> [SpeakerProtectionAction] {
        actions
    }
}

private final class PausingPipelineEventStore: EventStoring, @unchecked Sendable {
    private let condition = NSCondition()
    private var events: [LidMuteEvent] = []
    private var pauseKind: LidMuteEventKind?
    private var appendPaused = false
    private var resumeAppend = false

    var isAppendPaused: Bool { condition.withLock { appendPaused } }

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

    func resumePausedAppend() {
        condition.withLock {
            resumeAppend = true
            condition.broadcast()
        }
    }
}

private final class PausingObservationEventStore: EventStoring, @unchecked Sendable {
    private let condition = NSCondition()
    private let timeline: SharedOperationTimeline
    private var events: [LidMuteEvent] = []
    private var shouldPauseLidClosed = true
    private var lidClosedPaused = false
    private var resumeLidClosed = false

    init(timeline: SharedOperationTimeline) {
        self.timeline = timeline
    }

    var isLidClosedAppendPaused: Bool {
        condition.withLock { lidClosedPaused }
    }

    func append(_ event: LidMuteEvent) throws {
        condition.lock()
        events.append(event)
        timeline.append("store.\(event.kind)")
        if event.kind == .lidClosed, shouldPauseLidClosed {
            shouldPauseLidClosed = false
            lidClosedPaused = true
            condition.broadcast()
            let deadline = Date().addingTimeInterval(0.25)
            while !resumeLidClosed, condition.wait(until: deadline) {}
            lidClosedPaused = false
        }
        condition.unlock()
    }

    func load() throws -> [LidMuteEvent] {
        condition.withLock { events }
    }

    func clear() throws {
        condition.withLock { events.removeAll() }
    }

    func resumePausedAppend() {
        condition.withLock {
            resumeLidClosed = true
            condition.broadcast()
        }
    }
}

private final class RecoveringHealthEventStore: EventStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var nextError: EventStoreError?
    private var events: [LidMuteEvent] = []

    init(firstError: EventStoreError) {
        nextError = firstError
    }

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
    func clear() throws { lock.withLock { events.removeAll() } }
}

@MainActor
final class ProtectionCoordinatorJournalIntegrationTests: XCTestCase {
    func testChromeSafetyDeliveryRetriesUnavailableActiveProtectionUntilMatchingRouteIsProtected() async {
        let protection = UnavailableThenMatchingChromeProtectionApplying()
        let coordinator = ProtectionCoordinator(
            protection: protection,
            store: MemoryEventStore()
        )
        await coordinator.setEnabled(true)
        await coordinator.receivePhysicalLid(closed: true)
        XCTAssertEqual(coordinator.state, .unavailable)

        let evidence = ChromeTabEvidence.fixture(audible: true, incognito: false)
        let firstDelivery = await coordinator.ensureProtected(for: evidence)
        XCTAssertEqual(firstDelivery, .unsafe)
        XCTAssertEqual(coordinator.state, .unavailable)

        let secondDelivery = await coordinator.ensureProtected(for: evidence)
        XCTAssertEqual(secondDelivery, .protected)
        XCTAssertEqual(coordinator.state, .protecting)
        let appliedActions = await protection.appliedActions()
        XCTAssertEqual(
            appliedActions,
            [
                .begin(sources: [.physicalLid]),
                .routeChangedWhileProtectionRequired(sources: [.physicalLid]),
                .routeChangedWhileProtectionRequired(sources: [.physicalLid]),
            ]
        )
    }

    func testDetachedObservationLoggingReportsTypedHealthAndRecoversWithoutBlockingSafety() async {
        let cases: [(EventStoreError, ObservationStorageHealth)] = [
            (.permissionFailure, .permissionFailure),
            (.capacityFailure, .capacityFailure),
            (.corruptRecord(line: 7), .corruptRecord(line: 7)),
        ]

        for (error, expectedHealth) in cases {
            let protection = TimelineProtectionApplying(timeline: SharedOperationTimeline())
            let store = RecoveringHealthEventStore(firstError: error)
            let coordinator = ProtectionCoordinator(
                protection: protection,
                store: store
            )
            var observedHealth: [ObservationStorageHealth] = []
            coordinator.onStorageHealth = { observedHealth.append($0) }

            await coordinator.setEnabled(true)
            await coordinator.flushObservationLogging()
            XCTAssertEqual(observedHealth, [expectedHealth])

            await coordinator.receivePhysicalLid(closed: true)
            XCTAssertEqual(coordinator.state, .protecting)
            await coordinator.flushObservationLogging()
            XCTAssertEqual(observedHealth, [expectedHealth, .healthy])
        }
    }

    func testObservationClearDefersOnlyNewestBoundedEventsUntilBoundaryEnds() async throws {
        let protection = PausingRouteProtectionApplying()
        let store = PausingPipelineEventStore()
        let coordinator = ProtectionCoordinator(
            protection: protection,
            store: store,
            maximumDeferredObservationEvents: 3
        )
        await coordinator.setEnabled(true)
        await coordinator.flushObservationLogging()

        let boundary = await coordinator.beginObservationClear()
        try store.clear()
        await coordinator.receivePhysicalLid(closed: true)
        await coordinator.receivePhysicalLid(closed: false)
        XCTAssertTrue(try store.load().isEmpty)

        coordinator.endObservationClear(
            boundary,
            report: ObservationClearReport(oldGeneration: 0, newGeneration: 1, failures: [])
        )
        await coordinator.flushObservationLogging()

        XCTAssertEqual(
            try store.load().map(\.kind),
            [.muteEnforced, .lidOpened, .restored]
        )
    }

    func testSuccessfulInboxClearRemovesCoordinatorChromeEvidenceWithoutEndingProtection() async {
        let timeline = SharedOperationTimeline()
        let coordinator = ProtectionCoordinator(
            protection: TimelineProtectionApplying(timeline: timeline),
            store: MemoryEventStore()
        )
        await coordinator.setEnabled(true)
        await coordinator.receivePhysicalLid(closed: true)
        let evidence = ChromeTabEvidence.fixture(audible: true, incognito: false)
        await coordinator.receiveChromeEvidence(evidence)
        XCTAssertEqual(coordinator.latestChromeEvidence?.title, "Example")
        XCTAssertEqual(coordinator.latestChromeEvidence?.url, "https://example.com/watch?q=1#now")

        let boundary = await coordinator.beginObservationClear()
        coordinator.endObservationClear(
            boundary,
            report: ObservationClearReport(oldGeneration: 0, newGeneration: 1, failures: [])
        )

        XCTAssertNil(coordinator.latestChromeEvidence)
        XCTAssertEqual(coordinator.state, .protecting)
        await coordinator.receiveAudioRouteChanged()
        XCTAssertTrue(timeline.snapshot().contains("protection.routeChanged"))
    }

    func testFailedInboxClearRetainsCoordinatorChromeEvidence() async {
        let coordinator = ProtectionCoordinator(
            protection: TimelineProtectionApplying(timeline: SharedOperationTimeline()),
            store: MemoryEventStore()
        )
        await coordinator.setEnabled(true)
        await coordinator.receivePhysicalLid(closed: true)
        let evidence = ChromeTabEvidence.fixture(audible: true, incognito: false)
        await coordinator.receiveChromeEvidence(evidence)

        let boundary = await coordinator.beginObservationClear()
        coordinator.endObservationClear(
            boundary,
            report: ObservationClearReport(
                oldGeneration: 0,
                newGeneration: 1,
                failures: [.inbox]
            )
        )

        XCTAssertEqual(coordinator.latestChromeEvidence?.title, "Example")
        XCTAssertEqual(coordinator.latestChromeEvidence?.url, "https://example.com/watch?q=1#now")
        XCTAssertEqual(coordinator.state, .protecting)
    }

    func testObservationFlushWaitsForInFlightTransitionAndItsLoggingTail() async throws {
        let protection = PausingRouteProtectionApplying()
        let store = PausingPipelineEventStore()
        let coordinator = ProtectionCoordinator(
            protection: protection,
            store: store
        )
        await coordinator.setEnabled(true)
        await coordinator.receivePhysicalLid(closed: true)
        await coordinator.flushObservationLogging()

        store.pauseNextAppend(of: .muteEnforced)
        await protection.pauseNextRouteChange()
        let route = Task { @MainActor in await coordinator.receiveAudioRouteChanged() }
        await protection.waitUntilRouteChangeStarts()

        let barrierStarted = LockedFlag()
        let barrierFinished = LockedFlag()
        let barrier = Task { @MainActor in
            barrierStarted.set()
            await coordinator.flushObservationLogging()
            barrierFinished.set()
        }
        while !barrierStarted.get() { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(barrierFinished.get())

        await protection.resumeRouteChange()
        for _ in 0..<100 where !store.isAppendPaused {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(store.isAppendPaused)
        XCTAssertFalse(barrierFinished.get())

        store.resumePausedAppend()
        await route.value
        await barrier.value
        XCTAssertTrue(barrierFinished.get())
        XCTAssertEqual(
            try store.load().map(\.kind),
            [.protectionEnabled, .lidClosed, .muteEnforced, .muteEnforced]
        )
    }

    func testObservationStorageCannotDelaySpeakerSafetyTransitions() async throws {
        let timeline = SharedOperationTimeline()
        let protection = TimelineProtectionApplying(timeline: timeline)
        let store = PausingObservationEventStore(timeline: timeline)
        let coordinator = ProtectionCoordinator(
            protection: protection,
            store: store
        )

        await coordinator.setEnabled(true)
        await coordinator.receivePhysicalLid(closed: true)
        for _ in 0..<100 where !store.isLidClosedAppendPaused {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(store.isLidClosedAppendPaused)
        XCTAssertLessThan(
            try XCTUnwrap(timeline.snapshot().firstIndex(of: "protection.begin")),
            try XCTUnwrap(timeline.snapshot().firstIndex(of: "store.lidClosed"))
        )

        let mainActorRanWhileStorePaused = LockedFlag()
        await Task.detached {
            await MainActor.run {
                if store.isLidClosedAppendPaused { mainActorRanWhileStorePaused.set() }
            }
        }.value
        XCTAssertTrue(mainActorRanWhileStorePaused.get())

        await coordinator.receivePhysicalLid(closed: false)
        XCTAssertTrue(timeline.snapshot().contains("protection.end"))
        XCTAssertTrue(store.isLidClosedAppendPaused)

        store.resumePausedAppend()
        for _ in 0..<100 {
            if try store.load().count == 5 { break }
            await Task.yield()
        }
        XCTAssertEqual(
            try store.load().map(\.kind),
            [.protectionEnabled, .lidClosed, .muteEnforced, .lidOpened, .restored]
        )
    }

    // This fails if coordinator waits on a semaphore and blocks MainActor during speaker I/O.
    func testProtectionTransitionYieldsMainActorWhileApplying() async {
        let applying = DelayedProtectionApplying(delay: .milliseconds(100))
        let audio = ScriptedAudioController()
        let coordinator = ProtectionCoordinator(
            protection: applying,
            store: MemoryEventStore()
        )
        await coordinator.setEnabled(true)
        let mainActorRan = LockedFlag()
        let queued = Task.detached {
            await applying.waitUntilStarted()
            await MainActor.run { mainActorRan.set() }
        }

        await coordinator.receivePhysicalLid(closed: true)

        XCTAssertTrue(mainActorRan.get())
        await queued.value
    }

    // This fails if the physical-lid path bypasses the durable recovery transaction.
    func testPhysicalLidPathJournalsBeforeActualAudioMutation() async throws {
        let fixture = OrderedProtectionFixture()

        await fixture.coordinator.setEnabled(true)
        await fixture.coordinator.receivePhysicalLid(closed: true)

        let timeline = fixture.timeline.snapshot()
        XCTAssertLessThan(
            try XCTUnwrap(timeline.firstIndex(of: "journal.save")),
            try XCTUnwrap(timeline.firstIndex(of: "audio.writeMuted:true"))
        )
        XCTAssertEqual(fixture.coordinator.state, .protecting)
    }

    // This fails if a journal write failure still permits any speaker mutation.
    func testJournalFailureThroughCoordinatorPerformsNoAudioMutation() async {
        let fixture = OrderedProtectionFixture(journalFailure: FakeRecoveryStoreError.diskFull)

        await fixture.coordinator.setEnabled(true)
        await fixture.coordinator.receivePhysicalLid(closed: true)

        XCTAssertFalse(fixture.timeline.snapshot().contains { $0.hasPrefix("audio.write") })
        XCTAssertEqual(fixture.coordinator.state, .unavailable)
    }

    // This fails if simulation and night source transitions bypass begin/end recovery actions.
    func testSimulationAndNightTransitionsUseJournaledRuntime() async {
        let simulation = OrderedProtectionFixture()
        await simulation.coordinator.setEnabled(true)
        await simulation.coordinator.receiveSimulation(.closed)
        await simulation.coordinator.receiveSimulation(.opened)
        XCTAssertEqual(simulation.recoveryStore.operations.filter { $0 == "save" }.count, 1)
        XCTAssertEqual(simulation.recoveryStore.operations.filter { $0 == "remove" }.count, 1)

        let night = OrderedProtectionFixture()
        await night.coordinator.setEnabled(true)
        await night.coordinator.receiveNightProtection(true)
        await night.coordinator.receiveNightProtection(false)
        XCTAssertEqual(night.recoveryStore.operations.filter { $0 == "save" }.count, 1)
        XCTAssertEqual(night.recoveryStore.operations.filter { $0 == "remove" }.count, 1)
    }

    // This fails if disabling with multiple active sources restores more than once or skips recovery.
    func testDisableEndsOneSharedJournaledProtectionTransaction() async {
        let fixture = OrderedProtectionFixture()
        await fixture.coordinator.setEnabled(true)
        await fixture.coordinator.receivePhysicalLid(closed: true)
        await fixture.coordinator.receiveSimulation(.closed)
        await fixture.coordinator.receiveNightProtection(true)

        await fixture.coordinator.setEnabled(false)

        XCTAssertEqual(fixture.recoveryStore.operations.filter { $0 == "remove" }.count, 1)
        XCTAssertEqual(fixture.coordinator.state, .inactive)
    }

    // This fails if process/Chrome evidence performs a direct write or does not reinforce the journal UID.
    func testAudioAndChromeEvidenceReinforceThroughRuntime() async {
        let fixture = OrderedProtectionFixture()
        await fixture.coordinator.setEnabled(true)
        await fixture.coordinator.receivePhysicalLid(closed: true)
        let initialWrites = fixture.audio.writtenDeviceUIDs.count
        let process = AudioProcess(
            pid: 42,
            name: "Google Chrome",
            bundleID: "com.google.Chrome",
            executablePath: nil,
            launchDate: nil,
            isOutputActive: true
        )

        await fixture.coordinator.receiveAudioSnapshot([process])
        await fixture.coordinator.receiveChromeEvidence(.fixture(audible: true, incognito: false))

        XCTAssertGreaterThan(fixture.audio.writtenDeviceUIDs.count, initialWrites)
        XCTAssertTrue(fixture.audio.writtenDeviceUIDs.allSatisfy { $0 == "built-in-a" })
    }

    // This fails if a cancelled shutdown leaves the coordinator logically enabled while the UI is off.
    func testShutdownEndsProtectionAndDisablesCoordinator() async {
        let fixture = OrderedProtectionFixture()
        await fixture.coordinator.setEnabled(true)
        await fixture.coordinator.receivePhysicalLid(closed: true)

        let outcome = await fixture.coordinator.endProtectionForShutdown()

        XCTAssertEqual(outcome, .restored)
        XCTAssertFalse(fixture.coordinator.isEnabled)
        XCTAssertEqual(fixture.coordinator.state, .inactive)
    }

    // This fails if shutdown drains stale queued reinforcements before restoring the speaker.
    func testShutdownSkipsQueuedProtectionTransitions() async {
        let applying = DelayedProtectionApplying(delay: .milliseconds(20))
        let coordinator = ProtectionCoordinator(
            protection: applying,
            store: MemoryEventStore()
        )
        let activeProcess = AudioProcess(
            pid: 42,
            name: "Chrome",
            bundleID: "com.google.Chrome",
            executablePath: nil,
            launchDate: nil,
            isOutputActive: true
        )

        await coordinator.setEnabled(true)
        let firstTransition = Task { await coordinator.receivePhysicalLid(closed: true) }
        await applying.waitUntilStarted()
        let queuedReinforcement = Task {
            await coordinator.receiveAudioSnapshot([activeProcess])
        }
        let shutdown = Task { await coordinator.endProtectionForShutdown() }

        await firstTransition.value
        await queuedReinforcement.value
        _ = await shutdown.value

        let applyCount = await applying.observedApplyCount()
        XCTAssertEqual(applyCount, 2)
    }
}

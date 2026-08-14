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

@MainActor
final class ProtectionCoordinatorJournalIntegrationTests: XCTestCase {
    func testObservationStorageCannotDelaySpeakerSafetyTransitions() async throws {
        let timeline = SharedOperationTimeline()
        let protection = TimelineProtectionApplying(timeline: timeline)
        let store = PausingObservationEventStore(timeline: timeline)
        let coordinator = ProtectionCoordinator(
            protection: protection,
            processEvidence: ScriptedAudioController(),
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
            processEvidence: audio,
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
}

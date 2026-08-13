import XCTest
@testable import LidMuteCore

@MainActor
final class ProtectionCoordinatorJournalIntegrationTests: XCTestCase {
    // This fails if the physical-lid path bypasses the durable recovery transaction.
    func testPhysicalLidPathJournalsBeforeActualAudioMutation() async throws {
        let fixture = OrderedProtectionFixture()

        fixture.coordinator.setEnabled(true)
        fixture.coordinator.receivePhysicalLid(closed: true)

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

        fixture.coordinator.setEnabled(true)
        fixture.coordinator.receivePhysicalLid(closed: true)

        XCTAssertFalse(fixture.timeline.snapshot().contains { $0.hasPrefix("audio.write") })
        XCTAssertEqual(fixture.coordinator.state, .unavailable)
    }

    // This fails if simulation and night source transitions bypass begin/end recovery actions.
    func testSimulationAndNightTransitionsUseJournaledRuntime() async {
        let simulation = OrderedProtectionFixture()
        simulation.coordinator.setEnabled(true)
        simulation.coordinator.receiveSimulation(.closed)
        simulation.coordinator.receiveSimulation(.opened)
        XCTAssertEqual(simulation.recoveryStore.operations.filter { $0 == "save" }.count, 1)
        XCTAssertEqual(simulation.recoveryStore.operations.filter { $0 == "remove" }.count, 1)

        let night = OrderedProtectionFixture()
        night.coordinator.setEnabled(true)
        night.coordinator.receiveNightProtection(true)
        night.coordinator.receiveNightProtection(false)
        XCTAssertEqual(night.recoveryStore.operations.filter { $0 == "save" }.count, 1)
        XCTAssertEqual(night.recoveryStore.operations.filter { $0 == "remove" }.count, 1)
    }

    // This fails if disabling with multiple active sources restores more than once or skips recovery.
    func testDisableEndsOneSharedJournaledProtectionTransaction() async {
        let fixture = OrderedProtectionFixture()
        fixture.coordinator.setEnabled(true)
        fixture.coordinator.receivePhysicalLid(closed: true)
        fixture.coordinator.receiveSimulation(.closed)
        fixture.coordinator.receiveNightProtection(true)

        fixture.coordinator.setEnabled(false)

        XCTAssertEqual(fixture.recoveryStore.operations.filter { $0 == "remove" }.count, 1)
        XCTAssertEqual(fixture.coordinator.state, .inactive)
    }

    // This fails if process/Chrome evidence performs a direct write or does not reinforce the journal UID.
    func testAudioAndChromeEvidenceReinforceThroughRuntime() async {
        let fixture = OrderedProtectionFixture()
        fixture.coordinator.setEnabled(true)
        fixture.coordinator.receivePhysicalLid(closed: true)
        let initialWrites = fixture.audio.writtenDeviceUIDs.count
        let process = AudioProcess(
            pid: 42,
            name: "Google Chrome",
            bundleID: "com.google.Chrome",
            executablePath: nil,
            launchDate: nil,
            isOutputActive: true
        )

        fixture.coordinator.receiveAudioSnapshot([process])
        fixture.coordinator.receiveChromeEvidence(.fixture(audible: true, incognito: false))

        XCTAssertGreaterThan(fixture.audio.writtenDeviceUIDs.count, initialWrites)
        XCTAssertTrue(fixture.audio.writtenDeviceUIDs.allSatisfy { $0 == "built-in-a" })
    }
}

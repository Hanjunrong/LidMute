import XCTest
@testable import LidMuteCore

@MainActor
final class ProtectionSourceStateTests: XCTestCase {
    // This fails if simulation and physical lid protection share one source.
    func testSimulationOpenCannotReleasePhysicalProtection() {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())
        coordinator.setEnabled(true)
        coordinator.receivePhysicalLid(closed: true)
        coordinator.receiveSimulation(.opened)
        XCTAssertEqual(coordinator.state, .protecting)
        XCTAssertEqual(audio.mutations.filter { $0.hasPrefix("restore:") }.count, 0)
    }

    // This fails if a physical-open observation can clear a simulated closure.
    func testPhysicalOpenCannotReleaseClosedSimulation() {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())
        coordinator.setEnabled(true)
        coordinator.receiveSimulation(.closed)
        coordinator.receivePhysicalLid(closed: false)
        XCTAssertEqual(coordinator.state, .protecting)
    }

    // This fails if reset clears every protection source instead of simulation only.
    func testResetOnlyRemovesSimulationSource() {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())
        coordinator.setEnabled(true)
        coordinator.receivePhysicalLid(closed: true)
        coordinator.receiveSimulation(.closed)
        coordinator.receiveSimulation(.reset)
        XCTAssertEqual(coordinator.state, .protecting)
    }

    // This fails if duplicate or irrelevant observations repeat the first silence mutation.
    func testRepeatedAndOutOfOrderInputsDoNotRepeatMutations() {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())
        coordinator.setEnabled(true)
        coordinator.receivePhysicalLid(closed: true)
        coordinator.receivePhysicalLid(closed: true)
        coordinator.receiveSimulation(.opened)
        coordinator.receiveSimulation(.opened)
        XCTAssertEqual(audio.mutations.filter { $0.hasPrefix("silence:") }.count, 1)
    }

    // This fails if disabling restores once per active source instead of once overall.
    func testDisableClearsAllSourcesAndRestoresOnce() {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())
        coordinator.setEnabled(true)
        coordinator.receivePhysicalLid(closed: true)
        coordinator.receiveSimulation(.closed)
        coordinator.receiveNightProtection(true)
        coordinator.setEnabled(false)
        XCTAssertEqual(coordinator.state, .inactive)
        XCTAssertEqual(audio.mutations.filter { $0.hasPrefix("restore:") }.count, 1)
    }

    // This fails if disable clears a simulated closure before the next enable.
    func testEnablingReplaysSimulatedClosedStateAfterDisable() {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)
        coordinator.receiveSimulation(.closed)
        coordinator.setEnabled(false)
        coordinator.setEnabled(true)

        XCTAssertEqual(coordinator.state, .protecting)
        XCTAssertEqual(audio.mutations.filter { $0.hasPrefix("silence:") }.count, 2)
    }
}

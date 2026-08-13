import XCTest
@testable import LidMuteCore

@MainActor
final class ProtectionRouteRetryTests: XCTestCase {
    // This fails if an active source is discarded after the initial built-in route is missing.
    func testRouteChangeRetriesUnavailableActiveProtection() async {
        let timeline = SharedOperationTimeline()
        let audio = ScriptedAudioController(timeline: timeline)
        audio.defaultBuiltIn = nil
        let runtime = SpeakerRecoveryRuntime(
            audio: audio,
            recoveryStore: MemorySpeakerRecoveryStore(timeline: timeline),
            appVersion: "0.1.0"
        )
        let coordinator = ProtectionCoordinator(
            protection: runtime,
            processEvidence: audio,
            store: MemoryEventStore()
        )

        coordinator.setEnabled(true)
        coordinator.receivePhysicalLid(closed: true)
        XCTAssertEqual(coordinator.state, .unavailable)

        audio.defaultBuiltIn = audio.resolvedUIDs["built-in-a"]
        coordinator.receiveAudioRouteChanged()

        XCTAssertEqual(coordinator.state, .protecting)
        XCTAssertEqual(audio.writtenDeviceUIDs, ["built-in-a"])
    }

    // This fails if restoration targets the current external route instead of re-resolving original UID A.
    func testProtectionEndRestoresOriginalBuiltInUIDWhenExternalRouteIsDefault() async {
        let audio = ScriptedAudioController()
        let runtime = SpeakerRecoveryRuntime(
            audio: audio,
            recoveryStore: MemorySpeakerRecoveryStore(),
            appVersion: "0.1.0"
        )
        let coordinator = ProtectionCoordinator(
            protection: runtime,
            processEvidence: audio,
            store: MemoryEventStore()
        )
        coordinator.setEnabled(true)
        coordinator.receivePhysicalLid(closed: true)

        audio.defaultBuiltIn = nil
        coordinator.receivePhysicalLid(closed: false)

        XCTAssertEqual(coordinator.state, .armed)
        XCTAssertFalse(audio.writtenDeviceUIDs.isEmpty)
        XCTAssertTrue(audio.writtenDeviceUIDs.allSatisfy { $0 == "built-in-a" })
    }
}

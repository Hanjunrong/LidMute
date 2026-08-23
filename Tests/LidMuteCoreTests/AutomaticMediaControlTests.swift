import XCTest
@testable import LidMuteCore

@MainActor
final class AutomaticMediaControlTests: XCTestCase {
    func testProtectionInputsDoNotExposeAutomaticMediaCallback() {
        let coordinator = ProtectionCoordinator(audio: FakeAudioController(), store: MemoryEventStore())
        XCTAssertNil(Mirror(reflecting: coordinator).children.first { $0.label == "onMediaPauseRequest" })
    }

    func testChromeEvidenceDuringProtectionLeavesTimelineOwnershipWithConsumerAndReinforcesSilence() {
        let audio = FakeAudioController()
        audio.activeProcesses = [
            .init(
                pid: 42,
                name: "Google Chrome",
                bundleID: "com.google.Chrome",
                executablePath: nil,
                launchDate: nil,
                isOutputActive: true
            ),
        ]
        let store = MemoryEventStore()
        let coordinator = ProtectionCoordinator(audio: audio, store: store)
        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        let evidence = ChromeTabEvidence.fixture(audible: true, incognito: false)
        coordinator.receiveChromeEvidence(evidence)
        XCTAssertFalse(store.events.contains { $0.kind == .chromeTabAudible })
        XCTAssertTrue(store.events.contains { $0.kind == .muteEnforced })
        XCTAssertEqual(coordinator.latestChromeEvidence, evidence)
    }

}

extension ChromeTabEvidence {
    static func fixture(audible: Bool, incognito: Bool) -> ChromeTabEvidence {
        ChromeTabEvidence(
            sessionID: "session",
            windowID: 1,
            tabID: 2,
            index: 0,
            title: "Example",
            url: "https://example.com/watch?q=1#now",
            audible: audible,
            muted: false,
            isActive: true,
            isPinned: false,
            isIncognito: incognito
        )
    }
}

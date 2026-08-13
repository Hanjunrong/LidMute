import XCTest
@testable import LidMuteCore

@MainActor
final class AutomaticMediaControlTests: XCTestCase {
    func testProtectionInputsDoNotExposeAutomaticMediaCallback() {
        let coordinator = ProtectionCoordinator(audio: FakeAudioController(), store: MemoryEventStore())
        XCTAssertNil(Mirror(reflecting: coordinator).children.first { $0.label == "onMediaPauseRequest" })
    }

    func testChromeEvidenceDuringProtectionOnlyRecordsEvidenceAndSilence() {
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
        coordinator.receiveChromeEvidence(.fixture(audible: true, incognito: false))
        XCTAssertTrue(store.events.contains { $0.kind == .chromeTabAudible })
        XCTAssertTrue(store.events.contains { $0.kind == .muteEnforced })
    }

    func testManualMediaDescriptorsRemainAvailable() {
        XCTAssertEqual(MediaKeyEventDescriptor.events(for: .playPause).count, 2)
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

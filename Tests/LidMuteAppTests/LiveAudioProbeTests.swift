import XCTest
@testable import LidMuteApp

/// This is intentionally a smoke test against the host's live CoreAudio graph.
/// It verifies that the production path can enumerate real process objects and
/// run the Process Tap without crashing when apps are open or silent.
final class LiveAudioProbeTests: XCTestCase {
    func testLiveCoreAudioProcessQueryIsSafe() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LIDMUTE_LIVE_AUDIO_TEST"] == "1",
            "Opt-in: creates real CoreAudio process taps and may take time on a busy host"
        )
        let controller = SystemAudioController()
        let processes = try controller.activeOutputProcesses()
        print("Live LidMute audio processes: \(processes.map { "\($0.displayName) [\($0.pid)]" }.joined(separator: ", "))")
        XCTAssertTrue(processes.allSatisfy { $0.isOutputActive })
    }
}

import Foundation
import LidMuteCore

@main
struct LidMuteCoreBehaviorTests {
    static func main() {
        do {
            try chromeEvidenceRoundTripsWithoutLosingURL()
            try eventStoreReloadsValidLinesAndSkipsMalformedInput()
            try protectionRestoresCapturedSpeakerState()
            try chromeFrameCapturesAudibleTabDetails()
            try chromeEventDeduplicatorPersistsAcceptedIDs()
            print("PASS Chrome tab evidence round-trips URL and identifiers")
            print("PASS JSONL store reloads valid records and skips malformed input")
            print("PASS protection mutes on close and restores on open")
            print("PASS Chrome audible frame retains tab-level details")
            print("PASS Chrome event deduplicator persists accepted IDs")
        } catch {
            fputs("FAIL \(error)\n", stderr)
            exit(1)
        }
    }

    private static func chromeEvidenceRoundTripsWithoutLosingURL() throws {
        let evidence = ChromeTabEvidence(
            sessionID: "chrome-session-1",
            windowID: 1,
            tabID: 2,
            index: 0,
            title: "优酷",
            url: "https://v.youku.com/v_show/id_example",
            audible: true,
            muted: false,
            isActive: false,
            isPinned: false,
            isIncognito: false
        )

        let decoded = try JSONDecoder().decode(
            ChromeTabEvidence.self,
            from: JSONEncoder().encode(evidence)
        )

        guard decoded == evidence, decoded.url == "https://v.youku.com/v_show/id_example" else {
            throw BehaviorTestError.expectationFailed("Chrome tab URL or identifiers changed during encoding")
        }
    }

    private static func eventStoreReloadsValidLinesAndSkipsMalformedInput() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "lidmute-events-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = JSONLineEventStore(url: url)
        try store.append(LidMuteEvent(kind: .muteEnforced, detail: "test"))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handle.write(Data("not-json\n".utf8))
        try handle.close()

        guard try store.load().count == 1 else {
            throw BehaviorTestError.expectationFailed("event store did not preserve only valid records")
        }
    }

    @MainActor
    private static func protectionRestoresCapturedSpeakerState() throws {
        let audio = FakeAudioController()
        let store = MemoryEventStore()
        let coordinator = ProtectionCoordinator(audio: audio, store: store)

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        guard audio.lastMute == true else {
            throw BehaviorTestError.expectationFailed("guard did not mute built-in speaker")
        }

        coordinator.receiveLidState(closed: false)
        guard audio.lastMute == false, audio.lastVolume == 0.72 else {
            throw BehaviorTestError.expectationFailed("guard did not restore captured speaker state")
        }
    }

    private static func chromeFrameCapturesAudibleTabDetails() throws {
        let json = #"{"v":1,"type":"tab_audio_started","eventId":"e","extensionSessionId":"s","seq":"1","sentAt":"2026-07-10T01:22:56Z","tab":{"windowId":3,"tabId":9,"index":1,"title":"优酷","url":"https://v.youku.com","status":"complete","audible":true,"muted":{"value":false},"active":false,"pinned":false,"incognito":false}}"#
        let evidence = try ChromeBridgeFrame.decode(Data(json.utf8)).evidence
        guard evidence.tabID == 9, evidence.url == "https://v.youku.com", evidence.audible else {
            throw BehaviorTestError.expectationFailed("Chrome frame lost tab-level evidence")
        }
    }

    private static func chromeEventDeduplicatorPersistsAcceptedIDs() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "lidmute-seen-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = ChromeEventDeduplicator(url: url)
        guard try first.accept("chrome-event-1") else {
            throw BehaviorTestError.expectationFailed("first Chrome event should be accepted")
        }
        guard !(try first.accept("chrome-event-1")) else {
            throw BehaviorTestError.expectationFailed("duplicate Chrome event should be rejected")
        }
        let restarted = ChromeEventDeduplicator(url: url)
        guard !(try restarted.accept("chrome-event-1")) else {
            throw BehaviorTestError.expectationFailed("persisted Chrome event should remain rejected after restart")
        }
    }
}

enum BehaviorTestError: Error {
    case expectationFailed(String)
}

private final class MemoryEventStore: EventStoring, @unchecked Sendable {
    private(set) var events: [LidMuteEvent] = []

    func append(_ event: LidMuteEvent) throws { events.append(event) }
    func load() throws -> [LidMuteEvent] { events }
    func clear() throws { events.removeAll() }
}

private final class FakeAudioController: AudioControlling, @unchecked Sendable {
    private let device = AudioDevice(id: 1, uid: "built-in", name: "Built-in Speakers", isBuiltIn: true)
    var lastMute: Bool?
    var lastVolume: Float?

    func builtInSpeaker() throws -> AudioDevice? { device }
    func captureState(of device: AudioDevice) throws -> AudioDeviceState { .init(muted: false, volume: 0.72, usedVolumeFallback: false) }
    func enforceSilence(on device: AudioDevice) throws { lastMute = true }
    func restore(_ state: AudioDeviceState, on device: AudioDevice) throws { lastMute = state.muted; lastVolume = state.volume }
    func activeOutputProcesses() throws -> [AudioProcess] { [] }
}

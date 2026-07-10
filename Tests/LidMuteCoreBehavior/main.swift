import Foundation
import LidMuteCore

@main
struct LidMuteCoreBehaviorTests {
    static func main() {
        do {
            try chromeEvidenceRoundTripsWithoutLosingURL()
            try eventStoreReloadsValidLinesAndSkipsMalformedInput()
            try protectionRestoresVolumeButKeepsMutedOnLidOpen()
            try manualDisableFullyRestoresCapturedSpeakerState()
            try manualDisableAfterLidOpenFullyRestoresCapturedSpeakerState()
            try volumeFallbackKeepsOutputSilentOnLidOpen()
            try repeatedAudioSnapshotsDoNotDuplicateLogEvents()
            try audioProcessCanBeLoggedAgainAfterStopping()
            try silenceErrorIsLoggedAgainAfterAudioRestarts()
            try chromeFrameCapturesAudibleTabDetails()
            try chromeEventDeduplicatorPersistsAcceptedIDs()
            print("PASS Chrome tab evidence round-trips URL and identifiers")
            print("PASS JSONL store reloads valid records and skips malformed input")
            print("PASS lid-open restores volume while keeping speaker muted")
            print("PASS manual disable fully restores captured speaker state")
            print("PASS manual disable after lid-open fully restores captured speaker state")
            print("PASS volume fallback keeps output silent on lid-open")
            print("PASS repeated audio snapshots do not duplicate log events")
            print("PASS stopped audio process can be logged after becoming active again")
            print("PASS silence error is logged again after audio restarts")
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
    private static func protectionRestoresVolumeButKeepsMutedOnLidOpen() throws {
        let audio = FakeAudioController()
        let store = MemoryEventStore()
        let coordinator = ProtectionCoordinator(audio: audio, store: store)

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        guard audio.lastMute == true else {
            throw BehaviorTestError.expectationFailed("guard did not mute built-in speaker")
        }

        coordinator.receiveLidState(closed: false)
        guard audio.lastMute == true, audio.lastVolume == 0.72 else {
            throw BehaviorTestError.expectationFailed("lid-open did not restore volume while keeping speaker muted")
        }
    }

    @MainActor
    private static func manualDisableFullyRestoresCapturedSpeakerState() throws {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        coordinator.setEnabled(false)

        guard audio.lastMute == false, audio.lastVolume == 0.72 else {
            throw BehaviorTestError.expectationFailed("manual disable did not fully restore captured speaker state")
        }
    }

    @MainActor
    private static func manualDisableAfterLidOpenFullyRestoresCapturedSpeakerState() throws {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        coordinator.receiveLidState(closed: false)
        coordinator.setEnabled(false)

        guard audio.lastMute == false, audio.lastVolume == 0.72 else {
            throw BehaviorTestError.expectationFailed("manual disable after lid-open did not restore captured state")
        }
    }

    @MainActor
    private static func volumeFallbackKeepsOutputSilentOnLidOpen() throws {
        let audio = FakeAudioController()
        audio.capturedState = .init(muted: false, volume: 0.72, usedVolumeFallback: true)
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        coordinator.receiveLidState(closed: false)

        guard audio.lastMute == true, audio.lastVolume == 0 else {
            throw BehaviorTestError.expectationFailed("volume fallback restored an audible output level on lid-open")
        }
    }

    @MainActor
    private static func repeatedAudioSnapshotsDoNotDuplicateLogEvents() throws {
        let audio = FakeAudioController()
        let store = MemoryEventStore()
        let coordinator = ProtectionCoordinator(audio: audio, store: store)
        let process = activeProcess(pid: 1357)

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        coordinator.receiveAudioSnapshot([process])
        let countAfterFirstSnapshot = store.events.count
        let enforcementCountAfterFirstSnapshot = audio.enforceSilenceCount
        coordinator.receiveAudioSnapshot([process])

        guard store.events.count == countAfterFirstSnapshot,
              audio.enforceSilenceCount == enforcementCountAfterFirstSnapshot + 1 else {
            throw BehaviorTestError.expectationFailed("identical snapshots duplicated logs or stopped silence enforcement")
        }
    }

    @MainActor
    private static func audioProcessCanBeLoggedAgainAfterStopping() throws {
        let store = MemoryEventStore()
        let coordinator = ProtectionCoordinator(audio: FakeAudioController(), store: store)
        let process = activeProcess(pid: 1357)

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        coordinator.receiveAudioSnapshot([process])
        let firstCount = store.events.count
        coordinator.receiveAudioSnapshot([])
        coordinator.receiveAudioSnapshot([process])

        guard store.events.count > firstCount else {
            throw BehaviorTestError.expectationFailed("reactivated audio process was not logged again")
        }
    }

    @MainActor
    private static func silenceErrorIsLoggedAgainAfterAudioRestarts() throws {
        let audio = FakeAudioController()
        let store = MemoryEventStore()
        let coordinator = ProtectionCoordinator(audio: audio, store: store)
        let process = activeProcess(pid: 2468)

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        audio.enforceError = FakeAudioError.enforcementFailed
        coordinator.receiveAudioSnapshot([process])
        coordinator.receiveAudioSnapshot([])
        coordinator.receiveAudioSnapshot([process])

        let errorCount = store.events.filter { $0.kind == .error }.count
        guard errorCount == 2 else {
            throw BehaviorTestError.expectationFailed("a new audio activity period did not record its silence error")
        }
    }

    private static func activeProcess(pid: Int32) -> AudioProcess {
        AudioProcess(
            pid: pid,
            name: "Google Chrome",
            bundleID: "com.google.Chrome",
            executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            launchDate: nil,
            isOutputActive: true
        )
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

private enum FakeAudioError: Error {
    case enforcementFailed
}

private final class MemoryEventStore: EventStoring, @unchecked Sendable {
    private(set) var events: [LidMuteEvent] = []

    func append(_ event: LidMuteEvent) throws { events.append(event) }
    func load() throws -> [LidMuteEvent] { events }
    func clear() throws { events.removeAll() }
}

private final class FakeAudioController: AudioControlling, @unchecked Sendable {
    private let device = AudioDevice(id: 1, uid: "built-in", name: "Built-in Speakers", isBuiltIn: true)
    var capturedState = AudioDeviceState(muted: false, volume: 0.72, usedVolumeFallback: false)
    var enforceError: Error?
    private(set) var enforceSilenceCount = 0
    var lastMute: Bool?
    var lastVolume: Float?

    func builtInSpeaker() throws -> AudioDevice? { device }
    func captureState(of device: AudioDevice) throws -> AudioDeviceState { capturedState }
    func enforceSilence(on device: AudioDevice) throws {
        enforceSilenceCount += 1
        if let enforceError { throw enforceError }
        lastMute = true
    }
    func restore(_ state: AudioDeviceState, on device: AudioDevice) throws { lastMute = state.muted; lastVolume = state.volume }
    func activeOutputProcesses() throws -> [AudioProcess] { [] }
}

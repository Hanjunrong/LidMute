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
            try enablingGuardDoesNotChangeCurrentAudioState()
            try nightProtectionMutesOnlyWhenPolicyIsActive()
            try nightProtectionRestoresWhenItEnds()
            try nightEndDoesNotRestoreWhileLidIsClosed()
            try nightScheduleHandlesBeijingTimeAcrossMidnight()
            try mediaCommandsUseSystemKeyTypes()
            try eventPresentationUsesReadableChineseLabels()
            try mediaPauseRequestRetainsEvidenceAndReadablePresentation()
            try protectedSourcesRequestPauseOnlyWithChromeEvidence()
            try protectionExitNeverRequestsMediaPlayback()
            try chromePauseRequestsUseGlobalDebounce()
            try mediaPauseResultsUseHonestEventWording()
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
            print("PASS enabling guard does not change current audio state")
            print("PASS night protection mutes only when policy is active")
            print("PASS night protection restores when it ends")
            print("PASS night end does not restore while lid is closed")
            print("PASS night schedule handles Beijing time across midnight")
            print("PASS media commands use system key types")
            print("PASS event presentation uses readable Chinese labels")
            print("PASS media pause requests retain evidence and readable presentation")
            print("PASS protected sources request pause only with Chrome evidence")
            print("PASS protection exit never requests media playback")
            print("PASS Chrome pause requests use global debounce")
            print("PASS media pause results use honest event wording")
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
    private static func enablingGuardDoesNotChangeCurrentAudioState() throws {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)

        guard audio.enforceSilenceCount == 0, audio.captureCount == 0,
              audio.lastMute == false, audio.lastVolume == 0.72 else {
            throw BehaviorTestError.expectationFailed("enabling the guard changed current audio state")
        }
    }

    @MainActor
    private static func nightProtectionMutesOnlyWhenPolicyIsActive() throws {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)
        coordinator.receiveNightProtection(false)
        guard audio.enforceSilenceCount == 0 else {
            throw BehaviorTestError.expectationFailed("inactive night policy muted the speaker")
        }

        coordinator.receiveNightProtection(true)
        guard audio.enforceSilenceCount == 1, audio.lastMute == true else {
            throw BehaviorTestError.expectationFailed("active night policy did not mute the speaker")
        }
    }

    @MainActor
    private static func nightProtectionRestoresWhenItEnds() throws {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)
        coordinator.receiveNightProtection(true)
        coordinator.receiveNightProtection(false)

        guard audio.lastMute == false, audio.lastVolume == 0.72 else {
            throw BehaviorTestError.expectationFailed("night protection did not restore the captured state")
        }
    }

    @MainActor
    private static func nightEndDoesNotRestoreWhileLidIsClosed() throws {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        coordinator.receiveNightProtection(true)
        coordinator.receiveNightProtection(false)

        guard audio.lastMute == true else {
            throw BehaviorTestError.expectationFailed("night end unmuted an actively closed lid")
        }
    }

    private static func nightScheduleHandlesBeijingTimeAcrossMidnight() throws {
        let schedule = NightSchedule(startMinutes: 23 * 60, endMinutes: 8 * 60)
        guard schedule.isActive(at: beijingDate(hour: 23, minute: 30)),
              schedule.isActive(at: beijingDate(hour: 1, minute: 30)),
              !schedule.isActive(at: beijingDate(hour: 12)) else {
            throw BehaviorTestError.expectationFailed("Beijing night schedule did not handle a cross-midnight interval")
        }
    }

    private static func mediaCommandsUseSystemKeyTypes() throws {
        guard MediaCommand.previous.rawValue == 20,
              MediaCommand.next.rawValue == 19,
              MediaCommand.playPause.rawValue == 16 else {
            throw BehaviorTestError.expectationFailed("media command key types are not mapped to macOS system keys")
        }
    }

    private static func eventPresentationUsesReadableChineseLabels() throws {
        let detected = EventPresentation(kind: .audioProcessDetected)
        let restored = EventPresentation(kind: .restored)
        guard detected.title == "检测到音频输出",
              detected.symbolName == "waveform.badge.exclamationmark",
              restored.title == "扬声器状态已恢复" else {
            throw BehaviorTestError.expectationFailed("event presentation is not human readable")
        }
    }

    private static func mediaPauseRequestRetainsEvidenceAndReadablePresentation() throws {
        let process = activeProcess(pid: 1357)
        let request = MediaPauseRequest(
            trigger: .lidProtectionStarted,
            source: .lid,
            process: process,
            chromeTab: nil,
            correlation: .systemMatched
        )
        let sent = EventPresentation(kind: .mediaPauseRequested)
        let failed = EventPresentation(kind: .mediaPauseRequestFailed)

        guard request.source == .lid,
              request.process == process,
              sent.title == "已请求系统暂停",
              sent.symbolName == "pause.circle.fill",
              failed.title == "系统暂停请求失败" else {
            throw BehaviorTestError.expectationFailed("media pause request model or presentation lost evidence")
        }
    }

    @MainActor
    private static func protectedSourcesRequestPauseOnlyWithChromeEvidence() throws {
        let cases: [(MediaPauseTrigger, ProtectionSource, @MainActor (ProtectionCoordinator) -> Void)] = [
            (.lidProtectionStarted, .lid, { $0.receiveLidState(closed: true) }),
            (.simulatedLidProtectionStarted, .lid, { $0.receiveLidState(closed: true, simulated: true) }),
            (.nightProtectionStarted, .night, { $0.receiveNightProtection(true) }),
        ]

        for (expectedTrigger, source, activate) in cases {
            let audio = FakeAudioController()
            audio.activeProcesses = [activeProcess(pid: 1357)]
            let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())
            var requests: [MediaPauseRequest] = []
            coordinator.onMediaPauseRequest = { requests.append($0) }

            coordinator.setEnabled(true)
            activate(coordinator)

            guard requests.count == 1,
                  requests[0].trigger == expectedTrigger,
                  requests[0].source == source,
                  requests[0].process?.bundleID == "com.google.Chrome" else {
                throw BehaviorTestError.expectationFailed("protected source did not request one evidence-backed pause")
            }
        }

        let silentCoordinator = ProtectionCoordinator(audio: FakeAudioController(), store: MemoryEventStore())
        var silentRequests = 0
        silentCoordinator.onMediaPauseRequest = { _ in silentRequests += 1 }
        silentCoordinator.setEnabled(true)
        silentCoordinator.receiveLidState(closed: true)
        guard silentRequests == 0 else {
            throw BehaviorTestError.expectationFailed("protection requested pause without Chrome audio evidence")
        }
    }

    @MainActor
    private static func protectionExitNeverRequestsMediaPlayback() throws {
        let audio = FakeAudioController()
        audio.activeProcesses = [activeProcess(pid: 1357)]
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())
        var requestCount = 0
        coordinator.onMediaPauseRequest = { _ in requestCount += 1 }

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        let countWhileProtected = requestCount
        coordinator.receiveLidState(closed: false)
        coordinator.setEnabled(false)

        guard requestCount == countWhileProtected else {
            throw BehaviorTestError.expectationFailed("protection exit sent a media command")
        }
    }

    @MainActor
    private static func chromePauseRequestsUseGlobalDebounce() throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        let coordinator = ProtectionCoordinator(
            audio: FakeAudioController(),
            store: MemoryEventStore(),
            mediaPauseDebounce: 3,
            now: { clock }
        )
        var requests: [MediaPauseRequest] = []
        coordinator.onMediaPauseRequest = { requests.append($0) }
        let evidence = ChromeTabEvidence(
            sessionID: "s",
            windowID: 1,
            tabID: 2,
            index: 0,
            title: "优酷",
            url: "https://v.youku.com",
            audible: true,
            muted: false,
            isActive: true,
            isPinned: false,
            isIncognito: false
        )

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        coordinator.receiveChromeEvidence(evidence)
        coordinator.receiveChromeEvidence(evidence)
        guard requests.count == 1 else {
            throw BehaviorTestError.expectationFailed("Chrome pause request ignored debounce")
        }

        clock = clock.addingTimeInterval(3.1)
        coordinator.receiveChromeEvidence(evidence)
        guard requests.count == 2,
              requests[1].trigger == .chromeAudioStarted,
              requests[1].chromeTab == evidence else {
            throw BehaviorTestError.expectationFailed("fresh Chrome event did not request pause after debounce")
        }
    }

    @MainActor
    private static func mediaPauseResultsUseHonestEventWording() throws {
        let store = MemoryEventStore()
        let coordinator = ProtectionCoordinator(audio: FakeAudioController(), store: store)
        let request = MediaPauseRequest(
            trigger: .lidProtectionStarted,
            source: .lid,
            process: activeProcess(pid: 1357),
            chromeTab: nil,
            correlation: .systemMatched
        )

        coordinator.recordMediaPauseResult(request, errorDescription: nil)
        coordinator.recordMediaPauseResult(request, errorDescription: "event failed")

        guard store.events.count == 2,
              store.events[0].kind == .mediaPauseRequested,
              store.events[0].detail.contains("已发送系统暂停请求"),
              !store.events[0].detail.contains("网页已暂停"),
              store.events[1].kind == .mediaPauseRequestFailed,
              store.events[1].detail.contains("event failed") else {
            throw BehaviorTestError.expectationFailed("media pause result log overclaimed or lost failure details")
        }
    }

    private static func beijingDate(hour: Int, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: hour, minute: minute))!
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
    var activeProcesses: [AudioProcess] = []
    private(set) var enforceSilenceCount = 0
    private(set) var captureCount = 0
    var lastMute: Bool? = false
    var lastVolume: Float? = 0.72

    func builtInSpeaker() throws -> AudioDevice? { device }
    func captureState(of device: AudioDevice) throws -> AudioDeviceState {
        captureCount += 1
        return capturedState
    }
    func enforceSilence(on device: AudioDevice) throws {
        enforceSilenceCount += 1
        if let enforceError { throw enforceError }
        lastMute = true
    }
    func restore(_ state: AudioDeviceState, on device: AudioDevice) throws { lastMute = state.muted; lastVolume = state.volume }
    func activeOutputProcesses() throws -> [AudioProcess] { activeProcesses }
}

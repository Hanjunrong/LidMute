import Foundation
import Testing
@testable import LidMuteCore

@Suite struct ExistingBehaviorTests {

    @Test func testChromeEvidenceRoundTripsWithoutLosingURL() throws {
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

        #expect(decoded == evidence)
        #expect(decoded.url == "https://v.youku.com/v_show/id_example")
    }

    @Test func testEventStoreReloadsValidLinesAndSkipsMalformedInput() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "lidmute-events-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = JSONLineEventStore(url: url)
        try store.append(LidMuteEvent(kind: .muteEnforced, detail: "test"))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handle.write(Data("not-json\n".utf8))
        try handle.close()

        #expect(try store.load().count == 1, "event store did not preserve only valid records")
    }

    @MainActor
    @Test func testProtectionRestoresVolumeButKeepsMutedOnLidOpen() throws {
        let audio = FakeAudioController()
        let store = MemoryEventStore()
        let coordinator = ProtectionCoordinator(audio: audio, store: store)

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        #expect(audio.lastMute == true, "guard did not mute built-in speaker")

        coordinator.receiveLidState(closed: false)
        #expect(audio.lastMute == false)
        #expect(audio.lastVolume == 0.72)
    }

    @MainActor
    @Test func testManualDisableFullyRestoresCapturedSpeakerState() throws {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        coordinator.setEnabled(false)

        #expect(audio.lastMute == false)
        #expect(audio.lastVolume == 0.72)
    }

    @MainActor
    @Test func testManualDisableAfterLidOpenFullyRestoresCapturedSpeakerState() throws {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        coordinator.receiveLidState(closed: false)
        coordinator.setEnabled(false)

        #expect(audio.lastMute == false)
        #expect(audio.lastVolume == 0.72)
    }

    @MainActor
    @Test func testVolumeFallbackKeepsOutputSilentOnLidOpen() throws {
        let audio = FakeAudioController()
        audio.capturedState = .init(muted: false, volume: 0.72, usedVolumeFallback: true)
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        coordinator.receiveLidState(closed: false)

        #expect(audio.lastMute == false)
        #expect(audio.lastVolume == 0)
    }

    @MainActor
    @Test func testEnablingGuardDoesNotChangeCurrentAudioState() throws {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)

        #expect(audio.enforceSilenceCount == 0)
        #expect(audio.captureCount == 0)
        #expect(audio.lastMute == false)
        #expect(audio.lastVolume == 0.72)
    }

    @MainActor
    @Test func testNightProtectionMutesOnlyWhenPolicyIsActive() throws {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)
        coordinator.receiveNightProtection(false)
        #expect(audio.enforceSilenceCount == 0, "inactive night policy muted the speaker")

        coordinator.receiveNightProtection(true)
        #expect(audio.enforceSilenceCount == 1)
        #expect(audio.lastMute == true)
    }

    @MainActor
    @Test func testNightProtectionRestoresWhenItEnds() throws {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)
        coordinator.receiveNightProtection(true)
        coordinator.receiveNightProtection(false)

        #expect(audio.lastMute == false)
        #expect(audio.lastVolume == 0.72)
    }

    @MainActor
    @Test func testNightEndDoesNotRestoreWhileLidIsClosed() throws {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        coordinator.receiveNightProtection(true)
        coordinator.receiveNightProtection(false)

        #expect(audio.lastMute == true, "night end unmuted an actively closed lid")
    }

    @Test func testNightScheduleHandlesBeijingTimeAcrossMidnight() throws {
        let schedule = NightSchedule(startMinutes: 23 * 60, endMinutes: 8 * 60)
        #expect(schedule.isActive(at: beijingDate(hour: 23, minute: 30)))
        #expect(schedule.isActive(at: beijingDate(hour: 1, minute: 30)))
        #expect(!(schedule.isActive(at: beijingDate(hour: 12))))
    }

    @Test func testNightProtectionPreferencesPreserveLastValidSchedule() throws {
        let suiteName = "LidMuteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = NightProtectionPreferences(defaults: defaults)

        #expect(preferences.load() == NightProtectionConfiguration(
            enabled: false,
            startText: "00:00",
            endText: "08:00"
        ), "night preferences did not provide defaults")

        preferences.saveEnabled(true)
        #expect(preferences.saveSchedule(startText: "23:30", endText: "07:15"), "valid night schedule was rejected")
        #expect(!preferences.saveSchedule(startText: "25:00", endText: "07:15"), "invalid night schedule was persisted")

        #expect(preferences.load() == NightProtectionConfiguration(
            enabled: true,
            startText: "23:30",
            endText: "07:15"
        ), "invalid edit replaced the last valid schedule")
    }

    @Test func testMediaCommandsUseSystemKeyTypes() throws {
        #expect(MediaCommand.previous.rawValue == 18)
        #expect(MediaCommand.next.rawValue == 17)
        #expect(MediaCommand.playPause.rawValue == 16)

        let events = MediaKeyEventDescriptor.events(for: .playPause)
        #expect(events == [
            MediaKeyEventDescriptor(modifierFlags: 0xA00, data1: 0x100A00),
            MediaKeyEventDescriptor(modifierFlags: 0xB00, data1: 0x100B00),
        ])
    }

    @Test func testAudioSourcePresentationPrefersReadableNames() throws {
        let chrome = activeProcess(pid: 1357)
        let tab = ChromeTabEvidence(
            sessionID: "session",
            windowID: 3,
            tabID: 9,
            index: 1,
            title: "优酷",
            url: "https://v.youku.com",
            audible: true,
            muted: false,
            isActive: false,
            isPinned: false,
            isIncognito: false
        )
        let chromeSource = AudioSourcePresentation(process: chrome, chromeTab: tab)
        let music = AudioProcess(
            pid: 2468,
            name: "网易云音乐",
            bundleID: "com.netease.163music",
            executablePath: nil,
            launchDate: nil,
            isOutputActive: true
        )
        let musicSource = AudioSourcePresentation(process: music, chromeTab: nil)
        let unknown = AudioProcess(
            pid: 9753,
            name: "PID 9753",
            bundleID: nil,
            executablePath: nil,
            launchDate: nil,
            isOutputActive: true
        )
        let unknownSource = AudioSourcePresentation(process: unknown, chromeTab: nil)

        #expect(chromeSource.title == "优酷")
        #expect(chromeSource.subtitle == "Google Chrome · https://v.youku.com")
        #expect(musicSource.title == "网易云音乐")
        #expect(musicSource.subtitle == "com.netease.163music")
        #expect(unknownSource.title == "PID 9753")
        #expect(unknownSource.subtitle.isEmpty)
    }

    @Test func testCurrentAudioSourcesRequireAnActiveChromeProcess() throws {
        let chrome = activeProcess(pid: 1357)
        let tab = ChromeTabEvidence(
            sessionID: "session",
            windowID: 3,
            tabID: 9,
            index: 1,
            title: "优酷",
            url: "https://v.youku.com",
            audible: true,
            muted: false,
            isActive: false,
            isPinned: false,
            isIncognito: false
        )

        #expect(AudioSourcePresentation.current(processes: [chrome], chromeTab: tab).first?.title == "优酷")
        #expect(AudioSourcePresentation.current(processes: [], chromeTab: tab).isEmpty)
    }

    @Test func testEventPresentationUsesReadableChineseLabels() throws {
        let detected = EventPresentation(kind: .audioProcessDetected)
        let restored = EventPresentation(kind: .restored)
        #expect(detected.title == "检测到音频输出")
        #expect(detected.symbolName == "waveform.badge.exclamationmark")
        #expect(restored.title == "扬声器状态已恢复")
    }

    @Test func testMediaPauseRequestRetainsEvidenceAndReadablePresentation() throws {
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

        #expect(request.source == .lid)
        #expect(request.process == process)
        #expect(sent.title == "已请求系统暂停")
        #expect(sent.symbolName == "pause.circle.fill")
        #expect(failed.title == "系统暂停请求失败")
    }

    @MainActor
    @Test func testProtectedSourcesRequestPauseOnlyWithChromeEvidence() throws {
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

            #expect(requests.count == 1)
            let request = try #require(requests.first)
            #expect(request.trigger == expectedTrigger)
            #expect(request.source == source)
            #expect(request.process?.bundleID == "com.google.Chrome")
        }

        let silentCoordinator = ProtectionCoordinator(audio: FakeAudioController(), store: MemoryEventStore())
        var silentRequests = 0
        silentCoordinator.onMediaPauseRequest = { _ in silentRequests += 1 }
        silentCoordinator.setEnabled(true)
        silentCoordinator.receiveLidState(closed: true)
        #expect(silentRequests == 0, "protection requested pause without Chrome audio evidence")
    }

    @MainActor
    @Test func testProtectionExitNeverRequestsMediaPlayback() throws {
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

        #expect(requestCount == countWhileProtected, "protection exit sent a media command")
    }

    @MainActor
    @Test func testChromePauseRequestsUseGlobalDebounce() throws {
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
        #expect(requests.count == 1, "Chrome pause request ignored debounce")

        clock = clock.addingTimeInterval(3.1)
        coordinator.receiveChromeEvidence(evidence)
        #expect(requests.count == 2)
        #expect(requests[1].trigger == .chromeAudioStarted)
        #expect(requests[1].chromeTab == evidence)
    }

    @MainActor
    @Test func testMediaPauseResultsUseHonestEventWording() throws {
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

        #expect(store.events.count == 2)
        #expect(store.events[0].kind == .mediaPauseRequested)
        #expect(store.events[0].detail.contains("已发送系统暂停请求"))
        #expect(!(store.events[0].detail.contains("网页已暂停")))
        #expect(store.events[1].kind == .mediaPauseRequestFailed)
        #expect(store.events[1].detail.contains("event failed"))
    }

    @MainActor
    @Test func testTimelineRecordsOnlyWhileGuardIsEnabled() throws {
        let store = MemoryEventStore()
        let coordinator = ProtectionCoordinator(audio: FakeAudioController(), store: store)
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

        coordinator.receiveChromeEvidence(evidence)
        #expect(store.events.isEmpty, "disabled guard still recorded Chrome timeline events")

        coordinator.setEnabled(true)
        coordinator.receiveChromeEvidence(evidence)
        #expect(store.events.count == 2)
        #expect(store.events[0].kind == .protectionEnabled)
        #expect(store.events[1].kind == .chromeTabAudible)

        coordinator.setEnabled(false)
        let countAfterDisable = store.events.count
        coordinator.receiveChromeEvidence(evidence)
        #expect(store.events.count == countAfterDisable, "guard recorded Chrome timeline events after being disabled")
    }

    private func beijingDate(hour: Int, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: hour, minute: minute))!
    }

    @MainActor
    @Test func testRepeatedAudioSnapshotsDoNotDuplicateLogEvents() throws {
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

        #expect(store.events.count == countAfterFirstSnapshot)
        #expect(audio.enforceSilenceCount == enforcementCountAfterFirstSnapshot + 1)
    }

    @MainActor
    @Test func testAudioProcessCanBeLoggedAgainAfterStopping() throws {
        let store = MemoryEventStore()
        let coordinator = ProtectionCoordinator(audio: FakeAudioController(), store: store)
        let process = activeProcess(pid: 1357)

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        coordinator.receiveAudioSnapshot([process])
        let firstCount = store.events.count
        coordinator.receiveAudioSnapshot([])
        coordinator.receiveAudioSnapshot([process])

        #expect(store.events.count > firstCount, "reactivated audio process was not logged again")
    }

    @MainActor
    @Test func testSilenceErrorIsLoggedAgainAfterAudioRestarts() throws {
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
        #expect(errorCount == 2, "a new audio activity period did not record its silence error")
    }

    private func activeProcess(pid: Int32) -> AudioProcess {
        AudioProcess(
            pid: pid,
            name: "Google Chrome",
            bundleID: "com.google.Chrome",
            executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            launchDate: nil,
            isOutputActive: true
        )
    }

    @Test func testVisualLayoutKeepsCardsFlush() throws {
        #expect(VisualLayoutMetrics.cardSpacing == 0)
        #expect(VisualLayoutMetrics.automationCardHeight + VisualLayoutMetrics.simulationCardHeight == VisualLayoutMetrics.middleDeckHeight)
    }

    @Test func testVisualLayoutShowsExactlyThreeTimelineRowsByDefault() throws {
        let expected = VisualLayoutMetrics.timelineRowHeight * Double(VisualLayoutMetrics.timelineVisibleRowCount)
        #expect(VisualLayoutMetrics.timelineDefaultViewportHeight == expected, "timeline default viewport is not exactly three rows")
    }

    @Test func testVisualLayoutAssignsExtraHeightOnlyToTimeline() throws {
        let defaultContentHeight = VisualLayoutMetrics.defaultWindowHeight - VisualLayoutMetrics.appPadding * 2
        let stretchedContentHeight = defaultContentHeight + 160
        let defaultViewport = VisualLayoutMetrics.timelineViewportHeight(forAvailableContentHeight: defaultContentHeight)
        let stretchedViewport = VisualLayoutMetrics.timelineViewportHeight(forAvailableContentHeight: stretchedContentHeight)

        #expect(defaultViewport == VisualLayoutMetrics.timelineDefaultViewportHeight, "default timeline viewport is not clamped to three rows")
        #expect(stretchedViewport == defaultViewport + 160, "extra window height was not assigned only to the timeline")
    }

    @Test func testChromeFrameCapturesAudibleTabDetails() throws {
        let json = #"{"v":1,"type":"tab_audio_started","eventId":"e","extensionSessionId":"s","seq":"1","sentAt":"2026-07-10T01:22:56Z","tab":{"windowId":3,"tabId":9,"index":1,"title":"优酷","url":"https://v.youku.com","status":"complete","audible":true,"muted":{"value":false},"active":false,"pinned":false,"incognito":false}}"#
        let evidence = try ChromeBridgeFrame.decode(Data(json.utf8)).evidence
        #expect(evidence.tabID == 9)
        #expect(evidence.url == "https://v.youku.com")
        #expect(evidence.audible)
    }

    @Test func testChromeEventDeduplicatorPersistsAcceptedIDs() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "lidmute-seen-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = ChromeEventDeduplicator(url: url)
        #expect(try first.accept("chrome-event-1"), "first Chrome event should be accepted")
        #expect(!(try first.accept("chrome-event-1")), "duplicate Chrome event should be rejected")
        let restarted = ChromeEventDeduplicator(url: url)
        #expect(!(try restarted.accept("chrome-event-1")), "persisted Chrome event should remain rejected after restart")
    }
}

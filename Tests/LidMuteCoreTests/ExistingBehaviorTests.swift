import Foundation
import XCTest
@testable import LidMuteCore

final class ExistingBehaviorTests: XCTestCase {

    func testChromeEvidenceRoundTripsWithoutLosingURL() throws {
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

        XCTAssertTrue(decoded == evidence)
        XCTAssertTrue(decoded.url == "https://v.youku.com/v_show/id_example")
    }

    func testEventStoreReportsMalformedInputWithoutSilentlySkippingIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "lidmute-events-\(UUID().uuidString)", directoryHint: .isDirectory)
        let url = root.appending(path: "events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = BoundedJSONLineEventStore(url: url)
        try store.append(LidMuteEvent(kind: .muteEnforced, detail: "test"))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handle.write(Data("not-json\n".utf8))
        try handle.close()

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? EventStoreError, .corruptRecord(line: 2))
            XCTAssertEqual(store.health, .corruptRecord(line: 2))
        }
    }

    @MainActor
    func testProtectionRestoresVolumeButKeepsMutedOnLidOpen() throws {
        let audio = FakeAudioController()
        let store = MemoryEventStore()
        let coordinator = ProtectionCoordinator(audio: audio, store: store)

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        XCTAssertTrue(audio.lastMute == true, "guard did not mute built-in speaker")

        coordinator.receiveLidState(closed: false)
        XCTAssertTrue(audio.lastMute == false)
        XCTAssertTrue(audio.lastVolume == 0.72)
    }

    @MainActor
    func testManualDisableFullyRestoresCapturedSpeakerState() throws {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        coordinator.setEnabled(false)

        XCTAssertTrue(audio.lastMute == false)
        XCTAssertTrue(audio.lastVolume == 0.72)
    }

    @MainActor
    func testManualDisableAfterLidOpenFullyRestoresCapturedSpeakerState() throws {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        coordinator.receiveLidState(closed: false)
        coordinator.setEnabled(false)

        XCTAssertTrue(audio.lastMute == false)
        XCTAssertTrue(audio.lastVolume == 0.72)
    }

    @MainActor
    func testVolumeFallbackKeepsOutputSilentOnLidOpen() throws {
        let audio = FakeAudioController()
        audio.capturedState = .init(muted: false, volume: 0.72, usedVolumeFallback: true)
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        coordinator.receiveLidState(closed: false)

        XCTAssertTrue(audio.lastMute == false)
        XCTAssertTrue(audio.lastVolume == 0)
    }

    @MainActor
    func testEnablingGuardDoesNotChangeCurrentAudioState() throws {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)

        XCTAssertTrue(audio.enforceSilenceCount == 0)
        XCTAssertTrue(audio.captureCount == 0)
        XCTAssertTrue(audio.lastMute == false)
        XCTAssertTrue(audio.lastVolume == 0.72)
    }

    @MainActor
    func testNightProtectionMutesOnlyWhenPolicyIsActive() throws {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)
        coordinator.receiveNightProtection(false)
        XCTAssertTrue(audio.enforceSilenceCount == 0, "inactive night policy muted the speaker")

        coordinator.receiveNightProtection(true)
        XCTAssertTrue(audio.enforceSilenceCount == 1)
        XCTAssertTrue(audio.lastMute == true)
    }

    @MainActor
    func testNightProtectionRestoresWhenItEnds() throws {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)
        coordinator.receiveNightProtection(true)
        coordinator.receiveNightProtection(false)

        XCTAssertTrue(audio.lastMute == false)
        XCTAssertTrue(audio.lastVolume == 0.72)
    }

    @MainActor
    func testNightEndDoesNotRestoreWhileLidIsClosed() throws {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        coordinator.receiveNightProtection(true)
        coordinator.receiveNightProtection(false)

        XCTAssertTrue(audio.lastMute == true, "night end unmuted an actively closed lid")
    }

    func testNightScheduleHandlesBeijingTimeAcrossMidnight() throws {
        let schedule = NightSchedule(startMinutes: 23 * 60, endMinutes: 8 * 60)
        XCTAssertTrue(schedule.isActive(at: beijingDate(hour: 23, minute: 30)))
        XCTAssertTrue(schedule.isActive(at: beijingDate(hour: 1, minute: 30)))
        XCTAssertTrue(!(schedule.isActive(at: beijingDate(hour: 12))))
    }

    func testNightProtectionPreferencesPreserveLastValidSchedule() throws {
        let suiteName = "LidMuteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = NightProtectionPreferences(defaults: defaults)

        XCTAssertTrue(preferences.load() == NightProtectionConfiguration(
            enabled: false,
            startText: "00:00",
            endText: "08:00"
        ), "night preferences did not provide defaults")

        preferences.saveEnabled(true)
        XCTAssertTrue(preferences.saveSchedule(startText: "23:30", endText: "07:15"), "valid night schedule was rejected")
        XCTAssertTrue(!preferences.saveSchedule(startText: "25:00", endText: "07:15"), "invalid night schedule was persisted")

        XCTAssertTrue(preferences.load() == NightProtectionConfiguration(
            enabled: true,
            startText: "23:30",
            endText: "07:15"
        ), "invalid edit replaced the last valid schedule")
    }

    func testMediaCommandsUseSystemKeyTypes() throws {
        XCTAssertTrue(MediaCommand.previous.rawValue == 18)
        XCTAssertTrue(MediaCommand.next.rawValue == 17)
        XCTAssertTrue(MediaCommand.playPause.rawValue == 16)

        let events = MediaKeyEventDescriptor.events(for: .playPause)
        XCTAssertTrue(events == [
            MediaKeyEventDescriptor(modifierFlags: 0xA00, data1: 0x100A00),
            MediaKeyEventDescriptor(modifierFlags: 0xB00, data1: 0x100B00),
        ])
    }

    func testAudioSourcePresentationPrefersReadableNames() throws {
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

        XCTAssertTrue(chromeSource.title == "优酷")
        XCTAssertTrue(chromeSource.subtitle == "Google Chrome · https://v.youku.com")
        XCTAssertTrue(musicSource.title == "网易云音乐")
        XCTAssertTrue(musicSource.subtitle == "com.netease.163music")
        XCTAssertTrue(unknownSource.title == "PID 9753")
        XCTAssertTrue(unknownSource.subtitle.isEmpty)
    }

    func testCurrentAudioSourcesRequireAnActiveChromeProcess() throws {
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

        XCTAssertTrue(AudioSourcePresentation.current(processes: [chrome], chromeTab: tab).first?.title == "优酷")
        XCTAssertTrue(AudioSourcePresentation.current(processes: [], chromeTab: tab).isEmpty)
    }

    func testEventPresentationUsesReadableChineseLabels() throws {
        let detected = EventPresentation(kind: .audioProcessDetected)
        let restored = EventPresentation(kind: .restored)
        XCTAssertTrue(detected.title == "检测到音频输出")
        XCTAssertTrue(detected.symbolName == "waveform.badge.exclamationmark")
        XCTAssertTrue(restored.title == "扬声器状态已恢复")
    }

    @MainActor
    func testTimelineRecordsOnlyWhileGuardIsEnabled() throws {
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
        XCTAssertTrue(store.events.isEmpty, "disabled guard still recorded Chrome timeline events")

        coordinator.setEnabled(true)
        coordinator.receiveChromeEvidence(evidence)
        XCTAssertTrue(store.events.count == 2)
        XCTAssertTrue(store.events[0].kind == .protectionEnabled)
        XCTAssertTrue(store.events[1].kind == .chromeTabAudible)

        coordinator.setEnabled(false)
        let countAfterDisable = store.events.count
        coordinator.receiveChromeEvidence(evidence)
        XCTAssertTrue(store.events.count == countAfterDisable, "guard recorded Chrome timeline events after being disabled")
    }

    private func beijingDate(hour: Int, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: hour, minute: minute))!
    }

    @MainActor
    func testRepeatedAudioSnapshotsDoNotDuplicateLogEvents() throws {
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

        XCTAssertTrue(store.events.count == countAfterFirstSnapshot)
        XCTAssertTrue(audio.enforceSilenceCount == enforcementCountAfterFirstSnapshot + 1)
    }

    @MainActor
    func testAudioProcessCanBeLoggedAgainAfterStopping() throws {
        let store = MemoryEventStore()
        let coordinator = ProtectionCoordinator(audio: FakeAudioController(), store: store)
        let process = activeProcess(pid: 1357)

        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        coordinator.receiveAudioSnapshot([process])
        let firstCount = store.events.count
        coordinator.receiveAudioSnapshot([])
        coordinator.receiveAudioSnapshot([process])

        XCTAssertTrue(store.events.count > firstCount, "reactivated audio process was not logged again")
    }

    @MainActor
    func testSilenceErrorIsLoggedAgainAfterAudioRestarts() throws {
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
        XCTAssertTrue(errorCount == 2, "a new audio activity period did not record its silence error")
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

    func testVisualLayoutKeepsCardsFlush() throws {
        XCTAssertTrue(VisualLayoutMetrics.cardSpacing == 0)
        XCTAssertTrue(VisualLayoutMetrics.automationCardHeight + VisualLayoutMetrics.simulationCardHeight == VisualLayoutMetrics.middleDeckHeight)
    }

    func testVisualLayoutShowsExactlyThreeTimelineRowsByDefault() throws {
        let expected = VisualLayoutMetrics.timelineRowHeight * Double(VisualLayoutMetrics.timelineVisibleRowCount)
        XCTAssertTrue(VisualLayoutMetrics.timelineDefaultViewportHeight == expected, "timeline default viewport is not exactly three rows")
    }

    func testVisualLayoutAssignsExtraHeightOnlyToTimeline() throws {
        let defaultContentHeight = VisualLayoutMetrics.defaultWindowHeight - VisualLayoutMetrics.appPadding * 2
        let stretchedContentHeight = defaultContentHeight + 160
        let defaultViewport = VisualLayoutMetrics.timelineViewportHeight(forAvailableContentHeight: defaultContentHeight)
        let stretchedViewport = VisualLayoutMetrics.timelineViewportHeight(forAvailableContentHeight: stretchedContentHeight)

        XCTAssertTrue(defaultViewport == VisualLayoutMetrics.timelineDefaultViewportHeight, "default timeline viewport is not clamped to three rows")
        XCTAssertTrue(stretchedViewport == defaultViewport + 160, "extra window height was not assigned only to the timeline")
    }

}

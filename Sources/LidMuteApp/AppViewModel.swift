import Combine
import Foundation
import LidMuteCore

enum SimulatedLidState {
    case closed
    case opened
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var isEnabled = false
    @Published private(set) var statusText = "守卫未开启"
    @Published private(set) var events: [LidMuteEvent] = []
    @Published private(set) var chromeBridgeStatus = "等待 Chrome 扩展连接"
    @Published private(set) var simulatedLidState: SimulatedLidState = .opened
    @Published private(set) var currentAudioProcesses: [AudioProcess] = []
    @Published var nightScheduleEnabled = false
    @Published var nightStartText = "00:00"
    @Published var nightEndText = "08:00"
    @Published private(set) var isDisplaySleeping = false
    @Published private(set) var isNightProtectionActive = false
    @Published private(set) var nightScheduleStatus = "夜间静音未开启"
    @Published private(set) var mediaStatus = "系统媒体控制就绪"

    private let coordinator: ProtectionCoordinator
    private let store: JSONLineEventStore
    private let inboxURL: URL
    private let chromeDeduplicator: ChromeEventDeduplicator
    private var inboxOffset = 0
    private var audioTimer: Timer?
    private var inboxTimer: Timer?
    private var nightTimer: Timer?
    private var lidMonitor: SystemLidMonitor?
    private var displayMonitor: SystemDisplayMonitor?
    private var latestSystemLidClosed: Bool?
    private let mediaController = SystemMediaController()
    private let settings = UserDefaults.standard

    init() {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LidMute", directoryHint: .isDirectory)
        store = JSONLineEventStore(url: applicationSupport.appending(path: "events.jsonl"))
        inboxURL = applicationSupport.appending(path: "chrome-inbox.jsonl")
        chromeDeduplicator = ChromeEventDeduplicator(url: applicationSupport.appending(path: "chrome-seen-event-ids.json"))
        coordinator = ProtectionCoordinator(audio: SystemAudioController(), store: store)
        nightScheduleEnabled = settings.bool(forKey: "nightScheduleEnabled")
        nightStartText = settings.string(forKey: "nightStart") ?? "00:00"
        nightEndText = settings.string(forKey: "nightEnd") ?? "08:00"
        coordinator.onEvent = { [weak self] _ in self?.refresh() }
        refresh()
    }

    func start() {
        if lidMonitor == nil {
            let monitor = SystemLidMonitor { [weak self] closed in self?.receiveSystemLidState(closed) }
            monitor.start()
            lidMonitor = monitor
        }
        if displayMonitor == nil {
            let monitor = SystemDisplayMonitor { [weak self] sleeping in self?.receiveDisplaySleep(sleeping) }
            monitor.start()
            displayMonitor = monitor
        }
        if audioTimer == nil {
            audioTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let controller = SystemAudioController()
                    let processes = (try? controller.activeOutputProcesses()) ?? []
                    self.currentAudioProcesses = processes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    self.coordinator.receiveAudioSnapshot(processes)
                }
            }
        }
        if inboxTimer == nil {
            inboxTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.drainChromeInbox() }
            }
        }
        if nightTimer == nil {
            nightTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshNightProtection() }
            }
        }
        pollAudioProcesses()
        refreshNightProtection()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        coordinator.setEnabled(enabled)
        if !enabled {
            isNightProtectionActive = false
        }
        if enabled, let latestSystemLidClosed {
            coordinator.receiveLidState(closed: latestSystemLidClosed)
        }
        refreshNightProtection()
        refresh()
    }

    func receiveSystemLidState(_ closed: Bool) {
        latestSystemLidClosed = closed
        coordinator.receiveLidState(closed: closed)
        refresh()
    }

    func receiveDisplaySleep(_ sleeping: Bool) {
        isDisplaySleeping = sleeping
        refreshNightProtection()
    }

    func simulateLidClosed() {
        guard simulatedLidState != .closed else { return }
        simulatedLidState = .closed
        coordinator.receiveLidState(closed: true, simulated: true)
        refresh()
    }

    func simulateLidOpened() {
        guard simulatedLidState != .opened else { return }
        simulatedLidState = .opened
        coordinator.receiveLidState(closed: false, simulated: true)
        refresh()
    }

    func resetSimulationState() {
        simulatedLidState = .opened
        if isEnabled { coordinator.receiveLidState(closed: false, simulated: true) }
        refresh()
    }

    func applyNightSchedule() {
        settings.set(nightScheduleEnabled, forKey: "nightScheduleEnabled")
        settings.set(nightStartText, forKey: "nightStart")
        settings.set(nightEndText, forKey: "nightEnd")
        refreshNightProtection()
    }

    func sendMediaCommand(_ command: MediaCommand) {
        do {
            try mediaController.send(command)
            mediaStatus = "已发送系统媒体命令：\(mediaCommandName(command))"
        } catch {
            mediaStatus = "媒体命令失败：\(error.localizedDescription)"
        }
    }

    func clearLog() {
        try? store.clear()
        refresh()
    }

    private func drainChromeInbox() {
        guard let data = try? Data(contentsOf: inboxURL), data.count > inboxOffset else { return }
        let unread = data[inboxOffset...]
        inboxOffset = data.count
        for line in String(decoding: unread, as: UTF8.self).split(separator: "\n") {
            guard let decoded = try? ChromeBridgeFrame.decode(Data(line.utf8)),
                  (try? chromeDeduplicator.accept(decoded.eventID)) == true else { continue }
            chromeBridgeStatus = "已接收 Chrome 标签页事件"
            coordinator.receiveChromeEvidence(decoded.evidence)
        }
        refresh()
    }

    private func pollAudioProcesses() {
        let controller = SystemAudioController()
        let processes = (try? controller.activeOutputProcesses()) ?? []
        currentAudioProcesses = processes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        coordinator.receiveAudioSnapshot(processes)
    }

    private func refreshNightProtection() {
        let schedule = NightSchedule(
            startMinutes: minutes(from: nightStartText) ?? 0,
            endMinutes: minutes(from: nightEndText) ?? 8 * 60
        )
        let validTime = minutes(from: nightStartText) != nil && minutes(from: nightEndText) != nil
        nightScheduleStatus = validTime
            ? (nightScheduleEnabled ? "夜间时段：\(nightStartText)-\(nightEndText)（北京时间）" : "夜间静音未开启")
            : "时间格式应为 HH:mm"

        let shouldProtect = isEnabled && nightScheduleEnabled && isDisplaySleeping && validTime && schedule.isActive(at: Date())
        guard shouldProtect != isNightProtectionActive else { return }
        isNightProtectionActive = shouldProtect
        coordinator.receiveNightProtection(shouldProtect)
        refresh()
    }

    private func minutes(from text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    private func mediaCommandName(_ command: MediaCommand) -> String {
        switch command {
        case .previous: return "上一首"
        case .next: return "下一首"
        case .playPause: return "暂停/开始"
        }
    }

    private func refresh() {
        events = (try? store.load())?.reversed() ?? []
        switch coordinator.state {
        case .inactive: statusText = "守卫未开启"
        case .armed: statusText = "已开启，等待合盖"
        case .protecting: statusText = "正在保护内建扬声器"
        case .unavailable: statusText = "未发现可控制的内建扬声器"
        }
    }
}

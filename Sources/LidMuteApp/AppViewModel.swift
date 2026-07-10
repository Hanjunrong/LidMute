import Combine
import Foundation
import LidMuteCore

@MainActor
final class AppViewModel: ObservableObject {
    @Published var isEnabled = false
    @Published private(set) var statusText = "守卫未开启"
    @Published private(set) var events: [LidMuteEvent] = []
    @Published private(set) var chromeBridgeStatus = "等待 Chrome 扩展连接"

    private let coordinator: ProtectionCoordinator
    private let store: JSONLineEventStore
    private let inboxURL: URL
    private var inboxOffset = 0
    private var audioTimer: Timer?
    private var inboxTimer: Timer?
    private var lidMonitor: SystemLidMonitor?

    init() {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LidMute", directoryHint: .isDirectory)
        store = JSONLineEventStore(url: applicationSupport.appending(path: "events.jsonl"))
        inboxURL = applicationSupport.appending(path: "chrome-inbox.jsonl")
        coordinator = ProtectionCoordinator(audio: SystemAudioController(), store: store)
        coordinator.onEvent = { [weak self] _ in self?.refresh() }
        refresh()
    }

    func start() {
        if lidMonitor == nil {
            let monitor = SystemLidMonitor { [weak self] closed in self?.receiveSystemLidState(closed) }
            monitor.start()
            lidMonitor = monitor
        }
        audioTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let controller = SystemAudioController()
                self.coordinator.receiveAudioSnapshot((try? controller.activeOutputProcesses()) ?? [])
            }
        }
        inboxTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.drainChromeInbox() }
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        coordinator.setEnabled(enabled)
        refresh()
    }

    func receiveSystemLidState(_ closed: Bool) {
        coordinator.receiveLidState(closed: closed)
        refresh()
    }

    func simulateLidClosed() {
        coordinator.receiveLidState(closed: true, simulated: true)
        refresh()
    }

    func simulateLidOpened() {
        coordinator.receiveLidState(closed: false, simulated: true)
        refresh()
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
            guard let decoded = try? ChromeBridgeFrame.decode(Data(line.utf8)) else { continue }
            chromeBridgeStatus = "已接收 Chrome 标签页事件"
            coordinator.receiveChromeEvidence(decoded.evidence)
        }
        refresh()
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

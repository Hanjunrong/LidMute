import Foundation

@MainActor
public final class ProtectionCoordinator {
    public private(set) var state: ProtectionState = .inactive
    public private(set) var isEnabled = false
    public var onEvent: ((LidMuteEvent) -> Void)?

    private let audio: AudioControlling
    private let store: EventStoring
    private var savedState: AudioDeviceState?
    private var targetDevice: AudioDevice?
    private var sequence: UInt64 = 0

    public init(audio: AudioControlling, store: EventStoring) {
        self.audio = audio
        self.store = store
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            restoreIfNeeded()
            state = .inactive
            record(.protectionDisabled, "守卫已关闭")
        } else {
            state = .armed
            record(.protectionEnabled, "守卫已开启，等待合盖")
        }
    }

    public func receiveLidState(closed: Bool, simulated: Bool = false) {
        guard isEnabled else { return }
        if closed {
            record(simulated ? .simulation : .lidClosed, simulated ? "模拟合盖" : "检测到合盖")
            armAndMute()
        } else {
            record(simulated ? .simulation : .lidOpened, simulated ? "模拟开盖" : "检测到开盖")
            restoreIfNeeded()
            state = .armed
        }
    }

    public func receiveAudioSnapshot(_ processes: [AudioProcess]) {
        guard isEnabled, state == .protecting else { return }
        let active = processes.filter(\.isOutputActive)
        for process in active {
            record(.audioProcessDetected, "合盖期间检测到音频输出进程：\(process.name)", process: process)
        }
        if !active.isEmpty, let targetDevice {
            do {
                try audio.enforceSilence(on: targetDevice)
                record(.muteEnforced, "检测到音频输出，已再次静音内建扬声器")
            } catch {
                record(.error, "无法重新静音内建扬声器：\(error.localizedDescription)")
            }
        }
    }

    public func receiveChromeEvidence(_ evidence: ChromeTabEvidence) {
        let chromeProcess = try? audio.activeOutputProcesses().first {
            $0.isOutputActive && ($0.bundleID?.localizedCaseInsensitiveContains("chrome") == true || $0.name.localizedCaseInsensitiveContains("chrome"))
        }
        let correlation: CorrelationStatus = chromeProcess == nil ? .browserObservedOnly : .systemMatched
        record(.chromeTabAudible, "Chrome 标签页开始发声：\(evidence.title)", process: chromeProcess, chromeTab: evidence, correlation: correlation)

        if isEnabled, state == .protecting, let targetDevice {
            do {
                try audio.enforceSilence(on: targetDevice)
                record(.muteEnforced, "Chrome 标签页发声，已强制静音内建扬声器", chromeTab: evidence, correlation: correlation)
            } catch {
                record(.error, "Chrome 事件后静音失败：\(error.localizedDescription)", chromeTab: evidence, correlation: correlation)
            }
        }
    }

    private func armAndMute() {
        do {
            guard let device = try audio.builtInSpeaker() else {
                state = .unavailable
                record(.error, "未找到可控制的内建扬声器")
                return
            }
            targetDevice = device
            savedState = try audio.captureState(of: device)
            try audio.enforceSilence(on: device)
            state = .protecting
            record(.muteEnforced, "已静音内建扬声器：\(device.name)")
        } catch {
            state = .unavailable
            record(.error, "无法启动扬声器保护：\(error.localizedDescription)")
        }
    }

    private func restoreIfNeeded() {
        defer {
            savedState = nil
            targetDevice = nil
        }
        guard let savedState, let targetDevice else { return }
        do {
            try audio.restore(savedState, on: targetDevice)
            record(.restored, "已恢复内建扬声器合盖前状态")
        } catch {
            record(.error, "无法恢复内建扬声器状态：\(error.localizedDescription)")
        }
    }

    private func record(
        _ kind: LidMuteEventKind,
        _ detail: String,
        process: AudioProcess? = nil,
        chromeTab: ChromeTabEvidence? = nil,
        correlation: CorrelationStatus = .notApplicable
    ) {
        sequence += 1
        let event = LidMuteEvent(sequence: sequence, kind: kind, detail: detail, process: process, chromeTab: chromeTab, correlation: correlation)
        try? store.append(event)
        onEvent?(event)
    }
}

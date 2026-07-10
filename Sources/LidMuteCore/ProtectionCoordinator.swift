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
    private var disableRestoreState: AudioDeviceState?
    private var disableRestoreDevice: AudioDevice?
    private var observedLidClosed: Bool?
    private var activeOutputPIDs: Set<Int32> = []
    private var lastSilenceError: String?
    private var sequence: UInt64 = 0

    public init(audio: AudioControlling, store: EventStoring) {
        self.audio = audio
        self.store = store
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled {
            restoreForGuardDisable()
            resetObservationState()
            state = .inactive
            record(.protectionDisabled, "守卫已关闭")
        } else {
            clearCapturedState()
            resetObservationState()
            state = .armed
            record(.protectionEnabled, "守卫已开启，等待合盖")
        }
    }

    public func receiveLidState(closed: Bool, simulated: Bool = false) {
        guard isEnabled else { return }
        guard observedLidClosed != closed else { return }
        observedLidClosed = closed
        activeOutputPIDs.removeAll()
        lastSilenceError = nil

        if closed {
            record(simulated ? .simulation : .lidClosed, simulated ? "模拟合盖" : "检测到合盖")
            armAndMute()
        } else {
            record(simulated ? .simulation : .lidOpened, simulated ? "模拟开盖" : "检测到开盖")
            state = restoreForLidOpen() ? .armed : .unavailable
        }
    }

    public func receiveAudioSnapshot(_ processes: [AudioProcess]) {
        guard isEnabled, state == .protecting else { return }
        let active = processes.filter(\.isOutputActive)
        let currentPIDs = Set(active.map(\.pid))
        let newlyActive = active.filter { !activeOutputPIDs.contains($0.pid) }
        activeOutputPIDs = currentPIDs
        if active.isEmpty {
            lastSilenceError = nil
        }

        for process in newlyActive {
            record(.audioProcessDetected, "合盖期间检测到音频输出进程：\(process.name)", process: process)
        }

        if !active.isEmpty, let targetDevice {
            do {
                try audio.enforceSilence(on: targetDevice)
                lastSilenceError = nil
                if !newlyActive.isEmpty {
                    record(.muteEnforced, "检测到新的音频输出，已再次静音内建扬声器")
                }
            } catch {
                let detail = "无法重新静音内建扬声器：\(error.localizedDescription)"
                if detail != lastSilenceError {
                    record(.error, detail)
                    lastSilenceError = detail
                }
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
            let capturedState = try audio.captureState(of: device)
            savedState = capturedState
            if disableRestoreState == nil {
                disableRestoreState = capturedState
                disableRestoreDevice = device
            }
            try audio.enforceSilence(on: device)
            state = .protecting
            record(.muteEnforced, "已静音内建扬声器：\(device.name)")
        } catch {
            state = .unavailable
            record(.error, "无法启动扬声器保护：\(error.localizedDescription)")
        }
    }

    private func restoreForLidOpen() -> Bool {
        guard let savedState, let targetDevice else { return true }
        do {
            let safeVolume = savedState.usedVolumeFallback ? 0 : savedState.volume
            let openState = AudioDeviceState(
                muted: true,
                volume: safeVolume,
                usedVolumeFallback: savedState.usedVolumeFallback
            )
            try audio.restore(openState, on: targetDevice)
            self.savedState = nil
            self.targetDevice = nil
            let detail = savedState.usedVolumeFallback
                ? "设备不支持可写静音属性，开盖后继续保持音量为 0"
                : "已恢复内建扬声器合盖前音量并保持静音"
            record(.restored, detail)
            return true
        } catch {
            record(.error, "无法恢复内建扬声器状态：\(error.localizedDescription)")
            return false
        }
    }

    private func restoreForGuardDisable() {
        guard let disableRestoreState, let disableRestoreDevice else {
            clearCapturedState()
            return
        }
        do {
            try audio.restore(disableRestoreState, on: disableRestoreDevice)
            record(.restored, "守卫关闭，已恢复内建扬声器合盖前状态")
            clearCapturedState()
        } catch {
            record(.error, "无法恢复内建扬声器状态：\(error.localizedDescription)")
        }
    }

    private func clearCapturedState() {
        savedState = nil
        targetDevice = nil
        disableRestoreState = nil
        disableRestoreDevice = nil
    }

    private func resetObservationState() {
        observedLidClosed = nil
        activeOutputPIDs.removeAll()
        lastSilenceError = nil
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

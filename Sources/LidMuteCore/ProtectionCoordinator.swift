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
    private var activeSources: Set<ProtectionSource> = []
    private var observedPhysicalLidClosed: Bool?
    private var observedSimulation: SimulationLidState?
    private var activeOutputPIDs: Set<Int32> = []
    private var lastSilenceError: String?
    private var sequence: UInt64 = 0

    public init(
        audio: AudioControlling,
        store: EventStoring
    ) {
        self.audio = audio
        self.store = store
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled {
            restoreForGuardDisable()
            activeSources.removeAll()
            resetObservationState(preservingSimulation: true)
            state = .inactive
            record(.protectionDisabled, "守卫已关闭")
        } else {
            let simulationToReplay = observedSimulation
            clearCapturedState()
            activeSources.removeAll()
            resetObservationState()
            state = .armed
            record(.protectionEnabled, "守卫已开启，等待合盖")
            if simulationToReplay == .closed {
                receiveSimulation(.closed)
            }
        }
    }

    public func receivePhysicalLid(closed: Bool) {
        guard isEnabled else { return }
        guard observedPhysicalLidClosed != closed else { return }
        observedPhysicalLidClosed = closed
        activeOutputPIDs.removeAll()
        lastSilenceError = nil

        if closed {
            record(.lidClosed, "检测到合盖")
            updateProtectionSource(.physicalLid, active: true)
        } else {
            record(.lidOpened, "检测到开盖")
            updateProtectionSource(.physicalLid, active: false)
        }
    }

    public func receiveSimulation(_ simulation: SimulationLidState) {
        guard isEnabled else {
            observedSimulation = simulation == .reset ? nil : simulation
            return
        }
        guard simulation == .reset || observedSimulation != simulation else { return }

        switch simulation {
        case .closed:
            observedSimulation = .closed
            activeOutputPIDs.removeAll()
            lastSilenceError = nil
            record(.simulation, "模拟合盖")
            updateProtectionSource(.simulation, active: true)
        case .opened:
            observedSimulation = .opened
            activeOutputPIDs.removeAll()
            lastSilenceError = nil
            record(.simulation, "模拟开盖")
            updateProtectionSource(.simulation, active: false)
        case .reset:
            observedSimulation = nil
            activeOutputPIDs.removeAll()
            lastSilenceError = nil
            record(.simulation, "已重置模拟合盖状态")
            updateProtectionSource(.simulation, active: false)
        }
    }

    public func receiveLidState(closed: Bool, simulated: Bool = false) {
        if simulated {
            receiveSimulation(closed ? .closed : .opened)
        } else {
            receivePhysicalLid(closed: closed)
        }
    }

    public func receiveNightProtection(_ active: Bool) {
        guard isEnabled else { return }
        record(active ? .nightProtectionStarted : .nightProtectionEnded, active ? "进入夜间息屏静音时段" : "夜间息屏静音时段结束")
        updateProtectionSource(.night, active: active)
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
        guard isEnabled else { return }
        let chromeProcess = try? audio.activeOutputProcesses().first {
            $0.isOutputActive && ($0.bundleID?.localizedCaseInsensitiveContains("chrome") == true || $0.name.localizedCaseInsensitiveContains("chrome"))
        }
        let correlation: CorrelationStatus = chromeProcess == nil ? .browserObservedOnly : .systemMatched
        record(.chromeTabAudible, "Chrome 标签页开始发声：\(evidence.title)", process: chromeProcess, chromeTab: evidence, correlation: correlation)

        if state == .protecting, let targetDevice {
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

    private func updateProtectionSource(_ source: ProtectionSource, active: Bool) {
        let wasProtected = !activeSources.isEmpty
        if active {
            guard activeSources.insert(source).inserted else { return }
            if wasProtected {
                if let targetDevice { try? audio.enforceSilence(on: targetDevice) }
            } else {
                armAndMute()
            }
            return
        }

        guard activeSources.remove(source) != nil, activeSources.isEmpty else {
            return
        }

        if source == .physicalLid || source == .simulation {
            state = restoreForLidOpen() ? .armed : .unavailable
        } else {
            restoreForNightEnd()
            state = .armed
        }
    }

    private func restoreForLidOpen() -> Bool {
        guard let savedState, let targetDevice else { return true }
        do {
            let safeVolume = savedState.usedVolumeFallback ? 0 : savedState.volume
            let openState = AudioDeviceState(
                muted: savedState.muted,
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
        restoreFullState(detail: "守卫关闭，已恢复内建扬声器合盖前状态")
    }

    private func restoreForNightEnd() {
        restoreFullState(detail: "夜间息屏静音时段结束，已恢复进入时段前状态")
    }

    private func restoreFullState(detail: String) {
        guard let disableRestoreState, let disableRestoreDevice else {
            clearCapturedState()
            return
        }
        do {
            try audio.restore(disableRestoreState, on: disableRestoreDevice)
            record(.restored, detail)
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

    private func resetObservationState(preservingSimulation: Bool = false) {
        observedPhysicalLidClosed = nil
        if !preservingSimulation {
            observedSimulation = nil
        }
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

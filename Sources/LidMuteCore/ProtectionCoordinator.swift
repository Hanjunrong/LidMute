import Foundation

@MainActor
public final class ProtectionCoordinator {
    public private(set) var state: ProtectionState = .inactive
    public private(set) var isEnabled = false
    public var onEvent: ((LidMuteEvent) -> Void)?

    private let protection: any SpeakerProtectionApplying
    private let processEvidence: any AudioProcessEvidenceProviding
    private let store: EventStoring
    private var activeSources: Set<ProtectionSource> = []
    private var observedPhysicalLidClosed: Bool?
    private var observedSimulation: SimulationLidState?
    private var activeOutputPIDs: Set<Int32> = []
    private var lastSilenceError: String?
    private var sequence: UInt64 = 0

    public init(
        protection: any SpeakerProtectionApplying,
        processEvidence: any AudioProcessEvidenceProviding,
        store: EventStoring
    ) {
        self.protection = protection
        self.processEvidence = processEvidence
        self.store = store
    }

    public convenience init<ProtectionAndEvidence>(
        audio: ProtectionAndEvidence,
        store: EventStoring
    ) where ProtectionAndEvidence: SpeakerProtectionApplying & AudioProcessEvidenceProviding {
        self.init(protection: audio, processEvidence: audio, store: store)
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if !enabled {
            let outcome = activeSources.isEmpty
                ? SpeakerRecoveryOutcome.noPendingRecovery
                : perform(.end)
            isEnabled = false
            activeSources.removeAll()
            resetObservationState(preservingSimulation: true)
            state = endState(for: outcome, readyState: .inactive)
            record(.protectionDisabled, "守卫已关闭")
            return
        }

        let simulationToReplay = observedSimulation
        isEnabled = true
        activeSources.removeAll()
        resetObservationState()
        state = .armed
        record(.protectionEnabled, "守卫已开启，等待合盖")
        if simulationToReplay == .closed {
            receiveSimulation(.closed)
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
        record(
            active ? .nightProtectionStarted : .nightProtectionEnded,
            active ? "进入夜间息屏静音时段" : "夜间息屏静音时段结束"
        )
        updateProtectionSource(.night, active: active)
    }

    public func receiveAudioSnapshot(_ processes: [AudioProcess]) {
        guard isEnabled, !activeSources.isEmpty else { return }
        let active = processes.filter(\.isOutputActive)
        let currentPIDs = Set(active.map(\.pid))
        let newlyActive = active.filter { !activeOutputPIDs.contains($0.pid) }
        activeOutputPIDs = currentPIDs
        if active.isEmpty { lastSilenceError = nil }

        for process in newlyActive {
            record(.audioProcessDetected, "合盖期间检测到音频输出进程：\(process.name)", process: process)
        }

        guard !active.isEmpty else { return }
        let outcome = perform(.reinforce)
        publishReinforcement(outcome, successDetail: newlyActive.isEmpty ? nil : "检测到新的音频输出，已再次静音内建扬声器")
    }

    public func receiveChromeEvidence(_ evidence: ChromeTabEvidence) {
        guard isEnabled else { return }
        let chromeProcess: AudioProcess?
        do {
            chromeProcess = try processEvidence.activeOutputProcesses().first {
                $0.isOutputActive && (
                    $0.bundleID?.localizedCaseInsensitiveContains("chrome") == true ||
                    $0.name.localizedCaseInsensitiveContains("chrome")
                )
            }
        } catch {
            chromeProcess = nil
            record(.error, "无法读取系统音频进程：\(error.localizedDescription)")
        }
        let correlation: CorrelationStatus = chromeProcess == nil ? .browserObservedOnly : .systemMatched
        record(
            .chromeTabAudible,
            "Chrome 标签页开始发声：\(evidence.title)",
            process: chromeProcess,
            chromeTab: evidence,
            correlation: correlation
        )

        guard state == .protecting else { return }
        let outcome = perform(.reinforce)
        publishReinforcement(
            outcome,
            successDetail: "Chrome 标签页发声，已强制静音内建扬声器",
            chromeTab: evidence,
            correlation: correlation
        )
    }

    public func receiveAudioRouteChanged() {
        guard isEnabled, !activeSources.isEmpty else { return }
        let outcome = perform(.routeChangedWhileProtectionRequired(sources: activeSources))
        state = beginState(for: outcome)
        if state == .protecting {
            record(.muteEnforced, "音频路由变化后已重新验证并保护内建扬声器")
        } else {
            record(.error, "音频路由变化后无法保护内建扬声器")
        }
    }

    public func endProtectionForShutdown() -> SpeakerRecoveryOutcome {
        let outcome = perform(.end)
        activeSources.removeAll()
        state = endState(for: outcome, readyState: isEnabled ? .armed : .inactive)
        return outcome
    }

    private func updateProtectionSource(_ source: ProtectionSource, active: Bool) {
        let wasProtected = !activeSources.isEmpty
        if active {
            guard activeSources.insert(source).inserted else { return }
            guard !wasProtected else { return }
            let outcome = perform(.begin(sources: activeSources))
            state = beginState(for: outcome)
            if state == .protecting {
                record(.muteEnforced, "已静音内建扬声器")
            } else {
                record(.error, "无法启动扬声器保护")
            }
            return
        }

        guard activeSources.remove(source) != nil, activeSources.isEmpty else { return }
        let outcome = perform(.end)
        state = endState(for: outcome, readyState: .armed)
        if state == .armed {
            record(.restored, "已恢复内建扬声器保护前状态")
        } else {
            record(.error, "无法恢复内建扬声器状态")
        }
    }

    private func perform(_ action: SpeakerProtectionAction) -> SpeakerRecoveryOutcome {
        let result = LockedRecoveryOutcome()
        let semaphore = DispatchSemaphore(value: 0)
        let protection = protection
        Task.detached {
            let outcome = await protection.apply(action)
            result.set(outcome)
            semaphore.signal()
        }
        semaphore.wait()
        return result.get()
    }

    private func beginState(for outcome: SpeakerRecoveryOutcome) -> ProtectionState {
        switch outcome {
        case .noPendingRecovery, .failedButVerifiedSilent:
            return .protecting
        case .restored:
            return .protecting
        case .waitingForMatchingDevice, .corruptSnapshot, .unsupportedSnapshot, .failedSafetyUnknown:
            return .unavailable
        }
    }

    private func endState(
        for outcome: SpeakerRecoveryOutcome,
        readyState: ProtectionState
    ) -> ProtectionState {
        switch outcome {
        case .noPendingRecovery, .restored:
            return readyState
        case .waitingForMatchingDevice, .corruptSnapshot, .unsupportedSnapshot,
             .failedButVerifiedSilent, .failedSafetyUnknown:
            return .unavailable
        }
    }

    private func publishReinforcement(
        _ outcome: SpeakerRecoveryOutcome,
        successDetail: String?,
        chromeTab: ChromeTabEvidence? = nil,
        correlation: CorrelationStatus = .notApplicable
    ) {
        switch outcome {
        case .noPendingRecovery, .failedButVerifiedSilent:
            state = .protecting
            lastSilenceError = nil
            if let successDetail {
                record(.muteEnforced, successDetail, chromeTab: chromeTab, correlation: correlation)
            }
        case .restored, .waitingForMatchingDevice, .corruptSnapshot,
             .unsupportedSnapshot, .failedSafetyUnknown:
            state = .unavailable
            let detail = "无法重新静音内建扬声器"
            if detail != lastSilenceError {
                record(.error, detail, chromeTab: chromeTab, correlation: correlation)
                lastSilenceError = detail
            }
        }
    }

    private func resetObservationState(preservingSimulation: Bool = false) {
        observedPhysicalLidClosed = nil
        if !preservingSimulation { observedSimulation = nil }
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
        let event = LidMuteEvent(
            sequence: sequence,
            kind: kind,
            detail: detail,
            process: process,
            chromeTab: chromeTab,
            correlation: correlation
        )
        do {
            try store.append(event)
        } catch {
            // Event logging is observational and cannot relax speaker safety.
        }
        onEvent?(event)
    }
}

private final class LockedRecoveryOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: SpeakerRecoveryOutcome?

    func set(_ outcome: SpeakerRecoveryOutcome) {
        lock.lock()
        self.outcome = outcome
        lock.unlock()
    }

    func get() -> SpeakerRecoveryOutcome {
        lock.lock()
        defer { lock.unlock() }
        return outcome ?? .failedSafetyUnknown
    }
}

@MainActor
public final class SimulationProtectionLifecycle {
    private let coordinator: ProtectionCoordinator

    public init(coordinator: ProtectionCoordinator) {
        self.coordinator = coordinator
    }

    public func update(_ state: SimulationLidState) {
        coordinator.receiveSimulation(state)
    }
}

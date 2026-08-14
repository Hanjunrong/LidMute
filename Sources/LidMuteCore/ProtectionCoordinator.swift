import Foundation

@MainActor
public final class ProtectionCoordinator<Protection: SpeakerProtectionApplying> {
    public private(set) var state: ProtectionState = .inactive
    public private(set) var isEnabled = false
    public var onEvent: ((LidMuteEvent) -> Void)?

    private let protection: Protection
    private let processEvidence: any AudioProcessEvidenceProviding
    private let store: EventStoring
    private var activeSources: Set<ProtectionSource> = []
    private var observedPhysicalLidClosed: Bool?
    private var observedSimulation: SimulationLidState?
    private var activeOutputPIDs: Set<Int32> = []
    private var lastSilenceError: String?
    private var sequence: UInt64 = 0
    private var transitionTask: Task<Void, Never>?
    private var transitionSequence: UInt64 = 0
    private var bufferedObservationEvents: [LidMuteEvent]?
    private var observationLoggingTask: Task<Void, Never>?

    public init(
        protection: Protection,
        processEvidence: any AudioProcessEvidenceProviding,
        store: EventStoring
    ) {
        self.protection = protection
        self.processEvidence = processEvidence
        self.store = store
    }

    public convenience init(
        audio: Protection,
        store: EventStoring
    ) where Protection: AudioProcessEvidenceProviding {
        self.init(protection: audio, processEvidence: audio, store: store)
    }

    public func setEnabled(_ enabled: Bool) async {
        _ = await enqueue(.setEnabled(enabled))
    }

    public func receivePhysicalLid(closed: Bool) async {
        _ = await enqueue(.physicalLid(closed))
    }

    public func receiveSimulation(_ simulation: SimulationLidState) async {
        _ = await enqueue(.simulation(simulation))
    }

    public func receiveLidState(closed: Bool, simulated: Bool = false) async {
        _ = await enqueue(simulated ? .simulation(closed ? .closed : .opened) : .physicalLid(closed))
    }

    public func receiveNightProtection(_ active: Bool) async {
        _ = await enqueue(.night(active))
    }

    public func receiveAudioSnapshot(_ processes: [AudioProcess]) async {
        _ = await enqueue(.audioSnapshot(processes))
    }

    public func receiveChromeEvidence(_ evidence: ChromeTabEvidence) async {
        _ = await enqueue(.chromeEvidence(evidence))
    }

    public func receiveAudioRouteChanged() async {
        _ = await enqueue(.audioRouteChanged)
    }

    public func endProtectionForShutdown() async -> SpeakerRecoveryOutcome {
        await enqueue(.shutdown)
    }

    public func flushObservationLogging() async {
        let predecessor = transitionTask
        transitionSequence += 1
        let sequence = transitionSequence
        let fence = Task { @MainActor in
            if let predecessor { await predecessor.value }
        }
        transitionTask = fence
        await fence.value
        if transitionSequence == sequence { transitionTask = nil }

        let loggingTail = observationLoggingTask
        await loggingTail?.value
    }

    private func enqueue(_ input: ProtectionCoordinatorInput) async -> SpeakerRecoveryOutcome {
        let predecessor = transitionTask
        transitionSequence += 1
        let sequence = transitionSequence
        let task = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return SpeakerRecoveryOutcome.failedSafetyUnknown }
            return await self.process(input)
        }
        transitionTask = Task { _ = await task.value }
        let outcome = await task.value
        if transitionSequence == sequence { transitionTask = nil }
        return outcome
    }

    private func process(_ input: ProtectionCoordinatorInput) async -> SpeakerRecoveryOutcome {
        bufferedObservationEvents = []
        guard let prepared = prepare(input) else {
            enqueueBufferedObservationEvents()
            return .noPendingRecovery
        }
        let outcome = await protection.apply(prepared.action)
        complete(prepared.completion, outcome: outcome)
        enqueueBufferedObservationEvents()
        return outcome
    }

    private func prepare(_ input: ProtectionCoordinatorInput) -> PreparedProtectionAction? {
        switch input {
        case let .setEnabled(enabled):
            return prepareEnabled(enabled)
        case let .physicalLid(closed):
            guard isEnabled, observedPhysicalLidClosed != closed else { return nil }
            observedPhysicalLidClosed = closed
            activeOutputPIDs.removeAll()
            lastSilenceError = nil
            record(closed ? .lidClosed : .lidOpened, closed ? "检测到合盖" : "检测到开盖")
            return prepareProtectionSource(.physicalLid, active: closed)
        case let .simulation(simulation):
            return prepareSimulation(simulation)
        case let .night(active):
            guard isEnabled else { return nil }
            record(
                active ? .nightProtectionStarted : .nightProtectionEnded,
                active ? "进入夜间息屏静音时段" : "夜间息屏静音时段结束"
            )
            return prepareProtectionSource(.night, active: active)
        case let .audioSnapshot(processes):
            return prepareAudioSnapshot(processes)
        case let .chromeEvidence(evidence):
            return prepareChromeEvidence(evidence)
        case .audioRouteChanged:
            guard isEnabled, !activeSources.isEmpty else { return nil }
            return PreparedProtectionAction(
                action: .routeChangedWhileProtectionRequired(sources: activeSources),
                completion: .routeChanged
            )
        case .shutdown:
            isEnabled = false
            activeSources.removeAll()
            resetObservationState(preservingSimulation: true)
            return PreparedProtectionAction(
                action: .end,
                completion: .end(readyState: .inactive, recordsRestored: false)
            )
        }
    }

    private func prepareEnabled(_ enabled: Bool) -> PreparedProtectionAction? {
        guard enabled != isEnabled else { return nil }
        if !enabled {
            let needsRestore = !activeSources.isEmpty
            isEnabled = false
            activeSources.removeAll()
            resetObservationState(preservingSimulation: true)
            record(.protectionDisabled, "守卫已关闭")
            guard needsRestore else {
                state = .inactive
                return nil
            }
            return PreparedProtectionAction(
                action: .end,
                completion: .end(readyState: .inactive, recordsRestored: false)
            )
        }

        let simulationToReplay = observedSimulation
        isEnabled = true
        activeSources.removeAll()
        resetObservationState()
        state = .armed
        record(.protectionEnabled, "守卫已开启，等待合盖")
        guard simulationToReplay == .closed else { return nil }
        return prepareSimulation(.closed)
    }

    private func prepareSimulation(_ simulation: SimulationLidState) -> PreparedProtectionAction? {
        guard isEnabled else {
            observedSimulation = simulation == .reset ? nil : simulation
            return nil
        }
        guard simulation == .reset || observedSimulation != simulation else { return nil }

        switch simulation {
        case .closed:
            observedSimulation = .closed
            record(.simulation, "模拟合盖")
        case .opened:
            observedSimulation = .opened
            record(.simulation, "模拟开盖")
        case .reset:
            observedSimulation = nil
            record(.simulation, "已重置模拟合盖状态")
        }
        activeOutputPIDs.removeAll()
        lastSilenceError = nil
        return prepareProtectionSource(.simulation, active: simulation == .closed)
    }

    private func prepareProtectionSource(_ source: ProtectionSource, active: Bool) -> PreparedProtectionAction? {
        let wasProtected = !activeSources.isEmpty
        if active {
            guard activeSources.insert(source).inserted else { return nil }
            guard !wasProtected else { return nil }
            return PreparedProtectionAction(action: .begin(sources: activeSources), completion: .begin)
        }

        guard activeSources.remove(source) != nil, activeSources.isEmpty else { return nil }
        return PreparedProtectionAction(
            action: .end,
            completion: .end(readyState: .armed, recordsRestored: true)
        )
    }

    private func prepareAudioSnapshot(_ processes: [AudioProcess]) -> PreparedProtectionAction? {
        guard isEnabled, !activeSources.isEmpty else { return nil }
        let active = processes.filter(\.isOutputActive)
        let currentPIDs = Set(active.map(\.pid))
        let newlyActive = active.filter { !activeOutputPIDs.contains($0.pid) }
        activeOutputPIDs = currentPIDs
        if active.isEmpty { lastSilenceError = nil }

        for process in newlyActive {
            record(.audioProcessDetected, "合盖期间检测到音频输出进程：\(process.name)", process: process)
        }

        guard !active.isEmpty else { return nil }
        return PreparedProtectionAction(
            action: .reinforce,
            completion: .reinforcement(
                successDetail: newlyActive.isEmpty ? nil : "检测到新的音频输出，已再次静音内建扬声器",
                chromeTab: nil,
                correlation: .notApplicable
            )
        )
    }

    private func prepareChromeEvidence(_ evidence: ChromeTabEvidence) -> PreparedProtectionAction? {
        guard isEnabled else { return nil }
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

        guard state == .protecting else { return nil }
        return PreparedProtectionAction(
            action: .reinforce,
            completion: .reinforcement(
                successDetail: "Chrome 标签页发声，已强制静音内建扬声器",
                chromeTab: evidence,
                correlation: correlation
            )
        )
    }

    private func complete(_ completion: ProtectionCompletion, outcome: SpeakerRecoveryOutcome) {
        switch completion {
        case .begin:
            state = beginState(for: outcome)
            record(state == .protecting ? .muteEnforced : .error,
                   state == .protecting ? "已静音内建扬声器" : "无法启动扬声器保护")
        case let .end(readyState, recordsRestored):
            state = endState(for: outcome, readyState: readyState)
            if recordsRestored {
                record(state == readyState ? .restored : .error,
                       state == readyState ? "已恢复内建扬声器保护前状态" : "无法恢复内建扬声器状态")
            }
        case let .reinforcement(successDetail, chromeTab, correlation):
            publishReinforcement(
                outcome,
                successDetail: successDetail,
                chromeTab: chromeTab,
                correlation: correlation
            )
        case .routeChanged:
            state = beginState(for: outcome)
            record(
                state == .protecting ? .muteEnforced : .error,
                state == .protecting
                    ? "音频路由变化后已重新验证并保护内建扬声器"
                    : "音频路由变化后无法保护内建扬声器"
            )
        }
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
        if bufferedObservationEvents != nil {
            bufferedObservationEvents?.append(event)
            return
        }
        persistSynchronously(event)
    }

    private func persistSynchronously(_ event: LidMuteEvent) {
        do {
            try store.append(event)
        } catch {
            // Event logging is observational and cannot relax speaker safety.
        }
        onEvent?(event)
    }

    private func enqueueBufferedObservationEvents() {
        let events = bufferedObservationEvents ?? []
        bufferedObservationEvents = nil
        guard !events.isEmpty else { return }

        let predecessor = observationLoggingTask
        let store = store
        let task = Task.detached(priority: .utility) { [weak self] in
            await predecessor?.value
            for event in events {
                do {
                    try store.append(event)
                } catch {
                    // Event logging is observational and cannot relax speaker safety.
                }
                await self?.publishLoggedEvent(event)
            }
        }
        observationLoggingTask = task
    }

    private func publishLoggedEvent(_ event: LidMuteEvent) {
        onEvent?(event)
    }
}

private enum ProtectionCoordinatorInput: Sendable {
    case setEnabled(Bool)
    case physicalLid(Bool)
    case simulation(SimulationLidState)
    case night(Bool)
    case audioSnapshot([AudioProcess])
    case chromeEvidence(ChromeTabEvidence)
    case audioRouteChanged
    case shutdown
}

private struct PreparedProtectionAction {
    let action: SpeakerProtectionAction
    let completion: ProtectionCompletion
}

private enum ProtectionCompletion {
    case begin
    case end(readyState: ProtectionState, recordsRestored: Bool)
    case reinforcement(
        successDetail: String?,
        chromeTab: ChromeTabEvidence?,
        correlation: CorrelationStatus
    )
    case routeChanged
}

@MainActor
public final class SimulationProtectionLifecycle<Protection: SpeakerProtectionApplying> {
    private let coordinator: ProtectionCoordinator<Protection>

    public init(coordinator: ProtectionCoordinator<Protection>) {
        self.coordinator = coordinator
    }

    public func update(_ state: SimulationLidState) async {
        await coordinator.receiveSimulation(state)
    }
}

@MainActor
extension SimulationProtectionLifecycle where Protection: SynchronousSpeakerProtectionApplying {
    func update(_ state: SimulationLidState) {
        coordinator.receiveSimulation(state)
    }
}

@MainActor
extension ProtectionCoordinator where Protection: SynchronousSpeakerProtectionApplying {
    func setEnabled(_ enabled: Bool) {
        applySynchronously(.setEnabled(enabled))
    }

    func receivePhysicalLid(closed: Bool) {
        applySynchronously(.physicalLid(closed))
    }

    func receiveSimulation(_ simulation: SimulationLidState) {
        applySynchronously(.simulation(simulation))
    }

    func receiveLidState(closed: Bool, simulated: Bool = false) {
        applySynchronously(simulated ? .simulation(closed ? .closed : .opened) : .physicalLid(closed))
    }

    func receiveNightProtection(_ active: Bool) {
        applySynchronously(.night(active))
    }

    func receiveAudioSnapshot(_ processes: [AudioProcess]) {
        applySynchronously(.audioSnapshot(processes))
    }

    func receiveChromeEvidence(_ evidence: ChromeTabEvidence) {
        applySynchronously(.chromeEvidence(evidence))
    }

    func receiveAudioRouteChanged() {
        applySynchronously(.audioRouteChanged)
    }

    private func applySynchronously(_ input: ProtectionCoordinatorInput) {
        guard let prepared = prepare(input) else { return }
        complete(prepared.completion, outcome: protection.applySynchronously(prepared.action))
    }
}

import Foundation

@MainActor
public protocol ApplicationMonitoring: AnyObject {
    func startAll() throws
    func startRouteOnly() throws
    func stopAll()
}

@MainActor
public final class ApplicationLifecycleCoordinator {
    public private(set) var state: AppLifecycleState = .recovering

    private let recovery: any PendingSpeakerRecovering
    private let monitors: any ApplicationMonitoring
    private var hasStarted = false
    private var isStopped = false

    public init(
        recovery: any PendingSpeakerRecovering,
        monitors: any ApplicationMonitoring
    ) {
        self.recovery = recovery
        self.monitors = monitors
    }

    public func start() async {
        guard !hasStarted, !isStopped else { return }
        hasStarted = true
        state = .recovering
        await recoverAndPublish()
    }

    public func receiveAudioRouteChanged() async {
        guard !isStopped,
              case .recoveryBlocked(.waitingForMatchingDevice) = state else { return }
        state = .recovering
        await recoverAndPublish()
    }

    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        monitors.stopAll()
    }

    private func recoverAndPublish() async {
        let outcome = await recovery.recoverPending()
        guard !isStopped else { return }
        switch outcome {
        case .noPendingRecovery, .restored:
            do {
                try monitors.startAll()
                state = .ready
            } catch {
                state = .recoveryBlocked(.failedSafetyUnknown)
            }
        case .waitingForMatchingDevice:
            do {
                try monitors.startRouteOnly()
            } catch {
                state = .recoveryBlocked(.failedSafetyUnknown)
                return
            }
            state = .recoveryBlocked(.waitingForMatchingDevice)
        case .corruptSnapshot, .unsupportedSnapshot,
             .failedButVerifiedSilent, .failedSafetyUnknown:
            state = .recoveryBlocked(outcome)
        }
    }
}

@MainActor
public protocol ApplicationShuttingDown: AnyObject {
    func shutdownAndRestore() async -> ShutdownOutcome
}

public protocol TerminationTiming: Sendable {
    func wait(for duration: Duration) async
}

public struct ContinuousTerminationTiming: TerminationTiming {
    public init() {}

    public func wait(for duration: Duration) async {
        do {
            try await Task.sleep(for: duration)
        } catch {
            // Cancellation only stops the losing timeout branch.
        }
    }
}

@MainActor
public final class ApplicationTerminationCoordinator {
    public private(set) var lastOutcome: ShutdownOutcome?

    private let shutdown: any ApplicationShuttingDown
    private let timeout: Duration
    private let timing: any TerminationTiming
    private var terminationTask: Task<TerminationDecision, Never>?

    public init(
        shutdown: any ApplicationShuttingDown,
        timeout: Duration,
        timing: any TerminationTiming = ContinuousTerminationTiming()
    ) {
        self.shutdown = shutdown
        self.timeout = timeout
        self.timing = timing
    }

    public func requestTermination() async -> TerminationDecision {
        if let terminationTask {
            return await terminationTask.value
        }

        let shutdown = shutdown
        let timeout = timeout
        let timing = timing
        let task = Task<TerminationDecision, Never> { @MainActor [weak self] in
            let outcome = await Self.firstOutcome(
                shutdown: shutdown,
                timeout: timeout,
                timing: timing
            )
            self?.lastOutcome = outcome
            switch outcome {
            case .restored, .verifiedSilent:
                return .allow
            case .safetyUnknown, .timedOut:
                return .cancel
            }
        }
        terminationTask = task
        return await task.value
    }

    private static func firstOutcome(
        shutdown: any ApplicationShuttingDown,
        timeout: Duration,
        timing: any TerminationTiming
    ) async -> ShutdownOutcome {
        await withCheckedContinuation { continuation in
            let race = TerminationOutcomeRace(continuation: continuation)
            Task { @MainActor in
                race.finish(await shutdown.shutdownAndRestore())
            }
            Task {
                await timing.wait(for: timeout)
                race.finish(.timedOut)
            }
        }
    }
}

private final class TerminationOutcomeRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ShutdownOutcome, Never>?

    init(continuation: CheckedContinuation<ShutdownOutcome, Never>) {
        self.continuation = continuation
    }

    func finish(_ outcome: ShutdownOutcome) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
    }
}

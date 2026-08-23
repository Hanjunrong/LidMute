import XCTest
@testable import LidMuteCore

@MainActor
final class ApplicationLifecycleCoordinatorTests: XCTestCase {
    // This fails if lid/display/audio/Chrome work starts before the missing UID is recovered.
    func testMonitorsStartOnlyAfterRecoveryIsReady() async {
        let recovery = ControllableRecoveryRuntime(result: .waitingForMatchingDevice)
        let monitors = MonitorSpy()
        let lifecycle = ApplicationLifecycleCoordinator(recovery: recovery, monitors: monitors)

        await lifecycle.start()

        XCTAssertEqual(lifecycle.state, .recoveryBlocked(.waitingForMatchingDevice))
        XCTAssertEqual(monitors.startAllCount, 0)
        XCTAssertEqual(monitors.startRouteOnlyCount, 1)
    }

    // This fails if successful startup recovery does not start the complete monitor set exactly once.
    func testSuccessfulRecoveryStartsAllMonitorsOnce() async {
        let recovery = ControllableRecoveryRuntime(result: .restored)
        let monitors = MonitorSpy()
        let lifecycle = ApplicationLifecycleCoordinator(recovery: recovery, monitors: monitors)

        await lifecycle.start()
        await lifecycle.start()

        XCTAssertEqual(lifecycle.state, .ready)
        XCTAssertEqual(monitors.startAllCount, 1)
        XCTAssertEqual(monitors.startRouteOnlyCount, 0)
    }

    // This fails if route-only startup cannot retry the missing recovery UID and transition to ready.
    func testRouteChangeRetriesBlockedRecoveryBeforeStartingAllMonitors() async {
        let recovery = ControllableRecoveryRuntime(results: [.waitingForMatchingDevice, .restored])
        let monitors = MonitorSpy()
        let lifecycle = ApplicationLifecycleCoordinator(recovery: recovery, monitors: monitors)
        await lifecycle.start()

        await lifecycle.receiveAudioRouteChanged()

        XCTAssertEqual(lifecycle.state, .ready)
        XCTAssertEqual(monitors.startRouteOnlyCount, 1)
        XCTAssertEqual(monitors.startAllCount, 1)
        XCTAssertEqual(recovery.callCount, 2)
    }

    // This fails if a second route event is discarded while the first missing-UID retry is in flight.
    func testRouteChangesQueuedDuringBlockedRetryDrainUntilRecoveryIsReady() async {
        let recovery = BlockingRouteRecoveryRuntime()
        let monitors = MonitorSpy()
        let lifecycle = ApplicationLifecycleCoordinator(recovery: recovery, monitors: monitors)
        await lifecycle.start()

        let first = Task { await lifecycle.receiveAudioRouteChanged() }
        while await recovery.observedCallCount() < 2 { await Task.yield() }
        let second = Task { await lifecycle.receiveAudioRouteChanged() }
        await recovery.resumeBlockedRoute(with: .waitingForMatchingDevice)
        await first.value
        await second.value

        XCTAssertEqual(lifecycle.state, .ready)
        let callCount = await recovery.observedCallCount()
        XCTAssertEqual(callCount, 3)
        XCTAssertEqual(monitors.startAllCount, 1)
    }

    // This fails if a cancelled termination leaves the lifecycle permanently unable to retry a missing UID.
    func testResumeAfterStopAllowsBlockedRouteRecovery() async {
        let recovery = ControllableRecoveryRuntime(results: [.waitingForMatchingDevice, .restored])
        let monitors = MonitorSpy()
        let lifecycle = ApplicationLifecycleCoordinator(recovery: recovery, monitors: monitors)
        await lifecycle.start()

        lifecycle.stop()
        lifecycle.resume()
        await lifecycle.receiveAudioRouteChanged()

        XCTAssertEqual(lifecycle.state, .ready)
        XCTAssertEqual(monitors.startAllCount, 1)
    }

    // This fails if stop/resume during startup discards recovery and leaves the lifecycle stuck recovering.
    func testResumeDuringInFlightStartupRecoveryRestartsRecovery() async {
        let recovery = BlockingRouteRecoveryRuntime(blockedCall: 1)
        let monitors = MonitorSpy()
        let lifecycle = ApplicationLifecycleCoordinator(recovery: recovery, monitors: monitors)
        let startup = Task { await lifecycle.start() }
        while await recovery.observedCallCount() < 1 { await Task.yield() }

        lifecycle.stop()
        lifecycle.resume()
        await recovery.resumeBlockedRoute(with: .restored)
        await startup.value

        XCTAssertEqual(lifecycle.state, .ready)
        let callCount = await recovery.observedCallCount()
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(monitors.startAllCount, 1)
    }

    // This fails if corrupt or safety-unknown recovery starts even route monitoring.
    func testNonRouteRecoveryBlockStartsNoMonitors() async {
        let recovery = ControllableRecoveryRuntime(result: .failedSafetyUnknown)
        let monitors = MonitorSpy()
        let lifecycle = ApplicationLifecycleCoordinator(recovery: recovery, monitors: monitors)

        await lifecycle.start()

        XCTAssertEqual(lifecycle.state, .recoveryBlocked(.failedSafetyUnknown))
        XCTAssertEqual(monitors.startAllCount, 0)
        XCTAssertEqual(monitors.startRouteOnlyCount, 0)
    }

    func testResumeAfterShutdownUsesActualRecoveryOutcomeForMonitorPolicy() async {
        for (outcome, expectedAll, expectedRoute) in [
            (SpeakerRecoveryOutcome.restored, 2, 0),
            (.waitingForMatchingDevice, 1, 1),
            (.corruptSnapshot, 1, 0),
            (.unsupportedSnapshot(9), 1, 0),
            (.failedButVerifiedSilent, 1, 0),
            (.failedSafetyUnknown, 1, 0),
        ] {
            let recovery = ControllableRecoveryRuntime(result: .restored)
            let monitors = MonitorSpy()
            let lifecycle = ApplicationLifecycleCoordinator(recovery: recovery, monitors: monitors)
            await lifecycle.start()
            lifecycle.stop()

            lifecycle.resume(after: outcome)

            XCTAssertEqual(monitors.startAllCount, expectedAll, "outcome: \(outcome)")
            XCTAssertEqual(monitors.startRouteOnlyCount, expectedRoute, "outcome: \(outcome)")
            XCTAssertEqual(
                lifecycle.state,
                outcome == .restored ? .ready : .recoveryBlocked(outcome),
                "outcome: \(outcome)"
            )
        }
    }
}

@MainActor
final class ApplicationTerminationCoordinatorTests: XCTestCase {
    // This fails if repeated AppKit termination requests launch separate restoration transactions.
    func testRepeatedTerminationRequestsShareOneShutdown() async {
        let shutdown = ShutdownSpy(result: .recovery(.restored))
        let coordinator = ApplicationTerminationCoordinator(
            shutdown: shutdown,
            timeout: .seconds(5),
            timing: SystemTerminationTimeout()
        )

        async let first = coordinator.requestTermination()
        async let second = coordinator.requestTermination()
        let decisions = await [first, second]

        XCTAssertEqual(decisions, [.allow, .allow])
        XCTAssertEqual(shutdown.callCount, 1)
    }

    // This fails if a verified-silent shutdown is treated as unsafe to terminate.
    func testVerifiedSilentAllowsTermination() async {
        let coordinator = ApplicationTerminationCoordinator(
            shutdown: ShutdownSpy(result: .recovery(.failedButVerifiedSilent)),
            timeout: .seconds(5),
            timing: SystemTerminationTimeout()
        )
        let decision = await coordinator.requestTermination()
        XCTAssertEqual(decision, .allow)
    }

    // This fails if an unknown speaker state permits ordinary process termination.
    func testSafetyUnknownCancelsTermination() async {
        let shutdown = ShutdownSpy(result: .recovery(.corruptSnapshot))
        let coordinator = ApplicationTerminationCoordinator(
            shutdown: shutdown,
            timeout: .seconds(5),
            timing: SystemTerminationTimeout()
        )
        let decision = await coordinator.requestTermination()
        XCTAssertEqual(decision, .cancel)
        XCTAssertEqual(coordinator.lastOutcome, .recovery(.corruptSnapshot))
        XCTAssertEqual(shutdown.resumedResults, [.recovery(.corruptSnapshot)])
    }

    // This fails if the timeout path waits indefinitely or permits termination.
    func testTimeoutCancelsTerminationWithTypedOutcome() async {
        let shutdown = ShutdownSpy(result: .recovery(.restored))
        let coordinator = ApplicationTerminationCoordinator(
            shutdown: shutdown,
            timeout: .seconds(5),
            timing: ImmediateTerminationTimeout()
        )

        let decision = await coordinator.requestTermination()
        XCTAssertEqual(decision, .cancel)
        XCTAssertEqual(shutdown.resumedResults.first, .timedOut)
    }

    // This fails if a safety-unknown cancellation is cached and blocks a later successful retry.
    func testSafetyUnknownCancellationAllowsLaterSuccessfulAttempt() async {
        let shutdown = ShutdownSpy(results: [.recovery(.failedSafetyUnknown), .recovery(.restored)])
        let coordinator = ApplicationTerminationCoordinator(
            shutdown: shutdown,
            timeout: .seconds(5),
            timing: SystemTerminationTimeout()
        )

        let first = await coordinator.requestTermination()
        let second = await coordinator.requestTermination()

        XCTAssertEqual([first, second], [.cancel, .allow])
        XCTAssertEqual(shutdown.callCount, 2)
        XCTAssertEqual(shutdown.cancelledAttemptCount, 1)
    }

    // This fails if a timed-out attempt remains cached instead of permitting a fresh shutdown.
    func testTimeoutCancellationAllowsLaterSuccessfulAttempt() async {
        let shutdown = ShutdownSpy(results: [.recovery(.restored), .recovery(.restored)])
        let coordinator = ApplicationTerminationCoordinator(
            shutdown: shutdown,
            timeout: .seconds(5),
            timing: SequencedTerminationTiming()
        )

        let first = await coordinator.requestTermination()
        let second = await coordinator.requestTermination()

        XCTAssertEqual([first, second], [.cancel, .allow])
        XCTAssertEqual(shutdown.callCount, 2)
        XCTAssertEqual(shutdown.cancelledAttemptCount, 2)
    }

    // This fails if timeout resumes monitoring or starts a second shutdown before the first one converges.
    func testTimeoutCancelsRetryUntilShutdownConvergesThenAllowsFreshAttempt() async {
        let shutdown = BlockingShutdownSpy()
        let coordinator = ApplicationTerminationCoordinator(
            shutdown: shutdown,
            timeout: .seconds(5),
            timing: SequencedTerminationTiming()
        )

        let firstDecision = await coordinator.requestTermination()
        XCTAssertEqual(firstDecision, .cancel)
        XCTAssertEqual(shutdown.cancelledAttemptCount, 1)

        let retryDecision = await coordinator.requestTermination()
        XCTAssertEqual(retryDecision, .cancel)
        XCTAssertEqual(shutdown.callCount, 1)

        shutdown.finishFirst(with: .recovery(.restored))
        while shutdown.cancelledAttemptCount < 2 { await Task.yield() }
        XCTAssertEqual(coordinator.lastOutcome, .recovery(.restored))
        XCTAssertEqual(shutdown.resumedResults, [.timedOut, .recovery(.restored)])
        let freshDecision = await coordinator.requestTermination()
        XCTAssertEqual(freshDecision, .allow)
        XCTAssertEqual(shutdown.callCount, 2)
        XCTAssertEqual(shutdown.cancelledAttemptCount, 2)
    }

    // This fails if concurrent retries during convergence create any new shutdown attempt.
    func testConcurrentRetriesDuringTimeoutConvergenceCancelWithoutNewShutdown() async {
        let shutdown = BlockingShutdownSpy()
        let coordinator = ApplicationTerminationCoordinator(
            shutdown: shutdown,
            timeout: .seconds(5),
            timing: SequencedTerminationTiming()
        )
        let firstDecision = await coordinator.requestTermination()
        XCTAssertEqual(firstDecision, .cancel)

        async let firstRetry = coordinator.requestTermination()
        async let secondRetry = coordinator.requestTermination()
        await Task.yield()
        XCTAssertEqual(shutdown.callCount, 1)

        shutdown.finishFirst(with: .recovery(.restored))
        let retryDecisions = await [firstRetry, secondRetry]
        XCTAssertEqual(retryDecisions, [.cancel, .cancel])
        XCTAssertEqual(shutdown.callCount, 1)
    }

    // This fails if a retry remains pending while a previously timed-out shutdown has not converged.
    func testRetryWhileTimedOutShutdownIsHungReturnsBoundedCancellation() async {
        let shutdown = BlockingShutdownSpy()
        let coordinator = ApplicationTerminationCoordinator(
            shutdown: shutdown,
            timeout: .seconds(5),
            timing: ImmediateTerminationTiming()
        )

        let first = await coordinator.requestTermination()
        let probe = TerminationDecisionProbe()
        let retry = Task {
            let decision = await coordinator.requestTermination()
            await probe.record(decision)
            return decision
        }
        for _ in 0..<10 { await Task.yield() }
        let observedRetry = await probe.observedDecision()

        XCTAssertEqual(first, .cancel)
        XCTAssertEqual(observedRetry, .cancel)
        XCTAssertEqual(shutdown.callCount, 1)

        shutdown.finishFirst(with: .recovery(.restored))
        _ = await retry.value
        while shutdown.cancelledAttemptCount == 0 { await Task.yield() }
    }
}

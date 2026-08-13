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
}

@MainActor
final class ApplicationTerminationCoordinatorTests: XCTestCase {
    // This fails if repeated AppKit termination requests launch separate restoration transactions.
    func testRepeatedTerminationRequestsShareOneShutdown() async {
        let shutdown = ShutdownSpy(result: .restored)
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
            shutdown: ShutdownSpy(result: .verifiedSilent),
            timeout: .seconds(5),
            timing: SystemTerminationTimeout()
        )
        let decision = await coordinator.requestTermination()
        XCTAssertEqual(decision, .allow)
    }

    // This fails if an unknown speaker state permits ordinary process termination.
    func testSafetyUnknownCancelsTermination() async {
        let coordinator = ApplicationTerminationCoordinator(
            shutdown: ShutdownSpy(result: .safetyUnknown),
            timeout: .seconds(5),
            timing: SystemTerminationTimeout()
        )
        let decision = await coordinator.requestTermination()
        XCTAssertEqual(decision, .cancel)
    }

    // This fails if the timeout path waits indefinitely or permits termination.
    func testTimeoutCancelsTerminationWithTypedOutcome() async {
        let coordinator = ApplicationTerminationCoordinator(
            shutdown: ShutdownSpy(result: .restored),
            timeout: .seconds(5),
            timing: ImmediateTerminationTimeout()
        )

        let decision = await coordinator.requestTermination()
        XCTAssertEqual(decision, .cancel)
        XCTAssertEqual(coordinator.lastOutcome, .timedOut)
    }

    // This fails if a safety-unknown cancellation is cached and blocks a later successful retry.
    func testSafetyUnknownCancellationAllowsLaterSuccessfulAttempt() async {
        let shutdown = ShutdownSpy(results: [.safetyUnknown, .restored])
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
        let shutdown = ShutdownSpy(results: [.restored, .restored])
        let coordinator = ApplicationTerminationCoordinator(
            shutdown: shutdown,
            timeout: .seconds(5),
            timing: SequencedTerminationTiming()
        )

        let first = await coordinator.requestTermination()
        let second = await coordinator.requestTermination()

        XCTAssertEqual([first, second], [.cancel, .allow])
        XCTAssertEqual(shutdown.callCount, 2)
        XCTAssertEqual(shutdown.cancelledAttemptCount, 1)
    }

    // This fails if timeout resumes monitoring or starts a second shutdown before the first one converges.
    func testTimeoutWaitsForShutdownConvergenceBeforeResumeAndRetry() async {
        let shutdown = BlockingShutdownSpy()
        let coordinator = ApplicationTerminationCoordinator(
            shutdown: shutdown,
            timeout: .seconds(5),
            timing: SequencedTerminationTiming()
        )

        let firstDecision = await coordinator.requestTermination()
        XCTAssertEqual(firstDecision, .cancel)
        XCTAssertEqual(shutdown.cancelledAttemptCount, 0)

        let retry = Task { await coordinator.requestTermination() }
        await Task.yield()
        XCTAssertEqual(shutdown.callCount, 1)

        shutdown.finishFirst(with: .restored)
        let retryDecision = await retry.value
        XCTAssertEqual(retryDecision, .allow)
        XCTAssertEqual(shutdown.callCount, 2)
        XCTAssertEqual(shutdown.cancelledAttemptCount, 1)
    }

    // This fails if concurrent retries after timeout each create their own shutdown attempt.
    func testConcurrentRetriesDuringTimeoutConvergenceShareOneFreshShutdown() async {
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

        shutdown.finishFirst(with: .restored)
        let retryDecisions = await [firstRetry, secondRetry]
        XCTAssertEqual(retryDecisions, [.allow, .allow])
        XCTAssertEqual(shutdown.callCount, 2)
    }
}

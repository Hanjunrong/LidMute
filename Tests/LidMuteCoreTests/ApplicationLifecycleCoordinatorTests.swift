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
}

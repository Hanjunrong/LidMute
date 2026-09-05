import Foundation
import Testing
@testable import LidMuteApp
@testable import LidMuteCore

private final class BlockingAudioPoller: AudioProcessPolling, @unchecked Sendable {
    private let condition = NSCondition()
    private var calls = 0
    private var released: Set<Int> = []
    private var finished: Set<Int> = []

    var callCount: Int { condition.withLock { calls } }
    func hasFinished(_ call: Int) -> Bool { condition.withLock { finished.contains(call) } }

    func release(_ call: Int) {
        condition.withLock {
            released.insert(call)
            condition.broadcast()
        }
    }

    func releaseAll() {
        condition.withLock {
            released.formUnion(1...100)
            condition.broadcast()
        }
    }

    func pollAudioProcesses() -> Result<[AudioProcess], AudioQueryFailure> {
        condition.lock()
        calls += 1
        let call = calls
        let deadline = Date().addingTimeInterval(5)
        while !released.contains(call), condition.wait(until: deadline) {}
        finished.insert(call)
        condition.unlock()
        return .success([AudioProcess(
            pid: Int32(call), name: "Poll \(call)", bundleID: nil,
            executablePath: nil, launchDate: nil, isOutputActive: true
        )])
    }
}

@MainActor
private final class AudioPollingReadyLifecycle: LifecycleStateProviding {
    let state: AppLifecycleState = .ready
    func receiveAudioRouteChanged() async {}
}

@MainActor
private func waitForAudioPolling(_ predicate: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while !predicate(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
    return predicate()
}

@MainActor @Test func cancelledAudioPollCannotPublishOrClearItsReplacement() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let poller = BlockingAudioPoller()
    let model = AppViewModel(
        applicationSupport: root, lifecycle: AudioPollingReadyLifecycle(),
        audioPoller: poller, chromeInstalled: false
    )
    defer {
        model.stopAll()
        poller.releaseAll()
        try? FileManager.default.removeItem(at: root)
    }

    model.pollAudioProcesses()
    try #require(await waitForAudioPolling { poller.callCount == 1 })
    model.stopAll()
    model.pollAudioProcesses()
    try #require(await waitForAudioPolling { poller.callCount == 2 })

    poller.release(1)
    try #require(await waitForAudioPolling { poller.hasFinished(1) })
    // Give the old outer task an opportunity to resume. Repeated requests must
    // continue to coalesce into the replacement, which remains blocked.
    for _ in 0..<50 {
        model.pollAudioProcesses()
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(model.currentAudioProcesses.isEmpty)
    #expect(poller.callCount == 2)

    poller.release(2)
    try #require(await waitForAudioPolling { model.currentAudioProcesses.map(\.pid) == [2] })
    model.pollAudioProcesses()
    try #require(await waitForAudioPolling { poller.callCount == 3 })
    poller.release(3)
    try #require(await waitForAudioPolling { model.currentAudioProcesses.map(\.pid) == [3] })
}

@MainActor @Test func audioPollCancelledBeforeItsTaskStartsDoesNotStartIO() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let poller = BlockingAudioPoller()
    let model = AppViewModel(
        applicationSupport: root, lifecycle: AudioPollingReadyLifecycle(),
        audioPoller: poller, chromeInstalled: false
    )
    defer {
        model.stopAll()
        poller.releaseAll()
        try? FileManager.default.removeItem(at: root)
    }

    // No suspension between scheduling and stop: the MainActor task has not run.
    model.pollAudioProcesses()
    model.stopAll()
    model.pollAudioProcesses()
    try #require(await waitForAudioPolling { poller.callCount >= 1 })
    for _ in 0..<50 { try await Task.sleep(for: .milliseconds(1)) }
    #expect(poller.callCount == 1)
    poller.release(1)
    try #require(await waitForAudioPolling { model.currentAudioProcesses.map(\.pid) == [1] })
}

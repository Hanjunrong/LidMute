import Foundation
@testable import LidMuteCore

enum FakeAudioError: Error {
    case enforcementFailed
    case scriptedFailure
}

enum FakeRecoveryStoreError: Error {
    case diskFull
}

final class SharedOperationTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

actor DelayedProtectionApplying: SpeakerProtectionApplying {
    let delay: Duration
    private var started = false

    init(delay: Duration) {
        self.delay = delay
    }

    func apply(_ action: SpeakerProtectionAction) async -> SpeakerRecoveryOutcome {
        started = true
        try? await Task.sleep(for: delay)
        return .noPendingRecovery
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}

final class MemorySpeakerRecoveryStore: SpeakerRecoveryStoring, @unchecked Sendable {
    var loadResult: SpeakerRecoveryLoadResult
    var saveError: Error?
    var markError: Error?
    var removeError: Error?
    private(set) var operations: [String] = []
    private(set) var savedSnapshot: SpeakerRecoverySnapshot?
    private let timeline: SharedOperationTimeline?

    init(
        loadResult: SpeakerRecoveryLoadResult = .none,
        timeline: SharedOperationTimeline? = nil
    ) {
        self.loadResult = loadResult
        self.timeline = timeline
    }

    static func withPendingFixture(
        uid: String = "built-in-a",
        stage: SpeakerRecoveryStage = .protected,
        originalState: AudioDeviceState = .init(
            muted: false,
            volume: 0.72,
            usedVolumeFallback: false
        ),
        timeline: SharedOperationTimeline? = nil
    ) -> MemorySpeakerRecoveryStore {
        let device = AudioDevice(id: 7, uid: uid, name: "MacBook Speakers", isBuiltIn: true)
        let snapshot = SpeakerRecoverySnapshot(
            transactionID: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
            device: device,
            originalState: originalState,
            stage: stage,
            capturedAt: Date(timeIntervalSince1970: 1_723_500_000),
            sources: [.physicalLid],
            appVersion: "0.1.0"
        )
        return MemorySpeakerRecoveryStore(loadResult: .snapshot(snapshot), timeline: timeline)
    }

    func load() throws -> SpeakerRecoveryLoadResult {
        operations.append("load")
        return loadResult
    }

    func saveBeforeMutation(_ snapshot: SpeakerRecoverySnapshot) throws {
        operations.append("save")
        timeline?.append("journal.save")
        if let saveError { throw saveError }
        savedSnapshot = snapshot
        loadResult = .snapshot(snapshot)
    }

    func markFinalizingRestore(transactionID: UUID) throws {
        operations.append("markFinalizing")
        timeline?.append("journal.finalizing")
        if let markError { throw markError }
        guard case let .snapshot(snapshot) = loadResult,
              snapshot.transactionID == transactionID else {
            throw SpeakerRecoveryStoreError.noPendingTransaction
        }
        loadResult = .snapshot(snapshot.with(stage: .finalizingRestore))
    }

    func removeCompleted(transactionID: UUID) throws {
        operations.append("remove")
        timeline?.append("journal.remove")
        if let removeError { throw removeError }
        loadResult = .none
    }

    func timelineIndex(of entry: String) -> Int? {
        timeline?.snapshot().firstIndex(of: entry)
    }
}

final class ScriptedAudioController: AudioControlling, @unchecked Sendable {
    enum FailurePoint: Equatable {
        case capture
        case initialSilence
        case initialReadBack
        case restoreMute
        case restoreMuteReadBack
        case restoreVolume
        case restoreVolumeReadBack
        case finalUnmute
        case finalReadBack
        case resilence
        case finalUnmuteAndResilence
        case finalUnmuteAndResilenceReadBack
        case readBack
    }

    var defaultBuiltIn: AudioDevice?
    var resolvedUIDs: [String: AudioDevice]
    var capturedState: AudioDeviceState
    var readBack: AudioDeviceState
    var supportsMute = true
    let failAt: FailurePoint?
    private(set) var operations: [String] = []
    private(set) var writtenDeviceUIDs: [String] = []
    private var writeMutedCount = 0
    private var writeVolumeCount = 0
    private var readCount = 0
    private let timeline: SharedOperationTimeline?

    init(
        failAt: FailurePoint? = nil,
        readBack: AudioDeviceState = .init(muted: false, volume: 0.72, usedVolumeFallback: false),
        resolvedUIDs: [String: AudioDevice]? = nil,
        timeline: SharedOperationTimeline? = nil
    ) {
        let device = AudioDevice(id: 7, uid: "built-in-a", name: "MacBook Speakers", isBuiltIn: true)
        self.defaultBuiltIn = device
        self.resolvedUIDs = resolvedUIDs ?? [device.uid: device]
        self.capturedState = .init(muted: false, volume: 0.72, usedVolumeFallback: false)
        self.readBack = readBack
        self.failAt = failAt
        self.timeline = timeline
    }

    func resolveBuiltInSpeaker(uid: String?) throws -> AudioDevice? {
        operations.append("resolve:\(uid ?? "nil")")
        if let uid { return resolvedUIDs[uid] }
        return defaultBuiltIn
    }

    func captureState(of device: AudioDevice) throws -> AudioDeviceState {
        operations.append("capture")
        if failAt == .capture { throw FakeAudioError.scriptedFailure }
        return capturedState
    }

    func writeMuted(_ muted: Bool, on device: AudioDevice) throws {
        writeMutedCount += 1
        operations.append("writeMuted:\(muted)")
        writtenDeviceUIDs.append(device.uid)
        timeline?.append("audio.writeMuted:\(muted)")
        if (writeMutedCount == 1 && (failAt == .initialSilence || failAt == .restoreMute)) ||
            (writeMutedCount == 2 && (
                failAt == .finalUnmute ||
                failAt == .finalUnmuteAndResilence ||
                failAt == .finalUnmuteAndResilenceReadBack
            )) ||
            (writeMutedCount == 3 && failAt == .finalUnmuteAndResilence) {
            throw FakeAudioError.scriptedFailure
        }
        if muted {
            operations.append("silence")
            timeline?.append("audio.silence")
            readBack = .init(muted: true, volume: readBack.volume, usedVolumeFallback: false)
        } else {
            readBack = .init(muted: false, volume: readBack.volume, usedVolumeFallback: false)
        }
    }

    func writeVolume(_ volume: Float, on device: AudioDevice) throws {
        writeVolumeCount += 1
        operations.append("writeVolume:\(volume)")
        writtenDeviceUIDs.append(device.uid)
        timeline?.append("audio.writeVolume:\(volume)")
        if failAt == .restoreVolume { throw FakeAudioError.scriptedFailure }
        readBack = .init(muted: readBack.muted, volume: volume, usedVolumeFallback: !supportsMute)
    }

    func readState(of device: AudioDevice) throws -> AudioDeviceState {
        readCount += 1
        operations.append("readState")
        if failAt == .readBack ||
            (readCount == 1 && (failAt == .initialReadBack || failAt == .restoreMuteReadBack)) ||
            (readCount == 2 && failAt == .restoreVolumeReadBack) ||
            (readCount == 3 && (
                failAt == .finalReadBack ||
                failAt == .finalUnmuteAndResilenceReadBack
            )) {
            throw FakeAudioError.scriptedFailure
        }
        return readBack
    }

    func supportsWritableMute(on device: AudioDevice) -> Bool { supportsMute }
    func activeOutputProcesses() throws -> [AudioProcess] { [] }

    func timelineIndex(of entry: String) -> Int? {
        timeline?.snapshot().firstIndex(of: entry == "silence" ? "audio.silence" : entry)
    }
}

struct OrderedProtectionFixture {
    let timeline: SharedOperationTimeline
    let audio: ScriptedAudioController
    let recoveryStore: MemorySpeakerRecoveryStore
    let coordinator: ProtectionCoordinator<SpeakerRecoveryRuntime>

    @MainActor
    init(journalFailure: Error? = nil) {
        let timeline = SharedOperationTimeline()
        let audio = ScriptedAudioController(timeline: timeline)
        let recoveryStore = MemorySpeakerRecoveryStore(timeline: timeline)
        recoveryStore.saveError = journalFailure
        let runtime = SpeakerRecoveryRuntime(
            audio: audio,
            recoveryStore: recoveryStore,
            appVersion: "0.1.0"
        )
        self.timeline = timeline
        self.audio = audio
        self.recoveryStore = recoveryStore
        self.coordinator = ProtectionCoordinator(
            protection: runtime,
            processEvidence: audio,
            store: MemoryEventStore()
        )
    }
}

final class ControllableRecoveryRuntime: PendingSpeakerRecovering, @unchecked Sendable {
    var results: [SpeakerRecoveryOutcome]
    private(set) var callCount = 0

    init(result: SpeakerRecoveryOutcome) {
        self.results = [result]
    }

    init(results: [SpeakerRecoveryOutcome]) {
        self.results = results
    }

    func recoverPending() async -> SpeakerRecoveryOutcome {
        callCount += 1
        if results.count > 1 { return results.removeFirst() }
        return results.first ?? .failedSafetyUnknown
    }
}

actor BlockingRouteRecoveryRuntime: PendingSpeakerRecovering {
    private var callCount = 0
    private var blockedContinuation: CheckedContinuation<SpeakerRecoveryOutcome, Never>?

    func recoverPending() async -> SpeakerRecoveryOutcome {
        callCount += 1
        if callCount == 1 { return .waitingForMatchingDevice }
        if callCount == 2 {
            return await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        }
        return .restored
    }

    func observedCallCount() -> Int { callCount }

    func resumeBlockedRoute(with outcome: SpeakerRecoveryOutcome) {
        let continuation = blockedContinuation
        blockedContinuation = nil
        continuation?.resume(returning: outcome)
    }
}

@MainActor
final class MonitorSpy: ApplicationMonitoring {
    private(set) var startAllCount = 0
    private(set) var startRouteOnlyCount = 0
    private(set) var stopAllCount = 0

    func startAll() throws { startAllCount += 1 }
    func startRouteOnly() throws { startRouteOnlyCount += 1 }
    func stopAll() { stopAllCount += 1 }
}

@MainActor
final class ShutdownSpy: ApplicationShuttingDown {
    private var results: [ShutdownOutcome]
    private(set) var callCount = 0
    private(set) var cancelledAttemptCount = 0

    init(result: ShutdownOutcome) {
        self.results = [result]
    }

    init(results: [ShutdownOutcome]) {
        self.results = results
    }

    func shutdownAndRestore() async -> ShutdownOutcome {
        callCount += 1
        await Task.yield()
        if results.count > 1 { return results.removeFirst() }
        return results.first ?? .safetyUnknown
    }

    func resumeAfterCancelledTermination() async {
        cancelledAttemptCount += 1
    }
}

@MainActor
final class BlockingShutdownSpy: ApplicationShuttingDown {
    private(set) var callCount = 0
    private(set) var cancelledAttemptCount = 0
    private var firstContinuation: CheckedContinuation<ShutdownOutcome, Never>?

    func shutdownAndRestore() async -> ShutdownOutcome {
        callCount += 1
        guard callCount == 1 else { return .restored }
        return await withCheckedContinuation { continuation in
            firstContinuation = continuation
        }
    }

    func resumeAfterCancelledTermination() async {
        cancelledAttemptCount += 1
    }

    func finishFirst(with outcome: ShutdownOutcome) {
        let continuation = firstContinuation
        firstContinuation = nil
        continuation?.resume(returning: outcome)
    }
}

struct ImmediateTerminationTimeout: TerminationTiming {
    func wait(for duration: Duration) async {}
}

struct SystemTerminationTimeout: TerminationTiming {
    func wait(for duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

actor SequencedTerminationTiming: TerminationTiming {
    private var callCount = 0

    func wait(for duration: Duration) async {
        callCount += 1
        guard callCount > 1 else { return }
        do {
            try await Task.sleep(for: duration)
        } catch {}
    }
}

final class MemoryEventStore: EventStoring, @unchecked Sendable {
    private(set) var events: [LidMuteEvent] = []

    func append(_ event: LidMuteEvent) throws { events.append(event) }
    func load() throws -> [LidMuteEvent] { events }
    func clear() throws { events.removeAll() }
}

final class FakeAudioController: AudioControlling, SynchronousSpeakerProtectionApplying, @unchecked Sendable {
    var device = AudioDevice(id: 7, uid: "built-in-a", name: "MacBook Speakers", isBuiltIn: true)
    var capturedState = AudioDeviceState(muted: false, volume: 0.72, usedVolumeFallback: false)
    var enforceError: Error?
    var activeProcesses: [AudioProcess] = []
    private(set) var enforceSilenceCount = 0
    private(set) var captureCount = 0
    private(set) var mutations: [String] = []
    var lastMute: Bool? = false
    var lastVolume: Float? = 0.72

    func resolveBuiltInSpeaker(uid: String?) throws -> AudioDevice? {
        guard uid == nil || uid == device.uid else { return nil }
        return device
    }
    func captureState(of device: AudioDevice) throws -> AudioDeviceState {
        captureCount += 1
        return capturedState
    }
    func writeMuted(_ muted: Bool, on device: AudioDevice) throws {
        enforceSilenceCount += 1
        if let enforceError { throw enforceError }
        mutations.append(muted ? "silence:\(device.uid)" : "restore:\(device.uid)")
        lastMute = muted
    }
    func writeVolume(_ volume: Float, on device: AudioDevice) throws {
        mutations.append("restore:\(device.uid)")
        lastVolume = volume
    }
    func readState(of device: AudioDevice) throws -> AudioDeviceState {
        .init(muted: lastMute ?? false, volume: lastVolume ?? 0, usedVolumeFallback: !supportsWritableMute(on: device))
    }
    func supportsWritableMute(on device: AudioDevice) -> Bool { !capturedState.usedVolumeFallback }
    func activeOutputProcesses() throws -> [AudioProcess] { activeProcesses }

    func apply(_ action: SpeakerProtectionAction) async -> SpeakerRecoveryOutcome {
        applySynchronously(action)
    }

    func applySynchronously(_ action: SpeakerProtectionAction) -> SpeakerRecoveryOutcome {
        switch action {
        case .begin, .reinforce, .routeChangedWhileProtectionRequired:
            do {
                try writeMuted(true, on: device)
                return .noPendingRecovery
            } catch {
                return .failedSafetyUnknown
            }
        case .end:
            mutations.append("restore:\(device.uid)")
            lastMute = capturedState.muted
            lastVolume = capturedState.usedVolumeFallback ? 0 : capturedState.volume
            return .restored
        }
    }
}

extension SpeakerRecoverySnapshot {
    static func fixture(
        transactionID: UUID = UUID(),
        stage: SpeakerRecoveryStage = .protected
    ) -> Self {
        SpeakerRecoverySnapshot(
            transactionID: transactionID,
            device: AudioDevice(
                id: 7,
                uid: "built-in-a",
                name: "MacBook Speakers",
                isBuiltIn: true
            ),
            originalState: AudioDeviceState(
                muted: false,
                volume: 0.72,
                usedVolumeFallback: false
            ),
            stage: stage,
            capturedAt: Date(timeIntervalSince1970: 1_723_500_000),
            sources: [.physicalLid, .night],
            appVersion: "1.0-test"
        )
    }
}

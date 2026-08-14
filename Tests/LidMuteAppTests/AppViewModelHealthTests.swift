import Foundation
import Testing
@testable import LidMuteApp
@testable import LidMuteCore

private final class RecordingHealthDiagnostics: LidMuteDiagnosticSinking, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [LidMuteDiagnosticEvent] = []
    var events: [LidMuteDiagnosticEvent] { lock.withLock { storedEvents } }
    func emit(_ event: LidMuteDiagnosticEvent) { lock.withLock { storedEvents.append(event) } }
}

private final class MemoryHeartbeatStore: ChromeHostHeartbeatPersisting, @unchecked Sendable {
    var heartbeat: ChromeHostHeartbeat?
    init(_ heartbeat: ChromeHostHeartbeat? = nil) { self.heartbeat = heartbeat }
    func write(_ heartbeat: ChromeHostHeartbeat) throws { self.heartbeat = heartbeat }
    func readFreshness(nowUptime: TimeInterval, ttl: TimeInterval) -> HeartbeatFreshness {
        guard let heartbeat, heartbeat.version == ChromeHostHeartbeat.schemaVersion else {
            return .malformed
        }
        guard heartbeat.uptime >= 0,
              heartbeat.uptime <= nowUptime,
              nowUptime - heartbeat.uptime <= ttl else { return .stale }
        return .fresh(sessionToken: heartbeat.sessionToken, pid: heartbeat.pid)
    }
    func remove() throws { heartbeat = nil }
}

private final class MemoryAcceptanceStore: ChromeHostAcceptancePersisting, @unchecked Sendable {
    var acceptance: ChromeHostAcceptance?
    init(_ acceptance: ChromeHostAcceptance? = nil) { self.acceptance = acceptance }
    func write(_ acceptance: ChromeHostAcceptance) throws { self.acceptance = acceptance }
    func readFreshness(nowUptime: TimeInterval, ttl: TimeInterval) -> HeartbeatFreshness {
        guard let acceptance, acceptance.version == ChromeHostAcceptance.schemaVersion else {
            return .malformed
        }
        guard acceptance.uptime >= 0,
              acceptance.uptime <= nowUptime,
              nowUptime - acceptance.uptime <= ttl else { return .stale }
        return .fresh(sessionToken: acceptance.sessionToken, pid: acceptance.pid)
    }
    func remove() throws { acceptance = nil }
}

private final class MutableUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: TimeInterval
    init(_ value: TimeInterval) { storedValue = value }
    var value: TimeInterval { lock.withLock { storedValue } }
    func set(_ value: TimeInterval) { lock.withLock { storedValue = value } }
}

private final class MutableRegistration: ChromeHostRegistering {
    var inspection: ChromeManifestInspection
    private(set) var repairCalls = 0
    init(_ inspection: ChromeManifestInspection) { self.inspection = inspection }
    func inspect(expectedHostPath: URL) -> ChromeManifestInspection { inspection }
    func repair(expectedHostPath: URL) throws {
        repairCalls += 1
        inspection = .current
    }
}

private struct ScriptedAudioPoller: AudioProcessPolling {
    let result: Result<[AudioProcess], AudioQueryFailure>
    func pollAudioProcesses() -> Result<[AudioProcess], AudioQueryFailure> { result }
}

@MainActor
private final class ReadyHealthLifecycle: LifecycleStateProviding {
    var state: AppLifecycleState = .ready
    func receiveAudioRouteChanged() async {}
}

private final class EmptyHealthStore: EventStoring, ObservationClearing, @unchecked Sendable {
    func append(_ event: LidMuteEvent) throws {}
    func load() throws -> [LidMuteEvent] { [] }
    func clear() throws {}
    func clearObservationData(inMemoryReset: () throws -> Void) throws -> ObservationClearReport {
        try inMemoryReset()
        return ObservationClearReport(oldGeneration: 0, newGeneration: 1, failures: [])
    }
}

private final class EmptyHealthConsumer: ChromeInboxConsuming, @unchecked Sendable {
    func consumeAvailable() throws -> ChromeConsumeBatch {
        ChromeConsumeBatch(records: [], committedOffset: 0, health: .healthy)
    }
    func acknowledgeDelivery(_ deliveryID: UUID) throws {}
    func resetInMemoryState() {}
}

private final class OneBatchHealthConsumer: ChromeInboxConsuming, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [ChromeInboxRecord]

    init(records: [ChromeInboxRecord]) {
        self.records = records
    }

    func consumeAvailable() throws -> ChromeConsumeBatch {
        lock.withLock {
            defer { records = [] }
            return ChromeConsumeBatch(records: records, committedOffset: 0, health: .healthy)
        }
    }

    func acknowledgeDelivery(_ deliveryID: UUID) throws {}
    func resetInMemoryState() {}
}

@MainActor
private final class HealthyHealthPipeline: ObservationPipelineCoordinating {
    func ensureProtected(for evidence: ChromeTabEvidence) async -> ChromeSafetyDeliveryResult { .protected }
    func receivePhysicalLid(closed: Bool) async {}
    func receiveAudioRouteChanged() async {}
    func flushObservationLogging() async {}
    func beginObservationClear() async -> ObservationClearBoundary {
        ObservationClearBoundary(generation: 0)
    }
    func endObservationClear(_ boundary: ObservationClearBoundary, report: ObservationClearReport?) {}
}

@MainActor
private final class AppHealthFixture {
    let root: URL
    let heartbeat: MemoryHeartbeatStore
    let acceptance: MemoryAcceptanceStore
    let registration: MutableRegistration
    let diagnostics = RecordingHealthDiagnostics()
    let audioPoller: ScriptedAudioPoller
    let nowUptime: MutableUptime

    init(
        heartbeat: ChromeHostHeartbeat? = nil,
        acceptance: ChromeHostAcceptance? = nil,
        nowUptime: TimeInterval = 100,
        manifestPath: String? = nil,
        expectedHostPath: String = "/Applications/LidMute.app/Contents/MacOS/LidMuteNativeHost",
        audioPoll: Result<[AudioProcess], AudioQueryFailure> = .success([])
    ) {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        self.heartbeat = MemoryHeartbeatStore(heartbeat)
        self.acceptance = MemoryAcceptanceStore(acceptance)
        registration = MutableRegistration(manifestPath.map {
            .pathMismatch(expected: expectedHostPath, registered: $0)
        } ?? .current)
        audioPoller = ScriptedAudioPoller(result: audioPoll)
        self.nowUptime = MutableUptime(nowUptime)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func makeViewModel(
        expectedHostPath: String = "/Applications/LidMute.app/Contents/MacOS/LidMuteNativeHost",
        inboxConsumer: (any ChromeInboxConsuming)? = nil,
        observationPipelineCoordinator: (any ObservationPipelineCoordinating)? = nil
    ) -> AppViewModel {
        let store = EmptyHealthStore()
        return AppViewModel(
            applicationSupport: root,
            eventStore: store,
            inboxConsumer: inboxConsumer ?? EmptyHealthConsumer(),
            observationStore: store,
            lifecycle: ReadyHealthLifecycle(),
            chromeManifestURL: root.appending(path: "manifest.json"),
            observationPipelineCoordinator: observationPipelineCoordinator,
            heartbeatStore: heartbeat,
            acceptanceStore: acceptance,
            chromeRegistration: registration,
            diagnosticSink: diagnostics,
            audioPoller: audioPoller,
            uptime: { [nowUptime] in nowUptime.value },
            expectedChromeHostPath: URL(filePath: expectedHostPath)
        )
    }
}

@MainActor @Test func oldSessionBacklogCannotClaimTheCurrentHostIdentity() async {
    let current = UUID()
    let fixture = AppHealthFixture(
        heartbeat: .init(version: 1, sessionToken: current, pid: 8, uptime: 100),
        nowUptime: 100
    )
    let oldRecord = ChromeInboxRecord(
        generation: 0,
        eventID: UUID(),
        acceptedAt: Date(timeIntervalSince1970: 1_725_000_000),
        evidence: ChromeTabEvidence(
            sessionID: "old-session",
            windowID: 1,
            tabID: 2,
            index: 0,
            title: "Old backlog",
            url: "https://example.com/old?query=preserved#fragment",
            audible: true,
            muted: false,
            isActive: true,
            isPinned: false,
            isIncognito: false
        )
    )
    let model = fixture.makeViewModel(
        inboxConsumer: OneBatchHealthConsumer(records: [oldRecord]),
        observationPipelineCoordinator: HealthyHealthPipeline()
    )

    await model.pollChromeInbox()

    #expect(model.health.chrome == .connected(sessionToken: current, pid: 8))
}

@MainActor @Test func freshHeartbeatPublishesItsIdentityAndRecentAcceptanceExpires() {
    let token = UUID()
    let fixture = AppHealthFixture(
        heartbeat: .init(version: 1, sessionToken: token, pid: 8, uptime: 100),
        acceptance: .init(version: 1, sessionToken: token, pid: 8, uptime: 100),
        nowUptime: 100
    )
    let model = fixture.makeViewModel()
    model.refreshHealth()
    #expect(model.health.chrome == .recentlyAccepted(sessionToken: token, pid: 8))

    fixture.nowUptime.set(130.001)
    fixture.heartbeat.heartbeat = .init(version: 1, sessionToken: token, pid: 8, uptime: 130)
    model.refreshHealth()
    #expect(model.health.chrome == .connected(sessionToken: token, pid: 8))
}

@MainActor @Test func acceptanceFromAnotherSessionCannotClaimCurrentHeartbeat() {
    let current = UUID()
    let fixture = AppHealthFixture(
        heartbeat: .init(version: 1, sessionToken: current, pid: 8, uptime: 100),
        acceptance: .init(version: 1, sessionToken: UUID(), pid: 7, uptime: 100),
        nowUptime: 100
    )
    let model = fixture.makeViewModel()
    model.refreshHealth()
    #expect(model.health.chrome == .connected(sessionToken: current, pid: 8))
}

@MainActor @Test func bridgeDegradationOverridesFreshHeartbeat() {
    let fixture = AppHealthFixture(
        heartbeat: .init(version: 1, sessionToken: UUID(), pid: 8, uptime: 100),
        nowUptime: 100
    )
    let model = fixture.makeViewModel()
    model.receiveChromeBridgeDegraded()
    #expect(model.health.chrome == .degraded)
    #expect(fixture.diagnostics.events.contains(.chromeBridgeDegraded))
}

@MainActor @Test func staleHeartbeatDoesNotReportChromeConnected() {
    let fixture = AppHealthFixture(
        heartbeat: .init(version: 1, sessionToken: UUID(), pid: 8, uptime: 10),
        nowUptime: 16.001
    )
    let model = fixture.makeViewModel()
    model.refreshHealth()
    #expect(model.health.chrome == .waitingForConnection)
    #expect(fixture.diagnostics.events == [.chromeHeartbeatStale])
}

@MainActor @Test func movedManifestOffersRepairAndRepairClearsMismatch() {
    let fixture = AppHealthFixture(manifestPath: "/old/LidMuteNativeHost")
    let model = fixture.makeViewModel()
    model.refreshHealth()
    #expect(model.canRepairChromeManifest)
    model.repairChromeManifest()
    #expect(!model.canRepairChromeManifest)
    #expect(fixture.registration.repairCalls == 1)
}

@MainActor @Test func coreAudioFailureIsNotProjectedAsNoOutput() {
    let fixture = AppHealthFixture(audioPoll: .failure(.queryFailed))
    let model = fixture.makeViewModel()
    model.pollAudioProcesses()
    #expect(model.health.coreAudio == .queryFailed)
    #expect(fixture.diagnostics.events.contains(.coreAudioQueryFailed))
}

@MainActor @Test func audioFailurePreservesLastKnownProcessSnapshot() {
    let fixture = AppHealthFixture(audioPoll: .failure(.queryFailed))
    let model = fixture.makeViewModel()
    model.receiveAudioPollResult(.success([AudioProcess(
        pid: 7,
        name: "Music",
        bundleID: "com.apple.Music",
        executablePath: nil,
        launchDate: nil,
        isOutputActive: true
    )]))
    model.pollAudioProcesses()
    #expect(model.currentAudioProcesses.map(\.pid) == [7])
    #expect(model.health.coreAudio == .queryFailed)
}

@MainActor @Test func lidUnavailableAndReadFailureHaveDistinctHealth() {
    let unavailableFixture = AppHealthFixture()
    let unavailable = unavailableFixture.makeViewModel()
    unavailable.receiveLidMonitorResult(.unavailable)
    unavailable.refreshHealth()
    #expect(unavailable.health.lidMonitor == .unavailable)

    let failedFixture = AppHealthFixture()
    let failed = failedFixture.makeViewModel()
    failed.receiveLidMonitorResult(.readFailed)
    failed.refreshHealth()
    #expect(failed.health.lidMonitor == .readFailed)
}

@MainActor @Test(arguments: [
    (ObservationStorageHealth.healthy, LocalStorageHealth.healthy),
    (.corruptRecord(line: 17), .partiallyCorrupt),
    (.permissionFailure, .permissionFailed),
    (.capacityFailure, .capacityFailed),
    (.ioFailure("fixed-test-reason"), .ioFailed),
])
func everyStorageOutcomeMapsToHealth(input: ObservationStorageHealth, expected: LocalStorageHealth) {
    #expect(AppHealthMapper.storage(input) == expected)
}

@MainActor @Test(arguments: [
    (SpeakerRecoveryOutcome.noPendingRecovery, SpeakerRecoveryHealth.healthy),
    (.restored, .healthy),
    (.waitingForMatchingDevice, .waitingForMatchingDevice),
    (.corruptSnapshot, .corruptSnapshot),
    (.unsupportedSnapshot(99), .unsupportedSnapshot),
    (.failedButVerifiedSilent, .failedButVerifiedSilent),
    (.failedSafetyUnknown, .failedSafetyUnknown),
])
func everyRecoveryOutcomeMapsToHealth(input: SpeakerRecoveryOutcome, expected: SpeakerRecoveryHealth) {
    #expect(AppHealthMapper.recovery(input) == expected)
}

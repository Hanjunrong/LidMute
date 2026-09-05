import Combine
import Foundation
import LidMuteCore

enum SimulatedLidState {
    case closed
    case opened
}

enum ChromeConnectionState: Equatable {
    case unknown
    case notRegistered
    case waitingForExtension
    case connected
    case receivedEvent
}

enum StorageStatusSeverity: Int, Equatable {
    case none
    case warning
    case error
}

enum AudioQueryFailure: Error, Equatable {
    case queryFailed
}

protocol AudioProcessPolling: Sendable {
    func pollAudioProcesses() -> Result<[AudioProcess], AudioQueryFailure>
}

extension SystemAudioController: AudioProcessPolling {
    func pollAudioProcesses() -> Result<[AudioProcess], AudioQueryFailure> {
        do {
            return .success(try activeOutputProcesses())
        } catch {
            return .failure(.queryFailed)
        }
    }
}

enum AppHealthMapper {
    static func storage(_ value: ObservationStorageHealth) -> LocalStorageHealth {
        switch value {
        case .healthy: return .healthy
        case .corruptRecord: return .partiallyCorrupt
        case .permissionFailure: return .permissionFailed
        case .capacityFailure: return .capacityFailed
        case .ioFailure: return .ioFailed
        }
    }

    static func recovery(_ value: SpeakerRecoveryOutcome) -> SpeakerRecoveryHealth {
        switch value {
        case .noPendingRecovery, .restored: return .healthy
        case .waitingForMatchingDevice: return .waitingForMatchingDevice
        case .corruptSnapshot: return .corruptSnapshot
        case .unsupportedSnapshot: return .unsupportedSnapshot
        case .failedButVerifiedSilent: return .failedButVerifiedSilent
        case .failedSafetyUnknown: return .failedSafetyUnknown
        }
    }
}

private enum OperationalStorageHealth: Equatable {
    case healthy
    case warning(String)
    case failure(String)
}

private enum OperationalStorageSource {
    case startup
    case consume
    case acknowledgement
    case clear
}

private enum ChromeDiagnosticState: Equatable {
    case none
    case staleHeartbeat
    case manifestMismatch
    case degraded
}

private enum NightScheduleInputValidation {
    case valid(startMinutes: Int, endMinutes: Int)
    case invalid(message: String)
}

struct ChromeHealthIOResult: Sendable {
    let manifest: ChromeManifestInspection
    let heartbeat: HeartbeatFreshness
    let acceptance: HeartbeatFreshness
}

protocol AppHealthIOCollecting: Sendable {
    func collect(nowUptime: TimeInterval, expectedHostPath: URL) -> ChromeHealthIOResult
}

private struct DefaultAppHealthIOCollector: AppHealthIOCollecting {
    let heartbeatStore: any ChromeHostHeartbeatPersisting
    let acceptanceStore: any ChromeHostAcceptancePersisting
    let chromeRegistration: any ChromeManifestInspecting

    func collect(nowUptime: TimeInterval, expectedHostPath: URL) -> ChromeHealthIOResult {
        let manifest = chromeRegistration.inspect(expectedHostPath: expectedHostPath)
        guard manifest == .current else {
            return ChromeHealthIOResult(
                manifest: manifest,
                heartbeat: .stale,
                acceptance: .stale
            )
        }
        return ChromeHealthIOResult(
            manifest: manifest,
            heartbeat: heartbeatStore.readFreshness(nowUptime: nowUptime, ttl: 6),
            acceptance: acceptanceStore.readFreshness(nowUptime: nowUptime, ttl: 30)
        )
    }
}

@MainActor
protocol LifecycleStateProviding: AnyObject {
    var state: AppLifecycleState { get }
    func receiveAudioRouteChanged() async
}

extension ApplicationLifecycleCoordinator: LifecycleStateProviding {}

@MainActor
protocol ObservationPipelineCoordinating: AnyObject {
    func ensureProtected(for evidence: ChromeTabEvidence) async -> ChromeSafetyDeliveryResult
    func receivePhysicalLid(closed: Bool) async
    func receiveAudioRouteChanged() async
    func flushObservationLogging() async
    func beginObservationClear() async -> ObservationClearBoundary
    func endObservationClear(_ boundary: ObservationClearBoundary, report: ObservationClearReport?)
}

extension ProtectionCoordinator: ObservationPipelineCoordinating {}

@MainActor
final class AppViewModel: ObservableObject, ApplicationMonitoring, ApplicationShuttingDown {
    @Published var isEnabled = false
    @Published var isLightweightModeEnabled = false
    @Published private(set) var statusText = "守卫未开启"
    @Published private(set) var events: [LidMuteEvent] = []
    @Published private(set) var simulatedLidState: SimulatedLidState = .opened
    @Published private(set) var currentAudioProcesses: [AudioProcess] = []
    @Published private(set) var currentAudioSources: [AudioSourcePresentation] = []
    @Published var nightScheduleEnabled = false
    @Published var nightStartText = "00:00"
    @Published var nightEndText = "08:00"
    @Published private(set) var isNightScheduleInputValid = true
    @Published private(set) var isDisplaySleeping = false
    @Published private(set) var isNightProtectionActive = false
    @Published private(set) var nightScheduleStatus = "夜间静音未开启"
    @Published var chromeExtensionId = ""
    @Published private(set) var chromeRegistrationStatus = ""
    @Published private(set) var chromeExtensionPath = ""
    @Published private(set) var isChromeInstalled = false
    @Published private(set) var lifecycleState: AppLifecycleState = .recovering
    @Published private(set) var storageStatusText = ""
    @Published private(set) var storageStatusSeverity: StorageStatusSeverity = .none
    @Published private(set) var isClearingObservationData = false
    @Published private(set) var health = AppHealthSnapshot(
        coreAudio: .healthyNoActiveOutput,
        lidMonitor: .healthy,
        chrome: .waitingForConnection,
        storage: .healthy,
        recovery: .healthy
    )
    var chromeConnectionState: ChromeConnectionState {
        switch health.chrome {
        case .notRegistered, .manifestPathMismatch:
            return .notRegistered
        case .waitingForConnection, .degraded:
            return .waitingForExtension
        case .connected:
            return .connected
        case .recentlyAccepted:
            return .receivedEvent
        }
    }

    var chromeBridgeStatus: String {
        switch health.chrome {
        case .notRegistered: return "未注册 Chrome 通信主机"
        case .waitingForConnection: return "等待 Chrome 扩展连接"
        case .connected: return "Chrome 已连接"
        case .recentlyAccepted: return "最近收到 Chrome 事件"
        case .manifestPathMismatch: return "Chrome 通信路径需要修复"
        case .degraded: return "Chrome 通信异常"
        }
    }

    var canRepairChromeManifest: Bool {
        if case .manifestPathMismatch = health.chrome { return true }
        return false
    }

    var canToggleGuard: Bool { lifecycleState == .ready }

    private let coordinator: ProtectionCoordinator<SpeakerRecoveryRuntime>
    private let audioController: SystemAudioController
    private let recoveryRuntime: SpeakerRecoveryRuntime
    private var lifecycleCoordinator: ApplicationLifecycleCoordinator!
    private var lifecycleStateProvider: (any LifecycleStateProviding)!
    private lazy var routeMonitor = SystemAudioRouteMonitor { [weak self] in
        self?.receiveAudioRouteChanged()
    }
    private lazy var simulationProtectionLifecycle = SimulationProtectionLifecycle(coordinator: coordinator)
    private let store: any EventStoring
    private let inboxConsumer: any ChromeInboxConsuming
    private let observationStore: any ObservationClearing
    private let observationPipelineCoordinator: any ObservationPipelineCoordinating
    private let applicationSupport: URL
    private let chromeManifestURL: URL
    private let heartbeatStore: any ChromeHostHeartbeatPersisting
    private let acceptanceStore: any ChromeHostAcceptancePersisting
    private let chromeRegistration: any ChromeHostRegistering
    private let diagnosticSink: any LidMuteDiagnosticSinking
    private let audioPoller: any AudioProcessPolling
    private let uptime: @Sendable () -> TimeInterval
    private let expectedChromeHostPath: URL
    private let healthIOCollector: any AppHealthIOCollecting
    private var audioTimer: Timer?
    private var inboxTimer: Timer?
    private var nightTimer: Timer?
    private var lidMonitor: SystemLidMonitor?
    private var displayMonitor: SystemDisplayMonitor?
    private var latestSystemLidClosed: Bool?
    private var latestChromeEvidence: ChromeTabEvidence?
    private var lastLidMonitorResult: LidMonitorResult = .state(false)
    private var chromeDiagnosticState: ChromeDiagnosticState = .none
    private var chromeBridgeIsDegraded = false
    private let nightPreferences = NightProtectionPreferences()
    private var effectiveNightSchedule = NightSchedule(startMinutes: 0, endMinutes: 8 * 60)
    private var hasStarted = false
    private var isShuttingDown = false
    private var protectionEventTask: Task<Void, Never>?
    private var routeChangeTask: Task<Void, Never>?
    private var audioPollTask: Task<Void, Never>?
    private var audioPollWorkTask: Task<Result<[AudioProcess], AudioQueryFailure>, Never>?
    private var chromeInboxPollTask: Task<Void, Never>?
    private var chromeInboxWorkTask: Task<ChromeConsumeBatch, Error>?
    private var nightProtectionTask: Task<Void, Never>?
    private var observationClearWorkTask: Task<ObservationClearReport, Error>?
    private var routeChangePending = false
    private var isChromeInboxPollInFlight = false
    private var observationEpoch: UInt64 = 0
    private var coordinatorStorageHealth: ObservationStorageHealth = .healthy
    private var startupHealth: OperationalStorageHealth = .healthy
    private var consumeHealth: OperationalStorageHealth = .healthy
    private var ackHealth: OperationalStorageHealth = .healthy
    private var clearHealth: OperationalStorageHealth = .healthy
    private var startupTypedHealth: ObservationStorageHealth = .healthy
    private var consumeTypedHealth: ObservationStorageHealth = .healthy
    private var ackTypedHealth: ObservationStorageHealth = .healthy
    private var clearTypedHealth: ObservationStorageHealth = .healthy
    private var healthRefreshGeneration: UInt64 = 0
    private var healthRefreshTask: Task<Void, Never>?

    init(
        applicationSupport: URL? = nil,
        eventStore: (any EventStoring)? = nil,
        inboxConsumer: (any ChromeInboxConsuming)? = nil,
        observationStore: (any ObservationClearing)? = nil,
        lifecycle: (any LifecycleStateProviding)? = nil,
        chromeManifestURL: URL? = nil,
        observationPipelineCoordinator: (any ObservationPipelineCoordinating)? = nil,
        heartbeatStore: (any ChromeHostHeartbeatPersisting)? = nil,
        acceptanceStore: (any ChromeHostAcceptancePersisting)? = nil,
        chromeRegistration: (any ChromeHostRegistering & ChromeManifestInspecting)? = nil,
        diagnosticSink: (any LidMuteDiagnosticSinking)? = nil,
        audioPoller: (any AudioProcessPolling)? = nil,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        expectedChromeHostPath: URL? = nil,
        healthIOCollector: (any AppHealthIOCollecting)? = nil,
        chromeInstalled: Bool? = nil
    ) {
        let support = applicationSupport ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LidMute", directoryHint: .isDirectory)
        self.applicationSupport = support
        self.isChromeInstalled = chromeInstalled ?? Self.detectChromeInstallation()
        let resolvedManifestURL = chromeManifestURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.lidmute.nativehost.json")
        self.chromeManifestURL = resolvedManifestURL
        let originURL = support.appending(path: "chrome-origin.txt")
        let heartbeatURL = support.appending(path: "chrome-host-heartbeat.json")
        let resolvedHeartbeatStore = heartbeatStore ?? FileChromeHostHeartbeatStore(url: heartbeatURL)
        let resolvedAcceptanceStore = acceptanceStore ?? FileChromeHostAcceptanceStore(
            url: support.appending(path: "chrome-host-acceptance.json"),
            heartbeatURL: heartbeatURL
        )
        let resolvedChromeRegistration = chromeRegistration ?? ChromeHostRegistration(
            manifestURL: resolvedManifestURL,
            originURL: originURL
        )
        self.heartbeatStore = resolvedHeartbeatStore
        self.acceptanceStore = resolvedAcceptanceStore
        self.chromeRegistration = resolvedChromeRegistration
        self.diagnosticSink = diagnosticSink ?? LoggerDiagnosticSink()
        self.uptime = uptime
        self.expectedChromeHostPath = expectedChromeHostPath ?? Bundle.main.bundleURL
            .appending(path: "Contents/MacOS/LidMuteNativeHost")
        self.healthIOCollector = healthIOCollector ?? DefaultAppHealthIOCollector(
            heartbeatStore: resolvedHeartbeatStore,
            acceptanceStore: resolvedAcceptanceStore,
            chromeRegistration: resolvedChromeRegistration
        )

        let paths = ObservationPaths(root: support)
        let fileSystem = POSIXObservationFileSystem()
        let sharedLock = POSIXObservationLock(lockURL: paths.lock)
        let productionObservationStore = ObservationStore(
            paths: paths,
            fileSystem: fileSystem,
            lock: sharedLock
        )
        let productionEventStore = BoundedJSONLineEventStore(
            url: paths.events,
            maximumCount: 5_000,
            fileSystem: fileSystem,
            lock: sharedLock
        )
        store = eventStore ?? productionEventStore
        self.observationStore = observationStore ?? productionObservationStore
        self.inboxConsumer = inboxConsumer ?? ChromeInboxConsumer(
            paths: paths,
            observationStore: productionObservationStore,
            eventStore: productionEventStore,
            fileSystem: fileSystem
        )
        let audioController = SystemAudioController()
        let recoveryStore = FileSpeakerRecoveryStore(
            url: support.appending(path: "speaker-recovery.json")
        )
        let recoveryRuntime = SpeakerRecoveryRuntime(
            audio: audioController,
            recoveryStore: recoveryStore,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        )
        self.audioController = audioController
        self.audioPoller = audioPoller ?? audioController
        self.recoveryRuntime = recoveryRuntime
        let coordinator = ProtectionCoordinator(
            protection: recoveryRuntime,
            store: store
        )
        self.coordinator = coordinator
        self.observationPipelineCoordinator = observationPipelineCoordinator ?? coordinator
        let lifecycleCoordinator = ApplicationLifecycleCoordinator(
            recovery: recoveryRuntime,
            monitors: self
        )
        self.lifecycleCoordinator = lifecycleCoordinator
        lifecycleStateProvider = lifecycle ?? lifecycleCoordinator
        lifecycleState = lifecycleStateProvider.state
        let nightConfiguration = nightPreferences.load()
        nightScheduleEnabled = nightConfiguration.enabled
        nightStartText = nightConfiguration.startText
        nightEndText = nightConfiguration.endText
        effectiveNightSchedule = NightSchedule(
            startMinutes: NightProtectionPreferences.minutes(from: nightConfiguration.startText) ?? 0,
            endMinutes: NightProtectionPreferences.minutes(from: nightConfiguration.endText) ?? 8 * 60
        )
        coordinator.onEvent = { [weak self] event in self?.receiveCoordinatorEvent(event) }
        coordinator.onStorageHealth = { [weak self] health in
            self?.receiveCoordinatorStorageHealth(health)
        }
        coordinator.onRecoveryOutcome = { [weak self] outcome in
            self?.setRecoveryHealth(AppHealthMapper.recovery(outcome))
        }
        do {
            events = Array(try store.recent(limit: 5_000).reversed())
        } catch {
            events = []
            setOperationalStorageFailure(error, source: .startup)
        }
        resolveChromeExtensionPath()
        refresh()
        refreshHealth()
    }

    private static func detectChromeInstallation() -> Bool {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        return [
            URL(filePath: "/Applications/Google Chrome.app"),
            home.appending(path: "Applications/Google Chrome.app")
        ].contains { fileManager.fileExists(atPath: $0.path) }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await lifecycleCoordinator.start()
        lifecycleState = lifecycleCoordinator.state
        startChromeObservationTimerIfReady()
        refresh()
    }

    func startAll() throws {
        guard !isShuttingDown else { return }
        try routeMonitor.start()
        lifecycleState = .ready
        if lidMonitor == nil {
            let monitor = SystemLidMonitor { [weak self] result in self?.receiveLidMonitorResult(result) }
            monitor.start()
            lidMonitor = monitor
        }
        if displayMonitor == nil {
            let monitor = SystemDisplayMonitor { [weak self] sleeping in self?.receiveDisplaySleep(sleeping) }
            monitor.start()
            displayMonitor = monitor
        }
        if audioTimer == nil {
            audioTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.pollAudioProcesses() }
            }
        }
        if nightTimer == nil {
            nightTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleNightProtectionRefresh() }
            }
        }
        pollAudioProcesses()
        scheduleNightProtectionRefresh()
    }

    func startRouteOnly() throws {
        guard !isShuttingDown else { return }
        try routeMonitor.start(reportDeviceListChanges: true)
    }

    func stopAll() {
        routeMonitor.stop()
        lidMonitor?.stop()
        lidMonitor = nil
        displayMonitor?.stop()
        displayMonitor = nil
        audioTimer?.invalidate()
        audioTimer = nil
        inboxTimer?.invalidate()
        inboxTimer = nil
        nightTimer?.invalidate()
        nightTimer = nil
        protectionEventTask?.cancel()
        protectionEventTask = nil
        routeChangeTask?.cancel()
        routeChangeTask = nil
        audioPollTask?.cancel()
        audioPollTask = nil
        audioPollWorkTask?.cancel()
        audioPollWorkTask = nil
        chromeInboxPollTask?.cancel()
        chromeInboxPollTask = nil
        chromeInboxWorkTask?.cancel()
        chromeInboxWorkTask = nil
        nightProtectionTask?.cancel()
        nightProtectionTask = nil
        observationClearWorkTask?.cancel()
        observationClearWorkTask = nil
        healthRefreshTask?.cancel()
        healthRefreshTask = nil
        healthRefreshGeneration &+= 1
        isChromeInboxPollInFlight = false
        routeChangePending = false
    }

    func shutdownAndRestore() async -> ApplicationShutdownResult {
        guard !isShuttingDown else {
            return .recovery(await recoveryRuntime.recoverPending())
        }
        isShuttingDown = true
        // Stop monitors and cancel queued observation work before final recovery.
        // Waiting on the queue can retain stale Chrome/audio deliveries and delay
        // AppKit's terminate-later reply.
        lifecycleCoordinator.stop()
        let outcome = await coordinator.endProtectionForShutdown()
        setRecoveryHealth(AppHealthMapper.recovery(outcome))
        isEnabled = false
        refresh()
        return .recovery(outcome)
    }

    func resumeAfterCancelledTermination(_ result: ApplicationShutdownResult) async {
        if result == .timedOut {
            lifecycleState = .shutdownUnresolved
            refresh()
            return
        }
        isShuttingDown = false
        coordinator.resumeAfterCancelledShutdown()
        routeChangeTask = nil
        if case let .recovery(outcome) = result {
            lifecycleCoordinator.resume(after: outcome)
            lifecycleState = lifecycleCoordinator.state
            setRecoveryHealth(AppHealthMapper.recovery(outcome))
        }
        startChromeObservationTimerIfReady()
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        guard canToggleGuard, !isShuttingDown else { return }
        isEnabled = enabled
        if !enabled {
            isNightProtectionActive = false
        }
        enqueueProtectionEvent { model in
            guard !model.isShuttingDown else { return }
            await model.coordinator.setEnabled(enabled)
            if enabled, let latestSystemLidClosed = model.latestSystemLidClosed {
                await model.observationPipelineCoordinator.receivePhysicalLid(closed: latestSystemLidClosed)
            }
            await model.refreshNightProtection()
            model.refresh()
        }
    }

    func receiveSystemLidState(_ closed: Bool) {
        guard lifecycleState == .ready, !isShuttingDown else { return }
        latestSystemLidClosed = closed
        enqueueProtectionEvent { model in
            guard !model.isShuttingDown else { return }
            await model.observationPipelineCoordinator.receivePhysicalLid(closed: closed)
            model.refresh()
        }
    }

    func receiveLidMonitorResult(_ result: LidMonitorResult) {
        lastLidMonitorResult = result
        switch result {
        case let .state(closed):
            receiveSystemLidState(closed)
        case .unavailable:
            diagnosticSink.emit(.lidMonitorUnavailable)
            refreshHealth()
        case .readFailed:
            diagnosticSink.emit(.lidMonitorReadFailed)
            refreshHealth()
        }
    }

    func receiveDisplaySleep(_ sleeping: Bool) {
        guard lifecycleState == .ready, !isShuttingDown else { return }
        isDisplaySleeping = sleeping
        enqueueProtectionEvent { model in await model.refreshNightProtection() }
    }

    func simulateLidClosed() {
        guard lifecycleState == .ready, !isShuttingDown else { return }
        guard simulatedLidState != .closed else { return }
        simulatedLidState = .closed
        enqueueProtectionEvent { model in
            guard !model.isShuttingDown else { return }
            await model.simulationProtectionLifecycle.update(.closed)
            model.refresh()
        }
    }

    func simulateLidOpened() {
        guard lifecycleState == .ready, !isShuttingDown else { return }
        guard simulatedLidState != .opened else { return }
        simulatedLidState = .opened
        enqueueProtectionEvent { model in
            guard !model.isShuttingDown else { return }
            await model.simulationProtectionLifecycle.update(.opened)
            model.refresh()
        }
    }

    func resetSimulationState() {
        guard lifecycleState == .ready, !isShuttingDown else { return }
        simulatedLidState = .opened
        enqueueProtectionEvent { model in
            await model.simulationProtectionLifecycle.update(.reset)
            model.refresh()
        }
    }

    func setLightweightModeEnabled(_ enabled: Bool) {
        guard isLightweightModeEnabled != enabled else { return }
        isLightweightModeEnabled = enabled
    }

    func setNightScheduleEnabled(_ enabled: Bool) {
        guard isNightScheduleInputValid else {
            nightScheduleEnabled = false
            nightPreferences.saveEnabled(false)
            enqueueProtectionEvent { model in await model.refreshNightProtection() }
            return
        }
        nightScheduleEnabled = enabled
        nightPreferences.saveEnabled(enabled)
        enqueueProtectionEvent { model in await model.refreshNightProtection() }
    }

    func nightScheduleTextChanged() {
        switch validateNightScheduleInput() {
        case let .invalid(message):
            isNightScheduleInputValid = false
            nightScheduleStatus = message
            if nightScheduleEnabled {
                nightScheduleEnabled = false
                nightPreferences.saveEnabled(false)
            }
        case let .valid(startMinutes, endMinutes):
            isNightScheduleInputValid = true
            guard nightPreferences.saveSchedule(startText: nightStartText, endText: nightEndText) else { return }
            effectiveNightSchedule = NightSchedule(startMinutes: startMinutes, endMinutes: endMinutes)
            nightScheduleStatus = nightScheduleEnabled
                ? "夜间时段：\(nightStartText)-\(nightEndText)（北京时间）"
                : "夜间静音未开启"
        }
        enqueueProtectionEvent { model in await model.refreshNightProtection() }
    }

    private func validateNightScheduleInput() -> NightScheduleInputValidation {
        guard Self.hasTimeShape(nightStartText), Self.hasTimeShape(nightEndText) else {
            return .invalid(message: "请输入 HH:mm 格式")
        }
        guard let startMinutes = NightProtectionPreferences.minutes(from: nightStartText),
              let endMinutes = NightProtectionPreferences.minutes(from: nightEndText) else {
            return .invalid(message: "时间需在 00:00–23:59 之间")
        }
        guard NightSchedule.isValid(startMinutes: startMinutes, endMinutes: endMinutes) else {
            return .invalid(message: "夜间时段需在 12 小时以内")
        }
        return .valid(startMinutes: startMinutes, endMinutes: endMinutes)
    }

    private static func hasTimeShape(_ text: String) -> Bool {
        let characters = Array(text)
        guard characters.count == 5, characters[2] == ":" else { return false }
        return characters[0].isNumber && characters[1].isNumber &&
            characters[3].isNumber && characters[4].isNumber
    }

    func clearObservationData() async {
        guard !isClearingObservationData else { return }
        isClearingObservationData = true
        observationEpoch &+= 1
        healthRefreshGeneration &+= 1
        inboxTimer?.invalidate()
        inboxTimer = nil
        defer {
            isClearingObservationData = false
            refreshHealth()
            startChromeObservationTimerIfReady()
        }

        let queuedProtectionWork = protectionEventTask
        let queuedRouteWork = routeChangeTask
        await queuedProtectionWork?.value
        await queuedRouteWork?.value
        let clearBoundary = await observationPipelineCoordinator.beginObservationClear()
        var clearReport: ObservationClearReport?

        do {
            let observationStore = observationStore
            let acceptanceStore = acceptanceStore
            let clearTask = Task.detached(priority: .utility) {
                try observationStore.clearObservationData(
                    persistentReset: { try acceptanceStore.remove() },
                    inMemoryReset: {}
                )
            }
            observationClearWorkTask = clearTask
            defer { observationClearWorkTask = nil }
            let report = try await clearTask.value
            clearReport = report
            applyObservationClearReport(report)
            setOperationalStorageStatus(
                report.isComplete
                    ? ""
                    : "部分数据未清空：\(report.failures.map(\.rawValue).joined(separator: "、"))",
                severity: .warning,
                source: .clear
            )
            setOperationalStorageHealth(
                report.isComplete ? .healthy : .ioFailure("clear_partial"),
                source: .clear,
                updatePresentation: false
            )
        } catch {
            setOperationalStorageFailure(error, source: .clear)
        }
        observationPipelineCoordinator.endObservationClear(clearBoundary, report: clearReport)
    }

    func pollChromeInbox() async {
        guard lifecycleStateProvider.state == .ready,
              !isShuttingDown,
              !isClearingObservationData,
              !isChromeInboxPollInFlight else { return }
        isChromeInboxPollInFlight = true
        defer { isChromeInboxPollInFlight = false }

        let consumer = inboxConsumer
        let pollEpoch = observationEpoch
        do {
            let consumeTask = Task.detached(priority: .utility) {
                try consumer.consumeAvailable()
            }
            chromeInboxWorkTask = consumeTask
            defer { chromeInboxWorkTask = nil }
            let batch = try await consumeTask.value
            guard lifecycleStateProvider.state == .ready,
                  !isShuttingDown,
                  !isClearingObservationData,
                  observationEpoch == pollEpoch else { return }
            chromeBridgeIsDegraded = false
            setOperationalStorageHealth(batch.health, source: .consume)
            guard !batch.records.isEmpty else {
                checkChromeConnection()
                return
            }
            refreshHealth()

            for record in batch.records {
                latestChromeEvidence = record.evidence
                receiveCoordinatorEvent(Self.timelineEvent(for: record))
            }
            let deliveryTask = enqueueProtectionEvent { model in
                guard !model.isShuttingDown,
                      !model.isClearingObservationData,
                      model.observationEpoch == pollEpoch else { return }
                var deliveryIsSafeToAcknowledge = true
                for record in batch.records {
                    guard !model.isShuttingDown,
                          !model.isClearingObservationData,
                          model.observationEpoch == pollEpoch else {
                        deliveryIsSafeToAcknowledge = false
                        break
                    }
                    let outcome = await model.observationPipelineCoordinator
                        .ensureProtected(for: record.evidence)
                    deliveryIsSafeToAcknowledge = deliveryIsSafeToAcknowledge &&
                        outcome.deliveryIsSafeToAcknowledge
                }
                if deliveryIsSafeToAcknowledge, let deliveryID = batch.deliveryID {
                    let consumer = model.inboxConsumer
                    do {
                        try await Task.detached(priority: .utility) {
                            try consumer.acknowledgeDelivery(deliveryID)
                        }.value
                        guard model.lifecycleStateProvider.state == .ready,
                              !model.isShuttingDown,
                              !model.isClearingObservationData,
                              model.observationEpoch == pollEpoch else { return }
                        model.setOperationalStorageHealth(.healthy, source: .acknowledgement)
                    } catch {
                        guard model.lifecycleStateProvider.state == .ready,
                              !model.isShuttingDown,
                              !model.isClearingObservationData,
                              model.observationEpoch == pollEpoch else { return }
                        model.setOperationalStorageFailure(error, source: .acknowledgement)
                    }
                }
                model.refresh()
            }
            await deliveryTask.value
            guard lifecycleStateProvider.state == .ready,
                  !isShuttingDown,
                  !isClearingObservationData,
                  observationEpoch == pollEpoch else { return }
            rebuildCurrentAudioSources()
        } catch {
            guard lifecycleStateProvider.state == .ready,
                  !isShuttingDown,
                  !isClearingObservationData,
                  observationEpoch == pollEpoch else { return }
            receiveChromeBridgeDegraded()
            setOperationalStorageFailure(error, source: .consume)
        }
    }

    func receiveCoordinatorStorageHealth(_ health: ObservationStorageHealth) {
        coordinatorStorageHealth = health
        publishStorageStatusPresentation()
    }

    func receiveCoordinatorEvent(_ event: LidMuteEvent) {
        if let observationEventID = event.observationEventID {
            events.removeAll { $0.observationEventID == observationEventID }
        }
        events.insert(event, at: 0)
        if events.count > 5_000 {
            events.removeLast(events.count - 5_000)
        }
        refresh()
    }

    func pollAudioProcesses() {
        guard lifecycleState == .ready, !isShuttingDown else { return }
        guard audioPollTask == nil else { return }
        let poller = audioPoller
        audioPollTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            defer {
                // stopAll already cleared a cancelled task's slots. A newer
                // poll may now own them while the old synchronous query exits.
                if !Task.isCancelled {
                    self?.audioPollTask = nil
                    self?.audioPollWorkTask = nil
                }
            }
            let pollTask = Task.detached(priority: .utility) {
                poller.pollAudioProcesses()
            }
            self?.audioPollWorkTask = pollTask
            let result = await pollTask.value
            guard !Task.isCancelled,
                  let self, self.lifecycleState == .ready, !self.isShuttingDown else { return }
            self.receiveAudioPollResult(result)
        }
    }

    func receiveAudioPollResult(_ result: Result<[AudioProcess], AudioQueryFailure>) {
        switch result {
        case let .success(processes):
            updateHealth(coreAudio: processes.isEmpty
                ? .healthyNoActiveOutput
                : .healthy(activeOutputCount: processes.count))
            updateAudioProcesses(processes)
        case .failure:
            if health.coreAudio != .queryFailed {
                diagnosticSink.emit(.coreAudioQueryFailed)
            }
            updateHealth(coreAudio: .queryFailed)
            statusText = "无法查询 CoreAudio，请检查系统状态"
        }
    }

    private func updateAudioProcesses(_ processes: [AudioProcess]) {
        currentAudioProcesses = processes.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if !processes.contains(where: AudioSourcePresentation.isChrome) {
            latestChromeEvidence = nil
        }
        rebuildCurrentAudioSources()
        enqueueProtectionEvent { model in
            guard !model.isShuttingDown else { return }
            await model.coordinator.receiveAudioSnapshot(processes)
            model.refresh()
        }
    }

    private func rebuildCurrentAudioSources() {
        currentAudioSources = AudioSourcePresentation.current(
            processes: currentAudioProcesses,
            chromeTab: latestChromeEvidence
        )
    }

    private func applyObservationClearReport(_ report: ObservationClearReport) {
        if !report.failures.contains(.events) {
            events.removeAll()
        }
        if !report.failures.contains(.inbox) {
            latestChromeEvidence = nil
            currentAudioSources = AudioSourcePresentation.current(
                processes: currentAudioProcesses,
                chromeTab: nil
            )
        }
        if !report.failures.contains(.cursor),
           !report.failures.contains(.pendingDelivery) {
            inboxConsumer.resetInMemoryState()
        }
    }

    private func refreshNightProtection() async {
        guard lifecycleState == .ready, !isShuttingDown else { return }
        guard isNightScheduleInputValid else {
            if nightScheduleEnabled {
                nightScheduleEnabled = false
                nightPreferences.saveEnabled(false)
            }
            if case let .invalid(message) = validateNightScheduleInput() {
                nightScheduleStatus = message
            }
            if isNightProtectionActive {
                isNightProtectionActive = false
                await coordinator.receiveNightProtection(false)
                refresh()
            }
            return
        }
        nightScheduleStatus = nightScheduleEnabled
            ? "夜间时段：\(nightStartText)-\(nightEndText)（北京时间）"
            : "夜间静音未开启"

        let shouldProtect = isEnabled && nightScheduleEnabled && isDisplaySleeping && effectiveNightSchedule.isActive(at: Date())
        guard shouldProtect != isNightProtectionActive else { return }
        isNightProtectionActive = shouldProtect
        await coordinator.receiveNightProtection(shouldProtect)
        refresh()
    }

    private func startChromeObservationTimerIfReady() {
        guard lifecycleStateProvider.state == .ready,
              !isShuttingDown,
              !isClearingObservationData,
              inboxTimer == nil else { return }
        inboxTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleChromeInboxPoll() }
        }
        scheduleChromeInboxPoll()
    }

    private func scheduleChromeInboxPoll() {
        guard chromeInboxPollTask == nil, !isShuttingDown else { return }
        chromeInboxPollTask = Task { @MainActor [weak self] in
            defer { self?.chromeInboxPollTask = nil }
            await self?.pollChromeInbox()
        }
    }

    private func scheduleNightProtectionRefresh() {
        guard nightProtectionTask == nil, !isShuttingDown else { return }
        nightProtectionTask = Task { @MainActor [weak self] in
            defer { self?.nightProtectionTask = nil }
            await self?.refreshNightProtection()
        }
    }

    private func resolveChromeExtensionPath() {
        // Production: inside app bundle
        let bundlePath = Bundle.main.bundleURL
            .appending(path: "Contents/Resources/ChromeExtension").path
        if FileManager.default.fileExists(atPath: bundlePath) {
            chromeExtensionPath = bundlePath
            return
        }
        // Development: relative to executable
        let devPath = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "ChromeExtension").path
        if FileManager.default.fileExists(atPath: devPath) {
            chromeExtensionPath = devPath
            return
        }
        chromeExtensionPath = "LidMute.app/Contents/Resources/ChromeExtension"
    }

    private var chromeOriginURL: URL {
        applicationSupport.appending(path: "chrome-origin.txt")
    }

    private var registeredExtensionId: String? {
        guard let data = try? Data(contentsOf: chromeOriginURL),
              let content = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              content.hasPrefix("chrome-extension://"),
              content.hasSuffix("/") else { return nil }
        return String(content.dropFirst("chrome-extension://".count).dropLast())
    }

    func checkChromeConnection() {
        refreshHealth()

        // Pre-fill extension ID if registered
        if chromeExtensionId.isEmpty, let registeredId = registeredExtensionId {
            chromeExtensionId = registeredId
        }
    }

    func refreshHealth() {
        guard !isShuttingDown else { return }
        healthRefreshTask?.cancel()
        refreshLocalHealth()
        healthRefreshGeneration &+= 1
        let generation = healthRefreshGeneration
        let collector = healthIOCollector
        let uptime = self.uptime
        let expectedHostPath = expectedChromeHostPath
        healthRefreshTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                collector.collect(nowUptime: uptime(), expectedHostPath: expectedHostPath)
            }.value
            guard let self, self.healthRefreshGeneration == generation else { return }
            self.applyChromeHealthResult(result)
        }
    }

    private func refreshLocalHealth() {
        switch lastLidMonitorResult {
        case .state:
            updateHealth(lidMonitor: .healthy)
        case .unavailable:
            updateHealth(lidMonitor: .unavailable)
        case .readFailed:
            updateHealth(lidMonitor: .readFailed)
        }

        switch lifecycleState {
        case let .recoveryBlocked(outcome):
            setRecoveryHealth(AppHealthMapper.recovery(outcome))
        case .ready where !isShuttingDown:
            setRecoveryHealth(.healthy)
        case .ready, .recovering, .shutdownUnresolved:
            break
        }

    }

    func waitForHealthRefresh() async {
        await healthRefreshTask?.value
    }

    private func applyChromeHealthResult(_ result: ChromeHealthIOResult) {
        let nextChromeHealth: ChromeBridgeHealth
        let nextDiagnosticState: ChromeDiagnosticState
        switch result.manifest {
        case .notRegistered:
            nextChromeHealth = .notRegistered
            nextDiagnosticState = .none
        case let .pathMismatch(expected, registered):
            nextChromeHealth = .manifestPathMismatch(expected: expected, registered: registered)
            nextDiagnosticState = .manifestMismatch
        case .malformed:
            nextChromeHealth = .degraded
            nextDiagnosticState = .degraded
        case .current:
            if chromeBridgeIsDegraded {
                nextChromeHealth = .degraded
                nextDiagnosticState = .degraded
            } else {
                switch result.heartbeat {
                case let .fresh(sessionToken, pid):
                    if result.acceptance ==
                        .fresh(sessionToken: sessionToken, pid: pid) {
                        nextChromeHealth = .recentlyAccepted(sessionToken: sessionToken, pid: pid)
                    } else {
                        nextChromeHealth = .connected(sessionToken: sessionToken, pid: pid)
                    }
                    nextDiagnosticState = .none
                case .stale, .malformed:
                    nextChromeHealth = .waitingForConnection
                    nextDiagnosticState = .staleHeartbeat
                }
            }
        }
        updateHealth(chrome: nextChromeHealth)
        if nextDiagnosticState != chromeDiagnosticState {
            switch nextDiagnosticState {
            case .none:
                break
            case .staleHeartbeat:
                diagnosticSink.emit(.chromeHeartbeatStale)
            case .manifestMismatch:
                diagnosticSink.emit(.chromeManifestPathMismatch)
            case .degraded:
                diagnosticSink.emit(.chromeBridgeDegraded)
            }
            chromeDiagnosticState = nextDiagnosticState
        }
    }

    func receiveChromeBridgeDegraded() {
        chromeBridgeIsDegraded = true
        refreshHealth()
    }

    func repairChromeManifest() {
        guard canRepairChromeManifest else { return }
        do {
            try chromeRegistration.repair(expectedHostPath: expectedChromeHostPath)
            chromeRegistrationStatus = "Chrome 通信路径已修复"
            diagnosticSink.emit(.chromeManifestRepaired)
        } catch {
            chromeRegistrationStatus = "Chrome 通信路径修复失败"
        }
        refreshHealth()
    }

    func registerChromeHost(extensionId: String) {
        let extId = extensionId.trimmingCharacters(in: .whitespaces)
        guard !extId.isEmpty else {
            chromeRegistrationStatus = "请输入扩展 ID"
            return
        }

        let origin = "chrome-extension://\(extId)/"

        do {
            try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: applicationSupport.path)

            // Write origin file
            try origin.write(to: chromeOriginURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: chromeOriginURL.path)

            // Find native host path
            let hostPath = findNativeHostPath()
            guard FileManager.default.isExecutableFile(atPath: hostPath) else {
                chromeRegistrationStatus = "找不到 LidMuteNativeHost，请先编译项目"
                return
            }

            // Write NativeMessagingHost manifest
            let manifestDir = chromeManifestURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: manifestDir, withIntermediateDirectories: true)

            let manifest: [String: Any] = [
                "name": "com.lidmute.nativehost",
                "description": "LidMute Chrome bridge",
                "path": hostPath,
                "type": "stdio",
                "allowed_origins": [origin],
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
            try data.write(to: chromeManifestURL, options: .atomic)

            // Set permissions to 600 (owner read/write only)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: chromeManifestURL.path)

            chromeRegistrationStatus = "注册成功！请在 Chrome 扩展页面刷新后回到本应用"
            checkChromeConnection()
        } catch {
            chromeRegistrationStatus = "注册失败：\(error.localizedDescription)"
        }
    }

    private func findNativeHostPath() -> String {
        // Same directory as the running executable
        let appDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let hostPath = appDir.appending(path: "LidMuteNativeHost").path
        if FileManager.default.isExecutableFile(atPath: hostPath) {
            return hostPath
        }
        // Fallback: inside app bundle
        let bundleHost = Bundle.main.bundleURL
            .appending(path: "Contents/MacOS/LidMuteNativeHost").path
        if FileManager.default.isExecutableFile(atPath: bundleHost) {
            return bundleHost
        }
        return hostPath
    }

    private func refresh() {
        refreshLocalHealth()
        switch lifecycleState {
        case .recovering:
            statusText = "正在恢复内建扬声器安全状态"
            return
        case .shutdownUnresolved:
            statusText = "关机恢复仍在进行，守卫操作已暂时停用"
            return
        case let .recoveryBlocked(outcome):
            statusText = recoveryBlockedStatus(outcome)
            return
        case .ready:
            break
        }
        switch coordinator.state {
        case .inactive: statusText = "守卫未开启"
        case .armed: statusText = "已开启，等待合盖"
        case .protecting: statusText = "正在保护内建扬声器"
        case .unavailable: statusText = "未发现可控制的内建扬声器"
        }
    }

    private func updateHealth(
        coreAudio: CoreAudioHealth? = nil,
        lidMonitor: LidMonitorHealth? = nil,
        chrome: ChromeBridgeHealth? = nil,
        storage: LocalStorageHealth? = nil,
        recovery: SpeakerRecoveryHealth? = nil
    ) {
        health = AppHealthSnapshot(
            coreAudio: coreAudio ?? health.coreAudio,
            lidMonitor: lidMonitor ?? health.lidMonitor,
            chrome: chrome ?? health.chrome,
            storage: storage ?? health.storage,
            recovery: recovery ?? health.recovery
        )
    }

    private func setRecoveryHealth(_ value: SpeakerRecoveryHealth) {
        guard health.recovery != value else { return }
        updateHealth(recovery: value)
        switch value {
        case .waitingForMatchingDevice:
            diagnosticSink.emit(.recoveryWaitingForMatchingDevice)
        case .failedButVerifiedSilent:
            diagnosticSink.emit(.recoveryFailedButVerifiedSilent)
        case .failedSafetyUnknown:
            diagnosticSink.emit(.recoveryFailedSafetyUnknown)
        case .healthy, .corruptSnapshot, .unsupportedSnapshot:
            break
        }
    }

    func receiveAudioRouteChanged() {
        guard !isShuttingDown else { return }
        if routeChangeTask != nil {
            routeChangePending = true
            return
        }
        let routeEpoch = observationEpoch
        routeChangeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                routeChangeTask = nil
                routeChangePending = false
            }
            repeat {
                routeChangePending = false
                await lifecycleStateProvider.receiveAudioRouteChanged()
                lifecycleState = lifecycleStateProvider.state
                if !isClearingObservationData, observationEpoch == routeEpoch {
                    startChromeObservationTimerIfReady()
                }
                if lifecycleState == .ready, !isShuttingDown {
                    await observationPipelineCoordinator.receiveAudioRouteChanged()
                }
                refresh()
            } while routeChangePending && !isShuttingDown
        }
    }

    @discardableResult
    private func enqueueProtectionEvent(
        _ operation: @escaping @MainActor (AppViewModel) async -> Void
    ) -> Task<Void, Never> {
        let predecessor = protectionEventTask
        let task = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }
            await operation(self)
        }
        protectionEventTask = task
        return task
    }

    private func recoveryBlockedStatus(_ outcome: SpeakerRecoveryOutcome) -> String {
        switch outcome {
        case .waitingForMatchingDevice:
            return "等待原内建扬声器重新出现"
        case .corruptSnapshot:
            return "扬声器恢复记录损坏，守卫已阻止启动"
        case let .unsupportedSnapshot(version):
            return "扬声器恢复记录版本不受支持（\(version)）"
        case .failedButVerifiedSilent:
            return "恢复失败，但已验证扬声器保持静音"
        case .failedSafetyUnknown:
            return "扬声器安全状态未知，守卫已阻止启动"
        case .noPendingRecovery, .restored:
            return "扬声器恢复已完成"
        }
    }

    private static func timelineEvent(for record: ChromeInboxRecord) -> LidMuteEvent {
        LidMuteEvent(
            timestamp: record.acceptedAt,
            kind: .chromeTabAudible,
            detail: "\(record.evidence.title) · \(record.evidence.url)",
            observationEventID: record.eventID,
            chromeTab: record.evidence,
            correlation: .browserObservedOnly
        )
    }

    private static func storageFailureText(_ error: Error) -> String {
        switch error {
        case EventStoreError.corruptRecord:
            return "观察记录损坏，未静默跳过"
        case EventStoreError.permissionFailure, ChromeConsumeError.permissionFailure:
            return "观察存储权限不足"
        case EventStoreError.capacityFailure, ChromeConsumeError.capacityFailure:
            return "观察存储空间不足"
        case ChromeConsumeError.corruptRecord, ChromeConsumeError.corruptCursor:
            return "Chrome 观察数据损坏，未静默跳过"
        default:
            return "观察存储失败：\(error.localizedDescription)"
        }
    }

    private func setOperationalStorageStatus(
        _ text: String,
        severity: StorageStatusSeverity = .error,
        source: OperationalStorageSource
    ) {
        let health: OperationalStorageHealth
        if text.isEmpty {
            health = .healthy
        } else if severity == .warning {
            health = .warning(text)
        } else {
            health = .failure(text)
        }
        switch source {
        case .startup:
            startupHealth = health
        case .consume:
            consumeHealth = health
        case .acknowledgement:
            ackHealth = health
        case .clear:
            clearHealth = health
        }
        publishStorageStatusPresentation()
    }

    private func setOperationalStorageHealth(
        _ health: ObservationStorageHealth,
        source: OperationalStorageSource,
        updatePresentation: Bool = true
    ) {
        switch source {
        case .startup:
            startupTypedHealth = health
        case .consume:
            consumeTypedHealth = health
        case .acknowledgement:
            ackTypedHealth = health
        case .clear:
            clearTypedHealth = health
        }
        if updatePresentation {
            setOperationalStorageStatus(Self.storageHealthText(health), source: source)
        } else {
            publishStorageStatusPresentation()
        }
    }

    private func setOperationalStorageFailure(_ error: Error, source: OperationalStorageSource) {
        let typed = Self.storageHealth(for: error)
        switch source {
        case .startup:
            startupTypedHealth = typed
        case .consume:
            consumeTypedHealth = typed
        case .acknowledgement:
            ackTypedHealth = typed
        case .clear:
            clearTypedHealth = typed
        }
        setOperationalStorageStatus(Self.storageFailureText(error), source: source)
    }

    private func publishStorageStatusPresentation() {
        var messages: [String] = []
        var severity: StorageStatusSeverity = .none
        if coordinatorStorageHealth != .healthy {
            messages.append(Self.storageHealthText(coordinatorStorageHealth))
            severity = .error
        }

        for health in [startupHealth, consumeHealth, ackHealth, clearHealth] {
            switch health {
            case .healthy:
                break
            case let .warning(text):
                messages.append(text)
                if severity == .none {
                    severity = .warning
                }
            case let .failure(text):
                messages.append(text)
                severity = .error
            }
        }

        storageStatusText = messages.reduce(into: [String]()) { uniqueMessages, message in
            if !uniqueMessages.contains(message) {
                uniqueMessages.append(message)
            }
        }.joined(separator: "\n")
        storageStatusSeverity = severity

        let candidates = [coordinatorStorageHealth, startupTypedHealth, consumeTypedHealth, ackTypedHealth, clearTypedHealth]
            .map(AppHealthMapper.storage)
        let mapped = candidates.max(by: { Self.storageRank($0) < Self.storageRank($1) }) ?? .healthy
        if mapped != health.storage {
            updateHealth(storage: mapped)
            switch mapped {
            case .partiallyCorrupt:
                diagnosticSink.emit(.storagePartiallyCorrupt)
            case .permissionFailed:
                diagnosticSink.emit(.storagePermissionFailed)
            case .capacityFailed:
                diagnosticSink.emit(.storageCapacityFailed)
            case .healthy, .ioFailed:
                break
            }
        }
    }

    private static func storageRank(_ health: LocalStorageHealth) -> Int {
        switch health {
        case .healthy: 0
        case .partiallyCorrupt: 1
        case .ioFailed: 2
        case .permissionFailed: 3
        case .capacityFailed: 4
        }
    }

    private static func storageHealth(for error: Error) -> ObservationStorageHealth {
        switch error {
        case let error as EventStoreError:
            switch error {
            case let .corruptRecord(line): return .corruptRecord(line: line)
            case .permissionFailure: return .permissionFailure
            case .capacityFailure: return .capacityFailure
            case let .ioFailure(reason): return .ioFailure(reason)
            }
        case let error as ChromeConsumeError:
            switch error {
            case let .corruptRecord(line): return .corruptRecord(line: line)
            case .corruptCursor, .corruptPendingDelivery: return .corruptRecord(line: 0)
            case .permissionFailure: return .permissionFailure
            case .capacityFailure: return .capacityFailure
            case let .ioFailure(reason): return .ioFailure(reason)
            case .cursorCommitFailure: return .ioFailure("cursor_commit")
            }
        default:
            return .ioFailure("operation")
        }
    }

    private static func storageHealthText(_ health: ObservationStorageHealth) -> String {
        switch health {
        case .healthy:
            return ""
        case .corruptRecord:
            return "观察记录损坏，未静默跳过"
        case .permissionFailure:
            return "观察存储权限不足"
        case .capacityFailure:
            return "观察存储空间不足"
        case .ioFailure:
            return "观察存储 I/O 失败"
        }
    }

}

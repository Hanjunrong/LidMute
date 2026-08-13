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

@MainActor
final class AppViewModel: ObservableObject, ApplicationMonitoring, ApplicationShuttingDown {
    @Published var isEnabled = false
    @Published var isLightweightModeEnabled = false
    @Published private(set) var statusText = "守卫未开启"
    @Published private(set) var events: [LidMuteEvent] = []
    @Published private(set) var chromeBridgeStatus = "等待 Chrome 扩展连接"
    @Published private(set) var simulatedLidState: SimulatedLidState = .opened
    @Published private(set) var currentAudioProcesses: [AudioProcess] = []
    @Published private(set) var currentAudioSources: [AudioSourcePresentation] = []
    @Published var nightScheduleEnabled = false
    @Published var nightStartText = "00:00"
    @Published var nightEndText = "08:00"
    @Published private(set) var isDisplaySleeping = false
    @Published private(set) var isNightProtectionActive = false
    @Published private(set) var nightScheduleStatus = "夜间静音未开启"
    @Published private(set) var mediaStatus = "系统媒体控制就绪"
    @Published private(set) var chromeConnectionState: ChromeConnectionState = .unknown
    @Published var chromeExtensionId = ""
    @Published private(set) var chromeRegistrationStatus = ""
    @Published private(set) var chromeExtensionPath = ""
    @Published private(set) var lifecycleState: AppLifecycleState = .recovering

    var canToggleGuard: Bool { lifecycleState == .ready }

    private let coordinator: ProtectionCoordinator<SpeakerRecoveryRuntime>
    private let audioController: SystemAudioController
    private let recoveryRuntime: SpeakerRecoveryRuntime
    private lazy var lifecycleCoordinator = ApplicationLifecycleCoordinator(
        recovery: recoveryRuntime,
        monitors: self
    )
    private lazy var routeMonitor = SystemAudioRouteMonitor { [weak self] in
        self?.receiveAudioRouteChanged()
    }
    private lazy var simulationProtectionLifecycle = SimulationProtectionLifecycle(coordinator: coordinator)
    private let store: JSONLineEventStore
    private let applicationSupport: URL
    private let inboxURL: URL
    private let chromeDeduplicator: ChromeEventDeduplicator
    private var inboxOffset = 0
    private var audioTimer: Timer?
    private var inboxTimer: Timer?
    private var nightTimer: Timer?
    private var lidMonitor: SystemLidMonitor?
    private var displayMonitor: SystemDisplayMonitor?
    private var latestSystemLidClosed: Bool?
    private var latestChromeEvidence: ChromeTabEvidence?
    private var lastChromeEventAt: Date?
    private let mediaController = SystemMediaController()
    private let nightPreferences = NightProtectionPreferences()
    private var effectiveNightSchedule = NightSchedule(startMinutes: 0, endMinutes: 8 * 60)
    private var hasStarted = false
    private var isShuttingDown = false
    private var protectionEventTask: Task<Void, Never>?
    private var routeChangeTask: Task<Void, Never>?
    private var routeChangePending = false

    init() {
        self.applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LidMute", directoryHint: .isDirectory)
        store = JSONLineEventStore(url: applicationSupport.appending(path: "events.jsonl"))
        inboxURL = applicationSupport.appending(path: "chrome-inbox.jsonl")
        chromeDeduplicator = ChromeEventDeduplicator(url: applicationSupport.appending(path: "chrome-seen-event-ids.json"))
        let audioController = SystemAudioController()
        let recoveryStore = FileSpeakerRecoveryStore(
            url: applicationSupport.appending(path: "speaker-recovery.json")
        )
        let recoveryRuntime = SpeakerRecoveryRuntime(
            audio: audioController,
            recoveryStore: recoveryStore,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        )
        self.audioController = audioController
        self.recoveryRuntime = recoveryRuntime
        coordinator = ProtectionCoordinator(
            protection: recoveryRuntime,
            processEvidence: audioController,
            store: store
        )
        let nightConfiguration = nightPreferences.load()
        nightScheduleEnabled = nightConfiguration.enabled
        nightStartText = nightConfiguration.startText
        nightEndText = nightConfiguration.endText
        effectiveNightSchedule = NightSchedule(
            startMinutes: NightProtectionPreferences.minutes(from: nightConfiguration.startText) ?? 0,
            endMinutes: NightProtectionPreferences.minutes(from: nightConfiguration.endText) ?? 8 * 60
        )
        coordinator.onEvent = { [weak self] _ in self?.refresh() }
        resolveChromeExtensionPath()
        refresh()
        checkChromeConnection()
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await lifecycleCoordinator.start()
        lifecycleState = lifecycleCoordinator.state
        refresh()
    }

    func startAll() throws {
        guard !isShuttingDown else { return }
        try routeMonitor.start()
        lifecycleState = .ready
        if lidMonitor == nil {
            let monitor = SystemLidMonitor { [weak self] closed in self?.receiveSystemLidState(closed) }
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
                Task { @MainActor [weak self] in
                    self?.pollAudioProcesses()
                }
            }
        }
        if inboxTimer == nil {
            inboxTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.drainChromeInbox() }
            }
        }
        if nightTimer == nil {
            nightTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshNightProtection() }
            }
        }
        pollAudioProcesses()
        Task { @MainActor [weak self] in await self?.refreshNightProtection() }
    }

    func startRouteOnly() throws {
        guard !isShuttingDown else { return }
        try routeMonitor.start()
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
        routeChangePending = false
    }

    func shutdownAndRestore() async -> ShutdownOutcome {
        guard !isShuttingDown else {
            return mapShutdownOutcome(await recoveryRuntime.recoverPending())
        }
        isShuttingDown = true
        lifecycleCoordinator.stop()
        let pendingProtectionEvents = protectionEventTask
        stopAll()
        await pendingProtectionEvents?.value
        let outcome = await coordinator.endProtectionForShutdown()
        isEnabled = false
        refresh()
        return mapShutdownOutcome(outcome)
    }

    func resumeAfterCancelledTermination() async {
        isShuttingDown = false
        routeChangeTask = nil
        lifecycleCoordinator.resume()
        switch lifecycleState {
        case .ready:
            do {
                try startAll()
            } catch {
                lifecycleState = .recoveryBlocked(.failedSafetyUnknown)
            }
        case .recoveryBlocked(.waitingForMatchingDevice):
            do {
                try startRouteOnly()
            } catch {
                lifecycleState = .recoveryBlocked(.failedSafetyUnknown)
            }
        case .recovering, .recoveryBlocked:
            break
        }
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
                await model.coordinator.receivePhysicalLid(closed: latestSystemLidClosed)
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
            await model.coordinator.receivePhysicalLid(closed: closed)
            model.refresh()
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
        nightScheduleEnabled = enabled
        nightPreferences.saveEnabled(enabled)
        enqueueProtectionEvent { model in await model.refreshNightProtection() }
    }

    func nightScheduleTextChanged() {
        if nightPreferences.saveSchedule(startText: nightStartText, endText: nightEndText),
           let startMinutes = NightProtectionPreferences.minutes(from: nightStartText),
           let endMinutes = NightProtectionPreferences.minutes(from: nightEndText) {
            effectiveNightSchedule = NightSchedule(startMinutes: startMinutes, endMinutes: endMinutes)
        }
        enqueueProtectionEvent { model in await model.refreshNightProtection() }
    }

    func sendMediaCommand(_ command: MediaCommand) {
        do {
            try mediaController.send(command)
            mediaStatus = "已发送系统媒体命令：\(mediaCommandName(command))"
        } catch {
            mediaStatus = "媒体命令失败：\(error.localizedDescription)"
        }
    }

    func clearLog() {
        try? store.clear()
        refresh()
    }

    private func drainChromeInbox() {
        guard lifecycleState == .ready, !isShuttingDown else { return }
        guard let data = try? Data(contentsOf: inboxURL), data.count > inboxOffset else {
            checkChromeConnection()
            return
        }
        let unread = data[inboxOffset...]
        inboxOffset = data.count
        var received = false
        for line in String(decoding: unread, as: UTF8.self).split(separator: "\n") {
            guard let decoded = try? ChromeBridgeFrame.decode(Data(line.utf8)),
                  (try? chromeDeduplicator.accept(decoded.eventID)) == true else { continue }
            chromeBridgeStatus = "已接收 Chrome 标签页事件"
            latestChromeEvidence = decoded.evidence
            enqueueProtectionEvent { model in
                guard !model.isShuttingDown else { return }
                await model.coordinator.receiveChromeEvidence(decoded.evidence)
                model.refresh()
            }
            received = true
        }
        if received {
            lastChromeEventAt = Date()
        }
        rebuildCurrentAudioSources()
        checkChromeConnection()
        refresh()
    }

    private func pollAudioProcesses() {
        guard lifecycleState == .ready, !isShuttingDown else { return }
        do {
            updateAudioProcesses(try audioController.activeOutputProcesses())
        } catch {
            statusText = "无法读取音频进程：\(error.localizedDescription)"
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

    private func refreshNightProtection() async {
        guard lifecycleState == .ready, !isShuttingDown else { return }
        let validTime = NightProtectionPreferences.minutes(from: nightStartText) != nil &&
            NightProtectionPreferences.minutes(from: nightEndText) != nil
        nightScheduleStatus = validTime
            ? (nightScheduleEnabled ? "夜间时段：\(nightStartText)-\(nightEndText)（北京时间）" : "夜间静音未开启")
            : "时间格式应为 HH:mm"

        let shouldProtect = isEnabled && nightScheduleEnabled && isDisplaySleeping && effectiveNightSchedule.isActive(at: Date())
        guard shouldProtect != isNightProtectionActive else { return }
        isNightProtectionActive = shouldProtect
        await coordinator.receiveNightProtection(shouldProtect)
        refresh()
    }

    private func mediaCommandName(_ command: MediaCommand) -> String {
        switch command {
        case .previous: return "上一首"
        case .next: return "下一首"
        case .playPause: return "暂停/开始"
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

    private var chromeManifestURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.lidmute.nativehost.json")
    }

    private var chromePidURL: URL {
        applicationSupport.appending(path: "chrome-host.pid")
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
        let fm = FileManager.default
        let manifestExists = fm.fileExists(atPath: chromeManifestURL.path)

        if !manifestExists {
            chromeConnectionState = .notRegistered
            chromeBridgeStatus = "未注册 Chrome 通信主机"
            return
        }

        let isHostAlive: Bool = {
            guard let pidData = try? Data(contentsOf: chromePidURL),
                  let pidStr = String(data: pidData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let pid = Int32(pidStr) else { return false }
            return kill(pid, 0) == 0
        }()

        if isHostAlive {
            let recentlyReceived = lastChromeEventAt.map { Date().timeIntervalSince($0) < 30 } ?? false
            if recentlyReceived {
                chromeConnectionState = .receivedEvent
                chromeBridgeStatus = "最近收到 Chrome 事件"
            } else {
                chromeConnectionState = .connected
                chromeBridgeStatus = "Chrome 已连接"
            }
        } else {
            chromeConnectionState = .waitingForExtension
            chromeBridgeStatus = "等待 Chrome 扩展连接"
        }

        // Pre-fill extension ID if registered
        if chromeExtensionId.isEmpty, let registeredId = registeredExtensionId {
            chromeExtensionId = registeredId
        }
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

            // Write origin file
            try origin.write(to: chromeOriginURL, atomically: true, encoding: .utf8)

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
        events = (try? store.load())?.reversed() ?? []
        switch lifecycleState {
        case .recovering:
            statusText = "正在恢复内建扬声器安全状态"
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

    private func receiveAudioRouteChanged() {
        guard !isShuttingDown else { return }
        if routeChangeTask != nil {
            routeChangePending = true
            return
        }
        routeChangeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                routeChangeTask = nil
                routeChangePending = false
            }
            repeat {
                routeChangePending = false
                await lifecycleCoordinator.receiveAudioRouteChanged()
                lifecycleState = lifecycleCoordinator.state
                if lifecycleState == .ready, !isShuttingDown {
                    await coordinator.receiveAudioRouteChanged()
                }
                refresh()
            } while routeChangePending && !isShuttingDown
        }
    }

    private func enqueueProtectionEvent(
        _ operation: @escaping @MainActor (AppViewModel) async -> Void
    ) {
        let predecessor = protectionEventTask
        let task = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }
            await operation(self)
        }
        protectionEventTask = task
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

    private func mapShutdownOutcome(_ outcome: SpeakerRecoveryOutcome) -> ShutdownOutcome {
        switch outcome {
        case .noPendingRecovery, .restored:
            return .restored
        case .failedButVerifiedSilent:
            return .verifiedSilent
        case .waitingForMatchingDevice, .corruptSnapshot,
             .unsupportedSnapshot, .failedSafetyUnknown:
            return .safetyUnknown
        }
    }
}

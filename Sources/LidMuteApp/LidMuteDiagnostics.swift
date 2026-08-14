import OSLog

enum LidMuteDiagnosticEvent: Equatable, Sendable {
    case chromeHeartbeatStale
    case coreAudioQueryFailed
    case lidMonitorUnavailable
    case lidMonitorReadFailed
    case chromeManifestPathMismatch
    case chromeManifestRepaired
    case chromeBridgeDegraded
    case storagePartiallyCorrupt
    case storagePermissionFailed
    case storageCapacityFailed
    case recoveryWaitingForMatchingDevice
    case recoveryFailedButVerifiedSilent
    case recoveryFailedSafetyUnknown
}

protocol LidMuteDiagnosticSinking: Sendable {
    func emit(_ event: LidMuteDiagnosticEvent)
}

struct LoggerDiagnosticSink: LidMuteDiagnosticSinking {
    private let logger = Logger(subsystem: "local.lidmute.app", category: "health")

    func emit(_ event: LidMuteDiagnosticEvent) {
        switch event {
        case .chromeHeartbeatStale:
            logger.notice("Chrome heartbeat stale")
        case .coreAudioQueryFailed:
            logger.error("CoreAudio query failed")
        case .lidMonitorUnavailable:
            logger.error("Lid monitor unavailable")
        case .lidMonitorReadFailed:
            logger.error("Lid monitor read failed")
        case .chromeManifestPathMismatch:
            logger.notice("Chrome manifest path mismatch")
        case .chromeManifestRepaired:
            logger.notice("Chrome manifest repaired")
        case .chromeBridgeDegraded:
            logger.error("Chrome bridge degraded")
        case .storagePartiallyCorrupt:
            logger.error("Observation storage partially corrupt")
        case .storagePermissionFailed:
            logger.error("Observation storage permission failed")
        case .storageCapacityFailed:
            logger.error("Observation storage capacity failed")
        case .recoveryWaitingForMatchingDevice:
            logger.notice("Speaker recovery waiting for matching device")
        case .recoveryFailedButVerifiedSilent:
            logger.error("Speaker recovery failed with silence verified")
        case .recoveryFailedSafetyUnknown:
            logger.fault("Speaker recovery safety unknown")
        }
    }
}

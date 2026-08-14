import Foundation

public enum CoreAudioHealth: Equatable, Sendable {
    case healthyNoActiveOutput
    case healthy(activeOutputCount: Int)
    case queryFailed
}

public enum LidMonitorHealth: Equatable, Sendable {
    case healthy
    case unavailable
    case readFailed
}

public enum ChromeBridgeHealth: Equatable, Sendable {
    case notRegistered
    case waitingForConnection
    case connected(sessionToken: UUID, pid: Int32)
    case recentlyAccepted(sessionToken: UUID, pid: Int32)
    case manifestPathMismatch(expected: String, registered: String)
    case degraded
}

public enum LocalStorageHealth: Equatable, Sendable {
    case healthy
    case partiallyCorrupt
    case permissionFailed
    case capacityFailed
    case ioFailed
}

public enum SpeakerRecoveryHealth: Equatable, Sendable {
    case healthy
    case waitingForMatchingDevice
    case corruptSnapshot
    case unsupportedSnapshot
    case failedButVerifiedSilent
    case failedSafetyUnknown
}

public struct AppHealthSnapshot: Equatable, Sendable {
    public let coreAudio: CoreAudioHealth
    public let lidMonitor: LidMonitorHealth
    public let chrome: ChromeBridgeHealth
    public let storage: LocalStorageHealth
    public let recovery: SpeakerRecoveryHealth

    public init(
        coreAudio: CoreAudioHealth,
        lidMonitor: LidMonitorHealth,
        chrome: ChromeBridgeHealth,
        storage: LocalStorageHealth,
        recovery: SpeakerRecoveryHealth
    ) {
        self.coreAudio = coreAudio
        self.lidMonitor = lidMonitor
        self.chrome = chrome
        self.storage = storage
        self.recovery = recovery
    }
}

public enum HealthPriority: Int, Comparable, Sendable {
    case normal = 0
    case notice = 1
    case warning = 2
    case critical = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public extension AppHealthSnapshot {
    var highestPriority: HealthPriority {
        if recovery == .failedSafetyUnknown { return .critical }
        let chromeIsDegraded: Bool
        switch chrome {
        case .degraded:
            chromeIsDegraded = true
        default:
            chromeIsDegraded = false
        }
        if recovery == .failedButVerifiedSilent || recovery == .corruptSnapshot ||
            recovery == .unsupportedSnapshot || storage != .healthy ||
            coreAudio == .queryFailed || lidMonitor != .healthy || chromeIsDegraded {
            return .warning
        }
        let chromeNeedsConnection: Bool
        switch chrome {
        case .waitingForConnection, .notRegistered:
            chromeNeedsConnection = true
        default:
            chromeNeedsConnection = false
        }
        if recovery == .waitingForMatchingDevice || chromeNeedsConnection {
            return .notice
        }
        return .normal
    }

    var blocksNormalTermination: Bool { recovery == .failedSafetyUnknown }
}

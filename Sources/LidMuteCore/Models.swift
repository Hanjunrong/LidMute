import Foundation

public enum ProtectionState: String, Codable, Sendable {
    case inactive
    case armed
    case protecting
    case unavailable
}

public enum ProtectionSource: String, Codable, Hashable, Sendable {
    case lid
    case night
}

public enum MediaCommand: Int, Codable, CaseIterable, Sendable {
    case previous = 20
    case next = 19
    case playPause = 16
}

public enum LidMuteEventKind: String, Codable, Sendable {
    case protectionEnabled
    case protectionDisabled
    case lidClosed
    case lidOpened
    case muteEnforced
    case restored
    case audioProcessDetected
    case chromeTabAudible
    case error
    case simulation
    case nightProtectionStarted
    case nightProtectionEnded
    case mediaCommandSent
}

public enum CorrelationStatus: String, Codable, Sendable {
    case systemMatched
    case browserObservedOnly
    case notApplicable
}

public struct AudioDevice: Codable, Equatable, Sendable {
    public let id: UInt32
    public let uid: String
    public let name: String
    public let isBuiltIn: Bool

    public init(id: UInt32, uid: String, name: String, isBuiltIn: Bool) {
        self.id = id
        self.uid = uid
        self.name = name
        self.isBuiltIn = isBuiltIn
    }
}

public struct AudioDeviceState: Codable, Equatable, Sendable {
    public let muted: Bool
    public let volume: Float
    public let usedVolumeFallback: Bool

    public init(muted: Bool, volume: Float, usedVolumeFallback: Bool) {
        self.muted = muted
        self.volume = volume
        self.usedVolumeFallback = usedVolumeFallback
    }
}

public struct AudioProcess: Codable, Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let bundleID: String?
    public let executablePath: String?
    public let launchDate: Date?
    public let isOutputActive: Bool

    public init(pid: Int32, name: String, bundleID: String?, executablePath: String?, launchDate: Date?, isOutputActive: Bool) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.executablePath = executablePath
        self.launchDate = launchDate
        self.isOutputActive = isOutputActive
    }
}

public struct ChromeTabEvidence: Codable, Equatable, Sendable {
    public let sessionID: String
    public let windowID: Int
    public let tabID: Int
    public let index: Int
    public let title: String
    public let url: String
    public let audible: Bool
    public let muted: Bool
    public let isActive: Bool
    public let isPinned: Bool
    public let isIncognito: Bool

    public init(
        sessionID: String,
        windowID: Int,
        tabID: Int,
        index: Int,
        title: String,
        url: String,
        audible: Bool,
        muted: Bool,
        isActive: Bool,
        isPinned: Bool,
        isIncognito: Bool
    ) {
        self.sessionID = sessionID
        self.windowID = windowID
        self.tabID = tabID
        self.index = index
        self.title = title
        self.url = url
        self.audible = audible
        self.muted = muted
        self.isActive = isActive
        self.isPinned = isPinned
        self.isIncognito = isIncognito
    }
}

public struct LidMuteEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let sequence: UInt64
    public let kind: LidMuteEventKind
    public let detail: String
    public let process: AudioProcess?
    public let chromeTab: ChromeTabEvidence?
    public let correlation: CorrelationStatus

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sequence: UInt64 = 0,
        kind: LidMuteEventKind,
        detail: String,
        process: AudioProcess? = nil,
        chromeTab: ChromeTabEvidence? = nil,
        correlation: CorrelationStatus = .notApplicable
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sequence = sequence
        self.kind = kind
        self.detail = detail
        self.process = process
        self.chromeTab = chromeTab
        self.correlation = correlation
    }
}

public protocol EventStoring: AnyObject, Sendable {
    func append(_ event: LidMuteEvent) throws
    func load() throws -> [LidMuteEvent]
    func clear() throws
}

public protocol AudioControlling: AnyObject, Sendable {
    func builtInSpeaker() throws -> AudioDevice?
    func captureState(of device: AudioDevice) throws -> AudioDeviceState
    func enforceSilence(on device: AudioDevice) throws
    func restore(_ state: AudioDeviceState, on device: AudioDevice) throws
    func activeOutputProcesses() throws -> [AudioProcess]
}

import Darwin
import Dispatch
import Foundation

public struct ChromeHostHeartbeat: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let sessionToken: UUID
    public let pid: Int32
    public let uptime: TimeInterval

    public init(version: Int, sessionToken: UUID, pid: Int32, uptime: TimeInterval) {
        self.version = version
        self.sessionToken = sessionToken
        self.pid = pid
        self.uptime = uptime
    }
}

public enum HeartbeatFreshness: Equatable, Sendable {
    case fresh(sessionToken: UUID, pid: Int32)
    case stale
    case malformed
}

public protocol ChromeHostHeartbeatPersisting: Sendable {
    func write(_ heartbeat: ChromeHostHeartbeat) throws
    func readFreshness(nowUptime: TimeInterval, ttl: TimeInterval) -> HeartbeatFreshness
    func remove() throws
}

public struct ChromeHostAcceptance: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let sessionToken: UUID
    public let pid: Int32
    public let uptime: TimeInterval

    public init(version: Int, sessionToken: UUID, pid: Int32, uptime: TimeInterval) {
        self.version = version
        self.sessionToken = sessionToken
        self.pid = pid
        self.uptime = uptime
    }
}

public protocol ChromeHostAcceptancePersisting: Sendable {
    func write(_ acceptance: ChromeHostAcceptance) throws
    func readFreshness(nowUptime: TimeInterval, ttl: TimeInterval) -> HeartbeatFreshness
    func remove() throws
}

public final class FileChromeHostAcceptanceStore: ChromeHostAcceptancePersisting, @unchecked Sendable {
    private let url: URL
    private let heartbeatURL: URL
    private let fileManager: FileManager

    public init(url: URL, heartbeatURL: URL, fileManager: FileManager = .default) {
        self.url = url
        self.heartbeatURL = heartbeatURL
        self.fileManager = fileManager
    }

    public func write(_ acceptance: ChromeHostAcceptance) throws {
        try prepareDirectory()
        try withHeartbeatLock(exclusive: true) {
            guard let heartbeat = readHeartbeatLocked(),
                  heartbeat.version == ChromeHostHeartbeat.schemaVersion,
                  heartbeat.sessionToken == acceptance.sessionToken,
                  heartbeat.pid == acceptance.pid else { return }
            try writeLocked(acceptance)
        }
    }

    public func readFreshness(
        nowUptime: TimeInterval,
        ttl: TimeInterval
    ) -> HeartbeatFreshness {
        guard let acceptance = try? withHeartbeatLock(exclusive: false, readAcceptanceLocked),
              acceptance.version == ChromeHostAcceptance.schemaVersion else { return .malformed }
        guard acceptance.uptime >= 0,
              acceptance.uptime <= nowUptime,
              nowUptime - acceptance.uptime <= ttl else { return .stale }
        return .fresh(sessionToken: acceptance.sessionToken, pid: acceptance.pid)
    }

    public func remove() throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try withHeartbeatLock(exclusive: true) {
            do {
                try fileManager.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                return
            }
        }
    }

    private func prepareDirectory() throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func writeLocked(_ acceptance: ChromeHostAcceptance) throws {
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try JSONEncoder().encode(acceptance).write(to: temporaryURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func readHeartbeatLocked() -> ChromeHostHeartbeat? {
        guard let data = try? Data(contentsOf: heartbeatURL) else { return nil }
        return try? JSONDecoder().decode(ChromeHostHeartbeat.self, from: data)
    }

    private func readAcceptanceLocked() -> ChromeHostAcceptance? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ChromeHostAcceptance.self, from: data)
    }

    private func withHeartbeatLock<T>(exclusive: Bool, _ body: () throws -> T) throws -> T {
        let lockURL = heartbeatURL.deletingLastPathComponent()
            .appending(path: ".\(heartbeatURL.lastPathComponent).lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }
}

public final class FileChromeHostHeartbeatStore: ChromeHostHeartbeatPersisting, @unchecked Sendable {
    private let url: URL
    private let fileManager: FileManager
    private let beforeConditionalRemove: (@Sendable () -> Void)?

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
        beforeConditionalRemove = nil
    }

    init(
        url: URL,
        fileManager: FileManager = .default,
        beforeConditionalRemove: @escaping @Sendable () -> Void
    ) {
        self.url = url
        self.fileManager = fileManager
        self.beforeConditionalRemove = beforeConditionalRemove
    }

    public func write(_ heartbeat: ChromeHostHeartbeat) throws {
        try prepareDirectory()
        try withFileLock(exclusive: true) {
            try writeLocked(heartbeat)
        }
    }

    public func readFreshness(
        nowUptime: TimeInterval,
        ttl: TimeInterval = 6
    ) -> HeartbeatFreshness {
        guard let heartbeat = try? withFileLock(exclusive: false, readHeartbeatLocked),
              heartbeat.version == ChromeHostHeartbeat.schemaVersion else { return .malformed }
        guard heartbeat.uptime >= 0,
              heartbeat.uptime <= nowUptime,
              nowUptime - heartbeat.uptime <= ttl else { return .stale }
        return .fresh(sessionToken: heartbeat.sessionToken, pid: heartbeat.pid)
    }

    public func remove() throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try withFileLock(exclusive: true) {
            try removeLocked()
        }
    }

    @discardableResult
    func remove(ifSessionToken expectedToken: UUID) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        return try withFileLock(exclusive: true) {
            guard readHeartbeatLocked()?.sessionToken == expectedToken else { return false }
            beforeConditionalRemove?()
            try removeLocked()
            return true
        }
    }

    func refresh(_ heartbeat: ChromeHostHeartbeat) throws {
        try prepareDirectory()
        try withFileLock(exclusive: true) {
            if let current = readHeartbeatLocked(), current.sessionToken != heartbeat.sessionToken {
                return
            }
            try writeLocked(heartbeat)
        }
    }

    private func prepareDirectory() throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func writeLocked(_ heartbeat: ChromeHostHeartbeat) throws {
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try JSONEncoder().encode(heartbeat).write(to: temporaryURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func readHeartbeatLocked() -> ChromeHostHeartbeat? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ChromeHostHeartbeat.self, from: data)
    }

    private func removeLocked() throws {
        do {
            try fileManager.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    private func withFileLock<T>(exclusive: Bool, _ body: () throws -> T) throws -> T {
        let lockURL = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }
}

public final class ChromeHostHeartbeatWriter: @unchecked Sendable {
    private let store: FileChromeHostHeartbeatStore
    private let sessionToken: UUID
    private let pid: Int32
    private let heartbeatInterval: TimeInterval
    private let uptime: @Sendable () -> TimeInterval
    private let queue = DispatchQueue(label: "local.lidmute.chrome-heartbeat")
    private var timer: DispatchSourceTimer?
    private var isStopped = false

    public init(
        store: FileChromeHostHeartbeatStore,
        sessionToken: UUID,
        pid: Int32,
        heartbeatInterval: TimeInterval,
        uptime: @escaping @Sendable () -> TimeInterval
    ) {
        self.store = store
        self.sessionToken = sessionToken
        self.pid = pid
        self.heartbeatInterval = heartbeatInterval
        self.uptime = uptime
    }

    public func start() throws {
        try queue.sync {
            guard timer == nil, !isStopped else { return }
            try persistHeartbeat()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
            timer.setEventHandler { [weak self] in
                try? self?.refreshHeartbeat()
            }
            self.timer = timer
            timer.resume()
        }
    }

    public func stopAndRemove() {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            _ = try? store.remove(ifSessionToken: sessionToken)
        }
    }

    private func persistHeartbeat() throws {
        try store.write(ChromeHostHeartbeat(
            version: ChromeHostHeartbeat.schemaVersion,
            sessionToken: sessionToken,
            pid: pid,
            uptime: uptime()
        ))
    }

    private func refreshHeartbeat() throws {
        try store.refresh(ChromeHostHeartbeat(
            version: ChromeHostHeartbeat.schemaVersion,
            sessionToken: sessionToken,
            pid: pid,
            uptime: uptime()
        ))
    }
}

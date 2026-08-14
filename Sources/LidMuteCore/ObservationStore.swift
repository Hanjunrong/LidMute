import Darwin
import Foundation

public struct ObservationPaths: Sendable {
    public let root: URL
    public let lock: URL
    public let generation: URL
    public let inbox: URL
    public let dedup: URL
    public let cursor: URL
    public let events: URL

    public init(root: URL) {
        self.root = root
        lock = root.appending(path: "observation.lock")
        generation = root.appending(path: "observation-generation")
        inbox = root.appending(path: "chrome-inbox.jsonl")
        dedup = root.appending(path: "chrome-dedup.json")
        cursor = root.appending(path: "chrome-cursor.json")
        events = root.appending(path: "events.jsonl")
    }
}

public protocol ObservationLocking: Sendable {
    func withExclusiveLock<T>(_ body: () throws -> T) throws -> T
}

public protocol ObservationFileSystem: Sendable {
    func read(_ url: URL) throws -> Data
    func readLastCompleteLines(
        _ url: URL,
        maximumCount: Int,
        maximumLineBytes: Int
    ) throws -> [Data]
    func coordinatedAppend(_ data: Data, to url: URL) throws
    func atomicWrite(_ data: Data, to url: URL, permissions: Int16) throws
    func syncFile(_ url: URL) throws
    func syncDirectory(_ url: URL) throws
    func ensurePrivateDirectory(_ url: URL) throws
    func truncate(_ url: URL) throws
    func removeIfPresent(_ url: URL) throws
}

public struct ChromeInboxRecord: Codable, Equatable, Sendable {
    public let generation: UInt64
    public let eventID: UUID
    public let acceptedAt: Date
    public let evidence: ChromeTabEvidence

    public init(generation: UInt64, eventID: UUID, acceptedAt: Date, evidence: ChromeTabEvidence) {
        self.generation = generation
        self.eventID = eventID
        self.acceptedAt = acceptedAt
        self.evidence = evidence
    }
}

public enum ChromeAcceptDisposition: Equatable, Sendable {
    case accepted(UUID)
    case duplicate(UUID)
    case ignoredIncognito(UUID)
}

public enum ObservationStoreError: Error, Equatable, Sendable {
    case retryablePersistenceFailure
    case corruptMetadata(String)
}

public final class InProcessObservationLock: ObservationLocking, @unchecked Sendable {
    private let lock = NSRecursiveLock()

    public init() {}

    public func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public final class POSIXObservationLock: ObservationLocking, @unchecked Sendable {
    private let lockURL: URL
    private let recursiveLock = NSRecursiveLock()
    private let depthKey: String
    private var descriptor: Int32 = -1

    public init(lockURL: URL) {
        self.lockURL = lockURL
        depthKey = "LidMute.POSIXObservationLock.\(UUID().uuidString)"
    }

    public func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        recursiveLock.lock()
        let threadDictionary = Thread.current.threadDictionary
        let depth = threadDictionary[depthKey] as? Int ?? 0

        do {
            if depth == 0 {
                try prepareAndAcquireFileLock()
            }
            threadDictionary[depthKey] = depth + 1
        } catch {
            recursiveLock.unlock()
            throw error
        }

        let result = Result { try body() }
        let remainingDepth = (threadDictionary[depthKey] as? Int ?? 1) - 1
        if remainingDepth == 0 {
            threadDictionary.removeObject(forKey: depthKey)
            let releaseError = releaseFileLock()
            recursiveLock.unlock()
            if let releaseError { throw releaseError }
        } else {
            threadDictionary[depthKey] = remainingDepth
            recursiveLock.unlock()
        }
        return try result.get()
    }

    private func prepareAndAcquireFileLock() throws {
        let root = lockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard chmod(root.path, mode_t(0o700)) == 0 else { throw POSIXObservationError.current }

        descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXObservationError.current }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            let error = POSIXObservationError.current
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            let error = POSIXObservationError.current
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
    }

    private func releaseFileLock() -> Error? {
        guard descriptor >= 0 else { return nil }
        var releaseError: Error?
        if flock(descriptor, LOCK_UN) != 0 {
            releaseError = POSIXObservationError.current
        }
        if Darwin.close(descriptor) != 0, releaseError == nil {
            releaseError = POSIXObservationError.current
        }
        descriptor = -1
        return releaseError
    }
}

public struct POSIXObservationFileSystem: ObservationFileSystem, Sendable {
    public init() {}

    public func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Data()
        }
    }

    public func readLastCompleteLines(
        _ url: URL,
        maximumCount: Int,
        maximumLineBytes: Int
    ) throws -> [Data] {
        guard maximumCount > 0 else { return [] }

        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return [] }
            throw POSIXObservationError.current
        }
        defer { Darwin.close(descriptor) }

        let endOffset = lseek(descriptor, 0, SEEK_END)
        guard endOffset >= 0 else { throw POSIXObservationError.current }
        guard endOffset > 0 else { return [] }

        let chunkSize = 64 * 1_024
        var position = endOffset
        var completeLineCount = 0
        var currentLineBytes = 0
        var isFirstByteFromEnd = true
        var reverseChunks: [Data] = []

        while position > 0, completeLineCount < maximumCount {
            let byteCount = min(chunkSize, Int(position))
            position -= off_t(byteCount)
            var bytes = [UInt8](repeating: 0, count: byteCount)
            var bytesRead = 0

            try bytes.withUnsafeMutableBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                while bytesRead < byteCount {
                    let result = pread(
                        descriptor,
                        baseAddress.advanced(by: bytesRead),
                        byteCount - bytesRead,
                        position + off_t(bytesRead)
                    )
                    if result < 0, errno == EINTR { continue }
                    guard result > 0 else { throw POSIXObservationError.current }
                    bytesRead += result
                }
            }

            reverseChunks.append(Data(bytes))
            for byte in bytes.reversed() {
                if isFirstByteFromEnd {
                    guard byte == 0x0A else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    isFirstByteFromEnd = false
                } else if byte == 0x0A {
                    completeLineCount += 1
                    currentLineBytes = 0
                    if completeLineCount == maximumCount { break }
                } else {
                    currentLineBytes += 1
                    guard currentLineBytes <= maximumLineBytes else {
                        throw CocoaError(.fileReadTooLarge)
                    }
                }
            }
        }

        var tail = Data()
        tail.reserveCapacity(reverseChunks.reduce(0) { $0 + $1.count })
        for chunk in reverseChunks.reversed() {
            tail.append(chunk)
        }
        guard tail.last == 0x0A else {
            throw CocoaError(.fileReadCorruptFile)
        }

        if position > 0, let firstNewline = tail.firstIndex(of: 0x0A) {
            tail.removeSubrange(tail.startIndex...firstNewline)
        }

        var lines = tail.split(separator: 0x0A, omittingEmptySubsequences: false)
        guard lines.last?.isEmpty == true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        lines.removeLast()
        let retained = lines.suffix(maximumCount)
        guard retained.allSatisfy({ $0.count <= maximumLineBytes }) else {
            throw CocoaError(.fileReadTooLarge)
        }
        return retained.map { Data($0) }
    }

    public func coordinatedAppend(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXObservationError.current }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw POSIXObservationError.current }
        try writeAll(data, to: descriptor)
    }

    public func atomicWrite(_ data: Data, to url: URL, permissions: Int16) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let mode = mode_t(UInt16(bitPattern: permissions))
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw POSIXObservationError.current }

        do {
            try writeAll(data, to: descriptor)
            guard fchmod(descriptor, mode) == 0 else { throw POSIXObservationError.current }
            guard fsync(descriptor) == 0 else { throw POSIXObservationError.current }
            guard Darwin.close(descriptor) == 0 else { throw POSIXObservationError.current }
            guard rename(temporaryURL.path, url.path) == 0 else { throw POSIXObservationError.current }
        } catch {
            Darwin.close(descriptor)
            unlink(temporaryURL.path)
            throw error
        }
    }

    public func syncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXObservationError.current }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXObservationError.current }
    }

    public func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXObservationError.current }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXObservationError.current }
    }

    public func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard chmod(url.path, mode_t(0o700)) == 0 else { throw POSIXObservationError.current }
    }

    public func truncate(_ url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXObservationError.current }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            Darwin.close(descriptor)
            throw POSIXObservationError.current
        }
        guard Darwin.close(descriptor) == 0 else { throw POSIXObservationError.current }
    }

    public func removeIfPresent(_ url: URL) throws {
        guard unlink(url.path) == 0 else {
            if errno == ENOENT { return }
            throw POSIXObservationError.current
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXObservationError.current }
                written += count
            }
        }
    }
}

public final class ObservationStore: @unchecked Sendable {
    private static let maximumAcceptedEventIDs = 4_096
    private static let maximumInboxRecordBytes = 262_144

    private let paths: ObservationPaths
    private let fileSystem: any ObservationFileSystem
    private let lock: any ObservationLocking

    public init(
        paths: ObservationPaths,
        fileSystem: any ObservationFileSystem = POSIXObservationFileSystem(),
        lock: (any ObservationLocking)? = nil
    ) {
        self.paths = paths
        self.fileSystem = fileSystem
        self.lock = lock ?? POSIXObservationLock(lockURL: paths.lock)
    }

    public func accept(_ frame: ChromeValidatedFrame) throws -> ChromeAcceptDisposition {
        try mapPersistenceErrors {
            try lock.withExclusiveLock {
                let generation = try readGenerationWithoutLock()
                guard frame.privacy == .persist else {
                    return .ignoredIncognito(frame.eventID)
                }

                var acceptedIDs = try readAcceptedEventIDsWithoutLock()
                if acceptedIDs.contains(frame.eventID) {
                    try fileSystem.syncFile(paths.inbox)
                    try fileSystem.syncFile(paths.dedup)
                    try fileSystem.syncDirectory(paths.root)
                    return .duplicate(frame.eventID)
                }

                let inboxEventIDs = try readRecentInboxEventIDsWithoutLock(generation: generation)
                if inboxEventIDs != acceptedIDs {
                    try fileSystem.syncFile(paths.inbox)
                    acceptedIDs = inboxEventIDs
                    try persistAcceptedEventIDs(acceptedIDs)
                }
                if acceptedIDs.contains(frame.eventID) {
                    return .duplicate(frame.eventID)
                }

                try fileSystem.ensurePrivateDirectory(paths.root)
                let record = ChromeInboxRecord(
                    generation: generation,
                    eventID: frame.eventID,
                    acceptedAt: Date(),
                    evidence: frame.evidence
                )
                var recordData = try JSONEncoder().encode(record)
                recordData.append(0x0A)
                try fileSystem.coordinatedAppend(recordData, to: paths.inbox)
                try fileSystem.syncFile(paths.inbox)

                try persistAcceptedEventID(frame.eventID, acceptedIDs: &acceptedIDs)
                return .accepted(frame.eventID)
            }
        }
    }

    public func currentGeneration() throws -> UInt64 {
        try mapPersistenceErrors {
            try lock.withExclusiveLock { try readGenerationWithoutLock() }
        }
    }

    public func readInboxRecords() throws -> [ChromeInboxRecord] {
        try mapPersistenceErrors {
            try lock.withExclusiveLock {
                try readInboxRecordsWithoutLock()
            }
        }
    }

    public func acceptedEventIDs() throws -> [UUID] {
        try mapPersistenceErrors {
            try lock.withExclusiveLock { try readAcceptedEventIDsWithoutLock() }
        }
    }

    public func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        try mapPersistenceErrors { try lock.withExclusiveLock(body) }
    }

    private func readGenerationWithoutLock() throws -> UInt64 {
        let data = try fileSystem.read(paths.generation)
        guard !data.isEmpty else { return 0 }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let generation = UInt64(text) else {
            throw ObservationStoreError.corruptMetadata(paths.generation.lastPathComponent)
        }
        return generation
    }

    private func readAcceptedEventIDsWithoutLock() throws -> [UUID] {
        let data = try fileSystem.read(paths.dedup)
        guard !data.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([UUID].self, from: data)
        } catch {
            throw ObservationStoreError.corruptMetadata(paths.dedup.lastPathComponent)
        }
    }

    private func readInboxRecordsWithoutLock() throws -> [ChromeInboxRecord] {
        let data = try fileSystem.read(paths.inbox)
        guard !data.isEmpty else { return [] }
        guard data.last == 0x0A else {
            throw ObservationStoreError.corruptMetadata(paths.inbox.lastPathComponent)
        }

        return try data.split(separator: 0x0A).map { line in
            do {
                return try JSONDecoder().decode(ChromeInboxRecord.self, from: Data(line))
            } catch {
                throw ObservationStoreError.corruptMetadata(paths.inbox.lastPathComponent)
            }
        }
    }

    private func readRecentInboxEventIDsWithoutLock(generation: UInt64) throws -> [UUID] {
        let lines: [Data]
        do {
            lines = try fileSystem.readLastCompleteLines(
                paths.inbox,
                maximumCount: Self.maximumAcceptedEventIDs,
                maximumLineBytes: Self.maximumInboxRecordBytes
            )
        } catch let error as CocoaError where
            error.code == .fileReadCorruptFile || error.code == .fileReadTooLarge
        {
            throw ObservationStoreError.corruptMetadata(paths.inbox.lastPathComponent)
        }
        var eventIDs: [UUID] = []
        for line in lines {
            let record: ChromeInboxRecord
            do {
                record = try JSONDecoder().decode(ChromeInboxRecord.self, from: line)
            } catch {
                throw ObservationStoreError.corruptMetadata(paths.inbox.lastPathComponent)
            }
            guard record.generation <= generation else {
                throw ObservationStoreError.corruptMetadata(paths.inbox.lastPathComponent)
            }
            if record.generation == generation {
                eventIDs.append(record.eventID)
            }
        }
        return eventIDs
    }

    private func persistAcceptedEventID(_ eventID: UUID, acceptedIDs: inout [UUID]) throws {
        acceptedIDs.append(eventID)
        acceptedIDs = Array(acceptedIDs.suffix(Self.maximumAcceptedEventIDs))
        try persistAcceptedEventIDs(acceptedIDs)
    }

    private func persistAcceptedEventIDs(_ acceptedIDs: [UUID]) throws {
        try fileSystem.atomicWrite(
            try JSONEncoder().encode(acceptedIDs),
            to: paths.dedup,
            permissions: Int16(0o600)
        )
        try fileSystem.syncFile(paths.dedup)
        try fileSystem.syncDirectory(paths.root)
    }

    private func mapPersistenceErrors<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ObservationStoreError {
            throw error
        } catch {
            throw ObservationStoreError.retryablePersistenceFailure
        }
    }
}

extension ObservationStore: ChromeFrameAccepting {}

struct POSIXObservationError: Error, Sendable {
    let code: Int32

    static var current: POSIXObservationError { POSIXObservationError(code: errno) }
}

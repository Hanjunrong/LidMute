import Darwin
import Foundation

public final class FileSpeakerRecoveryStore: SpeakerRecoveryStoring, @unchecked Sendable {
    private let url: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private static let processLock = NSLock()

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func load() throws -> SpeakerRecoveryLoadResult {
        try withJournalLock { try loadLocked() }
    }

    public func saveBeforeMutation(_ snapshot: SpeakerRecoverySnapshot) throws {
        try withJournalLock {
            switch try loadLocked() {
            case .none:
                try writeLocked(snapshot)
            case let .snapshot(existing):
                guard existing.transactionID == snapshot.transactionID else {
                    throw SpeakerRecoveryStoreError.pendingTransaction(existing.transactionID)
                }
            case .corrupt, .unsupportedSchema:
                throw SpeakerRecoveryStoreError.unreadableJournal
            }
        }
    }

    public func markFinalizingRestore(transactionID: UUID) throws {
        try withJournalLock {
            let snapshot = try matchingSnapshotLocked(transactionID: transactionID)
            try writeLocked(snapshot.with(stage: .finalizingRestore))
        }
    }

    public func removeCompleted(transactionID: UUID) throws {
        try withJournalLock {
            _ = try matchingSnapshotLocked(transactionID: transactionID)
            guard Darwin.unlink(url.path) == 0 else {
                throw posixError()
            }
            try syncParentDirectory()
        }
    }

    private func withJournalLock<T>(_ body: () throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        try ensureParentDirectory()
        let lockURL = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).lock")
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        var acquiredLock = false
        defer {
            if acquiredLock { releaseExclusiveLock(descriptor) }
            Darwin.close(descriptor)
        }

        guard Darwin.fchmod(descriptor, 0o600) == 0 else { throw posixError() }
        try acquireExclusiveLock(descriptor)
        acquiredLock = true
        return try body()
    }

    private func acquireExclusiveLock(_ descriptor: Int32) throws {
        var lock = fileLock(type: Int16(F_WRLCK))
        while Darwin.fcntl(descriptor, F_SETLKW, &lock) != 0 {
            if errno == EINTR { continue }
            throw posixError()
        }
    }

    private func releaseExclusiveLock(_ descriptor: Int32) {
        var lock = fileLock(type: Int16(F_UNLCK))
        _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
    }

    private func fileLock(type: Int16) -> flock {
        flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: type,
            l_whence: Int16(SEEK_SET)
        )
    }

    private func matchingSnapshotLocked(transactionID: UUID) throws -> SpeakerRecoverySnapshot {
        switch try loadLocked() {
        case .none:
            throw SpeakerRecoveryStoreError.noPendingTransaction
        case let .snapshot(snapshot):
            guard snapshot.transactionID == transactionID else {
                throw SpeakerRecoveryStoreError.transactionMismatch(
                    expected: snapshot.transactionID,
                    received: transactionID
                )
            }
            return snapshot
        case .corrupt, .unsupportedSchema:
            throw SpeakerRecoveryStoreError.unreadableJournal
        }
    }

    private func loadLocked() throws -> SpeakerRecoveryLoadResult {
        guard fileManager.fileExists(atPath: url.path) else { return .none }

        let data = try Data(contentsOf: url)

        struct SchemaVersion: Decodable {
            let schemaVersion: Int
        }

        guard let version = try? decoder.decode(SchemaVersion.self, from: data).schemaVersion else {
            return .corrupt
        }
        guard version == SpeakerRecoverySnapshot.currentSchemaVersion else {
            return .unsupportedSchema(version)
        }
        guard let snapshot = try? decoder.decode(SpeakerRecoverySnapshot.self, from: data) else {
            return .corrupt
        }
        return .snapshot(snapshot)
    }

    private func writeLocked(_ snapshot: SpeakerRecoverySnapshot) throws {
        try ensureParentDirectory()
        try atomicallyWrite(try encoder.encode(snapshot))
    }

    private func ensureParentDirectory() throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard Darwin.chmod(directory.path, 0o700) == 0 else {
            throw posixError()
        }
    }

    private func atomicallyWrite(_ data: Data) throws {
        let temporaryURL = url.deletingLastPathComponent().appending(
            path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw posixError() }

        do {
            guard Darwin.fchmod(descriptor, 0o600) == 0 else { throw posixError() }
            try write(data, to: descriptor)
            guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
            guard Darwin.close(descriptor) == 0 else { throw posixError() }
        } catch {
            Darwin.close(descriptor)
            Darwin.unlink(temporaryURL.path)
            throw error
        }

        guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
            Darwin.unlink(temporaryURL.path)
            throw posixError()
        }
        guard Darwin.chmod(url.path, 0o600) == 0 else { throw posixError() }
        try syncParentDirectory()
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                offset += result
            }
        }
    }

    private func syncParentDirectory() throws {
        let directory = url.deletingLastPathComponent()
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

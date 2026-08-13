import Darwin
import Foundation

public final class FileSpeakerRecoveryStore: SpeakerRecoveryStoring, @unchecked Sendable {
    private let url: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func load() throws -> SpeakerRecoveryLoadResult {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    public func saveBeforeMutation(_ snapshot: SpeakerRecoverySnapshot) throws {
        lock.lock()
        defer { lock.unlock() }

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

    public func markFinalizingRestore(transactionID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        let snapshot = try matchingSnapshotLocked(transactionID: transactionID)
        try writeLocked(snapshot.with(stage: .finalizingRestore))
    }

    public func removeCompleted(transactionID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        _ = try matchingSnapshotLocked(transactionID: transactionID)
        guard Darwin.unlink(url.path) == 0 else {
            throw posixError()
        }
        try syncParentDirectory()
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

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw error
        }

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

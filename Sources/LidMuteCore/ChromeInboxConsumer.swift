import Darwin
import Foundation

public struct ChromeConsumeCursor: Codable, Equatable, Sendable {
    public let generation: UInt64
    public let inode: UInt64
    public let offset: UInt64
    public let remainder: Data

    public init(generation: UInt64, inode: UInt64, offset: UInt64, remainder: Data) {
        self.generation = generation
        self.inode = inode
        self.offset = offset
        self.remainder = remainder
    }
}

public struct ChromeConsumeBatch: Sendable {
    public let records: [ChromeInboxRecord]
    public let committedOffset: UInt64
    public let health: ObservationStorageHealth

    public init(
        records: [ChromeInboxRecord],
        committedOffset: UInt64,
        health: ObservationStorageHealth
    ) {
        self.records = records
        self.committedOffset = committedOffset
        self.health = health
    }
}

public enum ChromeConsumeError: Error, Equatable, Sendable {
    case corruptRecord(line: Int)
    case corruptCursor
    case permissionFailure
    case capacityFailure
    case cursorCommitFailure
    case ioFailure(String)
}

public protocol ChromeInboxConsuming: AnyObject, Sendable {
    func consumeAvailable() throws -> ChromeConsumeBatch
    func resetInMemoryState()
}

public final class ChromeInboxConsumer: ChromeInboxConsuming, @unchecked Sendable {
    public private(set) var health: ObservationStorageHealth = .healthy

    private static let maximumRecordBytes = 262_144

    private let paths: ObservationPaths
    private let observationStore: ObservationStore
    private let eventStore: BoundedJSONLineEventStore
    private let fileSystem: any ObservationFileSystem

    public init(
        paths: ObservationPaths,
        observationStore: ObservationStore,
        eventStore: BoundedJSONLineEventStore,
        fileSystem: any ObservationFileSystem = POSIXObservationFileSystem()
    ) {
        self.paths = paths
        self.observationStore = observationStore
        self.eventStore = eventStore
        self.fileSystem = fileSystem
    }

    public func consumeAvailable() throws -> ChromeConsumeBatch {
        do {
            let batch = try observationStore.withExclusiveLock {
                let generation = try observationStore.currentGeneration()
                let inbox = try readInboxSnapshot()
                let storedCursor = try readCursor()
                let normalization = try normalizedCursor(
                    storedCursor,
                    generation: generation,
                    inbox: inbox
                )
                let cursor = normalization.cursor
                let unreadStart = cursor.offset + UInt64(cursor.remainder.count)
                var combined = cursor.remainder
                combined.append(try fileSystem.read(paths.inbox, fromOffset: unreadStart))

                let split = try splitCompleteRecords(combined)
                var consumable: [(record: ChromeInboxRecord, event: LidMuteEvent)] = []
                for (index, line) in split.lines.enumerated() {
                    let record: ChromeInboxRecord
                    do {
                        record = try JSONDecoder().decode(ChromeInboxRecord.self, from: line)
                    } catch {
                        throw ChromeConsumeError.corruptRecord(line: index + 1)
                    }
                    guard record.generation <= generation else {
                        throw ChromeConsumeError.corruptRecord(line: index + 1)
                    }
                    guard record.generation == generation, !record.evidence.isIncognito else {
                        continue
                    }

                    let event = LidMuteEvent(
                        timestamp: record.acceptedAt,
                        kind: .chromeTabAudible,
                        detail: "\(record.evidence.title) · \(record.evidence.url)",
                        observationEventID: record.eventID,
                        chromeTab: record.evidence,
                        correlation: .browserObservedOnly
                    )
                    consumable.append((record, event))
                }

                let appendResult = try eventStore.appendBatchReporting(consumable.map(\.event))
                let insertedEventIDs = Set(appendResult.inserted.compactMap(\.observationEventID))
                let deliveredRecords = consumable.compactMap { item in
                    if !normalization.suppressPreviouslyCommittedDelivery {
                        return item.record
                    }
                    return insertedEventIDs.contains(item.record.eventID) ? item.record : nil
                }

                let committedOffset = cursor.offset + UInt64(split.completeByteCount)
                let committedCursor = ChromeConsumeCursor(
                    generation: generation,
                    inode: inbox.inode,
                    offset: committedOffset,
                    remainder: split.remainder
                )
                if storedCursor != committedCursor {
                    try persistCursor(committedCursor)
                }

                return ChromeConsumeBatch(
                    records: deliveredRecords,
                    committedOffset: committedOffset,
                    health: .healthy
                )
            }
            health = .healthy
            return batch
        } catch let error as ChromeConsumeError {
            health = error.health
            throw error
        } catch let error as EventStoreError {
            health = error.storageHealth
            throw error
        } catch {
            let mapped = ChromeConsumeError(storageError: error)
            health = mapped.health
            throw mapped
        }
    }

    public func resetInMemoryState() {
        // Cursor and partial-line state are durable; this type intentionally keeps no shadow copy.
    }

    private func readCursor() throws -> ChromeConsumeCursor? {
        let data = try fileSystem.read(paths.cursor)
        guard !data.isEmpty else { return nil }
        do {
            return try JSONDecoder().decode(ChromeConsumeCursor.self, from: data)
        } catch {
            throw ChromeConsumeError.corruptCursor
        }
    }

    private func normalizedCursor(
        _ cursor: ChromeConsumeCursor?,
        generation: UInt64,
        inbox: InboxSnapshot
    ) throws -> CursorNormalization {
        guard let cursor else {
            return CursorNormalization(
                cursor: ChromeConsumeCursor(
                    generation: generation,
                    inode: inbox.inode,
                    offset: 0,
                    remainder: Data()
                ),
                suppressPreviouslyCommittedDelivery: false
            )
        }
        guard cursor.generation == generation,
              cursor.inode == inbox.inode,
              cursor.remainder.count <= Self.maximumRecordBytes,
              let scannedOffset = cursor.offset.addingWithoutOverflow(UInt64(cursor.remainder.count)),
              scannedOffset <= inbox.size else {
            return CursorNormalization(
                cursor: ChromeConsumeCursor(
                    generation: generation,
                    inode: inbox.inode,
                    offset: 0,
                    remainder: Data()
                ),
                suppressPreviouslyCommittedDelivery: true
            )
        }
        return CursorNormalization(
            cursor: cursor,
            suppressPreviouslyCommittedDelivery: false
        )
    }

    private func splitCompleteRecords(_ data: Data) throws -> CompleteRecordSplit {
        guard let finalNewline = data.lastIndex(of: 0x0A) else {
            guard data.count <= Self.maximumRecordBytes else {
                throw ChromeConsumeError.corruptRecord(line: 1)
            }
            return CompleteRecordSplit(lines: [], completeByteCount: 0, remainder: data)
        }

        let completeEnd = data.index(after: finalNewline)
        let complete = data[..<completeEnd]
        let remainder = Data(data[completeEnd...])
        guard remainder.count <= Self.maximumRecordBytes else {
            throw ChromeConsumeError.corruptRecord(line: complete.split(separator: 0x0A).count + 1)
        }
        let lines = complete.split(separator: 0x0A, omittingEmptySubsequences: false)
        guard lines.last?.isEmpty == true else {
            throw ChromeConsumeError.corruptRecord(line: lines.count)
        }
        let records = lines.dropLast().enumerated().map { index, line -> Data in
            Data(line)
        }
        for (index, record) in records.enumerated() where record.count > Self.maximumRecordBytes {
            throw ChromeConsumeError.corruptRecord(line: index + 1)
        }
        return CompleteRecordSplit(
            lines: records,
            completeByteCount: complete.count,
            remainder: remainder
        )
    }

    private func persistCursor(_ cursor: ChromeConsumeCursor) throws {
        do {
            try fileSystem.ensurePrivateDirectory(paths.root)
            try fileSystem.atomicWrite(
                try JSONEncoder().encode(cursor),
                to: paths.cursor,
                permissions: Int16(0o600)
            )
            try fileSystem.syncFile(paths.cursor)
            try fileSystem.syncDirectory(paths.root)
        } catch let error as ChromeConsumeError {
            throw error
        } catch {
            let mapped = ChromeConsumeError(storageError: error)
            switch mapped {
            case .permissionFailure, .capacityFailure:
                throw mapped
            default:
                throw ChromeConsumeError.cursorCommitFailure
            }
        }
    }

    private func readInboxSnapshot() throws -> InboxSnapshot {
        let descriptor = open(paths.inbox.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return InboxSnapshot(inode: 0, size: 0)
            }
            throw POSIXObservationError.current
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw POSIXObservationError.current }
        return InboxSnapshot(
            inode: UInt64(metadata.st_ino),
            size: UInt64(metadata.st_size)
        )
    }
}

private struct CompleteRecordSplit {
    let lines: [Data]
    let completeByteCount: Int
    let remainder: Data
}

private struct CursorNormalization {
    let cursor: ChromeConsumeCursor
    let suppressPreviouslyCommittedDelivery: Bool
}

private struct InboxSnapshot {
    let inode: UInt64
    let size: UInt64
}

private extension UInt64 {
    func addingWithoutOverflow(_ other: UInt64) -> UInt64? {
        let (result, overflow) = addingReportingOverflow(other)
        return overflow ? nil : result
    }
}

private extension ChromeConsumeError {
    init(storageError error: Error) {
        if let error = error as? POSIXObservationError {
            switch error.code {
            case EACCES, EPERM:
                self = .permissionFailure
            case ENOSPC, EDQUOT:
                self = .capacityFailure
            default:
                self = .ioFailure("POSIX \(error.code)")
            }
            return
        }
        let cocoaError = error as? CocoaError
        switch cocoaError?.code {
        case .fileReadNoPermission, .fileWriteNoPermission:
            self = .permissionFailure
        case .fileWriteOutOfSpace:
            self = .capacityFailure
        default:
            self = .ioFailure(String(describing: error))
        }
    }

    var health: ObservationStorageHealth {
        switch self {
        case let .corruptRecord(line): .corruptRecord(line: line)
        case .corruptCursor: .ioFailure("corrupt cursor")
        case .permissionFailure: .permissionFailure
        case .capacityFailure: .capacityFailure
        case .cursorCommitFailure: .ioFailure("cursor commit failure")
        case let .ioFailure(message): .ioFailure(message)
        }
    }
}

private extension EventStoreError {
    var storageHealth: ObservationStorageHealth {
        switch self {
        case let .corruptRecord(line): .corruptRecord(line: line)
        case .permissionFailure: .permissionFailure
        case .capacityFailure: .capacityFailure
        case let .ioFailure(message): .ioFailure(message)
        }
    }
}

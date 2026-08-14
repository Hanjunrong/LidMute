import Foundation

public enum ObservationStorageHealth: Equatable, Sendable {
    case healthy
    case corruptRecord(line: Int)
    case permissionFailure
    case capacityFailure
    case ioFailure(String)
}

public enum EventStoreError: Error, Equatable {
    case corruptRecord(line: Int)
    case permissionFailure
    case capacityFailure
    case ioFailure(String)
}

public struct EventStoreAppendResult: Sendable {
    public let appended: LidMuteEvent
    public let evictedCount: Int
    public let wasInserted: Bool

    public init(appended: LidMuteEvent, evictedCount: Int, wasInserted: Bool = true) {
        self.appended = appended
        self.evictedCount = evictedCount
        self.wasInserted = wasInserted
    }
}

public final class BoundedJSONLineEventStore: EventStoring, @unchecked Sendable {
    public private(set) var health: ObservationStorageHealth = .healthy

    private let url: URL
    private let maximumCount: Int
    private let fileSystem: any ObservationFileSystem
    private let lock: any ObservationLocking

    public init(
        url: URL,
        maximumCount: Int = 5_000,
        fileSystem: any ObservationFileSystem = POSIXObservationFileSystem(),
        lock: any ObservationLocking = InProcessObservationLock()
    ) {
        precondition(maximumCount >= 0, "maximumCount must not be negative")
        self.url = url
        self.maximumCount = maximumCount
        self.fileSystem = fileSystem
        self.lock = lock
    }

    public func append(_ event: LidMuteEvent) throws {
        _ = try appendReporting(event)
    }

    @discardableResult
    public func appendReporting(_ event: LidMuteEvent) throws -> EventStoreAppendResult {
        try performStorageOperation {
            try lock.withExclusiveLock {
                var events = try decodeEvents(fileSystem.read(url))
                if let observationEventID = event.observationEventID,
                   events.contains(where: { $0.observationEventID == observationEventID }) {
                    return EventStoreAppendResult(
                        appended: event,
                        evictedCount: 0,
                        wasInserted: false
                    )
                }
                events.append(event)
                let evictedCount = max(0, events.count - maximumCount)
                let retained = maximumCount == 0 ? [] : Array(events.suffix(maximumCount))
                try persist(retained)
                return EventStoreAppendResult(
                    appended: event,
                    evictedCount: evictedCount,
                    wasInserted: true
                )
            }
        }
    }

    public func recent(limit: Int) throws -> [LidMuteEvent] {
        try performStorageOperation {
            try lock.withExclusiveLock {
                let events = try decodeEvents(fileSystem.read(url))
                guard limit > 0 else { return [] }
                return Array(events.suffix(min(limit, maximumCount)))
            }
        }
    }

    public func load() throws -> [LidMuteEvent] {
        try recent(limit: maximumCount)
    }

    public func clear() throws {
        try performStorageOperation {
            try lock.withExclusiveLock {
                try fileSystem.ensurePrivateDirectory(url.deletingLastPathComponent())
                try fileSystem.truncate(url)
                try fileSystem.syncFile(url)
                try fileSystem.syncDirectory(url.deletingLastPathComponent())
            }
        }
    }

    private func decodeEvents(_ data: Data) throws -> [LidMuteEvent] {
        guard !data.isEmpty else { return [] }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        guard lines.last?.isEmpty == true else {
            throw EventStoreError.corruptRecord(line: lines.count)
        }
        lines.removeLast()

        var events: [LidMuteEvent] = []
        events.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            do {
                events.append(try JSONDecoder().decode(LidMuteEvent.self, from: Data(line)))
            } catch {
                throw EventStoreError.corruptRecord(line: index + 1)
            }
        }
        return events
    }

    private func persist(_ events: [LidMuteEvent]) throws {
        try fileSystem.ensurePrivateDirectory(url.deletingLastPathComponent())
        var data = Data()
        for event in events {
            data.append(try JSONEncoder().encode(event))
            data.append(0x0A)
        }
        try fileSystem.atomicWrite(data, to: url, permissions: Int16(0o600))
        try fileSystem.syncFile(url)
        try fileSystem.syncDirectory(url.deletingLastPathComponent())
    }

    private func performStorageOperation<T>(_ body: () throws -> T) throws -> T {
        do {
            let result = try body()
            health = .healthy
            return result
        } catch let error as EventStoreError {
            health = error.health
            throw error
        } catch {
            let mapped = EventStoreError(storageError: error)
            health = mapped.health
            throw mapped
        }
    }
}

private extension EventStoreError {
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
        case .permissionFailure: .permissionFailure
        case .capacityFailure: .capacityFailure
        case let .ioFailure(message): .ioFailure(message)
        }
    }
}

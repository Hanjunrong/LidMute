import Foundation

public final class JSONLineEventStore: EventStoring, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public func append(_ event: LidMuteEvent) throws {
        lock.lock()
        defer { lock.unlock() }

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(JSONEncoder().encode(event))
        handle.write(Data([0x0A]))
    }

    public func load() throws -> [LidMuteEvent] {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? JSONDecoder().decode(LidMuteEvent.self, from: Data($0.utf8)) }
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.removeItem(at: url)
    }
}

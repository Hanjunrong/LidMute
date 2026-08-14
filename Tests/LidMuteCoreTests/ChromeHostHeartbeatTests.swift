import Foundation
import Testing
@testable import LidMuteCore

private final class HeartbeatTestErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []
    func record(_ error: Error) { lock.withLock { errors.append(error) } }
    func first() -> Error? { lock.withLock { errors.first } }
}

@Test func heartbeatIsFreshThroughSixSecondsOnly() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "chrome-host-heartbeat.json")
    let store = FileChromeHostHeartbeatStore(url: url)
    let token = UUID()
    try store.write(.init(version: 1, sessionToken: token, pid: 4312, uptime: 100))
    #expect(store.readFreshness(nowUptime: 106, ttl: 6) == .fresh(sessionToken: token, pid: 4312))
    #expect(store.readFreshness(nowUptime: 106.001, ttl: 6) == .stale)
}

@Test(arguments: [-1.0, 101.0])
func impossibleHeartbeatUptimeIsStale(_ heartbeatUptime: TimeInterval) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileChromeHostHeartbeatStore(url: root.appending(path: "heartbeat.json"))
    try store.write(.init(version: 1, sessionToken: UUID(), pid: 7, uptime: heartbeatUptime))
    #expect(store.readFreshness(nowUptime: 100, ttl: 6) == .stale)
}

@Test func heartbeatFileIsPrivateAndRemovalIsIdempotent() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "heartbeat.json")
    let store = FileChromeHostHeartbeatStore(url: url)
    try store.write(.init(version: 1, sessionToken: UUID(), pid: 9, uptime: 5))
    let mode = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
    #expect(mode.intValue == 0o600)
    let directoryMode = try #require(FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)
    #expect(directoryMode.intValue == 0o700)
    try store.remove()
    try store.remove()
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func unsupportedOrMalformedHeartbeatIsReportedAsMalformed() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "heartbeat.json")
    let store = FileChromeHostHeartbeatStore(url: url)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: url)
    #expect(store.readFreshness(nowUptime: 1) == .malformed)
    try store.write(.init(version: 2, sessionToken: UUID(), pid: 1, uptime: 1))
    #expect(store.readFreshness(nowUptime: 1) == .malformed)
}

@Test func writerPersistsImmediatelyAndOldSessionCannotEraseNewHeartbeat() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileChromeHostHeartbeatStore(url: root.appending(path: "heartbeat.json"))
    let oldToken = UUID()
    let writer = ChromeHostHeartbeatWriter(
        store: store,
        sessionToken: oldToken,
        pid: 12,
        heartbeatInterval: 2,
        uptime: { 42 }
    )
    try writer.start()
    #expect(store.readFreshness(nowUptime: 42) == .fresh(sessionToken: oldToken, pid: 12))

    let newToken = UUID()
    try store.write(.init(version: 1, sessionToken: newToken, pid: 13, uptime: 43))
    writer.stopAndRemove()
    #expect(store.readFreshness(nowUptime: 43) == .fresh(sessionToken: newToken, pid: 13))
}

@Test func replacementCannotSlipBetweenSessionComparisonAndRemoval() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "heartbeat.json")
    let oldToken = UUID()
    let newToken = UUID()
    let comparisonReached = DispatchSemaphore(value: 0)
    let allowRemoval = DispatchSemaphore(value: 0)
    let oldStore = FileChromeHostHeartbeatStore(
        url: url,
        beforeConditionalRemove: {
            comparisonReached.signal()
            allowRemoval.wait()
        }
    )
    let newStore = FileChromeHostHeartbeatStore(url: url)
    try oldStore.write(.init(version: 1, sessionToken: oldToken, pid: 1, uptime: 1))

    let group = DispatchGroup()
    let errors = HeartbeatTestErrors()
    group.enter()
    DispatchQueue.global().async {
        defer { group.leave() }
        do { try oldStore.remove(ifSessionToken: oldToken) } catch { errors.record(error) }
    }
    comparisonReached.wait()
    group.enter()
    DispatchQueue.global().async {
        defer { group.leave() }
        do {
            try newStore.write(.init(version: 1, sessionToken: newToken, pid: 2, uptime: 2))
        } catch {
            errors.record(error)
        }
    }
    allowRemoval.signal()
    group.wait()
    if let error = errors.first() { throw error }

    #expect(newStore.readFreshness(nowUptime: 2) == .fresh(sessionToken: newToken, pid: 2))
}

@Test func acceptanceMarkerIsPrivateFreshAndBoundToTheCurrentHeartbeatSession() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let heartbeatURL = root.appending(path: "chrome-host-heartbeat.json")
    let acceptanceURL = root.appending(path: "chrome-host-acceptance.json")
    let heartbeatStore = FileChromeHostHeartbeatStore(url: heartbeatURL)
    let acceptanceStore = FileChromeHostAcceptanceStore(
        url: acceptanceURL,
        heartbeatURL: heartbeatURL
    )
    let current = UUID()
    try heartbeatStore.write(.init(version: 1, sessionToken: current, pid: 8, uptime: 100))
    try acceptanceStore.write(.init(version: 1, sessionToken: current, pid: 8, uptime: 101))

    #expect(
        acceptanceStore.readFreshness(nowUptime: 131, ttl: 30) ==
            .fresh(sessionToken: current, pid: 8)
    )
    #expect(acceptanceStore.readFreshness(nowUptime: 131.001, ttl: 30) == .stale)
    let mode = try #require(
        FileManager.default.attributesOfItem(atPath: acceptanceURL.path)[.posixPermissions]
            as? NSNumber
    )
    #expect(mode.intValue == 0o600)

    let replacement = UUID()
    try heartbeatStore.write(.init(version: 1, sessionToken: replacement, pid: 9, uptime: 102))
    try acceptanceStore.write(.init(version: 1, sessionToken: current, pid: 8, uptime: 103))
    #expect(acceptanceStore.readFreshness(nowUptime: 133, ttl: 30) == .stale)
}

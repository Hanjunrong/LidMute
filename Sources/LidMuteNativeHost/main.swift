import Foundation
import LidMuteCore

private let fileManager = FileManager.default
private let appDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appending(path: "LidMute", directoryHint: .isDirectory)
private let originURL = appDirectory.appending(path: "chrome-origin.txt")
private let pidURL = appDirectory.appending(path: "chrome-host.pid")

do {
    try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appDirectory.path)

    let expectedOrigin = try String(contentsOf: originURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let actualOrigin = CommandLine.arguments.dropFirst().first ?? ""
    guard !actualOrigin.isEmpty, actualOrigin == expectedOrigin else {
        fail("origin_rejected", status: 2)
    }

    let heartbeatURL = appDirectory.appending(path: "chrome-host-heartbeat.json")
    let heartbeatStore = FileChromeHostHeartbeatStore(url: heartbeatURL)
    let acceptanceStore = FileChromeHostAcceptanceStore(
        url: appDirectory.appending(path: "chrome-host-acceptance.json"),
        heartbeatURL: heartbeatURL
    )
    let sessionToken = UUID()
    let processID = Int32(ProcessInfo.processInfo.processIdentifier)
    let heartbeatWriter = ChromeHostHeartbeatWriter(
        store: heartbeatStore,
        sessionToken: sessionToken,
        pid: processID,
        heartbeatInterval: 2,
        uptime: { ProcessInfo.processInfo.systemUptime }
    )
    try heartbeatWriter.start()
    defer { heartbeatWriter.stopAndRemove() }

    try writePrivate(Data("\(ProcessInfo.processInfo.processIdentifier)".utf8), to: pidURL)

    let paths = ObservationPaths(root: appDirectory)
    let store = ObservationStore(paths: paths)
    let session = NativeHostSession(
        acceptor: store,
        onAccepted: { _ in
            try? acceptanceStore.write(.init(
                version: ChromeHostAcceptance.schemaVersion,
                sessionToken: sessionToken,
                pid: processID,
                uptime: ProcessInfo.processInfo.systemUptime
            ))
        }
    )

    while true {
        let chunk = FileHandle.standardInput.availableData
        guard !chunk.isEmpty else { break }
        for acknowledgement in try session.receive(chunk) {
            try writeNativeMessage(acknowledgement)
        }
    }

    guard session.bufferedByteCount == 0 else {
        fail("partial_frame_at_eof", status: 3)
    }
} catch NativeMessageFramingError.frameTooLarge {
    fail("frame_too_large", status: 3)
} catch NativeHostProtocolError.unaddressableMalformedFrame {
    fail("unaddressable_malformed_frame", status: 3)
} catch {
    fail("native_host_failure", status: 4)
}

private func writeNativeMessage(_ acknowledgement: ChromeAcknowledgement) throws {
    let payload = try JSONEncoder().encode(acknowledgement)
    var length = UInt32(payload.count).littleEndian
    FileHandle.standardOutput.write(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
    FileHandle.standardOutput.write(payload)
}

private func writePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func fail(_ reason: StaticString, status: Int32) -> Never {
    fputs("\(reason)\n", stderr)
    exit(status)
}

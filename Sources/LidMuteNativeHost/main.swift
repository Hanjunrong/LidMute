import Foundation

let appDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appending(path: "LidMute", directoryHint: .isDirectory)
let inboxURL = appDirectory.appending(path: "chrome-inbox.jsonl")
let originURL = appDirectory.appending(path: "chrome-origin.txt")

try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
let expectedOrigin = (try? String(contentsOf: originURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
let actualOrigin = CommandLine.arguments.dropFirst().first ?? ""

guard !actualOrigin.isEmpty, actualOrigin == expectedOrigin else {
    fputs("LidMute rejected unregistered Chrome extension origin.\n", stderr)
    exit(2)
}

var buffer = Data()
while true {
    let chunk = FileHandle.standardInput.availableData
    guard !chunk.isEmpty else { break }
    buffer.append(chunk)

    while buffer.count >= 4 {
        let length = buffer.prefix(4).withUnsafeBytes { raw in
            UInt32(littleEndian: raw.loadUnaligned(as: UInt32.self))
        }
        guard length <= 262_144 else {
            fputs("LidMute rejected oversized native message.\n", stderr)
            exit(3)
        }
        let total = 4 + Int(length)
        guard buffer.count >= total else { break }

        let payload = buffer.subdata(in: 4..<total)
        buffer.removeSubrange(0..<total)
        try append(payload, to: inboxURL)
        try sendAcknowledgement(for: payload)
    }
}

private func append(_ data: Data, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    handle.write(data)
    handle.write(Data([0x0A]))
}

private func sendAcknowledgement(for payload: Data) throws {
    let object = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any]) ?? [:]
    let response: [String: Any] = [
        "v": 1,
        "type": "ack",
        "eventId": object["eventId"] as? String ?? "",
        "status": "accepted",
        "disposition": "observed",
        "appConnected": true,
        "receivedAt": ISO8601DateFormatter().string(from: Date()),
    ]
    let data = try JSONSerialization.data(withJSONObject: response)
    var length = UInt32(data.count).littleEndian
    FileHandle.standardOutput.write(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
    FileHandle.standardOutput.write(data)
}

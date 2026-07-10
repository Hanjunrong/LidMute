import Foundation

public enum ChromeProtocolError: LocalizedError {
    case unsupportedFrame

    public var errorDescription: String? { "不支持的 Chrome 桥接消息" }
}

public struct DecodedChromeFrame: Sendable {
    public let evidence: ChromeTabEvidence
    public let eventID: String
}

public final class ChromeEventDeduplicator: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var eventIDs: Set<String>

    public init(url: URL) {
        self.url = url
        eventIDs = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: url))) ?? [])
    }

    public func accept(_ eventID: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard eventIDs.insert(eventID).inserted else { return false }

        let retained = Array(eventIDs.sorted().suffix(4_096))
        eventIDs = Set(retained)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(retained).write(to: url, options: .atomic)
        return true
    }
}

public enum ChromeBridgeFrame {
    public static func decode(_ data: Data) throws -> DecodedChromeFrame {
        let frame = try JSONDecoder().decode(WireFrame.self, from: data)
        guard frame.version == 1, frame.type == "tab_audio_started", frame.tab.audible else {
            throw ChromeProtocolError.unsupportedFrame
        }
        return DecodedChromeFrame(
            evidence: ChromeTabEvidence(
                sessionID: frame.extensionSessionID,
                windowID: frame.tab.windowID,
                tabID: frame.tab.tabID,
                index: frame.tab.index,
                title: frame.tab.title,
                url: frame.tab.url,
                audible: frame.tab.audible,
                muted: frame.tab.muted.value,
                isActive: frame.tab.active,
                isPinned: frame.tab.pinned,
                isIncognito: frame.tab.incognito
            ),
            eventID: frame.eventID
        )
    }

    private struct WireFrame: Decodable {
        let version: Int
        let type: String
        let eventID: String
        let extensionSessionID: String
        let tab: WireTab

        enum CodingKeys: String, CodingKey {
            case version = "v"
            case type
            case eventID = "eventId"
            case extensionSessionID = "extensionSessionId"
            case tab
        }
    }

    private struct WireTab: Decodable {
        let windowID: Int
        let tabID: Int
        let index: Int
        let title: String
        let url: String
        let audible: Bool
        let muted: WireMuted
        let active: Bool
        let pinned: Bool
        let incognito: Bool

        enum CodingKeys: String, CodingKey {
            case windowID = "windowId"
            case tabID = "tabId"
            case index, title, url, audible, muted, active, pinned, incognito
        }
    }

    private struct WireMuted: Decodable {
        let value: Bool
    }
}

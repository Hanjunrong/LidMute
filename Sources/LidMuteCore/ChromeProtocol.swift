import Foundation

public enum ChromeFramePrivacy: Equatable, Sendable {
    case persist
    case ignoreIncognito
}

public struct ChromeValidatedFrame: Sendable {
    public let eventID: UUID
    public let extensionSessionID: UUID
    public let evidence: ChromeTabEvidence
    public let privacy: ChromeFramePrivacy

    public init(
        eventID: UUID,
        extensionSessionID: UUID,
        evidence: ChromeTabEvidence,
        privacy: ChromeFramePrivacy
    ) {
        self.eventID = eventID
        self.extensionSessionID = extensionSessionID
        self.evidence = evidence
        self.privacy = privacy
    }
}

public enum ChromeFrameValidationError: Error, Equatable, Sendable {
    case malformedJSON
    case unsupportedVersion
    case unsupportedType
    case notAudible
    case invalidEventID
    case invalidSessionID
    case titleTooLong
    case urlTooLong
    case statusTooLong
    case muteReasonTooLong
    case extensionIDTooLong
}

public struct ChromeFrameDecoder: Sendable {
    public init() {}

    public func decode(_ data: Data) throws -> ChromeValidatedFrame {
        let wire: WireFrame
        do {
            wire = try JSONDecoder().decode(WireFrame.self, from: data)
        } catch {
            throw ChromeFrameValidationError.malformedJSON
        }

        guard wire.version == 1 else { throw ChromeFrameValidationError.unsupportedVersion }
        guard wire.type == "tab_audio_started" else { throw ChromeFrameValidationError.unsupportedType }
        guard wire.tab.audible else { throw ChromeFrameValidationError.notAudible }
        guard Data(wire.eventID.utf8).count <= 64,
              let eventID = UUID(uuidString: wire.eventID)
        else { throw ChromeFrameValidationError.invalidEventID }
        guard Data(wire.extensionSessionID.utf8).count <= 64,
              let sessionID = UUID(uuidString: wire.extensionSessionID)
        else { throw ChromeFrameValidationError.invalidSessionID }
        guard Data(wire.tab.title.utf8).count <= 4_096 else {
            throw ChromeFrameValidationError.titleTooLong
        }
        guard Data(wire.tab.url.utf8).count <= 16_384 else {
            throw ChromeFrameValidationError.urlTooLong
        }
        guard Data(wire.tab.status.utf8).count <= 64 else {
            throw ChromeFrameValidationError.statusTooLong
        }
        guard wire.tab.muted.reason.map({ Data($0.utf8).count <= 64 }) ?? true else {
            throw ChromeFrameValidationError.muteReasonTooLong
        }
        guard wire.tab.muted.extensionID.map({ Data($0.utf8).count <= 128 }) ?? true else {
            throw ChromeFrameValidationError.extensionIDTooLong
        }

        let evidence = ChromeTabEvidence(
            sessionID: sessionID.uuidString,
            windowID: wire.tab.windowID,
            tabID: wire.tab.tabID,
            index: wire.tab.index,
            title: wire.tab.title,
            url: wire.tab.url,
            audible: true,
            muted: wire.tab.muted.value,
            isActive: wire.tab.active,
            isPinned: wire.tab.pinned,
            isIncognito: wire.tab.incognito
        )
        return ChromeValidatedFrame(
            eventID: eventID,
            extensionSessionID: sessionID,
            evidence: evidence,
            privacy: wire.tab.incognito ? .ignoreIncognito : .persist
        )
    }

    private struct WireFrame: Decodable {
        let version: Int
        let type: String
        let eventID: String
        let extensionSessionID: String
        let sequence: String
        let sentAt: String
        let tab: WireTab

        enum CodingKeys: String, CodingKey {
            case version = "v"
            case type
            case eventID = "eventId"
            case extensionSessionID = "extensionSessionId"
            case sequence = "seq"
            case sentAt
            case tab
        }
    }

    private struct WireTab: Decodable {
        let windowID: Int
        let tabID: Int
        let index: Int
        let title: String
        let url: String
        let status: String
        let audible: Bool
        let muted: WireMuted
        let active: Bool
        let pinned: Bool
        let incognito: Bool

        enum CodingKeys: String, CodingKey {
            case windowID = "windowId"
            case tabID = "tabId"
            case index
            case title
            case url
            case status
            case audible
            case muted
            case active
            case pinned
            case incognito
        }
    }

    private struct WireMuted: Decodable {
        let value: Bool
        let reason: String?
        let extensionID: String?

        enum CodingKeys: String, CodingKey {
            case value
            case reason
            case extensionID = "extensionId"
        }
    }
}

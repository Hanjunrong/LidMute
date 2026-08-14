import Foundation

public enum NativeMessageFramingError: Error, Equatable {
    case frameTooLarge(Int)
}

public final class NativeMessageFramer: @unchecked Sendable {
    private var buffer = Data()
    private let maxFrameBytes: Int

    public var bufferedByteCount: Int { buffer.count }

    public init(maxFrameBytes: Int = 262_144) {
        self.maxFrameBytes = maxFrameBytes
    }

    public func feed<S: DataProtocol>(_ bytes: S) throws -> [Data] {
        buffer.append(contentsOf: bytes)
        var frames: [Data] = []

        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes {
                Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
            }
            guard length <= maxFrameBytes else {
                throw NativeMessageFramingError.frameTooLarge(length)
            }
            guard buffer.count >= 4 + length else { break }

            frames.append(buffer.subdata(in: 4..<(4 + length)))
            buffer.removeSubrange(0..<(4 + length))
        }

        return frames
    }
}

public enum ChromeAckDisposition: String, Codable, Equatable, Sendable {
    case accepted
    case duplicate
    case ignoredIncognito = "ignored_incognito"
    case rejectedPermanent = "rejected_permanent"
    case retryableFailure = "retryable_failure"
}

public struct ChromeAcknowledgement: Codable, Equatable, Sendable {
    public let version: Int
    public let type: String
    public let eventID: UUID?
    public let disposition: ChromeAckDisposition

    public init(eventID: UUID?, disposition: ChromeAckDisposition) {
        version = 1
        type = "ack"
        self.eventID = eventID
        self.disposition = disposition
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case type
        case eventID = "eventId"
        case disposition
    }
}

public protocol ChromeFrameAccepting: Sendable {
    func accept(_ frame: ChromeValidatedFrame) throws -> ChromeAcceptDisposition
}

public enum NativeHostProtocolError: Error, Equatable, Sendable {
    case unaddressableMalformedFrame
}

public final class NativeHostSession: @unchecked Sendable {
    private let acceptor: any ChromeFrameAccepting
    private let decoder: ChromeFrameDecoder
    private let framer: NativeMessageFramer

    public var bufferedByteCount: Int { framer.bufferedByteCount }

    public init(
        acceptor: any ChromeFrameAccepting,
        decoder: ChromeFrameDecoder = .init(),
        framer: NativeMessageFramer = .init()
    ) {
        self.acceptor = acceptor
        self.decoder = decoder
        self.framer = framer
    }

    public func receive<S: DataProtocol>(_ bytes: S) throws -> [ChromeAcknowledgement] {
        try framer.feed(bytes).map(acknowledgement(for:))
    }

    private func acknowledgement(for payload: Data) throws -> ChromeAcknowledgement {
        let frame: ChromeValidatedFrame
        do {
            frame = try decoder.decode(payload)
        } catch is ChromeFrameValidationError {
            guard let eventID = safeEventID(from: payload) else {
                throw NativeHostProtocolError.unaddressableMalformedFrame
            }
            return ChromeAcknowledgement(eventID: eventID, disposition: .rejectedPermanent)
        }

        do {
            switch try acceptor.accept(frame) {
            case let .accepted(eventID):
                return ChromeAcknowledgement(eventID: eventID, disposition: .accepted)
            case let .duplicate(eventID):
                return ChromeAcknowledgement(eventID: eventID, disposition: .duplicate)
            case let .ignoredIncognito(eventID):
                return ChromeAcknowledgement(eventID: eventID, disposition: .ignoredIncognito)
            }
        } catch is ObservationStoreError {
            return ChromeAcknowledgement(eventID: frame.eventID, disposition: .retryableFailure)
        }
    }

    private func safeEventID(from payload: Data) -> UUID? {
        guard let envelope = try? JSONDecoder().decode(EventIDEnvelope.self, from: payload),
              Data(envelope.eventID.utf8).count <= 64
        else { return nil }
        return UUID(uuidString: envelope.eventID)
    }

    private struct EventIDEnvelope: Decodable {
        let eventID: String

        enum CodingKeys: String, CodingKey {
            case eventID = "eventId"
        }
    }
}

import Foundation
import XCTest
@testable import LidMuteCore

final class ChromeNativeMessagingTests: XCTestCase {
    private let eventID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let sessionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private func wire(_ payload: Data) -> Data {
        var count = UInt32(payload.count).littleEndian
        return Data(bytes: &count, count: 4) + payload
    }

    func testFramerWaitsForCompletePrefixAndPayload() throws {
        let payload = Data(#"{"title":"音乐🎵"}"#.utf8)
        let framed = wire(payload)
        let framer = NativeMessageFramer(maxFrameBytes: 262_144)

        XCTAssertTrue(try framer.feed(framed.prefix(1)).isEmpty)
        XCTAssertTrue(try framer.feed(framed.dropFirst(1).prefix(5)).isEmpty)
        XCTAssertEqual(try framer.feed(framed.dropFirst(6)), [payload])
    }

    func testFramerReturnsTwoGluedFramesAndKeepsTrailingHalfFrame() throws {
        let first = Data(#"{"v":1}"#.utf8)
        let second = Data(#"{"v":2}"#.utf8)
        let third = Data(#"{"v":3}"#.utf8)
        let thirdWire = wire(third)
        let framer = NativeMessageFramer(maxFrameBytes: 262_144)

        XCTAssertEqual(
            try framer.feed(wire(first) + wire(second) + thirdWire.prefix(6)),
            [first, second]
        )
        XCTAssertEqual(framer.bufferedByteCount, 6)
        XCTAssertEqual(try framer.feed(thirdWire.dropFirst(6)), [third])
    }

    func testFramerRejectsOversizeBeforeBufferingPayload() throws {
        var count = UInt32(262_145).littleEndian
        let prefix = Data(bytes: &count, count: 4)
        let framer = NativeMessageFramer(maxFrameBytes: 262_144)

        XCTAssertThrowsError(try framer.feed(prefix)) { error in
            XCTAssertEqual(error as? NativeMessageFramingError, .frameTooLarge(262_145))
        }
    }

    func testDecoderPreservesCompleteNormalURL() throws {
        let frame = try ChromeFrameDecoder().decode(validPayload())

        XCTAssertEqual(frame.eventID, eventID)
        XCTAssertEqual(frame.evidence.url, "https://example.com/watch?q=secret#chapter")
        XCTAssertEqual(frame.privacy, .persist)
    }

    func testDecoderClassifiesIncognitoBeforePersistence() throws {
        let frame = try ChromeFrameDecoder().decode(validPayload(incognito: true))

        XCTAssertEqual(frame.privacy, .ignoreIncognito)
    }

    func testDecoderRejectsPermanentProtocolErrors() {
        let unsupportedVersion = replacing("\"v\":1", with: "\"v\":2")
        let unsupportedType = replacing("tab_audio_started", with: "tab_audio_stopped")
        let notAudible = replacing("\"audible\":true", with: "\"audible\":false")
        let invalidEventID = validPayload(eventIDText: "not-a-uuid")
        let invalidSessionID = replacing(sessionID.uuidString, with: "not-a-uuid")
        let cases: [(Data, ChromeFrameValidationError)] = [
            (Data("not-json".utf8), .malformedJSON),
            (unsupportedVersion, .unsupportedVersion),
            (unsupportedType, .unsupportedType),
            (notAudible, .notAudible),
            (invalidEventID, .invalidEventID),
            (invalidSessionID, .invalidSessionID),
        ]

        for (payload, expectedError) in cases {
            XCTAssertThrowsError(try ChromeFrameDecoder().decode(payload)) { error in
                XCTAssertEqual(error as? ChromeFrameValidationError, expectedError)
            }
        }
    }

    func testDecoderRequiresTheCompleteWireSchema() {
        let missingSequence = replacing("\"seq\":\"7\",", with: "")

        XCTAssertThrowsError(try ChromeFrameDecoder().decode(missingSequence)) { error in
            XCTAssertEqual(error as? ChromeFrameValidationError, .malformedJSON)
        }
    }

    func testDecoderMeasuresAllStringLimitsInUTF8Bytes() {
        let oversizedTitle = String(repeating: "界", count: 1_366)
        let oversizedURL = String(repeating: "界", count: 5_462)
        let oversizedStatus = String(repeating: "界", count: 22)
        let oversizedReason = String(repeating: "界", count: 22)
        let oversizedExtensionID = String(repeating: "界", count: 43)
        let cases: [(Data, ChromeFrameValidationError)] = [
            (replacing("搜索", with: oversizedTitle), .titleTooLong),
            (replacing("https://example.com/watch?q=secret#chapter", with: oversizedURL), .urlTooLong),
            (replacing("complete", with: oversizedStatus), .statusTooLong),
            (replacing("\"reason\":null", with: "\"reason\":\"" + oversizedReason + "\""), .muteReasonTooLong),
            (replacing("\"extensionId\":null", with: "\"extensionId\":\"" + oversizedExtensionID + "\""), .extensionIDTooLong),
        ]

        for (payload, expectedError) in cases {
            XCTAssertThrowsError(try ChromeFrameDecoder().decode(payload)) { error in
                XCTAssertEqual(error as? ChromeFrameValidationError, expectedError)
            }
        }
    }

    private func validPayload(incognito: Bool = false, eventIDText: String? = nil) -> Data {
        Data(#"{"v":1,"type":"tab_audio_started","eventId":"\#(eventIDText ?? eventID.uuidString)","extensionSessionId":"\#(sessionID.uuidString)","seq":"7","sentAt":"2026-08-13T00:00:00Z","tab":{"windowId":1,"tabId":2,"index":0,"title":"搜索","url":"https://example.com/watch?q=secret#chapter","status":"complete","audible":true,"muted":{"value":false,"reason":null,"extensionId":null},"active":true,"pinned":false,"incognito":\#(incognito)}}"#.utf8)
    }

    private func replacing(_ target: String, with replacement: String) -> Data {
        let text = String(decoding: validPayload(), as: UTF8.self)
        return Data(text.replacingOccurrences(of: target, with: replacement).utf8)
    }
}

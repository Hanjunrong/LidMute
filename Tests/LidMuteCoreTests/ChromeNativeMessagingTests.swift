import Foundation
import XCTest
@testable import LidMuteCore

final class ChromeNativeMessagingTests: XCTestCase {
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
}

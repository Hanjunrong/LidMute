import XCTest
@testable import LidMuteCore

final class AudioDeviceResolutionTests: XCTestCase {
    func testExplicitUIDFindsBuiltInSpeakerWhenExternalRouteIsDefault() {
        let candidates = [
            AudioDeviceCandidate(
                device: .init(id: 9, uid: "external-b", name: "HDMI", isBuiltIn: false),
                isDefault: true,
                isInternalTransport: false,
                dataSourceName: "HDMI"
            ),
            AudioDeviceCandidate(
                device: .init(id: 11, uid: "built-in-a", name: "MacBook Speakers", isBuiltIn: true),
                isDefault: false,
                isInternalTransport: true,
                dataSourceName: "MacBook Speakers"
            ),
        ]

        XCTAssertEqual(AudioDeviceResolver.resolve(candidates, uid: "built-in-a")?.id, 11)
    }

    func testNilUIDRejectsExternalDefault() {
        let candidate = AudioDeviceCandidate(
            device: .init(id: 9, uid: "external-b", name: "HDMI", isBuiltIn: false),
            isDefault: true,
            isInternalTransport: false,
            dataSourceName: "HDMI"
        )

        XCTAssertNil(AudioDeviceResolver.resolve([candidate], uid: nil))
    }

    func testMatchingUIDStillRequiresInternalTransportAndSpeakerDataSource() {
        let impostor = AudioDeviceCandidate(
            device: .init(id: 15, uid: "built-in-a", name: "Display", isBuiltIn: false),
            isDefault: false,
            isInternalTransport: false,
            dataSourceName: "DisplayPort"
        )

        XCTAssertNil(AudioDeviceResolver.resolve([impostor], uid: "built-in-a"))
    }

    func testMatchingUIDRejectsInternalTransportWithoutSpeakerDataSource() {
        let internalNonSpeaker = AudioDeviceCandidate(
            device: .init(id: 17, uid: "built-in-a", name: "Internal Output", isBuiltIn: true),
            isDefault: false,
            isInternalTransport: true,
            dataSourceName: "Digital Output"
        )

        XCTAssertNil(AudioDeviceResolver.resolve([internalNonSpeaker], uid: "built-in-a"))
    }
}

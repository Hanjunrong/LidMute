import Foundation
import Testing
@testable import LidMuteApp

private final class ChromeRegistrationFixture {
    let root: URL
    let manifestURL: URL
    let originURL: URL

    init(registeredHostPath: String, registeredOrigin: String) throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        manifestURL = root.appending(path: "com.lidmute.nativehost.json")
        originURL = root.appending(path: "chrome-origin.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "name": "com.lidmute.nativehost",
            "description": "LidMute Chrome bridge",
            "path": registeredHostPath,
            "type": "stdio",
            "allowed_origins": [registeredOrigin],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        try registeredOrigin.write(to: originURL, atomically: true, encoding: .utf8)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

@MainActor @Test func movedBundleIsDetectedAndRepairPreservesRegisteredOrigin() throws {
    let fixture = try ChromeRegistrationFixture(
        registeredHostPath: "/Users/test/Downloads/LidMute.app/Contents/MacOS/LidMuteNativeHost",
        registeredOrigin: "chrome-extension://abcdefghijklmnopabcdefghijklmnop/"
    )
    let service = ChromeHostRegistration(
        manifestURL: fixture.manifestURL,
        originURL: fixture.originURL,
        isExecutableFile: { _ in true }
    )
    let expected = URL(filePath: "/Applications/LidMute.app/Contents/MacOS/LidMuteNativeHost")
    #expect(service.inspect(expectedHostPath: expected) == .pathMismatch(
        expected: expected.path,
        registered: "/Users/test/Downloads/LidMute.app/Contents/MacOS/LidMuteNativeHost"
    ))
    try service.repair(expectedHostPath: expected)
    let repaired = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifestURL)) as? [String: Any]
    #expect(repaired?["path"] as? String == expected.path)
    #expect(repaired?["allowed_origins"] as? [String] == ["chrome-extension://abcdefghijklmnopabcdefghijklmnop/"])
    #expect(service.inspect(expectedHostPath: expected) == .current)
    let mode = try #require(FileManager.default.attributesOfItem(atPath: fixture.manifestURL.path)[.posixPermissions] as? NSNumber)
    #expect(mode.intValue == 0o600)
}

@MainActor @Test func repairRejectsMissingOrInvalidRegisteredExtensionID() throws {
    let fixture = try ChromeRegistrationFixture(registeredHostPath: "/old/host", registeredOrigin: "chrome-extension://bad/")
    let service = ChromeHostRegistration(
        manifestURL: fixture.manifestURL,
        originURL: fixture.originURL,
        isExecutableFile: { _ in true }
    )
    #expect(throws: ChromeHostRegistrationError.invalidRegisteredExtensionID) {
        try service.repair(expectedHostPath: URL(filePath: "/Applications/LidMute.app/Contents/MacOS/LidMuteNativeHost"))
    }
}

@MainActor @Test func repairRejectsNonExecutableExpectedHost() throws {
    let fixture = try ChromeRegistrationFixture(
        registeredHostPath: "/old/host",
        registeredOrigin: "chrome-extension://abcdefghijklmnopabcdefghijklmnop/"
    )
    let service = ChromeHostRegistration(
        manifestURL: fixture.manifestURL,
        originURL: fixture.originURL,
        isExecutableFile: { _ in false }
    )
    #expect(throws: ChromeHostRegistrationError.expectedHostNotExecutable) {
        try service.repair(expectedHostPath: URL(filePath: "/missing/host"))
    }
}

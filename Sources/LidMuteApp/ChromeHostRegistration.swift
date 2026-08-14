import Foundation

enum ChromeManifestInspection: Equatable, Sendable {
    case notRegistered
    case current
    case pathMismatch(expected: String, registered: String)
    case malformed
}

enum ChromeHostRegistrationError: Error, Equatable {
    case invalidRegisteredExtensionID
    case expectedHostNotExecutable
    case malformedManifest
}

protocol ChromeManifestInspecting: Sendable {
    func inspect(expectedHostPath: URL) -> ChromeManifestInspection
}

@MainActor
protocol ChromeHostRegistering: Sendable {
    func inspect(expectedHostPath: URL) -> ChromeManifestInspection
    func repair(expectedHostPath: URL) throws
}

struct ChromeHostRegistration: ChromeHostRegistering, ChromeManifestInspecting, @unchecked Sendable {
    nonisolated private let manifestURL: URL
    nonisolated private let originURL: URL
    nonisolated(unsafe) private let fileManager: FileManager
    private let isExecutableFile: (String) -> Bool

    init(
        manifestURL: URL,
        originURL: URL,
        fileManager: FileManager = .default,
        isExecutableFile: ((String) -> Bool)? = nil
    ) {
        self.manifestURL = manifestURL
        self.originURL = originURL
        self.fileManager = fileManager
        self.isExecutableFile = isExecutableFile ?? fileManager.isExecutableFile(atPath:)
    }

    nonisolated func inspect(expectedHostPath: URL) -> ChromeManifestInspection {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return .notRegistered }
        guard let manifest = try? readManifest(),
              let registeredPath = try? validatedRegisteredPath(in: manifest) else {
            return .malformed
        }

        let expected = expectedHostPath.standardizedFileURL.path
        let registered = URL(filePath: registeredPath).standardizedFileURL.path
        return expected == registered
            ? .current
            : .pathMismatch(expected: expected, registered: registered)
    }

    func repair(expectedHostPath: URL) throws {
        let expectedPath = expectedHostPath.standardizedFileURL.path
        guard isExecutableFile(expectedPath) else {
            throw ChromeHostRegistrationError.expectedHostNotExecutable
        }

        var manifest = try readManifest()
        _ = try validatedRegisteredPath(in: manifest)
        let origin = try registeredOrigin()

        manifest["path"] = expectedPath
        manifest["allowed_origins"] = [origin]
        let data = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        )
        try fileManager.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: manifestURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifestURL.path
        )
    }

    nonisolated private func readManifest() throws -> [String: Any] {
        do {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
            guard let manifest = object as? [String: Any] else {
                throw ChromeHostRegistrationError.malformedManifest
            }
            return manifest
        } catch let error as ChromeHostRegistrationError {
            throw error
        } catch {
            throw ChromeHostRegistrationError.malformedManifest
        }
    }

    nonisolated private func validatedRegisteredPath(in manifest: [String: Any]) throws -> String {
        let origin = try registeredOrigin()
        guard manifest["name"] as? String == "com.lidmute.nativehost",
              manifest["description"] is String,
              manifest["type"] as? String == "stdio",
              let path = manifest["path"] as? String,
              let allowedOrigins = manifest["allowed_origins"] as? [String],
              allowedOrigins == [origin] else {
            throw ChromeHostRegistrationError.malformedManifest
        }
        return path
    }

    nonisolated private func registeredOrigin() throws -> String {
        guard let origin = try? String(contentsOf: originURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              origin.hasPrefix("chrome-extension://"), origin.hasSuffix("/") else {
            throw ChromeHostRegistrationError.invalidRegisteredExtensionID
        }
        let extensionID = String(origin.dropFirst("chrome-extension://".count).dropLast())
        guard extensionID.count == 32,
              extensionID.unicodeScalars.allSatisfy({ ("a"..."p").contains(Character(String($0))) }) else {
            throw ChromeHostRegistrationError.invalidRegisteredExtensionID
        }
        return origin
    }
}

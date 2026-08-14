import Foundation

enum ChromeManifestInspection: Equatable {
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

@MainActor
protocol ChromeHostRegistering {
    func inspect(expectedHostPath: URL) -> ChromeManifestInspection
    func repair(expectedHostPath: URL) throws
}

struct ChromeHostRegistration: ChromeHostRegistering {
    private let manifestURL: URL
    private let originURL: URL
    private let fileManager: FileManager
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

    func inspect(expectedHostPath: URL) -> ChromeManifestInspection {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return .notRegistered }
        guard let manifest = try? readManifest(),
              let registeredPath = manifest["path"] as? String else { return .malformed }

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
        guard manifest["name"] is String,
              manifest["description"] is String,
              manifest["type"] is String,
              manifest["path"] is String,
              let allowedOrigins = manifest["allowed_origins"] as? [String],
              allowedOrigins.count == 1 else {
            throw ChromeHostRegistrationError.malformedManifest
        }
        let origin = try registeredOrigin()
        guard allowedOrigins == [origin] else {
            throw ChromeHostRegistrationError.malformedManifest
        }

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

    private func readManifest() throws -> [String: Any] {
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

    private func registeredOrigin() throws -> String {
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

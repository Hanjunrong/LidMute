import Foundation

public enum SpeakerRecoveryStage: String, Codable, Sendable {
    case protected
    case finalizingRestore
}

public struct SpeakerRecoverySnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let transactionID: UUID
    public let deviceUID: String
    public let deviceName: String
    public let originalState: AudioDeviceState
    public let stage: SpeakerRecoveryStage
    public let capturedAt: Date
    public let sources: Set<ProtectionSource>
    public let appVersion: String

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        transactionID: UUID = UUID(),
        device: AudioDevice,
        originalState: AudioDeviceState,
        stage: SpeakerRecoveryStage,
        capturedAt: Date = Date(),
        sources: Set<ProtectionSource>,
        appVersion: String
    ) {
        self.schemaVersion = schemaVersion
        self.transactionID = transactionID
        self.deviceUID = device.uid
        self.deviceName = device.name
        self.originalState = originalState
        self.stage = stage
        self.capturedAt = capturedAt
        self.sources = sources
        self.appVersion = appVersion
    }

    func with(stage: SpeakerRecoveryStage) -> Self {
        Self(
            schemaVersion: schemaVersion,
            transactionID: transactionID,
            device: AudioDevice(id: 0, uid: deviceUID, name: deviceName, isBuiltIn: true),
            originalState: originalState,
            stage: stage,
            capturedAt: capturedAt,
            sources: sources,
            appVersion: appVersion
        )
    }
}

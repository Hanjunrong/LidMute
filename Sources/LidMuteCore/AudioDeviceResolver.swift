public struct AudioDeviceCandidate: Sendable {
    public let device: AudioDevice
    public let isDefault: Bool
    public let isInternalTransport: Bool
    public let dataSourceName: String

    public init(
        device: AudioDevice,
        isDefault: Bool,
        isInternalTransport: Bool,
        dataSourceName: String
    ) {
        self.device = device
        self.isDefault = isDefault
        self.isInternalTransport = isInternalTransport
        self.dataSourceName = dataSourceName
    }
}

public enum AudioDeviceResolver {
    public static func resolve(_ candidates: [AudioDeviceCandidate], uid: String?) -> AudioDevice? {
        let builtInSpeakers = candidates.filter { candidate in
            candidate.isInternalTransport && isSpeakerDataSource(candidate.dataSourceName)
        }

        if let uid {
            return builtInSpeakers.first { $0.device.uid == uid }?.device
        }
        return builtInSpeakers.first { $0.isDefault }?.device
    }

    private static func isSpeakerDataSource(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized.contains("speaker")
            || normalized.contains("扬声器")
            || normalized.contains("喇叭")
    }
}

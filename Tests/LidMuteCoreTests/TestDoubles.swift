import Foundation
@testable import LidMuteCore

enum FakeAudioError: Error {
    case enforcementFailed
}

final class MemoryEventStore: EventStoring, @unchecked Sendable {
    private(set) var events: [LidMuteEvent] = []

    func append(_ event: LidMuteEvent) throws { events.append(event) }
    func load() throws -> [LidMuteEvent] { events }
    func clear() throws { events.removeAll() }
}

final class FakeAudioController: AudioControlling, @unchecked Sendable {
    var device = AudioDevice(id: 7, uid: "built-in-a", name: "MacBook Speakers", isBuiltIn: true)
    var capturedState = AudioDeviceState(muted: false, volume: 0.72, usedVolumeFallback: false)
    var enforceError: Error?
    var activeProcesses: [AudioProcess] = []
    private(set) var enforceSilenceCount = 0
    private(set) var captureCount = 0
    private(set) var mutations: [String] = []
    var lastMute: Bool? = false
    var lastVolume: Float? = 0.72

    func resolveBuiltInSpeaker(uid: String?) throws -> AudioDevice? {
        guard uid == nil || uid == device.uid else { return nil }
        return device
    }
    func captureState(of device: AudioDevice) throws -> AudioDeviceState {
        captureCount += 1
        return capturedState
    }
    func enforceSilence(on device: AudioDevice) throws {
        enforceSilenceCount += 1
        if let enforceError { throw enforceError }
        mutations.append("silence:\(device.uid)")
        lastMute = true
    }
    func restore(_ state: AudioDeviceState, on device: AudioDevice) throws {
        mutations.append("restore:\(device.uid)")
        lastMute = state.muted
        lastVolume = state.volume
    }
    func activeOutputProcesses() throws -> [AudioProcess] { activeProcesses }
}

extension SpeakerRecoverySnapshot {
    static func fixture(
        transactionID: UUID = UUID(),
        stage: SpeakerRecoveryStage = .protected
    ) -> Self {
        SpeakerRecoverySnapshot(
            transactionID: transactionID,
            device: AudioDevice(
                id: 7,
                uid: "built-in-a",
                name: "MacBook Speakers",
                isBuiltIn: true
            ),
            originalState: AudioDeviceState(
                muted: false,
                volume: 0.72,
                usedVolumeFallback: false
            ),
            stage: stage,
            capturedAt: Date(timeIntervalSince1970: 1_723_500_000),
            sources: [.physicalLid, .night],
            appVersion: "1.0-test"
        )
    }
}

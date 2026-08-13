import Foundation

public actor SpeakerRecoveryRuntime: SpeakerProtectionApplying, PendingSpeakerRecovering {
    private let audio: AudioControlling
    private let recoveryStore: SpeakerRecoveryStoring
    private let appVersion: String

    public init(
        audio: AudioControlling,
        recoveryStore: SpeakerRecoveryStoring,
        appVersion: String
    ) {
        self.audio = audio
        self.recoveryStore = recoveryStore
        self.appVersion = appVersion
    }

    public func apply(_ action: SpeakerProtectionAction) async -> SpeakerRecoveryOutcome {
        switch action {
        case let .begin(sources):
            return protect(sources: sources)
        case .reinforce:
            return reinforcePendingProtection()
        case .end:
            return recoverPending()
        case let .routeChangedWhileProtectionRequired(sources):
            do {
                switch try recoveryStore.load() {
                case .none:
                    return protect(sources: sources)
                case .snapshot:
                    return reinforcePendingProtection()
                case .corrupt:
                    return .corruptSnapshot
                case let .unsupportedSchema(version):
                    return .unsupportedSnapshot(version)
                }
            } catch {
                return .failedSafetyUnknown
            }
        }
    }

    public func protect(sources: Set<ProtectionSource>) -> SpeakerRecoveryOutcome {
        var journaledDeviceUID: String?
        do {
            guard let device = try audio.resolveBuiltInSpeaker(uid: nil) else {
                return .waitingForMatchingDevice
            }
            let originalState = try audio.captureState(of: device)
            let snapshot = SpeakerRecoverySnapshot(
                device: device,
                originalState: originalState,
                stage: .protected,
                sources: sources,
                appVersion: appVersion
            )
            try recoveryStore.saveBeforeMutation(snapshot)
            journaledDeviceUID = snapshot.deviceUID
            try silenceAndVerify(device)
            return .noPendingRecovery
        } catch {
            guard let journaledDeviceUID else { return .failedSafetyUnknown }
            return verifySilentAfterFailure(deviceUID: journaledDeviceUID)
        }
    }

    public func recoverPending() -> SpeakerRecoveryOutcome {
        let loadResult: SpeakerRecoveryLoadResult
        do {
            loadResult = try recoveryStore.load()
        } catch {
            return .failedSafetyUnknown
        }

        switch loadResult {
        case .none:
            return .noPendingRecovery
        case .corrupt:
            return .corruptSnapshot
        case let .unsupportedSchema(version):
            return .unsupportedSnapshot(version)
        case let .snapshot(snapshot):
            return recover(snapshot)
        }
    }

    private func reinforcePendingProtection() -> SpeakerRecoveryOutcome {
        do {
            switch try recoveryStore.load() {
            case .none:
                return .noPendingRecovery
            case .corrupt:
                return .corruptSnapshot
            case let .unsupportedSchema(version):
                return .unsupportedSnapshot(version)
            case let .snapshot(snapshot):
                guard let device = try audio.resolveBuiltInSpeaker(uid: snapshot.deviceUID) else {
                    return .waitingForMatchingDevice
                }
                try silenceAndVerify(device)
                return .noPendingRecovery
            }
        } catch {
            return verifySilentAfterFailure(deviceUID: pendingUID())
        }
    }

    private func recover(_ snapshot: SpeakerRecoverySnapshot) -> SpeakerRecoveryOutcome {
        let device: AudioDevice
        do {
            guard let resolved = try audio.resolveBuiltInSpeaker(uid: snapshot.deviceUID) else {
                return .waitingForMatchingDevice
            }
            device = resolved

            if snapshot.stage == .finalizingRestore {
                let current = try audio.readState(of: device)
                if current == snapshot.originalState {
                    try recoveryStore.removeCompleted(transactionID: snapshot.transactionID)
                    return .restored
                }
                guard isVerifiedSilent(current) else {
                    return .failedSafetyUnknown
                }
            } else {
                try recoveryStore.markFinalizingRestore(transactionID: snapshot.transactionID)
            }

            guard audio.supportsWritableMute(on: device) else {
                return keepFallbackDeviceSilent(device)
            }

            try restore(snapshot.originalState, on: device)
            try recoveryStore.removeCompleted(transactionID: snapshot.transactionID)
            return .restored
        } catch {
            return verifySilentAfterFailure(deviceUID: snapshot.deviceUID)
        }
    }

    private func restore(_ originalState: AudioDeviceState, on device: AudioDevice) throws {
        try audio.writeMuted(true, on: device)
        let mutedState = try audio.readState(of: device)
        guard mutedState.muted else { throw SpeakerRecoveryRuntimeError.verificationFailed }

        try audio.writeVolume(originalState.volume, on: device)
        let volumeState = try audio.readState(of: device)
        guard volumeState.muted, volumeState.volume == originalState.volume else {
            throw SpeakerRecoveryRuntimeError.verificationFailed
        }

        if !originalState.muted {
            try audio.writeMuted(false, on: device)
        }

        guard try audio.readState(of: device) == originalState else {
            throw SpeakerRecoveryRuntimeError.verificationFailed
        }
    }

    private func keepFallbackDeviceSilent(_ device: AudioDevice) -> SpeakerRecoveryOutcome {
        do {
            try audio.writeVolume(0, on: device)
            return isVerifiedSilent(try audio.readState(of: device))
                ? .failedButVerifiedSilent
                : .failedSafetyUnknown
        } catch {
            return .failedSafetyUnknown
        }
    }

    private func silenceAndVerify(_ device: AudioDevice) throws {
        if audio.supportsWritableMute(on: device) {
            try audio.writeMuted(true, on: device)
        } else {
            try audio.writeVolume(0, on: device)
        }
        guard isVerifiedSilent(try audio.readState(of: device)) else {
            throw SpeakerRecoveryRuntimeError.verificationFailed
        }
    }

    private func verifySilentAfterFailure(deviceUID: String?) -> SpeakerRecoveryOutcome {
        guard let deviceUID else { return .failedSafetyUnknown }
        do {
            guard let device = try audio.resolveBuiltInSpeaker(uid: deviceUID) else {
                return .waitingForMatchingDevice
            }
            if audio.supportsWritableMute(on: device) {
                try audio.writeMuted(true, on: device)
            } else {
                try audio.writeVolume(0, on: device)
            }
            return isVerifiedSilent(try audio.readState(of: device))
                ? .failedButVerifiedSilent
                : .failedSafetyUnknown
        } catch {
            return .failedSafetyUnknown
        }
    }

    private func pendingUID() -> String? {
        let result: SpeakerRecoveryLoadResult
        do {
            result = try recoveryStore.load()
        } catch {
            return nil
        }
        guard case let .snapshot(snapshot) = result else { return nil }
        return snapshot.deviceUID
    }

    private func isVerifiedSilent(_ state: AudioDeviceState) -> Bool {
        state.muted || state.volume == 0
    }
}

private enum SpeakerRecoveryRuntimeError: Error {
    case verificationFailed
}

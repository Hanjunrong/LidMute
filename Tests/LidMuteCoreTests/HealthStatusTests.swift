import Foundation
import Testing
@testable import LidMuteCore

@Test func noActiveAudioIsHealthyRatherThanAnError() {
    #expect(CoreAudioHealth.healthyNoActiveOutput != .queryFailed)
}

@Test func unknownRecoverySafetyHasHighestPriority() {
    let snapshot = AppHealthSnapshot(
        coreAudio: .healthyNoActiveOutput,
        lidMonitor: .healthy,
        chrome: .waitingForConnection,
        storage: .healthy,
        recovery: .failedSafetyUnknown
    )
    #expect(snapshot.highestPriority == .critical)
    #expect(snapshot.blocksNormalTermination)
}

@Test func verifiedSilentFailureWarnsButDoesNotBlockTermination() {
    let snapshot = AppHealthSnapshot(
        coreAudio: .healthy(activeOutputCount: 1),
        lidMonitor: .healthy,
        chrome: .degraded,
        storage: .partiallyCorrupt,
        recovery: .failedButVerifiedSilent
    )
    #expect(snapshot.highestPriority == .warning)
    #expect(!snapshot.blocksNormalTermination)
}

@Test func connectedHealthRetainsNativeHostIdentity() {
    let token = UUID()
    let snapshot = AppHealthSnapshot(
        coreAudio: .healthyNoActiveOutput,
        lidMonitor: .healthy,
        chrome: .connected(sessionToken: token, pid: 4312),
        storage: .healthy,
        recovery: .healthy
    )
    #expect(snapshot.chrome == .connected(sessionToken: token, pid: 4312))
}

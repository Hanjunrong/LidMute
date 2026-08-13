import XCTest
@testable import LidMuteCore

final class SpeakerRecoveryRuntimeTests: XCTestCase {
    // This fails if protection writes audio before the recovery snapshot is durable.
    func testProtectPersistsSnapshotBeforeSilencing() async throws {
        let timeline = SharedOperationTimeline()
        let audio = ScriptedAudioController(timeline: timeline)
        let store = MemorySpeakerRecoveryStore(timeline: timeline)
        let runtime = SpeakerRecoveryRuntime(audio: audio, recoveryStore: store, appVersion: "0.1.0")

        _ = await runtime.protect(sources: [.physicalLid])

        XCTAssertEqual(store.operations.first, "save")
        XCTAssertEqual(audio.operations.first, "resolve:nil")
        XCTAssertLessThan(
            try XCTUnwrap(store.timelineIndex(of: "journal.save")),
            try XCTUnwrap(audio.timelineIndex(of: "silence"))
        )
    }

    // This fails if protection gives up after a journaled silence write/read failure without re-silencing.
    func testJournaledProtectionFailuresAreResilencedAndVerified() async {
        for failure in [
            ScriptedAudioController.FailurePoint.initialSilence,
            .initialReadBack,
        ] {
            let store = MemorySpeakerRecoveryStore()
            let runtime = SpeakerRecoveryRuntime(
                audio: ScriptedAudioController(failAt: failure),
                recoveryStore: store,
                appVersion: "0.1.0"
            )

            let outcome = await runtime.protect(sources: [.physicalLid])

            XCTAssertEqual(outcome, .failedButVerifiedSilent, "failure: \(failure)")
            guard case .snapshot = store.loadResult else {
                return XCTFail("journal removed after protection failure: \(failure)")
            }
        }
    }

    // This fails if a failed final unmute is reported unknown despite successful re-silencing and readback.
    func testRestoreFailureThatCanBeResilencedIsVerifiedSilent() async {
        let audio = ScriptedAudioController(
            failAt: .finalUnmute,
            readBack: .init(muted: true, volume: 0.72, usedVolumeFallback: false)
        )
        let runtime = SpeakerRecoveryRuntime(
            audio: audio,
            recoveryStore: MemorySpeakerRecoveryStore.withPendingFixture(),
            appVersion: "0.1.0"
        )

        let outcome = await runtime.recoverPending()
        XCTAssertEqual(outcome, .failedButVerifiedSilent)
    }

    // This fails if any restore write/read failure bypasses the common re-silence verification path.
    func testEveryRestoreWriteAndReadFailureRetainsJournalAndReportsVerifiedSilent() async {
        for failure in [
            ScriptedAudioController.FailurePoint.restoreMute,
            .restoreMuteReadBack,
            .restoreVolume,
            .restoreVolumeReadBack,
            .finalUnmute,
            .finalReadBack,
        ] {
            let store = MemorySpeakerRecoveryStore.withPendingFixture()
            let runtime = SpeakerRecoveryRuntime(
                audio: ScriptedAudioController(failAt: failure),
                recoveryStore: store,
                appVersion: "0.1.0"
            )

            let outcome = await runtime.recoverPending()

            XCTAssertEqual(outcome, .failedButVerifiedSilent, "failure: \(failure)")
            guard case let .snapshot(snapshot) = store.loadResult else {
                return XCTFail("journal removed after restore failure: \(failure)")
            }
            XCTAssertEqual(snapshot.stage, .finalizingRestore, "failure: \(failure)")
        }
    }

    // This fails if a failed re-silence write or its readback is reported as verified safe.
    func testResilenceWriteAndReadFailuresAreSafetyUnknown() async {
        for failure in [
            ScriptedAudioController.FailurePoint.finalUnmuteAndResilence,
            .finalUnmuteAndResilenceReadBack,
        ] {
            let runtime = SpeakerRecoveryRuntime(
                audio: ScriptedAudioController(failAt: failure),
                recoveryStore: MemorySpeakerRecoveryStore.withPendingFixture(),
                appVersion: "0.1.0"
            )

            let outcome = await runtime.recoverPending()

            XCTAssertEqual(outcome, .failedSafetyUnknown, "failure: \(failure)")
        }
    }

    // This fails if recovery claims safety after the final readback cannot establish silence.
    func testRestoreAndResilenceReadbackFailureIsSafetyUnknown() async {
        let audio = ScriptedAudioController(failAt: .readBack)
        let runtime = SpeakerRecoveryRuntime(
            audio: audio,
            recoveryStore: MemorySpeakerRecoveryStore.withPendingFixture(),
            appVersion: "0.1.0"
        )

        let outcome = await runtime.recoverPending()
        XCTAssertEqual(outcome, .failedSafetyUnknown)
    }

    // This fails if recovery writes to the default or cached device when the recorded UID is absent.
    func testMismatchedUIDNeverWritesAnotherDevice() async {
        let audio = ScriptedAudioController(resolvedUIDs: [:])
        let runtime = SpeakerRecoveryRuntime(
            audio: audio,
            recoveryStore: MemorySpeakerRecoveryStore.withPendingFixture(uid: "built-in-a"),
            appVersion: "0.1.0"
        )

        let outcome = await runtime.recoverPending()
        XCTAssertEqual(outcome, .waitingForMatchingDevice)
        XCTAssertFalse(audio.operations.contains { $0.hasPrefix("write") || $0 == "silence" })
    }

    // This fails if malformed or future journals are treated as safe to overwrite.
    func testTypedJournalLoadFailuresBlockRecovery() async {
        let audio = ScriptedAudioController()
        let corrupt = SpeakerRecoveryRuntime(
            audio: audio,
            recoveryStore: MemorySpeakerRecoveryStore(loadResult: .corrupt),
            appVersion: "0.1.0"
        )
        let unsupported = SpeakerRecoveryRuntime(
            audio: audio,
            recoveryStore: MemorySpeakerRecoveryStore(loadResult: .unsupportedSchema(99)),
            appVersion: "0.1.0"
        )

        let corruptOutcome = await corrupt.recoverPending()
        let unsupportedOutcome = await unsupported.recoverPending()
        XCTAssertEqual(corruptOutcome, .corruptSnapshot)
        XCTAssertEqual(unsupportedOutcome, .unsupportedSnapshot(99))
    }

    // This fails if a finalizing journal overwrites an ambiguous current speaker state.
    func testFinalizingRecoveryRefusesAmbiguousStateWithoutWriting() async {
        let audio = ScriptedAudioController(
            readBack: .init(muted: false, volume: 0.31, usedVolumeFallback: false)
        )
        let runtime = SpeakerRecoveryRuntime(
            audio: audio,
            recoveryStore: MemorySpeakerRecoveryStore.withPendingFixture(stage: .finalizingRestore),
            appVersion: "0.1.0"
        )

        let outcome = await runtime.recoverPending()
        XCTAssertEqual(outcome, .failedSafetyUnknown)
        XCTAssertFalse(audio.operations.contains { $0.hasPrefix("write") })
    }

    // This fails if exact post-crash restoration leaves a stale journal behind.
    func testFinalizingRecoveryRecognizesExactOriginalState() async {
        let store = MemorySpeakerRecoveryStore.withPendingFixture(stage: .finalizingRestore)
        let audio = ScriptedAudioController(
            readBack: .init(muted: false, volume: 0.72, usedVolumeFallback: false)
        )
        let runtime = SpeakerRecoveryRuntime(audio: audio, recoveryStore: store, appVersion: "0.1.0")

        let outcome = await runtime.recoverPending()
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(store.loadResult, .none)
        XCTAssertFalse(audio.operations.contains { $0.hasPrefix("write") })
    }
}

import Foundation
import XCTest
@testable import LidMuteCore

final class SpeakerRecoveryStoreTests: XCTestCase {
    // This fails if a saved recovery record loses protected state or permissions.
    func testRoundTripPreservesProtectedSnapshotAndPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lidmute-recovery-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let journalURL = root.appending(path: "speaker-recovery.json")
        let store = FileSpeakerRecoveryStore(url: journalURL)
        let snapshot = SpeakerRecoverySnapshot.fixture(stage: .protected)

        try store.saveBeforeMutation(snapshot)

        XCTAssertEqual(try store.load(), .snapshot(snapshot))
        let directoryMode = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue)
        let fileMode = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: journalURL.path)[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(fileMode & 0o777, 0o600)
    }

    // This fails if unreadable journal data escapes as an untyped decoding error.
    func testCorruptAndUnsupportedSnapshotsAreTypedResults() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lidmute-recovery-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "speaker-recovery.json")

        try Data("not-json".utf8).write(to: url)
        XCTAssertEqual(try FileSpeakerRecoveryStore(url: url).load(), .corrupt)

        try Data(#"{"schemaVersion":999}"#.utf8).write(to: url)
        XCTAssertEqual(try FileSpeakerRecoveryStore(url: url).load(), .unsupportedSchema(999))
    }

    // This fails if a stale or unrelated transaction can finalize or remove another recovery record.
    func testOnlyMatchingTransactionCanFinalizeAndRemoveRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lidmute-recovery-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSpeakerRecoveryStore(url: root.appending(path: "speaker-recovery.json"))
        let snapshot = SpeakerRecoverySnapshot.fixture()

        try store.saveBeforeMutation(snapshot)
        try store.markFinalizingRestore(transactionID: snapshot.transactionID)

        guard case let .snapshot(finalizing) = try store.load() else {
            return XCTFail("missing snapshot")
        }
        XCTAssertEqual(finalizing.stage, .finalizingRestore)
        XCTAssertThrowsError(try store.removeCompleted(transactionID: UUID()))
        try store.removeCompleted(transactionID: snapshot.transactionID)
        XCTAssertEqual(try store.load(), .none)
    }

    // This fails if a newer save can overwrite a still-pending transaction.
    func testSaveRejectsDifferentPendingTransaction() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lidmute-recovery-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSpeakerRecoveryStore(url: root.appending(path: "speaker-recovery.json"))

        try store.saveBeforeMutation(SpeakerRecoverySnapshot.fixture(transactionID: UUID()))
        XCTAssertThrowsError(try store.saveBeforeMutation(SpeakerRecoverySnapshot.fixture(transactionID: UUID())))
    }
}

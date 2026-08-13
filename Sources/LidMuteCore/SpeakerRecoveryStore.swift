import Foundation

public enum SpeakerRecoveryLoadResult: Equatable, Sendable {
    case none
    case snapshot(SpeakerRecoverySnapshot)
    case corrupt
    case unsupportedSchema(Int)
}

public enum SpeakerRecoveryStoreError: Error, Equatable, Sendable {
    case pendingTransaction(UUID)
    case transactionMismatch(expected: UUID, received: UUID)
    case noPendingTransaction
    case unreadableJournal
}

public protocol SpeakerRecoveryStoring: Sendable {
    func load() throws -> SpeakerRecoveryLoadResult
    func saveBeforeMutation(_ snapshot: SpeakerRecoverySnapshot) throws
    func markFinalizingRestore(transactionID: UUID) throws
    func removeCompleted(transactionID: UUID) throws
}

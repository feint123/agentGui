import Foundation

struct PersistedRecoveryItem: Equatable, Sendable, Identifiable {
    let id: UUID
    let sessionID: String
    let sourceKind: RecoverySourceKind
    let sourceIdentifier: String
    let titleText: String
    let summaryText: String
    let handlingState: RecoveryHandlingState
}
import Foundation
import Observation

struct SessionChangeReviewProjection: Equatable, Sendable {
    let sessionID: String
    let pendingProposalCount: Int
    let pendingFileCount: Int
    let proposalIDs: [UUID]

    static func empty(sessionID: String) -> SessionChangeReviewProjection {
        SessionChangeReviewProjection(
            sessionID: sessionID,
            pendingProposalCount: 0,
            pendingFileCount: 0,
            proposalIDs: []
        )
    }
}

@Observable
@MainActor
final class ChangeReviewProjectionStore {
    private(set) var snapshotsByProposalID: [UUID: ChangeProposalReviewSnapshot] = [:]

    func set(_ snapshot: ChangeProposalReviewSnapshot) {
        snapshotsByProposalID[snapshot.proposal.id] = snapshot
    }

    func snapshot(for proposalID: UUID) -> ChangeProposalReviewSnapshot? {
        snapshotsByProposalID[proposalID]
    }

    func projection(forSessionID sessionID: String) -> SessionChangeReviewProjection {
        let matchingSnapshots = snapshotsByProposalID.values.filter {
            $0.proposal.sessionID == sessionID && $0.proposal.state.isPendingReview
        }

        let pendingFileCount = matchingSnapshots.reduce(0) { partialResult, snapshot in
            partialResult + snapshot.fileChanges.filter { $0.state.isPendingReview }.count
        }

        return SessionChangeReviewProjection(
            sessionID: sessionID,
            pendingProposalCount: matchingSnapshots.count,
            pendingFileCount: pendingFileCount,
            proposalIDs: matchingSnapshots.map { $0.proposal.id }.sorted { $0.uuidString < $1.uuidString }
        )
    }
}
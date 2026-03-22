enum ChangeProposalReviewSelectionResolver {
    static func resolve(
        in snapshot: ChangeProposalReviewSnapshot,
        selectedFilePath: String?
    ) -> ProposedFileChangeSnapshot? {
        if let selectedFilePath,
           let explicitlySelected = snapshot.fileChanges.first(where: { $0.relativePath == selectedFilePath }) {
            return explicitlySelected
        }

        if let firstAwaitingDecision = snapshot.fileChanges.first(where: {
            $0.state == .proposed || $0.state == .conflict
        }) {
            return firstAwaitingDecision
        }

        if let firstPending = snapshot.fileChanges.first(where: { $0.state.isPendingReview }) {
            return firstPending
        }

        return snapshot.fileChanges.first
    }
}

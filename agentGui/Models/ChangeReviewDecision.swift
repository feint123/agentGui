import Foundation
import SwiftData

enum ChangeReviewDecisionAction: String, Codable, CaseIterable, Sendable {
    case applyAll
    case applySelected
    case discardProposal
    case discardFiles
    case reopenReview
}

@Model
final class ChangeReviewDecision {
    var id: UUID
    var proposalID: UUID
    var actionRaw: String
    var actorID: String?
    var relativePaths: [String]
    var note: String?
    var createdAt: Date

    var proposal: ChangeProposal?

    init(
        id: UUID = UUID(),
        proposalID: UUID,
        action: ChangeReviewDecisionAction,
        actorID: String? = nil,
        relativePaths: [String] = [],
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.proposalID = proposalID
        self.actionRaw = action.rawValue
        self.actorID = actorID
        self.relativePaths = relativePaths
        self.note = note
        self.createdAt = createdAt
    }
}

extension ChangeReviewDecision {
    var action: ChangeReviewDecisionAction {
        get { ChangeReviewDecisionAction(rawValue: actionRaw) ?? .applyAll }
        set { actionRaw = newValue.rawValue }
    }
}
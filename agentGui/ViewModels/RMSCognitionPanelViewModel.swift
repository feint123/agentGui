import Foundation
import Observation

@MainActor
@Observable
final class RMSPanelViewModel {
    enum Section: String, Equatable, Sendable {
        case frontiers
        case counterexamples
        case constraints
        case verificationDebt
        case suggestedActions
    }

    struct FrontierItem: Identifiable, Equatable {
        let id: String
        let goal: String
        let openClaim: String
        let impactLevel: String
        let suggestedProbe: String
        let stopCondition: String
    }

    struct CounterexampleItem: Identifiable, Equatable {
        let id: String
        let summary: String
        let replacementAction: String
    }

    struct ConstraintItem: Identifiable, Equatable {
        let id: String
        let summary: String
        let scopeSummary: String
    }

    struct VerificationDebtItem: Identifiable, Equatable {
        let id: String
        let claim: String
        let reason: String
    }

    struct SuggestedActionItem: Identifiable, Equatable {
        let id: String
        let summary: String
    }

    struct VerificationSummary: Equatable {
        let frontierCount: Int
        let debtCount: Int
    }

    let state: RMSState

    init(state: RMSState) {
        self.state = state.stableSnapshot()
    }

    var sectionOrder: [Section] {
        [
            .frontiers,
            .counterexamples,
            .constraints,
            .verificationDebt,
            .suggestedActions
        ]
    }

    var frontierItems: [FrontierItem] {
        state.frontiers.map { frontier in
            FrontierItem(
                id: frontier.id,
                goal: frontier.goal,
                openClaim: frontier.openClaim,
                impactLevel: "active",
                suggestedProbe: frontier.suggestedProbe,
                stopCondition: frontier.stopCondition
            )
        }
    }

    var counterexampleItems: [CounterexampleItem] {
        state.counterexamples.map { counterexample in
            CounterexampleItem(
                id: counterexample.id,
                summary: counterexample.summary,
                replacementAction: counterexample.replacementAction
            )
        }
    }

    var constraintItems: [ConstraintItem] {
        state.constraints.map { constraint in
            ConstraintItem(
                id: constraint.id,
                summary: constraint.summary,
                scopeSummary: constraint.scope.displaySummary
            )
        }
    }

    var verificationDebtItems: [VerificationDebtItem] {
        state.verificationDebts.map { debt in
            VerificationDebtItem(id: debt.id, claim: debt.claim, reason: debt.reason)
        }
    }

    var suggestedActionItems: [SuggestedActionItem] {
        state.candidateActions.map { action in
            SuggestedActionItem(id: action, summary: action)
        }
    }

    var verificationSummary: VerificationSummary? {
        let frontierCount = state.frontiers.count
        let debtCount = state.verificationDebts.count

        guard frontierCount > 0 || debtCount > 0 else {
            return nil
        }

        return VerificationSummary(
            frontierCount: frontierCount,
            debtCount: debtCount
        )
    }

    var showDeveloperDiagnosticsByDefault: Bool {
        false
    }

    var openCognitionItemCount: Int {
        frontierItems.count + verificationDebtItems.count
    }

    var requiresAttention: Bool {
        openCognitionItemCount > 0
    }
}

private extension MemoryScope {
    var displaySummary: String {
        switch self {
        case .user:
            return "user"
        case .workspace(let id):
            return "workspace · \(id)"
        case .project(let id):
            return "project · \(id)"
        case .session(let id):
            return "session · \(id)"
        case .thread(let id):
            return "thread · \(id)"
        case .workflowRun(let id):
            return "workflow-run · \(id)"
        }
    }
}
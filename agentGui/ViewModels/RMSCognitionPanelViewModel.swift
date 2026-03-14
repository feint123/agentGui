import Foundation
import Observation

@MainActor
@Observable
final class RMSCognitionPanelViewModel {
    enum Section: String, Equatable, Sendable {
        case frontiers
        case counterexamples
        case constraints
        case verificationDebt
        case influenceTrace
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

    struct InfluenceItem: Identifiable, Equatable {
        enum Kind: String, Equatable {
            case activatedMemory
            case rankedAction
            case blockedAction
            case actionRankingChange
            case blockedPathReason
            case frontierBudgetDecision
        }

        let id: String
        let kind: Kind
        let summary: String
    }

    struct SuggestedActionItem: Identifiable, Equatable {
        let id: String
        let summary: String
    }

    struct DeveloperDiagnostics: Equatable {
        let workingSetCost: Int
        let dereferenceCount: Int
        let retrievalIntentSummary: String
        let postEnforcementPromptChars: Int
        let trimmedCharCount: Int
        let wasFallbackExtractionUsed: Bool
        let jobBacklogCount: Int
        let recentFailedJobSummary: String?
    }

    struct VerificationSummary: Equatable {
        let residualRisk: Double
        let expectedValueOfMoreReasoning: Double
        let frontierCount: Int
        let debtCount: Int
    }

    let snapshot: MemoryRuntimeSnapshot
    let jobBacklogCount: Int
    let recentFailedJobSummary: String?

    convenience init(snapshot: MemoryRuntimeSnapshot) {
        self.init(snapshot: snapshot, jobBacklogCount: 0, recentFailedJobSummary: nil)
    }

    init(snapshot: MemoryRuntimeSnapshot, jobBacklogCount: Int = 0, recentFailedJobSummary: String? = nil) {
        self.snapshot = snapshot
        self.jobBacklogCount = jobBacklogCount
        self.recentFailedJobSummary = recentFailedJobSummary
    }

    var sectionOrder: [Section] {
        [
            .frontiers,
            .counterexamples,
            .constraints,
            .verificationDebt,
            .influenceTrace,
            .suggestedActions
        ]
    }

    var frontierItems: [FrontierItem] {
        let stableState = snapshot.epistemicState.stableSnapshot()
        return stableState.frontiers.map { frontier in
            FrontierItem(
                id: frontier.id,
                goal: frontier.goal,
                openClaim: frontier.openClaim,
                impactLevel: frontier.impactLevel.rawValue,
                suggestedProbe: frontier.suggestedProbe,
                stopCondition: frontier.stopCondition
            )
        }
    }

    var counterexampleItems: [CounterexampleItem] {
        let stableState = snapshot.epistemicState.stableSnapshot()
        return stableState.counterexamples.map { counterexample in
            CounterexampleItem(
                id: counterexample.id,
                summary: counterexample.summary,
                replacementAction: counterexample.replacementAction
            )
        }
    }

    var constraintItems: [ConstraintItem] {
        let stableState = snapshot.epistemicState.stableSnapshot()
        return stableState.activeConstraints.map { constraint in
            ConstraintItem(
                id: constraint.id,
                summary: constraint.summary,
                scopeSummary: constraint.scope.namespace
            )
        }
    }

    var verificationDebtItems: [VerificationDebtItem] {
        let stableState = snapshot.epistemicState.stableSnapshot()
        return stableState.verificationDebt.map { debt in
            VerificationDebtItem(id: debt.id, claim: debt.claim, reason: debt.reason)
        }
    }

    var influenceItems: [InfluenceItem] {
        let activated = snapshot.influenceTrace.activatedMemoryIDs.map {
            InfluenceItem(id: "activated-\($0)", kind: .activatedMemory, summary: $0)
        }
        let ranked = snapshot.influenceTrace.rankedActionIDs.map {
            InfluenceItem(id: "ranked-\($0)", kind: .rankedAction, summary: $0)
        }
        let blocked = snapshot.influenceTrace.blockedActionIDs.map {
            InfluenceItem(id: "blocked-\($0)", kind: .blockedAction, summary: $0)
        }
        let rankingChanges = snapshot.influenceTrace.actionRankingChanges.map {
            InfluenceItem(
                id: "ranking-change-\($0.id)",
                kind: .actionRankingChange,
                summary: "\($0.memoryID): \($0.fromAction) -> \($0.toAction) (\($0.rationale))"
            )
        }
        let blockedReasons = snapshot.influenceTrace.blockedPathReasons.map {
            InfluenceItem(
                id: "blocked-reason-\($0.id)",
                kind: .blockedPathReason,
                summary: "\($0.memoryID): blocked \($0.blockedAction) (\($0.rationale))"
            )
        }
        let frontierBudgets = snapshot.influenceTrace.frontierBudgetDecisions.map {
            InfluenceItem(
                id: "frontier-budget-\($0.id)",
                kind: .frontierBudgetDecision,
                summary: "\($0.frontierID): budget=\($0.allocatedBudget) (\($0.rationale))"
            )
        }
        return activated + ranked + blocked + rankingChanges + blockedReasons + frontierBudgets
    }

    var suggestedActionItems: [SuggestedActionItem] {
        let stableState = snapshot.epistemicState.stableSnapshot()
        return stableState.candidateActions.map { action in
            SuggestedActionItem(id: action, summary: action)
        }
    }

    var developerDiagnostics: DeveloperDiagnostics {
        let wasFallbackExtractionUsed = snapshot.warnings.contains { warning in
            let normalized = warning.lowercased()
            return normalized.contains("fallback") || normalized.contains("fell back")
        }

        return DeveloperDiagnostics(
            workingSetCost: snapshot.metrics.workingSetCost,
            dereferenceCount: snapshot.dereferenceCount,
            retrievalIntentSummary: retrievalIntentSummary,
            postEnforcementPromptChars: snapshot.metrics.postEnforcementPromptChars,
            trimmedCharCount: snapshot.metrics.trimmedCharCount,
            wasFallbackExtractionUsed: wasFallbackExtractionUsed,
            jobBacklogCount: jobBacklogCount,
            recentFailedJobSummary: recentFailedJobSummary
        )
    }

    var verificationSummary: VerificationSummary? {
        let stableState = snapshot.epistemicState.stableSnapshot()
        let residualRisk = stableState.residualRisk
        let expectedValue = stableState.expectedValueOfMoreReasoning
        let frontierCount = stableState.frontiers.count
        let debtCount = stableState.verificationDebt.count

        guard residualRisk > 0 || expectedValue > 0 || frontierCount > 0 || debtCount > 0 else {
            return nil
        }

        return VerificationSummary(
            residualRisk: residualRisk,
            expectedValueOfMoreReasoning: expectedValue,
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

    private var retrievalIntentSummary: String {
        guard let intent = snapshot.plan.retrievalIntent else {
            return "RMS retrieval fallback"
        }

        let objectTypes = intent.neededObjectTypes
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")

        if objectTypes.isEmpty {
            return intent.phase.rawValue
        }

        return "\(intent.phase.rawValue) · \(objectTypes)"
    }
}
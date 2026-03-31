import Foundation

struct AgentTeamMissionBriefDraft: Equatable, Sendable {
    var objective: String
    var constraintsText: String
    var acceptanceCriteriaText: String
    var mode: AgentTeamMode
    var maxActiveProviders: Int
    var tokenBudgetText: String
    var costBudgetText: String
    var initialContextSummary: String
    var sourceSessionTitle: String
    var eligibleProviderIDs: [String]
    var preferredConductorID: String
    var preferredReviewerID: String
    var dispatchPolicy: AgentTeamDispatchPolicy

    init(
        objective: String = "",
        constraintsText: String = "",
        acceptanceCriteriaText: String = "",
        mode: AgentTeamMode = .executionDelivery,
        maxActiveProviders: Int = 2,
        tokenBudgetText: String = "20k",
        costBudgetText: String = "medium",
        initialContextSummary: String = "",
        sourceSessionTitle: String = "",
        eligibleProviderIDs: [String] = [],
        preferredConductorID: String = "",
        preferredReviewerID: String = "",
        dispatchPolicy: AgentTeamDispatchPolicy = .manualSelection
    ) {
        self.objective = objective
        self.constraintsText = constraintsText
        self.acceptanceCriteriaText = acceptanceCriteriaText
        self.mode = mode
        self.maxActiveProviders = maxActiveProviders
        self.tokenBudgetText = tokenBudgetText
        self.costBudgetText = costBudgetText
        self.initialContextSummary = initialContextSummary
        self.sourceSessionTitle = sourceSessionTitle
        self.eligibleProviderIDs = eligibleProviderIDs
        self.preferredConductorID = preferredConductorID
        self.preferredReviewerID = preferredReviewerID
        self.dispatchPolicy = dispatchPolicy
    }
}

extension AgentTeamMissionBriefDraft {
    static func prefilled(from source: Session?) -> Self {
        let sourceTitle = source?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preview = source?.lastMessagePreview.trimmedNonEmpty
        let seededProvider = source?.defaultExecutionProviderReference.persistedValue ?? ""
        return Self(
            objective: defaultObjective(for: sourceTitle),
            constraintsText: "",
            acceptanceCriteriaText: "",
            mode: .executionDelivery,
            maxActiveProviders: 2,
            tokenBudgetText: "20k",
            costBudgetText: "medium",
            initialContextSummary: defaultContextSummary(sourceTitle: sourceTitle, preview: preview),
            sourceSessionTitle: sourceTitle,
            eligibleProviderIDs: seededProvider.isEmpty ? [] : [seededProvider],
            preferredConductorID: seededProvider,
            preferredReviewerID: "",
            dispatchPolicy: seededProvider.isEmpty ? .manualSelection : .sourceSessionSeeded
        )
    }

    static func prefilled(fromSourceContext sourceContext: NewSessionMenuAction.SourceContext?) -> Self {
        let sourceTitle = sourceContext?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let seededProvider = sourceContext?.defaultExecutionProviderReference.persistedValue ?? ""
        return Self(
            objective: defaultObjective(for: sourceTitle),
            constraintsText: "",
            acceptanceCriteriaText: "",
            mode: .executionDelivery,
            maxActiveProviders: 2,
            tokenBudgetText: "20k",
            costBudgetText: "medium",
            initialContextSummary: defaultContextSummary(sourceTitle: sourceTitle, preview: nil),
            sourceSessionTitle: sourceTitle,
            eligibleProviderIDs: seededProvider.isEmpty ? [] : [seededProvider],
            preferredConductorID: seededProvider,
            preferredReviewerID: "",
            dispatchPolicy: seededProvider.isEmpty ? .manualSelection : .sourceSessionSeeded
        )
    }

    func buildBrief() -> AgentTeamMissionBrief {
        AgentTeamMissionBrief(
            objective: resolvedObjective,
            constraints: Self.normalizeLines(from: constraintsText),
            acceptanceCriteria: Self.normalizeLines(from: acceptanceCriteriaText),
            mode: mode,
            dispatchBudget: AgentTeamDispatchBudget(
                maxActiveProviders: max(1, maxActiveProviders)
            ),
            initialContextSummary: resolvedContextSummary,
            providerPlan: buildProviderPlan()
        )
    }

    mutating func reconcileProviderOptions(
        _ options: [ExecutionOptionItem],
        sourceDefaultProviderID: String? = nil
    ) {
        let availableIDs = Set(options.filter(\ .isEnabled).map(\ .id))
        eligibleProviderIDs = eligibleProviderIDs.filter { availableIDs.contains($0) }

        if let sourceDefaultProviderID,
           sourceDefaultProviderID.isEmpty == false,
           availableIDs.contains(sourceDefaultProviderID),
           eligibleProviderIDs.isEmpty {
            eligibleProviderIDs = [sourceDefaultProviderID]
        }

        if preferredConductorID.isEmpty == false,
           eligibleProviderIDs.contains(preferredConductorID) == false {
            preferredConductorID = ""
        }

        if preferredConductorID.isEmpty,
           let firstEligible = eligibleProviderIDs.first {
            preferredConductorID = firstEligible
        }

        if preferredReviewerID.isEmpty == false,
           (eligibleProviderIDs.contains(preferredReviewerID) == false || preferredReviewerID == preferredConductorID) {
            preferredReviewerID = ""
        }

        if let sourceDefaultProviderID,
           sourceDefaultProviderID.isEmpty == false,
           preferredConductorID == sourceDefaultProviderID {
            dispatchPolicy = .sourceSessionSeeded
        } else {
            dispatchPolicy = .manualSelection
        }
    }

    mutating func toggleEligibleProvider(_ persistedValue: String) {
        let normalizedValue = persistedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedValue.isEmpty == false else {
            return
        }

        if let index = eligibleProviderIDs.firstIndex(of: normalizedValue) {
            eligibleProviderIDs.remove(at: index)
        } else {
            eligibleProviderIDs.append(normalizedValue)
        }

        if eligibleProviderIDs.contains(preferredConductorID) == false {
            preferredConductorID = eligibleProviderIDs.first ?? ""
        }

        if preferredReviewerID.isEmpty == false,
           (eligibleProviderIDs.contains(preferredReviewerID) == false || preferredReviewerID == preferredConductorID) {
            preferredReviewerID = ""
        }
    }

    private func buildProviderPlan() -> AgentTeamProviderPlan {
        let eligibleProviders = Self.normalizeProviderReferences(from: eligibleProviderIDs)
        let conductor = Self.resolvePreferredConductor(
            preferredConductorID,
            eligibleProviders: eligibleProviders
        )
        let reviewer = Self.resolvePreferredReviewer(
            preferredReviewerID,
            eligibleProviders: eligibleProviders,
            preferredConductor: conductor
        )

        return AgentTeamProviderPlan(
            eligibleProviders: eligibleProviders,
            preferredConductor: conductor,
            preferredReviewer: reviewer,
            dispatchPolicy: dispatchPolicy
        )
    }

    private var resolvedObjective: String {
        objective.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? Self.defaultObjective(for: sourceSessionTitle)
    }

    private var resolvedContextSummary: String {
        initialContextSummary.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? Self.defaultContextSummary(sourceTitle: sourceSessionTitle, preview: nil)
    }

    private static func defaultObjective(for sourceTitle: String) -> String {
        guard let sourceTitle = sourceTitle.trimmedNonEmpty else {
            return "为独立 Team Mode 会话收敛目标与约束"
        }
        return "围绕 \(sourceTitle) 组织 Team Mode 协作"
    }

    private static func defaultContextSummary(sourceTitle: String, preview: String?) -> String {
        guard let sourceTitle = sourceTitle.trimmedNonEmpty else {
            return "独立 Team Mode 会话，等待补充上下文摘要。"
        }

        guard let preview else {
            return "来源会话：\(sourceTitle)。请补充本次 team 任务的上下文摘要。"
        }

        return "来源会话：\(sourceTitle)。最近上下文：\(preview)"
    }

    private static func normalizeLines(from text: String) -> [String] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private static func normalizeProviderReferences(from persistedValues: [String]) -> [ExecutionProviderReference] {
        var references: [ExecutionProviderReference] = []
        var seen = Set<String>()

        for value in persistedValues {
            let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedValue.isEmpty == false else {
                continue
            }

            let reference = ExecutionProviderReference.decodePersisted(normalizedValue)
            guard seen.insert(reference.persistedValue).inserted else {
                continue
            }
            references.append(reference)
        }

        if references.isEmpty {
            references.append(.builtIn)
        }

        return references
    }

    private static func resolvePreferredConductor(
        _ persistedValue: String,
        eligibleProviders: [ExecutionProviderReference]
    ) -> ExecutionProviderReference {
        let requested = ExecutionProviderReference.decodePersisted(persistedValue)
        if eligibleProviders.contains(requested) {
            return requested
        }
        return eligibleProviders.first ?? .builtIn
    }

    private static func resolvePreferredReviewer(
        _ persistedValue: String,
        eligibleProviders: [ExecutionProviderReference],
        preferredConductor: ExecutionProviderReference
    ) -> ExecutionProviderReference? {
        let normalized = persistedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            return nil
        }

        let reviewer = ExecutionProviderReference.decodePersisted(normalized)
        guard eligibleProviders.contains(reviewer), reviewer != preferredConductor else {
            return nil
        }

        return reviewer
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
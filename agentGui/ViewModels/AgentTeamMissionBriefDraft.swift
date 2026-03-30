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

    init(
        objective: String = "",
        constraintsText: String = "",
        acceptanceCriteriaText: String = "",
        mode: AgentTeamMode = .executionDelivery,
        maxActiveProviders: Int = 2,
        tokenBudgetText: String = "20k",
        costBudgetText: String = "medium",
        initialContextSummary: String = "",
        sourceSessionTitle: String = ""
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
    }
}

extension AgentTeamMissionBriefDraft {
    static func prefilled(from source: Session?) -> Self {
        let sourceTitle = source?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preview = source?.lastMessagePreview.trimmedNonEmpty
        return Self(
            objective: defaultObjective(for: sourceTitle),
            constraintsText: "",
            acceptanceCriteriaText: "",
            mode: .executionDelivery,
            maxActiveProviders: 2,
            tokenBudgetText: "20k",
            costBudgetText: "medium",
            initialContextSummary: defaultContextSummary(sourceTitle: sourceTitle, preview: preview),
            sourceSessionTitle: sourceTitle
        )
    }

    static func prefilled(fromSourceContext sourceContext: NewSessionMenuAction.SourceContext?) -> Self {
        let sourceTitle = sourceContext?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(
            objective: defaultObjective(for: sourceTitle),
            constraintsText: "",
            acceptanceCriteriaText: "",
            mode: .executionDelivery,
            maxActiveProviders: 2,
            tokenBudgetText: "20k",
            costBudgetText: "medium",
            initialContextSummary: defaultContextSummary(sourceTitle: sourceTitle, preview: nil),
            sourceSessionTitle: sourceTitle
        )
    }

    func buildBrief() -> AgentTeamMissionBrief {
        AgentTeamMissionBrief(
            objective: resolvedObjective,
            constraints: Self.normalizeLines(from: constraintsText),
            acceptanceCriteria: Self.normalizeLines(from: acceptanceCriteriaText),
            mode: mode,
            budget: AgentTeamBudget(
                maxActiveProviders: max(1, maxActiveProviders),
                tokenBudgetText: tokenBudgetText.trimmingCharacters(in: .whitespacesAndNewlines),
                costBudgetText: costBudgetText.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            initialContextSummary: resolvedContextSummary
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
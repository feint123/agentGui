import Foundation

/// Builds the initial mission prompt that is dispatched to the conductor ACP
/// provider when a team session is launched.
struct AgentTeamMissionPromptBuilder {

    func buildPrompt(brief: AgentTeamMissionBrief, card: AgentTeamTaskCard) -> String {
        var lines: [String] = []

        lines.append("# Team Mission")
        lines.append("")
        lines.append("**Objective:** \(brief.objective)")

        let trimmedGoal = card.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGoal.isEmpty, trimmedGoal != brief.objective {
            lines.append("")
            lines.append("**Your Task:** \(card.title)")
            lines.append(trimmedGoal)
        }

        if !brief.constraints.isEmpty {
            lines.append("")
            lines.append("**Constraints:**")
            lines.append(contentsOf: brief.constraints.map { "- \($0)" })
        }

        if !brief.acceptanceCriteria.isEmpty {
            lines.append("")
            lines.append("**Acceptance Criteria:**")
            lines.append(contentsOf: brief.acceptanceCriteria.map { "- \($0)" })
        }

        let trimmedContext = brief.initialContextSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedContext.isEmpty {
            lines.append("")
            lines.append("**Context:**")
            lines.append(trimmedContext)
        }

        return lines.joined(separator: "\n")
    }
}

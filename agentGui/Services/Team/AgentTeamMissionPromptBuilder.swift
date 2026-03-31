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

    func buildPrompt(brief: AgentTeamMissionBrief, card: AgentTeamTaskCard, artifacts: [AgentTeamArtifact]) -> String {
        var prompt = buildPrompt(brief: brief, card: card)
        guard !artifacts.isEmpty else { return prompt }
        var lines: [String] = ["", "**Existing Artifacts:**"]
        for artifact in artifacts {
            lines.append("- [\(artifact.kind.rawValue)] \(artifact.title) (by \(artifact.producer)) — \(artifact.summary)")
        }
        prompt += "\n" + lines.joined(separator: "\n")
        return prompt
    }
}

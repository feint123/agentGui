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

// MARK: - Creative Parallelism Prompts

extension AgentTeamMissionPromptBuilder {

    /// 为创意 draft card 构建隔离 prompt。
    /// `draftIndex` 从 0 开始；prompt 明确告知 provider 当前是第几号草案、不参考同组其他草案。
    func buildCreativeDraftPrompt(
        brief: AgentTeamMissionBrief,
        card: AgentTeamTaskCard,
        draftIndex: Int,
        totalDrafts: Int
    ) -> String {
        var lines: [String] = []

        lines.append("# Creative Draft \(draftIndex + 1) / \(totalDrafts)")
        lines.append("")
        lines.append("**任务：草案 \(draftIndex + 1) / \(totalDrafts)**（独立创作，不要参考其他草案）")
        lines.append("")
        lines.append("**Objective:** \(brief.objective)")

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

        lines.append("")
        lines.append("**Instructions:** 请独立产出你的创意方案（`ideaDraft`）。本轮与其他草案完全隔离，其他 provider 的草案对你不可见，请勿尝试参考。")

        return lines.joined(separator: "\n")
    }

    /// 为 synthesis card 构建收敛 prompt，包含所有 ideaDraft artifacts。
    func buildSynthesisPrompt(
        brief: AgentTeamMissionBrief,
        synthesisCard: AgentTeamTaskCard,
        draftArtifacts: [AgentTeamArtifact]
    ) -> String {
        var lines: [String] = []

        lines.append("# Creative Synthesis")
        lines.append("")
        lines.append("**Objective:** \(brief.objective)")

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

        if !draftArtifacts.isEmpty {
            lines.append("")
            lines.append("## 各草案内容")
            for (index, artifact) in draftArtifacts.enumerated() {
                lines.append("")
                lines.append("### 草案 \(index + 1)：\(artifact.title)")
                lines.append("**摘要：** \(artifact.summary)")
                lines.append("")
                lines.append(artifact.payload.textContent)
            }
        }

        lines.append("")
        lines.append("**Instructions:** 请综合（synthesis）以上所有草案，找出各方案的优势与差异，输出一份统一的收敛方案（`finalSynthesis`）。")

        return lines.joined(separator: "\n")
    }
}

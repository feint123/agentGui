import Foundation

struct MemoryPromptAssembler {
    func render(context: MemoryRuntimeContext) -> String {
        if hasEpistemicContent(context.epistemicState) {
            return renderEpistemicContext(context)
        }

        var sections: [String] = []

        let verifiedFacts = context.records.filter {
            $0.layer != .episodic && $0.verificationStatus == .verified && $0.retentionPolicy != .archiveOnly
        }
        let speculativeRecords = context.records.filter {
            $0.layer != .episodic && $0.verificationStatus != .verified && $0.retentionPolicy != .archiveOnly
        }
        let episodicRecords = context.records.filter { $0.layer == .episodic }

        sections.append(renderSection(title: "已验证事实", records: verifiedFacts, emptyState: "暂无已验证事实"))
        sections.append(renderSection(title: "当前推测", records: speculativeRecords, emptyState: "暂无当前推测"))
        sections.append(renderSection(title: "相关事件", records: episodicRecords, emptyState: "暂无相关事件"))
        sections.append(renderWarnings(context.warnings, speculativeRecords: speculativeRecords))

        return sections.joined(separator: "\n\n")
    }

    private func renderEpistemicContext(_ context: MemoryRuntimeContext) -> String {
        var sections: [String] = []
        let state = context.epistemicState

        sections.append(renderFrontiers(state.frontiers))
        sections.append(renderCounterexamples(state.counterexamples))
        sections.append(renderConstraints(state.activeConstraints))
        sections.append(renderVerificationDebt(state.verificationDebt))
        sections.append(renderSupportingFacts(context.records))
        sections.append(renderWarnings(context.warnings, speculativeRecords: context.records.filter { $0.layer != .episodic && $0.verificationStatus != .verified && $0.retentionPolicy != .archiveOnly }))

        return sections.joined(separator: "\n\n")
    }

    private func renderFrontiers(_ frontiers: [FrontierMemory]) -> String {
        let body = frontiers.isEmpty
            ? "- 暂无未决前沿"
            : frontiers.map { frontier in
                "- \(frontier.openClaim)\n  goal: \(frontier.goal)\n  probe: \(frontier.suggestedProbe)\n  stop: \(frontier.stopCondition)"
            }.joined(separator: "\n")
        return "## 未决前沿\n\(body)"
    }

    private func renderCounterexamples(_ counterexamples: [CounterexampleMemory]) -> String {
        let body = counterexamples.isEmpty
            ? "- 暂无激活反例"
            : counterexamples.map { counterexample in
                "- \(counterexample.summary)\n  replacement_action: \(counterexample.replacementAction)"
            }.joined(separator: "\n")
        return "## 激活反例\n\(body)"
    }

    private func renderConstraints(_ constraints: [ConstraintMemory]) -> String {
        let body = constraints.isEmpty
            ? "- 暂无当前约束"
            : constraints.map { "- \($0.summary)" }.joined(separator: "\n")
        return "## 当前约束\n\(body)"
    }

    private func renderVerificationDebt(_ verificationDebt: [VerificationDebt]) -> String {
        let body = verificationDebt.isEmpty
            ? "- 暂无验证债务"
            : verificationDebt.map { debt in
                "- \(debt.claim)\n  reason: \(debt.reason)"
            }.joined(separator: "\n")
        return "## 验证债务\n\(body)"
    }

    private func renderSupportingFacts(_ records: [MemoryRecord]) -> String {
        let supportingFacts = records.filter {
            $0.layer != .episodic && $0.verificationStatus == .verified && $0.retentionPolicy != .archiveOnly
        }
        return renderSection(title: "支持性事实", records: supportingFacts, emptyState: "暂无支持性事实")
    }

    private func hasEpistemicContent(_ state: EpistemicState) -> Bool {
        !state.frontiers.isEmpty ||
        !state.counterexamples.isEmpty ||
        !state.activeConstraints.isEmpty ||
        !state.verificationDebt.isEmpty
    }

    private func renderSection(title: String, records: [MemoryRecord], emptyState: String) -> String {
        let body: String
        if records.isEmpty {
            body = "- \(emptyState)"
        } else {
            body = records.map { record in
                if record.summary.isEmpty || record.summary == record.title {
                    return "- \(record.title)"
                }
                return "- \(record.title)：\(record.summary)"
            }.joined(separator: "\n")
        }

        return "## \(title)\n\(body)"
    }

    private func renderWarnings(_ warnings: [String], speculativeRecords: [MemoryRecord]) -> String {
        let derivedWarnings = speculativeRecords.map { "未验证：\($0.title)" }
        let mergedWarnings = warnings + derivedWarnings
        let body: String = mergedWarnings.isEmpty
            ? "- 暂无风险或待确认项"
            : mergedWarnings.map { "- \($0)" }.joined(separator: "\n")

        return "## 风险与待确认项\n\(body)"
    }
}
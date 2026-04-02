//
//  SkillCatalogPromptRenderer.swift
//  agentGui
//

import Foundation

/// Budget-aware renderer for the Available Skills section of the system prompt.
///
/// Algorithm mirrors Claude Code `src/tools/SkillTool/prompt.ts`:
/// - skills 列表只注入 name + description + whenToUse 的摘要，不内联全文。
/// - 总长度由 charBudget 控制（默认 1% context window = 8000 chars）。
/// - bundled skills 始终保留完整描述；非 bundled 按比例截断。
/// - 极端超预算时，非 bundled 退化为 names-only。
struct SkillCatalogPromptRenderer {

    // MARK: - Constants

    static let skillBudgetContextPercent: Double = 0.01
    static let charsPerToken: Int = 4
    static let defaultCharBudget: Int = 8_000
    static let maxListingDescChars: Int = 250
    static let minDescLength: Int = 20

    // MARK: - Properties

    let charBudget: Int

    // MARK: - Init

    /// - Parameter contextWindowTokens: 当前模型的 context window token 数。若 nil，使用
    ///   `defaultCharBudget`；若提供，动态计算 1% × tokens × 4 chars/token。
    init(contextWindowTokens: Int? = nil) {
        if let tokens = contextWindowTokens {
            self.charBudget = max(
                SkillCatalogPromptRenderer.defaultCharBudget,
                Int(Double(tokens) * Double(SkillCatalogPromptRenderer.charsPerToken)
                    * SkillCatalogPromptRenderer.skillBudgetContextPercent)
            )
        } else {
            self.charBudget = SkillCatalogPromptRenderer.defaultCharBudget
        }
    }

    /// Direct init for testing with a specific budget.
    init(charBudget: Int) {
        self.charBudget = charBudget
    }

    // MARK: - Internal Helpers

    /// Combines description and whenToUse into a single routing description.
    /// Truncates to maxListingDescChars characters.
    func entryDescription(_ skill: Skill) -> String {
        let combined = skill.whenToUse.map { "\(skill.description) - \($0)" } ?? skill.description
        guard combined.count > Self.maxListingDescChars else { return combined }
        let truncated = combined.prefix(Self.maxListingDescChars - 1)
        return truncated + "…"
    }

    // MARK: - Public API

    /// Renders the Available Skills listing segment within the character budget.
    ///
    /// Format: each entry `- name: description`
    /// Result omits the "## Available Skills" header (caller's responsibility).
    func renderSkillListing(_ skills: [Skill]) -> String {
        guard !skills.isEmpty else { return "" }

        let fullEntries = skills.map { skill -> (skill: Skill, entry: String) in
            let desc = entryDescription(skill)
            return (skill: skill, entry: "- \(skill.name): \(desc)")
        }

        // Newlines between entries: N-1 chars for N entries
        let fullTotal = fullEntries.reduce(0) { $0 + $1.entry.count } + (fullEntries.count - 1)

        if fullTotal <= charBudget {
            return fullEntries.map(\.entry).joined(separator: "\n")
        }

        return truncateToBudget(fullEntries: fullEntries, skills: skills)
    }

    // MARK: - Private Helpers

    private func truncateToBudget(
        fullEntries: [(skill: Skill, entry: String)],
        skills: [Skill]
    ) -> String {
        // 1. 分区：bundled（始终保留完整）vs 其余
        var bundledIndices = IndexSet()
        var restSkills: [(index: Int, skill: Skill)] = []
        for (i, skillTuple) in fullEntries.enumerated() {
            if skillTuple.skill.loadedFrom == .bundled {
                bundledIndices.insert(i)
            } else {
                restSkills.append((index: i, skill: skillTuple.skill))
            }
        }

        // 2. bundled 占用的字符（含分隔符 +1 per entry）
        let bundledChars = fullEntries.enumerated().reduce(0) { sum, pair in
            bundledIndices.contains(pair.offset) ? sum + pair.element.entry.count + 1 : sum
        }
        let remainingBudget = charBudget - bundledChars

        // 3. 若无非 bundled skill，直接返回 bundled 全量
        if restSkills.isEmpty {
            return fullEntries.map(\.entry).joined(separator: "\n")
        }

        // 4. 计算非 bundled 可用于描述的字符数
        //    overhead = sum("- name: ".count) + (N-1 separators)
        let nameOverhead = restSkills.reduce(0) { $0 + $1.skill.name.count + 4 }  // "- " + ": " = 4
            + max(0, restSkills.count - 1)
        let availableForDescs = remainingBudget - nameOverhead
        let maxDescLen = restSkills.isEmpty ? 0 : availableForDescs / restSkills.count

        if maxDescLen < Self.minDescLength {
            // 极端超预算：非 bundled 退化为 names-only
            return fullEntries.enumerated().map { (i, pair) in
                bundledIndices.contains(i) ? pair.entry : "- \(pair.skill.name)"
            }.joined(separator: "\n")
        }

        // 5. 按 maxDescLen 截断非 bundled 描述
        return fullEntries.enumerated().map { (i, pair) in
            if bundledIndices.contains(i) { return pair.entry }
            let desc = entryDescription(pair.skill)
            if desc.count <= maxDescLen { return "- \(pair.skill.name): \(desc)" }
            let truncated = desc.prefix(maxDescLen - 1)
            return "- \(pair.skill.name): \(truncated)…"
        }.joined(separator: "\n")
    }
}

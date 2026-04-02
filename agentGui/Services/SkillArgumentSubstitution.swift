//
//  SkillArgumentSubstitution.swift
//  agentGui
//

import Foundation

/// 对 skill SKILL.md 内容执行变量替换，完成 $ARGUMENTS 和内置变量展开。
///
/// 对应 Claude Code `src/skills/loadSkillsDir.ts` → `substituteArguments()`。
enum SkillArgumentSubstitution {

    /// 将 content 中的所有已知占位符替换为具体值。
    ///
    /// 替换列表：
    /// - `$ARGUMENTS` / `${ARGUMENTS}`  → args（nil 时为空字符串）
    /// - `${CLAUDE_SKILL_DIR}`           → skillDirectory 的绝对路径
    /// - `${CLAUDE_SESSION_ID}`          → sessionId
    nonisolated static func substitute(
        content: String,
        args: String?,
        skillDirectory: URL,
        sessionId: String
    ) -> String {
        let argsValue = args ?? ""
        return content
            .replacingOccurrences(of: "${ARGUMENTS}", with: argsValue)
            .replacingOccurrences(of: "$ARGUMENTS", with: argsValue)
            .replacingOccurrences(of: "${CLAUDE_SKILL_DIR}", with: skillDirectory.path)
            .replacingOccurrences(of: "${CLAUDE_SESSION_ID}", with: sessionId)
    }
}

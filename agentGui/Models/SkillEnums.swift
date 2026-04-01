//
//  SkillEnums.swift
//  agentGui
//

import Foundation

/// 技能执行上下文：inline 将 prompt 展开到当前对话；fork 在独立子代理中运行。
/// 对应 SKILL.md frontmatter 的 `context:` 字段。
enum SkillExecutionContext: String, Codable, Sendable, CaseIterable {
    /// 默认：将技能 prompt 作为新 user message 注入当前会话继续执行。
    case inline
    /// 在独立子代理 session 中执行，结果以工具结果形式返回给主 agent。
    case fork
}

/// 技能加载来源，决定去重优先级和 UI 标注。
/// 优先级从高到低：managed > user > project（深→浅）> bundled。
enum SkillSource: String, Codable, Sendable, CaseIterable {
    /// 来自 `~/.claude/skills/`
    case user
    /// 来自 workspace 目录或其祖先目录下的 `.claude/skills/`
    case project
    /// 来自管理员下发的 `~/.claude/managed/.claude/skills/`
    case managed
    /// 与 app 一起打包的内置技能（不依赖磁盘文件）
    case bundled
}

/// 技能 effort 等级，与模型的 `thinking` budget 对应。
/// 对应 SKILL.md frontmatter 的 `effort:` 字段。
/// 值与 Claude Code src/utils/effort.ts 的 EFFORT_LEVELS 保持一致。
enum EffortLevel: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high
    case max
}

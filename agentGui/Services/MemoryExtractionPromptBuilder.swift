import Foundation

/// 生成 memory extraction subagent 的 user prompt（nonisolated）。
///
/// 对齐 Claude Code `buildExtractAutoOnlyPrompt`：
/// - 包含四类型语义指导（user / feedback / project / reference）
/// - 包含 "What NOT to save" 章节
/// - 注入现有 insights 摘要防重复
/// - 指定工具权限（memory_write + 只读）
enum MemoryExtractionPromptBuilder {

    static func build(
        newMessageCount: Int,
        existingInsights: [RMSInsight]
    ) -> String {
        var lines: [String] = []

        // 角色说明
        lines += [
            "You are now acting as the memory extraction subagent.",
            "Analyze the most recent ~\(newMessageCount) messages above and use them to update the persistent memory system.",
            "",
            "Available tools: memory_write (to persist insights), and read-only tools (read_file, bash for ls/cat/stat only).",
            "Do NOT call bash rm or any write-capable shell command. Do NOT call other agents.",
            "You have a limited turn budget — complete extraction in at most 3 turns.",
            "",
            "You MUST only use content from the last ~\(newMessageCount) messages. Do not investigate or verify content further.",
        ]

        // 现有 insights 摘要（防重复写入）
        if !existingInsights.isEmpty {
            lines += [
                "",
                "## Existing memories",
                "",
                "Before writing, check this list to avoid duplicates. Update an existing entry rather than creating a new one if the content is similar.",
                "",
            ]
            for insight in existingInsights {
                lines.append("- [\(insight.id)] \(insight.summary)")
            }
        }

        // 语义类型指导（四类型）
        lines += [
            "",
            "## Types of memory",
            "",
            "There are four types of memory. Use the `semantic_type` field of memory_write to classify each insight:",
            "",
            "<types>",
            "",
            "<type>",
            "  <name>user</name>",
            "  <description>User's role, preferences, goals, and background. Helps tailor future responses.</description>",
            "  <when_to_save>When you learn details about who the user is or how they prefer to work.</when_to_save>",
            "  <how_to_use>Adjust tone, depth, and priorities based on user profile.</how_to_use>",
            "  <examples>User is a senior Swift engineer. User prefers concise responses. User works on macOS-only projects.</examples>",
            "</type>",
            "",
            "<type>",
            "  <name>feedback</name>",
            "  <description>Corrections the user gave or behaviors they explicitly confirmed or rejected.</description>",
            "  <when_to_save>When the user corrects a mistake, confirms an approach, or gives explicit behavioral guidance.</when_to_save>",
            "  <how_to_use>Avoid repeating corrected behaviors; reinforce confirmed approaches.</how_to_use>",
            "  <examples>User said 'don't add comments to unchanged code'. User confirmed TDD-first approach is preferred.</examples>",
            "</type>",
            "",
            "<type>",
            "  <name>project</name>",
            "  <description>Project-specific context: goals, architectural decisions, key deadlines, incidents.</description>",
            "  <when_to_save>When you learn project goals, technical constraints, or significant decisions.</when_to_save>",
            "  <how_to_use>Frame suggestions in terms of project constraints and direction.</how_to_use>",
            "  <examples>This project targets macOS 15+. The SwiftData migration path was decided to use Codable JSON side-car files.</examples>",
            "</type>",
            "",
            "<type>",
            "  <name>reference</name>",
            "  <description>Pointers to external systems, documentation, or resources relevant to future work.</description>",
            "  <when_to_save>When you discover important external information sources, API endpoints, or documentation links.</when_to_save>",
            "  <how_to_use>Surface the reference when the user asks about the same topic.</how_to_use>",
            "  <examples>Anthropic streaming docs: https://docs.anthropic.com/streaming. Xcode test target config: agentGui.xcodeproj scheme 'agentGui'.</examples>",
            "</type>",
            "",
            "</types>",
        ]

        // What NOT to save
        lines += [
            "",
            "## What NOT to save",
            "",
            "Do NOT save anything that can be retrieved from the codebase at any time:",
            "- Code patterns, variable names, or file structure",
            "- Git history or commit messages",
            "- Content already in CLAUDE.md or README",
            "- Transient task progress (use todo list for that)",
            "- Hallucinated or unverified facts",
            "- Any sensitive data (API keys, credentials)",
        ]

        // 保存说明
        lines += [
            "",
            "## How to save",
            "",
            "Call memory_write with:",
            "- `content`: the insight text",
            "- `title`: concise topic label (used as the insight ID base)",
            "- `scope`: 'user' for personal, 'project' for project-scoped",
            "- `semantic_type`: one of user|feedback|project|reference",
            "",
            "If nothing new is worth saving, respond with a short explanation and stop. Do not write trivial or low-value memories.",
        ]

        return lines.joined(separator: "\n")
    }
}

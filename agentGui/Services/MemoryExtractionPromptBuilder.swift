import Foundation

/// 生成 memory extraction subagent 的 user prompt。
///
/// 对齐 Claude Code `buildExtractAutoOnlyPrompt` + `opener()`：
/// - 可注入当前已有记忆文件的 manifest（防重复写入）
/// - 四类型语义指导通过 `MemoryTypeGuidanceComposer` 提供（DRY）
/// - "How to save" 节匹配 M-04 之后 `memory_write` 直接写文件的行为
enum MemoryExtractionPromptBuilder {

    /// 构建 extraction subagent 的 user prompt。
    ///
    /// - Parameters:
    ///   - newMessageCount: 本次需要分析的消息数量，注入给 subagent 作为工作范围提示。
    ///   - existingMemoriesManifest: 已有记忆文件的 manifest（由 `MemoryManifestFormatter` 生成）。
    ///     空字符串时不注入 manifest 节。
    static func build(
        newMessageCount: Int,
        existingMemoriesManifest: String = ""
    ) -> String {
        var lines: [String] = []

        // 角色 + 工作范围
        lines += [
            "You are now acting as the memory extraction subagent.",
            "Analyze the most recent ~\(newMessageCount) messages above and use them to update the persistent memory system.",
            "",
            "Available tools: `memory_write` (writes a topic `.md` file and updates `MEMORY.md` automatically). " +
            "No other write tools are available. Do NOT call bash rm, run_subagent, or any agent tool.",
            "",
            "You have a limited turn budget — complete extraction in at most 3 turns.",
            "Efficient strategy: call all `memory_write` invocations in the same turn (parallel calls).",
            "",
            "You MUST only use content from the last ~\(newMessageCount) messages. " +
            "Do not investigate or verify content further.",
        ]

        // 现有文件 manifest（对齐 Claude Code opener() manifest 块）
        if !existingMemoriesManifest.isEmpty {
            lines += [
                "",
                "## Existing memory files",
                "",
                existingMemoriesManifest,
                "",
                "Check this list before writing — update an existing memory only if the topic is substantially the same. " +
                "Otherwise create a new file. Do NOT manually edit `MEMORY.md` — `memory_write` updates it automatically.",
            ]
        }

        // 型别指导（通过 MemoryTypeGuidanceComposer，与系统提示 DRY）
        let guidance = MemoryTypeGuidanceComposer()
        lines += ["", guidance.typesSection()]
        lines += ["", guidance.whatNotToSaveSection()]

        // 保存说明（extraction-specific：仅用 memory_write，无手动 MEMORY.md 步骤）
        lines += [
            "",
            "## How to save memories",
            "",
            "Call `memory_write` with:",
            "- `content`: the memory body (Markdown text)",
            "- `title`: concise topic label (e.g. `User prefers bun over npm`)",
            "- `type`: `user` | `feedback` | `project` | `reference` (default: `project`)",
            "- `description`: optional one-line hook for MEMORY.md index (≤ 150 chars)",
            "",
            "`memory_write` writes the topic file AND updates `MEMORY.md` automatically.",
            "Do NOT manually write to `MEMORY.md`.",
            "",
            "If nothing new is worth saving, respond with a short explanation and stop. " +
            "Do not write trivial or low-value memories.",
        ]

        return lines.joined(separator: "\n")
    }
}

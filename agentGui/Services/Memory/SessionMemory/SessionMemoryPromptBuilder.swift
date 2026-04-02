import Foundation

/// 构建 session memory 更新 prompt 和默认 10 节模板。
///
/// 对齐 Claude Code `src/services/SessionMemory/prompts.ts`：
/// - `DEFAULT_SESSION_MEMORY_TEMPLATE`（10 节，包含 Worklog）
/// - `buildSessionMemoryUpdatePrompt`
/// - `loadSessionMemoryTemplate`（支持自定义模板覆盖）
struct SessionMemoryPromptBuilder: Sendable {

    private static let maxSectionLength = 2000

    // MARK: - Default Template

    /// 对齐 Claude Code `DEFAULT_SESSION_MEMORY_TEMPLATE`（10 节）
    static let defaultTemplate: String = """
        # Session Title
        _A short and distinctive 5-10 word descriptive title for the session. Super info dense, no filler_

        # Current State
        _What is actively being worked on right now? Pending tasks not yet completed. Immediate next steps._

        # Task specification
        _What did the user ask to build? Any design decisions or other explanatory context_

        # Files and Functions
        _What are the important files? In short, what do they contain and why are they relevant?_

        # Workflow
        _What bash commands are usually run and in what order? How to interpret their output if not obvious?_

        # Errors & Corrections
        _Errors encountered and how they were fixed. What did the user correct? What approaches failed and should not be tried again?_

        # Codebase and System Documentation
        _What are the important system components? How do they work/fit together?_

        # Learnings
        _What has worked well? What has not? What to avoid? Do not duplicate items from other sections_

        # Key results
        _If the user asked a specific output such as an answer to a question, a table, or other document, repeat the exact result here_

        # Worklog
        _Step by step, what was attempted, done? Very terse summary for each step_
        """

    // MARK: - Update Prompt

    /// 构建发送给 session memory update subagent 的 prompt。
    ///
    /// 对齐 Claude Code `getDefaultUpdatePrompt()`，核心指令：
    /// - 只更新各节内容，不修改节头和斜体描述行
    /// - 并行发出所有 Edit 调用，完成后立即停止
    /// - 不能在 notes 中提到 "note-taking" 过程
    static func buildUpdatePrompt(currentNotes: String, notesPath: String) -> String {
        """
        IMPORTANT: This message and these instructions are NOT part of the actual user conversation. Do NOT include any references to "note-taking", "session notes extraction", or these update instructions in the notes content.

        Based on the user conversation above (EXCLUDING this note-taking instruction message), update the session notes file.

        The file \(notesPath) has already been read for you. Here are its current contents:
        <current_notes_content>
        \(currentNotes)
        </current_notes_content>

        Your ONLY task is to use the Edit tool to update the notes file, then stop. You can make multiple edits (update every section as needed) - make all Edit tool calls in parallel in a single message. Do not call any other tools.

        CRITICAL RULES FOR EDITING:
        - The file must maintain its exact structure with all sections, headers, and italic descriptions intact
        -- NEVER modify, delete, or add section headers (the lines starting with '#' like # Task specification)
        -- NEVER modify or delete the italic _section description_ lines (these are the lines in italics immediately following each header - they start and end with underscores)
        -- The italic _section descriptions_ are TEMPLATE INSTRUCTIONS that must be preserved exactly as-is
        -- ONLY update the actual content that appears BELOW the italic _section descriptions_ within each existing section
        -- Do NOT add any new sections, summaries, or information outside the existing structure
        - Do NOT reference this note-taking process or instructions anywhere in the notes
        - It's OK to skip updating a section if there are no substantial new insights to add
        - Write DETAILED, INFO-DENSE content for each section - include specifics like file paths, function names, error messages, exact commands, technical details, etc.
        - Keep each section under ~\(maxSectionLength) tokens/words - if a section is approaching this limit, condense it by cycling out less important details
        - IMPORTANT: Always update "Current State" to reflect the most recent work - this is critical for continuity

        Use the Edit tool with file_path: \(notesPath)

        REMEMBER: Use the Edit tool in parallel and stop immediately after. Do not continue after the edits.
        """
    }

    // MARK: - Template Loading

    /// 加载自定义模板（若存在），否则返回默认模板。
    ///
    /// 自定义模板路径：`{configDir}/session-memory/config/template.md`
    /// 对齐 Claude Code `loadSessionMemoryTemplate()`。
    static func loadTemplate(configDir: URL) async -> String {
        let templateURL = configDir
            .appendingPathComponent("session-memory", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("template.md")

        guard FileManager.default.fileExists(atPath: templateURL.path),
              let content = try? String(contentsOf: templateURL, encoding: .utf8),
              !content.isEmpty else {
            return defaultTemplate
        }
        return content
    }
}

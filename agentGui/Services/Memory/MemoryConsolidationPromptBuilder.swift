import Foundation

/// 为 consolidation subagent 构建 4 阶段 prompt。
///
/// 对齐 Claude Code `consolidationPrompt.ts`，但：
/// - 不依赖 transcript 目录路径（agentGui 用 SwiftData 存会话，subagent 只读内存目录）
/// - 对 Bash 工具的约束改为文案描述（subagent 本身通过工具白名单控制）
struct MemoryConsolidationPromptBuilder: Sendable {

    private static let maxIndexLines = 200
    private static let entrypointName = "MEMORY.md"

    func build(
        memoryDir: URL,
        sessionIds: [String],
        sessionCount: Int
    ) -> String {
        let memPath = memoryDir.path
        let sessionListText = sessionIds.isEmpty
            ? "（无可用 session ID）"
            : sessionIds.map { "- \($0)" }.joined(separator: "\n")

        return """
        # Dream：记忆整合

        你正在执行一次 dream —— 对记忆文件的反思性整理。\
        将最近多个 session 中学到的内容合并为持久、组织良好的记忆，以便未来 session 快速定向。

        记忆目录：`\(memPath)`

        ---

        ## Phase 1 — Orient（定向）

        - 用文件读取工具列出记忆目录，查看已有文件。
        - 读取 `\(Self.entrypointName)` 对现有索引建立全局印象。
        - 快速浏览各话题文件的 frontmatter，避免创建重复文件。
        - 若目录不存在，直接继续到 Phase 3 创建初始记忆。

        ---

        ## Phase 2 — Gather（采集新信号）

        以下 \(sessionCount) 个 session 在上次整合后发生过活动（排除了当前 session）：

        \(sessionListText)

        采集策略（按优先级）：
        1. 检查已有记忆文件中是否有已过时或矛盾的事实（与当前代码库/环境不符）。
        2. 回忆本次运行前 session 中讨论过、多次出现、或明显需要长期记住的信息。
        3. 不要穷举 session 内容——只专注于你已认为重要的信号。

        > **工具约束（本次运行）**：仅使用文件读取工具（read-only：read_file、file_glob、file_search）。
        > 不要执行 Bash 写入命令或修改记忆目录以外的任何文件。

        ---

        ## Phase 3 — Consolidate（整合）

        对每条值得保留的内容，在记忆目录顶层写入或更新对应话题文件。\
        遵循系统 prompt 中 auto-memory 节的文件格式和类型约定。

        重点：
        - 将新信号 **合并** 到已有话题文件，而非创建近似重复。
        - 将相对时间（"昨天"、"上周"）转换为绝对日期，确保日后仍可理解。
        - **删除已被推翻的事实**：若当前调查否定了旧记忆，直接在源文件修正，而不是添加矛盾条目。

        ---

        ## Phase 4 — Prune & Index（修剪索引）

        更新 `\(Self.entrypointName)`，保持 ≤ \(Self.maxIndexLines) 行且 ≤ 25 KB。\
        它是**索引**，不是转储——每行应 ≤ 150 字符：`- [Title](file.md) — 一行摘要`。\
        禁止将记忆内容直接写入索引文件。

        - 删除已过时、错误或已被替代的记忆的指针。
        - 缩短过长的索引行（> 200 字符）：把详细内容移入话题文件。
        - 为新写入的重要记忆添加指针。
        - 解决矛盾：若两个文件描述冲突，修正错误的那个。

        ---

        完成后，返回一段简短摘要：整合了什么、更新了什么、修剪了什么。\
        若记忆已经整洁紧凑，无需改动，也请明确说明。
        """
    }
}

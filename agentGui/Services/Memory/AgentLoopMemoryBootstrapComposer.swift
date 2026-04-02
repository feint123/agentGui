import Foundation

/// Memory bootstrap 注入结果。
/// 当 MEMORY.md 存在且非空时，`systemPromptSection` 为系统提示追加节；否则为 nil。
struct AgentLoopMemoryBootstrapComposition: Sendable {
    /// 要追加到系统提示的记忆节文本。nil 表示无记忆可注入（跳过）。
    var systemPromptSection: String?

    /// 无内容时的默认值
    init() { systemPromptSection = nil }
    init(systemPromptSection: String) { self.systemPromptSection = systemPromptSection }
}

/// 读取 `MEMORY.md` 并格式化为系统提示注入节。
///
/// 对齐 Claude Code `loadMemoryPrompt()` / `buildMemoryLines()` 的核心格式：
/// ```markdown
/// ## Your Memory
///
/// The following are your persistent memories from past sessions.
///
/// <memory>
/// [MEMORY.md content]
/// </memory>
///
/// This directory already exists — write to it directly with the memory_write tool.
/// ```
///
/// nonisolated struct，内部调用同步 `MemoryIndexReader`，适合在任意并发上下文调用。
struct AgentLoopMemoryBootstrapComposer: Sendable {

    let memoryDir: URL
    private let reader: MemoryIndexReader

    init(memoryDir: URL, reader: MemoryIndexReader = MemoryIndexReader()) {
        self.memoryDir = memoryDir
        self.reader = reader
    }

    func compose() -> AgentLoopMemoryBootstrapComposition {
        let indexURL = memoryDir.appendingPathComponent("MEMORY.md")
        guard let result = reader.read(from: indexURL), !result.content.isEmpty else {
            return AgentLoopMemoryBootstrapComposition()
        }
        return AgentLoopMemoryBootstrapComposition(
            systemPromptSection: buildSection(content: result.content)
        )
    }

    // MARK: - Private

    private func buildSection(content: String) -> String {
        """
        ## Your Memory

        The following are your persistent memories from past sessions.

        <memory>
        \(content)
        </memory>

        This directory already exists — write to it directly with the memory_write tool.
        """
    }
}

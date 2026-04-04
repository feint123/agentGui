import Foundation

/// 子代理记忆的存储策略 scope。
///
/// 控制子代理 `MEMORY.md` 及话题文件持久化到哪个目录层级：
/// - `.user`：跨工作区，写入 `~/.agentgui/agent-memory/<agentType>/`
/// - `.project`：项目级共享（可纳入 git），写入 `<workspace>/.agentgui/agent-memory/<agentType>/`
/// - `.local`：本机专用（不纳入 git），写入 `<workspace>/.agentgui/agent-memory-local/<agentType>/`
///
/// 与现有 `MemoryScope` 不同：`MemoryScope` 描述记忆条目在哪个**会话上下文**中产生，
/// 本类型描述记忆文件**持久化到哪个目录**。两者语义不同，不合并。
///
/// 对齐 Claude Code `AgentMemoryScope` (`agentMemory.ts`)。
enum AgentMemoryScope: String, Codable, Sendable, Equatable, CaseIterable {
    /// 跨工作区持久化：~/.agentgui/agent-memory/<agentType>/
    case user
    /// 项目级共享（可纳入 git）：<workspace>/.agentgui/agent-memory/<agentType>/
    case project
    /// 本机专用（不纳入 git）：<workspace>/.agentgui/agent-memory-local/<agentType>/
    case local
}

import Foundation

/// 给定代理类型名和 `AgentMemoryScope`，解析代理专用记忆目录及 MEMORY.md 索引文件的 URL。
///
/// **路径约定（对齐 Claude Code `agentMemory.ts`）：**
/// | scope | 目录 |
/// |-------|------|
/// | `.user` | `<agentguiBaseDir>/agent-memory/<sanitizedType>/` |
/// | `.project` | `<workspaceRoot>/.agentgui/agent-memory/<sanitizedType>/` |
/// | `.local` | `<workspaceRoot>/.agentgui/agent-memory-local/<sanitizedType>/` |
///
/// **安全约束：** 代理类型名经过 `sanitize(_:)` 处理，含 `/`、`..` 或以 `.` 开头的名称
/// 被视为非法路径，返回 `nil`（防止路径遍历攻击）。
struct AgentMemoryPathResolver: Sendable {

    /// 全局 agentgui 配置根目录，通常为 `~/.agentgui/`。
    let agentguiBaseDir: URL

    /// 工作区根目录。`nil` 时 project/local scope 使用 `FileManager.default.currentDirectoryPath`。
    let workspaceRoot: URL?

    // MARK: - Public API

    /// 返回代理记忆目录 URL（isDirectory = true）。
    /// 若 `agentType` 违反安全约束，调用方应使用 `memoryDirOrNil(agentType:scope:)` 代替。
    /// - Note: 不保证目录已存在，创建责任由调用方承担。
    func memoryDir(agentType: String, scope: AgentMemoryScope) -> URL {
        let sanitized = Self.sanitizeOrFallback(agentType)
        return buildDir(sanitizedType: sanitized, scope: scope)
    }

    /// 返回代理记忆目录 URL，若 `agentType` 违反安全约束则返回 `nil`。
    func memoryDirOrNil(agentType: String, scope: AgentMemoryScope) -> URL? {
        guard let sanitized = Self.sanitize(agentType) else { return nil }
        return buildDir(sanitizedType: sanitized, scope: scope)
    }

    /// 返回 MEMORY.md 索引文件 URL。
    func memoryIndexURL(agentType: String, scope: AgentMemoryScope) -> URL {
        memoryDir(agentType: agentType, scope: scope)
            .appendingPathComponent("MEMORY.md")
    }

    // MARK: - Sanitization

    /// 对代理类型名进行路径安全处理：
    /// 1. 将 `:` 替换为 `-`（namespaced plugin 格式，对齐 Claude Code `sanitizeAgentTypeForPath`）
    /// 2. 拒绝含 `/`、`..` 或以 `.` 开头、或为空/纯空白的名称（路径遍历防护）
    ///
    /// - Returns: 安全化后的目录名，或 `nil`（非法输入）。
    static func sanitize(_ agentType: String) -> String? {
        let trimmed = agentType.trimmingCharacters(in: .whitespaces)

        // 空字符串或纯空白拒绝
        guard !trimmed.isEmpty else { return nil }

        // 以 . 开头拒绝（防止隐藏文件名攻击，如 ".env"）
        guard !trimmed.hasPrefix(".") else { return nil }

        // 将 : 替换为 -（先于 / 检查，避免误报）
        let colonReplaced = trimmed.replacingOccurrences(of: ":", with: "-")

        // 含 / 拒绝（路径分隔符）
        guard !colonReplaced.contains("/") else { return nil }

        // 含 .. 模式拒绝（路径遍历）
        let components = colonReplaced.components(separatedBy: "/")
        guard !components.contains("..") else { return nil }

        return colonReplaced
    }

    // MARK: - Private

    private func buildDir(sanitizedType: String, scope: AgentMemoryScope) -> URL {
        switch scope {
        case .user:
            return agentguiBaseDir
                .appendingPathComponent("agent-memory", isDirectory: true)
                .appendingPathComponent(sanitizedType, isDirectory: true)
        case .project:
            return effectiveWorkspaceRoot
                .appendingPathComponent(".agentgui", isDirectory: true)
                .appendingPathComponent("agent-memory", isDirectory: true)
                .appendingPathComponent(sanitizedType, isDirectory: true)
        case .local:
            return effectiveWorkspaceRoot
                .appendingPathComponent(".agentgui", isDirectory: true)
                .appendingPathComponent("agent-memory-local", isDirectory: true)
                .appendingPathComponent(sanitizedType, isDirectory: true)
        }
    }

    private var effectiveWorkspaceRoot: URL {
        workspaceRoot ?? URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    }

    /// 内部辅助：sanitize 失败时以原始名（去除 : 后）fallback，
    /// 仅用于 `memoryDir`（非安全路径的公开入口，调用方理应传入合法名称）。
    private static func sanitizeOrFallback(_ agentType: String) -> String {
        sanitize(agentType) ?? agentType.replacingOccurrences(of: ":", with: "-")
    }
}

import Foundation
import SwiftAnthropic

// MARK: - ToolActivity

/// 单次工具调用的轻量活动记录。
/// 对应 Claude Code `LocalAgentTask.tsx` 的 `ToolActivity` 类型。
struct ToolActivity: Sendable, Equatable, Codable {
    /// 工具 ID，例如 "str_replace_based_edit_tool"
    var toolName: String
    /// 人类可读描述，例如 "Reading ClaudeService.swift"（nil = 未知）
    var activityDescription: String?
    /// 是否为只读操作（view、read_tool_payload、LSP query 等）
    var isRead: Bool
    /// 是否为搜索操作（web_search、bash grep 等）
    var isSearch: Bool
}

// MARK: - SubagentProgress

/// 某时刻的进度快照（不可变，供 UI / S-C4 读取）。
struct SubagentProgress: Sendable {
    var toolUseCount: Int
    var tokenCount: Int
    var recentActivities: [ToolActivity]
    var lastActivity: ToolActivity?
    /// 由 S-C4 SubagentProgressSummarizer 填充的短语（"Reading ClaudeService.swift"）
    var progressSummary: String?
}

// MARK: - SubagentProgressTracker

/// 跨轮次累积的可变进度追踪器。
///
/// **Token 计数语义（与 Claude Code 保持一致）：**
/// - `latestInputTokens` — Claude API 的 `input_tokens` 是每轮**累计**值（含所有历史 context），
///   因此只保存最新值，不累加。公式：
///   `latestInputTokens = inputTokens + cacheCreationInputTokens + cacheReadInputTokens`
/// - `cumulativeOutputTokens` — 每轮独立产出，显式累加。
/// - `tokenCount` = `latestInputTokens + cumulativeOutputTokens`
///
/// **线程安全：** 值类型（struct），存储于 `@MainActor` 的 `AgentLoopRunState` 中。
/// 所有 mutating 操作必须在 `@MainActor` 上调用（`AgentLoopRoundExecutor` 保证）。
struct SubagentProgressTracker: Sendable {

    // MARK: - State

    private(set) var toolUseCount: Int = 0
    private(set) var latestInputTokens: Int = 0
    private(set) var cumulativeOutputTokens: Int = 0
    private(set) var recentActivities: [ToolActivity] = []

    static let maxRecentActivities = 5

    // MARK: - Computed

    var tokenCount: Int { latestInputTokens + cumulativeOutputTokens }
    var lastActivity: ToolActivity? { recentActivities.last }

    // MARK: - Update

    /// 消费一轮 API 响应的 usage + pendingTools，原地更新追踪器状态。
    ///
    /// - Parameters:
    ///   - usage: 该轮 API 响应的 token 用量（nil = API 未返回，安全忽略）
    ///   - pendingTools: 该轮 assistant 消息中解析出的工具调用块
    mutating func update(
        usage: MessageResponse.Usage?,
        pendingTools: [AgentLoopPendingTool]
    ) {
        // 更新 token 计数
        if let usage {
            latestInputTokens = (usage.inputTokens ?? 0)
                + (usage.cacheCreationInputTokens ?? 0)
                + (usage.cacheReadInputTokens ?? 0)
            cumulativeOutputTokens += usage.outputTokens
        }

        // 更新工具活动
        let classifier = SubagentActivityClassifier()
        for tool in pendingTools {
            toolUseCount += 1
            let activity = classifier.classify(toolName: tool.name, input: tool.parsedInput)
            recentActivities.append(activity)
        }

        // 保持 recentActivities 上限
        while recentActivities.count > Self.maxRecentActivities {
            recentActivities.removeFirst()
        }
    }

    // MARK: - Snapshot

    /// 返回当前状态的不可变快照。
    func snapshot(progressSummary: String? = nil) -> SubagentProgress {
        SubagentProgress(
            toolUseCount: toolUseCount,
            tokenCount: tokenCount,
            recentActivities: recentActivities,
            lastActivity: lastActivity,
            progressSummary: progressSummary
        )
    }
}

// MARK: - SubagentActivityClassifier

/// 将工具名称 + 输入映射为可读 `ToolActivity`。
///
/// 对应 Claude Code `createActivityDescriptionResolver` +
/// 各工具的 `getActivityDescription` 方法。
/// 此处使用独立分类器（不修改 `ToolDefinition`），保持 S-C3 最小侵入性。
struct SubagentActivityClassifier: Sendable {

    func classify(
        toolName: String,
        input: MessageResponse.Content.Input
    ) -> ToolActivity {
        switch toolName {

        case "str_replace_based_edit_tool":
            let command = input["command"]?.stringValue ?? "view"
            let path = input["path"]?.stringValue.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            switch command {
            case "view":
                let desc = path.isEmpty ? "Reading file" : "Reading \(path)"
                return ToolActivity(toolName: toolName, activityDescription: desc, isRead: true, isSearch: false)
            case "str_replace":
                let desc = path.isEmpty ? "Editing file" : "Editing \(path)"
                return ToolActivity(toolName: toolName, activityDescription: desc, isRead: false, isSearch: false)
            case "create":
                let desc = path.isEmpty ? "Creating file" : "Creating \(path)"
                return ToolActivity(toolName: toolName, activityDescription: desc, isRead: false, isSearch: false)
            case "insert":
                let desc = path.isEmpty ? "Inserting in file" : "Inserting in \(path)"
                return ToolActivity(toolName: toolName, activityDescription: desc, isRead: false, isSearch: false)
            default:
                return ToolActivity(toolName: toolName, activityDescription: "Using editor", isRead: false, isSearch: false)
            }

        case "bash":
            let command = input["command"]?.stringValue ?? ""
            let preview = command.isEmpty ? "Running command" : "Running: \(String(command.prefix(40)))"
            // grep / rg / find 模式视为 search
            let isSearch = command.hasPrefix("grep") || command.hasPrefix("rg ") || command.hasPrefix("find ")
            return ToolActivity(toolName: toolName, activityDescription: preview, isRead: false, isSearch: isSearch)

        case "web_search", "web_search_brave":
            let query = input["query"]?.stringValue ?? ""
            let desc = query.isEmpty ? "Searching web" : "Searching for \(String(query.prefix(40)))"
            return ToolActivity(toolName: toolName, activityDescription: desc, isRead: false, isSearch: true)

        case "web_fetch":
            let url = input["url"]?.stringValue ?? ""
            let preview = url.isEmpty ? "Fetching URL" : "Fetching \(String(url.prefix(50)))"
            return ToolActivity(toolName: toolName, activityDescription: preview, isRead: true, isSearch: false)

        case "read_tool_payload":
            return ToolActivity(toolName: toolName, activityDescription: "Reading payload", isRead: true, isSearch: false)

        case let lsp where lsp.hasPrefix("lsp_"):
            let pretty = lsp.replacingOccurrences(of: "lsp_", with: "").replacingOccurrences(of: "_", with: " ")
            return ToolActivity(toolName: toolName, activityDescription: "LSP: \(pretty)", isRead: true, isSearch: false)

        case "run_subagent":
            let name = input["agent_name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? FORK_SUBAGENT_TYPE
            return ToolActivity(toolName: toolName, activityDescription: "Launching \(name)", isRead: false, isSearch: false)

        default:
            return ToolActivity(toolName: toolName, activityDescription: nil, isRead: false, isSearch: false)
        }
    }
}

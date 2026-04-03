// agentGui/Services/SubagentGovernance/SubagentProgressSummarizer.swift
import Foundation
import SwiftAnthropic
import SwiftData

// MARK: - SubagentSummaryContext

/// S-C4: 摘要请求所需的 cache-safe 参数快照。
/// 在 `runSubagentLoop` 构建 request 后、启动 loop 前捕获一次。
///
/// **cache 策略：** 与 Claude Code `CacheSafeParams` 对应。
/// 摘要 API 调用使用相同的 `systemPrompt` + `model`，命中 Anthropic prompt cache 中的 system 块。
/// 工具列表传空（SwiftAnthropic ToolChoice 暂不支持 `.none`），导致 tools 层 cache miss，可接受。
struct SubagentSummaryContext: Sendable {
    /// 子代理的系统提示（含 cache_control: ephemeral）
    let systemPrompt: MessageParameter.System?
    /// 子代理使用的模型 ID
    let modelId: String
    /// 用于发起 API 请求的 Anthropic 服务实例
    let service: any AnthropicService
    /// Anthropic API Key（仅用于无法通过 service 注入时的 fallback，一般不需要）
    let apiKey: String
}

// MARK: - SubagentSummaryCallbacks

/// S-C4: SubagentProgressSummarizer 所需的两个注入回调。
///
/// 由 `SubagentBackgroundExecutor` 创建，注入到 `SubagentLaunchClosure` 参数中，
/// 再由生产实现（`ClaudeService.runSubagentLoop`）回调：
/// - `onContextCaptured`: 在 loop 启动前触发一次，提供 cache 参数快照
/// - `onMessagesUpdated`: 每轮 API 结束后触发，提供最新消息快照（用于摘要请求的 context）
struct SubagentSummaryCallbacks: Sendable {
    /// 触发一次：在 runSubagentLoop 构建完请求后、开始第一轮 API 前调用
    let onContextCaptured: @Sendable (SubagentSummaryContext) -> Void
    /// 每轮触发：在 AgentLoopRunner 完成 applyPhaseOutcome 后调用
    let onMessagesUpdated: @Sendable ([MessageParameter.Message]) -> Void
}

// MARK: - SubagentProgressSummarizer

/// S-C4: 后台子代理进度摘要服务。
///
/// 每 30 秒（可配置）向 Claude API 发起单次摘要请求，生成 3-5 词现在进行时标签
/// （如 "Reading ClaudeService.swift"），写入 `SubagentTaskRecord.progressSummary`。
///
/// **设计决策：**
/// - 与 Claude Code `startAgentSummarization` 对应，逻辑完全一致
/// - API 请求使用与子代理相同的 system prompt（cache_control: ephemeral 命中 prompt cache）
///   但传空工具列表（SwiftAnthropic 暂不支持 tool_choice: none）
/// - 计时器使用 `Task.sleep` 循环而非 `DispatchSourceTimer`，防止摘要重叠
/// - 所有错误静默忽略，不影响子代理主 loop
actor SubagentProgressSummarizer {

    // MARK: - Types

    /// 可注入的 API 调用闭包，便于测试 mock。
    /// - Parameters:
    ///   - systemPrompt: 子代理的系统提示（cache-safe）
    ///   - currentMessages: 已过滤的当前消息列表（filterIncompleteToolCalls 后）
    ///   - previousSummary: 上一次摘要文本（nil = 首次），用于避免重复
    /// - Returns: 3-5 词摘要文本，nil 表示模型无输出
    typealias APIProvider = @Sendable (
        _ systemPrompt: MessageParameter.System?,
        _ currentMessages: [MessageParameter.Message],
        _ previousSummary: String?
    ) async throws -> String?

    // MARK: - State

    private let record: SubagentTaskRecord
    private let modelContext: ModelContext
    private let apiProvider: APIProvider
    private let intervalSeconds: Duration

    private(set) var context: SubagentSummaryContext? = nil
    private var latestMessages: [MessageParameter.Message] = []
    private var previousSummary: String? = nil

    private var timerTask: Task<Void, Never>? = nil
    private var isStopped = false

    // MARK: - Init

    /// - Parameters:
    ///   - record: 目标 SubagentTaskRecord（写入 progressSummary 字段）
    ///   - modelContext: 用于触发 save 的 ModelContext（MainActor 上下文）
    ///   - apiProvider: 可注入的 API 调用闭包（生产中由工厂方法构建，测试中 mock）
    ///   - intervalSeconds: 摘要间隔（默认 30s，测试可缩短）
    init(
        record: SubagentTaskRecord,
        modelContext: ModelContext,
        apiProvider: @escaping APIProvider,
        intervalSeconds: Duration = .seconds(30)
    ) {
        self.record = record
        self.modelContext = modelContext
        self.apiProvider = apiProvider
        self.intervalSeconds = intervalSeconds
    }

    // MARK: - Public Interface

    /// 启动摘要定时器（幂等：已运行时无操作）。
    func start() {
        guard timerTask == nil, !isStopped else { return }
        timerTask = Task<Void, Never> { [weak self] in
            await self?.summaryLoop()
        }
    }

    /// 停止摘要定时器，取消进行中的摘要请求（幂等）。
    func stop() {
        isStopped = true
        timerTask?.cancel()
        timerTask = nil
    }

    /// 更新 SubagentSummaryContext（触发一次，在 runSubagentLoop 构建 request 后调用）。
    func updateContext(_ ctx: SubagentSummaryContext) {
        context = ctx
    }

    /// 更新当前消息快照（每轮 API 结束后由 AgentLoopRunner 调用）。
    func updateMessages(_ msgs: [MessageParameter.Message]) {
        latestMessages = msgs
    }

    /// 供外部读取当前 context 的快照（仅用于 apiProvider 闭包内的延迟读取）。
    var contextSnapshot: SubagentSummaryContext? { context }

    // MARK: - Internal: Summary Loop

    private func summaryLoop() async {
        while !isStopped {
            do {
                try await Task.sleep(for: intervalSeconds)
            } catch {
                // Task 被取消，退出循环
                return
            }
            guard !isStopped else { return }
            await runSummary()
        }
    }

    private func runSummary() async {
        // 至少需要 3 条消息
        let cleanMessages = SubagentProgressSummarizer.filterIncompleteToolCalls(latestMessages)
        guard cleanMessages.count >= 3 else {
            debugLog("[S-C4] Skipping summary: only \(cleanMessages.count) messages")
            return
        }

        let currentContext = context  // 可能为 nil（context 尚未注入）
        let prev = previousSummary

        do {
            guard let summary = try await apiProvider(
                currentContext?.systemPrompt,
                cleanMessages,
                prev
            ), !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            debugLog("[S-C4] Summary: \(trimmed)")
            previousSummary = trimmed

            // 写入 SwiftData @Model（必须在 MainActor 上）
            let rec = record
            await MainActor.run {
                rec.progressSummary = trimmed
                try? modelContext.save()
            }
        } catch {
            // 静默降级
            debugLog("[S-C4] Summary API failed: \(error)")
        }
    }

    // MARK: - Static Helpers

    /// 过滤消息列表中"有 tool_use 请求但无对应 tool_result"的 assistant 消息。
    ///
    /// 对应 Claude Code `filterIncompleteToolCalls(messages: Message[])`:
    /// `src/tools/AgentTool/runAgent.ts:866`
    ///
    /// 摘要请求必须传"干净"消息，否则 Anthropic API 会返回 400 Invalid Request
    /// (tool_use block has no corresponding tool_result).
    static func filterIncompleteToolCalls(
        _ messages: [MessageParameter.Message]
    ) -> [MessageParameter.Message] {
        // 收集所有已有 tool_result 的 tool_use_id
        var resolvedToolUseIds = Set<String>()
        for msg in messages {
            guard case .list(let objects) = msg.content else { continue }
            for obj in objects {
                if case .toolResult(let id, _, _, _) = obj {
                    resolvedToolUseIds.insert(id)
                }
            }
        }

        // 过滤掉含未解析 tool_use 的 assistant 消息
        return messages.filter { msg in
            guard msg.role == MessageParameter.Message.Role.assistant.rawValue,
                  case .list(let objects) = msg.content else {
                return true
            }
            let hasOrphanedToolUse = objects.contains { obj in
                if case .toolUse(let id, _, _) = obj {
                    return !resolvedToolUseIds.contains(id)
                }
                return false
            }
            return !hasOrphanedToolUse
        }
    }
}

// MARK: - Summary Prompt Builder

extension SubagentProgressSummarizer {

    /// 构建摘要请求的 user prompt。
    ///
    /// 对应 Claude Code `buildSummaryPrompt(previousSummary: string | null)`:
    /// `src/services/AgentSummary/agentSummary.ts:28`
    static func buildSummaryPrompt(previousSummary: String?) -> String {
        let prevLine: String
        if let prev = previousSummary, !prev.isEmpty {
            prevLine = "\nPrevious: \"\(prev)\" — say something NEW.\n"
        } else {
            prevLine = ""
        }

        return """
        Describe your most recent action in 3-5 words using present tense (-ing). \
        Name the file or function, not the branch. Do not use tools.
        \(prevLine)
        Good: "Reading runAgent.ts"
        Good: "Fixing null check in validate.ts"
        Good: "Running auth module tests"
        Good: "Adding retry logic to fetchUser"

        Bad (past tense): "Analyzed the branch diff"
        Bad (too vague): "Investigating the issue"
        Bad (too long): "Reviewing full branch diff and AgentTool.tsx integration"
        Bad (branch name): "Analyzed adam/background-summary branch diff"
        """
    }
}

// MARK: - Debug Log Helper

private func debugLog(_ message: String) {
    #if DEBUG
    print(message)
    #endif
}

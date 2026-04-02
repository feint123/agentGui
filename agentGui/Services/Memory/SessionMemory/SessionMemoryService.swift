import Foundation
import SwiftAnthropic
import SwiftData

/// Session Memory 更新服务。
///
/// 职责：
/// 1. 检查 token/tool call 阈值（委托给 `SessionMemoryState`）
/// 2. 初始化 `summary.md`（首次时写入模板）
/// 3. 读取当前 notes 内容
/// 4. 启动 subagent（`str_replace_based_edit_tool` + `read_file`）更新 notes
///
/// 对齐 Claude Code `extractSessionMemory` + `setupSessionMemoryFile`。
struct SessionMemoryService: Sendable {

    let claudeService: ClaudeService
    let settings: AppSettings
    let sessionId: String
    let modelContext: ModelContext
    let sessionMemoryState: SessionMemoryState

    // MARK: - Public: Callback Builder

    /// 构建 hook callback，供 `SessionMemoryHook` 使用。
    func buildCallback() -> @Sendable (AgentLoopHookContext) async -> Void {
        let capturedService = claudeService
        let capturedSettings = settings
        let capturedSessionId = sessionId
        let capturedModelContext = modelContext
        let capturedState = sessionMemoryState

        return { @Sendable context in
            let estimatedTokens = SessionMemoryService.estimateTokens(from: context.messagesSnapshot)
            let toolCallsThisRound = (context.metadata["toolCallsThisRound"] as? Int) ?? 0

            guard await capturedState.shouldExtract(
                estimatedTokens: estimatedTokens,
                toolCallsThisRound: toolCallsThisRound
            ) else { return }

            guard await capturedState.beginExtraction() else { return }

            do {
                try await SessionMemoryService.performUpdate(
                    context: context,
                    claudeService: capturedService,
                    settings: capturedSettings,
                    sessionId: capturedSessionId,
                    modelContext: capturedModelContext
                )
                await capturedState.recordExtraction(estimatedTokens: estimatedTokens)
            } catch {
                #if DEBUG
                print("[SessionMemoryService] update error: \(error)")
                #endif
            }
            await capturedState.finishExtraction()
        }
    }

    // MARK: - Internal: Core Update Logic

    static func performUpdate(
        context: AgentLoopHookContext,
        claudeService: ClaudeService,
        settings: AppSettings,
        sessionId: String,
        modelContext: ModelContext
    ) async throws {
        let summaryURL = ConfigDirectoryManager.shared.sessionMemorySummaryURL(sessionId: sessionId)

        // 1. 加载模板（支持自定义）
        let template = await SessionMemoryPromptBuilder.loadTemplate(
            configDir: ConfigDirectoryManager.shared.agentGuiDir
        )

        // 2. 初始化 summary.md（不覆盖已有内容）
        try await ensureSummaryFileExists(at: summaryURL, template: template)

        // 3. 读取当前 notes
        let currentNotes = (await readSummaryContent(at: summaryURL)) ?? template

        // 4. 构建 update prompt
        let updatePrompt = SessionMemoryPromptBuilder.buildUpdatePrompt(
            currentNotes: currentNotes,
            notesPath: summaryURL.path
        )

        // 5. 构建受限工具集：str_replace_based_edit_tool + read_file
        let tools = await claudeService.buildSessionMemoryTools(settings: settings)
        guard !tools.isEmpty else { return }

        // 6. 组装消息：对话快照 + update prompt
        var loopMessages = context.messagesSnapshot
        loopMessages.append(.init(role: .user, content: .text(updatePrompt)))

        guard let service = await claudeService.service else { return }

        // 7. 启动 subagent（对齐 Claude Code runForkedAgent，单次完成后停止）
        let request = AgentLoopRunRequest(
            service: service,
            modelId: settings.selectedModel,
            tools: tools,
            system: await claudeService.makeEphemeralSystemPrompt(""),
            maxRounds: 3,
            toolExecutionContext: .backgroundTask,
            toolApprovalMode: .bypassApprovals,
            runSource: "sessionMemory",
            runLabel: "Session memory update",
            requestedBudgetSeconds: nil
        )
        let runtime = AgentLoopRuntime(
            settings: settings,
            session: nil,
            sessionId: sessionId,
            modelContext: modelContext,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none,
            toolInterceptor: nil,
            remoteDeliveryHandle: nil
        )

        _ = try await claudeService.runCoreAgentLoop(
            messages: &loopMessages,
            request: request,
            runtime: runtime
        )
    }

    // MARK: - Internal: File Helpers

    /// 确保 `summary.md` 存在。若不存在则创建并写入模板；若已存在则不修改。
    static func ensureSummaryFileExists(at url: URL, template: String) async throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        guard !fm.fileExists(atPath: url.path) else { return }
        try template.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 读取 `summary.md` 内容。文件不存在时返回 nil。
    static func readSummaryContent(at url: URL) async -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Internal: Token Estimation

    /// 粗估消息列表的 token 数。
    ///
    /// 对齐 Claude Code `tokenCountWithEstimation`：chars / 4（不调用 API，纯本地估算）。
    static func estimateTokens(from messages: [MessageParameter.Message]) -> Int {
        let totalChars = messages.reduce(0) { acc, msg in
            acc + messageCharCount(msg)
        }
        return totalChars / 4
    }

    private static func messageCharCount(_ msg: MessageParameter.Message) -> Int {
        switch msg.content {
        case .text(let t):
            return t.count
        case .list(let items):
            return items.reduce(0) { acc, item in
                switch item {
                case .text(let t): return acc + t.count
                case .toolResult(_, let content, _, _): return acc + content.count
                default: return acc
                }
            }
        }
    }
}

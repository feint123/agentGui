//
//  ClaudeService.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

// MARK: - Claude Service

/// Claude API 服务，使用 SwiftAnthropic 与 Claude 交互
@Observable
@MainActor
final class ClaudeService {

    // MARK: - Observable State

    var isStreaming: Bool = false
    var lastError: String?

    /// 当 Claude 调用 ask_user_question 时设置，触发 ChatView 弹出问题 sheet
    var pendingUserQuestion: AskUserQuestionRequest?

    /// 当前请求的输入 token 数（来自 message_start 事件）
    var currentInputTokens: Int = 0

    /// 当前正在使用的模型 ID（用于计算上下文窗口大小）
    var currentModelId: String = ""

    // MARK: - Context Window Helpers

    /// 根据模型 ID 返回上下文窗口大小（tokens）
    func contextWindowSize(for modelId: String) -> Int {
        // Claude 3.5 Haiku / all Claude 4 series: 200k
        return 200_000
    }

    /// 当前上下文使用率（0.0 ~ 1.0）
    var contextUsageRatio: Double {
        let windowSize = contextWindowSize(for: currentModelId)
        guard windowSize > 0, currentInputTokens > 0 else { return 0 }
        return Double(currentInputTokens) / Double(windowSize)
    }

    // MARK: - Internal Storage

    var service: (any AnthropicService)?

    /// 每个 Session 对应一个持久化 bash session（key = sessionId）
    var bashSessions: [String: BashSession] = [:]

    /// 每个 Session 对应一个 bash task registry（key = sessionId）
    var bashTaskRegistries: [String: BashTaskRegistry] = [:]

    /// 每个 Session 的 TodoList（key = sessionId）
    var sessionTodoLists: [String: [TodoItem]] = [:]

    /// 每个 Session 的完成验证记录（key = sessionId）
    var sessionVerifications: [String: CompletionVerification] = [:]

    /// 每个 Session 已观察到的执行证据（key = sessionId）
    var sessionExecutionEvidence: [String: Set<ExecutionEvidenceKind>] = [:]

    /// Skill service reference for tool dispatch and system prompt
    var skillService: SkillService?

    /// Shared payload store for large tool outputs that should not be injected inline.
    var toolPayloadStore = ToolPayloadStore()

    /// Shared budget controller used to shape large tool results before they are appended to the model context.
    var toolResultBudgetController = ToolResultBudgetController()

    /// Lazily configured LSP server manager used by semantic code tools.
    var lspServerManager: LSPServerManager?

    func makeEphemeralSystemPrompt(_ prompt: String) -> MessageParameter.System? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return .list([
            .init(text: trimmed, cacheControl: .init(type: .ephemeral))
        ])
    }

    func makeEphemeralTool(
        name: String,
        description: String? = nil,
        inputSchema: JSONSchema? = nil
    ) -> MessageParameter.Tool {
        .function(
            name: name,
            description: description,
            inputSchema: inputSchema,
            cacheControl: .init(type: .ephemeral)
        )
    }

    /// Optional structured business log sink used by tests and future observability integration.
    var businessLogSink: BusinessLogSink?

    /// Workflow runtime — injected from the app root after creation.
    var workflowRuntime: WorkflowRuntime?

    /// Workspace context snapshot captured at the start of each send, used by start_workflow.
    var currentWorkspaceContext: WorkflowWorkspaceContext = .empty

    /// The Session currently being processed, used by start_workflow.
    var currentSession: Session?

    // MARK: - Configuration

    var isConfigured: Bool { service != nil }

    func configure(apiKey: String, baseURL: String = "", settings: AppSettings? = nil) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { service = nil; return }
        let basePath = baseURL.trimmingCharacters(in: .whitespaces)

        #if !os(Linux)
        let httpClient: HTTPClient? = settings.map { ConfigurableHTTPClient(settings: $0) }
        #else
        let httpClient: HTTPClient? = nil
        #endif

        if basePath.isEmpty {
            service = AnthropicServiceFactory.service(
                apiKey: trimmed,
                betaHeaders: nil,
                httpClient: httpClient
            )
        } else {
            service = AnthropicServiceFactory.service(
                apiKey: trimmed,
                basePath: basePath,
                betaHeaders: nil,
                httpClient: httpClient,
                debugEnabled: false
            )
        }
    }

    func applyConnectionSettings(_ settings: AppSettings) {
        configure(apiKey: settings.apiKey, baseURL: settings.baseURL, settings: settings)
        resetBashSessions()
    }

    func resetBashSessions() {
        let existingSessions = Array(bashSessions.values)
        bashSessions.removeAll()
        bashTaskRegistries.removeAll()
        for session in existingSessions {
            Task {
                await session.terminate()
            }
        }
    }
}

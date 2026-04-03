import Foundation
import SwiftAnthropic

/// 一次 agent loop 的纯输入。
/// 这里不放持久化对象和 UI 投影依赖，避免执行器在调用链上顺手拿到所有运行时对象。
struct AgentLoopRunRequest {
    let service: any AnthropicService
    let modelId: String
    let tools: [MessageParameter.Tool]
    let system: MessageParameter.System?
    let maxRounds: Int
    let toolExecutionContext: ToolContext
    let toolApprovalMode: ToolApprovalMode
    let runSource: String
    let runLabel: String?
    let requestedBudgetSeconds: TimeInterval?
    /// 每轮 user-message 前重新注入的短提醒（nil = 不注入）。由 S-A5 引入。
    let criticalReminder: String?
    /// S-F3: 主代理已渲染的系统提示文本，供 fork 子代理直接复用以命中 prompt cache。
    /// 仅主代理 loop 设置此字段；subagent loop 保持 nil。
    let renderedSystemPromptText: String?

    init(
        service: any AnthropicService,
        modelId: String,
        tools: [MessageParameter.Tool],
        system: MessageParameter.System?,
        maxRounds: Int,
        toolExecutionContext: ToolContext,
        toolApprovalMode: ToolApprovalMode,
        runSource: String,
        runLabel: String?,
        requestedBudgetSeconds: TimeInterval?,
        criticalReminder: String? = nil,
        renderedSystemPromptText: String? = nil   // S-F3
    ) {
        self.service = service
        self.modelId = modelId
        self.tools = tools
        self.system = system
        self.maxRounds = maxRounds
        self.toolExecutionContext = toolExecutionContext
        self.toolApprovalMode = toolApprovalMode
        self.runSource = runSource
        self.runLabel = runLabel
        self.requestedBudgetSeconds = requestedBudgetSeconds
        self.criticalReminder = criticalReminder
        self.renderedSystemPromptText = renderedSystemPromptText   // S-F3
    }
}
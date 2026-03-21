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
}
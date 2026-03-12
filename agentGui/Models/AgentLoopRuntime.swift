import SwiftAnthropic
import SwiftData

/// 与当前运行环境绑定的依赖集合。
/// 这些值往往是引用类型、持久化上下文或回调，不适合作为 request 的一部分跨层传播。
struct AgentLoopRuntime {
    let settings: AppSettings
    let session: Session?
    let sessionId: String
    let modelContext: ModelContext
    let makeRound: (Int) -> AgentRound
    let parentMessage: Message?
    let streamProjectionTarget: AgentLoopStreamProjectionTarget
    let toolInterceptor: ((String, MessageResponse.Content.Input) async -> ToolExecutionResult?)?
}
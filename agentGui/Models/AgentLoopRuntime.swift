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
    let remoteDeliveryHandle: (any RemoteTurnDeliveryHandle)?
    /// S-C3: 子代理进度回调（nil = 主代理 loop，不追踪进度）。
    /// 每轮 API 响应结束后由 `AgentLoopRoundExecutor.executeStreamingRound` 调用。
    /// 标注 `@MainActor` 保证 SwiftData `@Model` 字段写入在主线程，且调用时无需 `await`。
    let subagentProgressUpdate: (@MainActor @Sendable (SubagentProgress) -> Void)?

    init(
        settings: AppSettings,
        session: Session?,
        sessionId: String,
        modelContext: ModelContext,
        makeRound: @escaping (Int) -> AgentRound,
        parentMessage: Message?,
        streamProjectionTarget: AgentLoopStreamProjectionTarget,
        toolInterceptor: ((String, MessageResponse.Content.Input) async -> ToolExecutionResult?)?,
        remoteDeliveryHandle: (any RemoteTurnDeliveryHandle)? = nil,
        subagentProgressUpdate: (@MainActor @Sendable (SubagentProgress) -> Void)? = nil
    ) {
        self.settings = settings
        self.session = session
        self.sessionId = sessionId
        self.modelContext = modelContext
        self.makeRound = makeRound
        self.parentMessage = parentMessage
        self.streamProjectionTarget = streamProjectionTarget
        self.toolInterceptor = toolInterceptor
        self.remoteDeliveryHandle = remoteDeliveryHandle
        self.subagentProgressUpdate = subagentProgressUpdate
    }
}
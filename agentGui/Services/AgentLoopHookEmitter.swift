import Foundation
import SwiftAnthropic

/// HookContext 的差异化覆盖项。
/// 运行时公共字段由 emitter 自动填充，调用方只提供本次 stage 特有的数据。
struct HookContextOverrides {
    var metadata: [String: Any] = [:]
    var toolName: String? = nil
    var projectedText: String? = nil
    var currentRoundText: String? = nil
    var currentRoundThinking: String? = nil
    var toolInput: MessageResponse.Content.Input? = nil
    var toolResultText: String? = nil
    var toolCallRecord: ToolCall? = nil

    nonisolated init(
        metadata: [String: Any] = [:],
        toolName: String? = nil,
        projectedText: String? = nil,
        currentRoundText: String? = nil,
        currentRoundThinking: String? = nil,
        toolInput: MessageResponse.Content.Input? = nil,
        toolResultText: String? = nil,
        toolCallRecord: ToolCall? = nil
    ) {
        self.metadata = metadata
        self.toolName = toolName
        self.projectedText = projectedText
        self.currentRoundText = currentRoundText
        self.currentRoundThinking = currentRoundThinking
        self.toolInput = toolInput
        self.toolResultText = toolResultText
        self.toolCallRecord = toolCallRecord
    }
}

@MainActor
/// 统一负责 HookContext 装配和 hook / business event 发射。
/// 这层的目的是把 run-time state 到 hook context 的映射收敛到一个地方，避免每个调用点重复拼 metadata。
struct AgentLoopHookEmitter {
    let dispatcher: AgentLoopHookDispatcher
    let request: AgentLoopRunRequest
    let runtime: AgentLoopRuntime
    let businessLogSink: BusinessLogSink?

    func makeContext(
        state: AgentLoopRunState,
        messages: [MessageParameter.Message],
        overrides: HookContextOverrides = .init()
    ) -> AgentLoopHookContext {
        var context = AgentLoopHookContext(
            runID: state.runID,
            sessionID: runtime.sessionId,
            workflowID: nil,
            executionContext: request.toolExecutionContext,
            modelId: request.modelId,
            roundIndex: state.loopCtx.roundIndex,
            phase: state.loopCtx.phase.label
        )
        context.pendingToolName = overrides.toolName
        context.stopReason = state.loopCtx.lastStopReason
        context.failureTrigger = state.loopCtx.pendingFailureTrigger
        context.accumulatedText = overrides.projectedText ?? state.accumulatedText
        // currentRoundText 的默认语义需要与重构前保持一致：显式覆盖优先，其次 projectedText，最后回退到 accumulatedText。
        context.currentRoundText = overrides.currentRoundText ?? overrides.projectedText ?? state.accumulatedText
        context.currentRoundThinking = overrides.currentRoundThinking ?? ""
        context.messagesSnapshot = messages
        context.metadata = overrides.metadata
        context.streamProjectionTarget = runtime.streamProjectionTarget
        context.toolInput = overrides.toolInput ?? [:]
        context.toolResultText = overrides.toolResultText ?? ""
        context.toolCallRecord = overrides.toolCallRecord
        return context
    }

    func emit(
        _ stage: AgentLoopHookStage,
        state: AgentLoopRunState,
        messages: [MessageParameter.Message],
        overrides: HookContextOverrides = .init()
    ) async {
        // 观察型 hook 容错处理沿用旧逻辑：失败不会打断主循环。
        let context = makeContext(state: state, messages: messages, overrides: overrides)
        _ = try? await dispatcher.dispatch(stage, context: context)
    }

    func dispatch(
        _ stage: AgentLoopHookStage,
        state: AgentLoopRunState,
        messages: [MessageParameter.Message],
        overrides: HookContextOverrides = .init()
    ) async throws -> AgentLoopHookDispatchResult {
        let context = makeContext(state: state, messages: messages, overrides: overrides)
        return try await dispatcher.dispatch(stage, context: context)
    }

    func emitBusinessEvent(
        _ event: AgentBusinessEvent,
        state: AgentLoopRunState,
        metadata: [String: Any] = [:]
    ) {
        // Business event 不走 hook dispatcher，它只消费统一的 run / phase / round 维度上下文。
        let context = BusinessLogContext(
            runID: state.runID,
            sessionID: runtime.sessionId.isEmpty ? nil : runtime.sessionId,
            roundIndex: state.loopCtx.roundIndex,
            phase: state.loopCtx.phase.label
        )
        BusinessMonitor.emit(event, context: context, metadata: metadata, sink: businessLogSink)
    }
}
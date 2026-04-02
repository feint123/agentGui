import Foundation

struct AgentLoopBuiltInHookFactory {
    final class State {
        var lastRound: AgentRound?
        var verificationState: VerificationState?
        var memoryRuntimeProfiles: [String] = []
        var memoryRuntimeLayers: [String] = []
        var memoryRuntimeWarnings: [String] = []
        var memoryRuntimeSnapshotID: String?
        var memoryRuntimeIntentPhase: String?
        var memoryRuntimeWorkingSetCost: Int?
        var memoryRuntimeDereferenceCount: Int?
    }

    struct Dependencies {
        let businessLogSink: BusinessLogSink?
        /// Bootstrap loader：返回要追加到系统提示的 Memory 节文本，nil 表示跳过注入。
        let memoryBootstrapLoader: (State) async throws -> String?
        let createToolCallRecord: (AgentLoopHookContext, State) async throws -> ToolCall
        let updateToolCallRecord: (AgentLoopHookContext, State) async throws -> Void
        // M-03: 会话末记忆自动提取回调
        let extractMemoriesCallback: @Sendable (AgentLoopHookContext) async -> Void
        // M-05: 中段记忆召回服务
        let memoryRecallService: (any MemoryRecallServiceProtocol)?
        // M-11: 会话内 session memory 自动更新回调
        let sessionMemoryCallback: @Sendable (AgentLoopHookContext) async -> Void
    }

    func makeHooks(
        dependencies: Dependencies,
        state: State
    ) -> [any AgentLoopHook] {
        [
            StreamProjectionHook(),
            RemoteChannelProjectionHook(),
            MemoryBootstrapHook { _ in
                try await dependencies.memoryBootstrapLoader(state)
            },
            ToolAuditHook(
                sink: dependencies.businessLogSink,
                createRecord: { context in
                    try await dependencies.createToolCallRecord(context, state)
                },
                updateRecord: { context in
                    try await dependencies.updateToolCallRecord(context, state)
                }
            ),
            FailureClassificationHook(),
            BusinessObservabilityHook(sink: dependencies.businessLogSink),
            // M-11: 每轮结束后更新 session memory notes（order=85，在 ExtractionHook(90) 前）
            SessionMemoryHook(callback: dependencies.sessionMemoryCallback),
            // M-03: 会话末记忆自动提取
            MemoryExtractionHook(callback: dependencies.extractMemoriesCallback),
            // M-05: 中段记忆召回
            MemoryRecallHook(recallService: dependencies.memoryRecallService),
        ]
    }
}
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
        let memoryBootstrapLoader: (State) async throws -> AgentLoopMessagePatch?
        let createToolCallRecord: (AgentLoopHookContext, State) async throws -> ToolCall
        let updateToolCallRecord: (AgentLoopHookContext, State) async throws -> Void
        // M-03: 会话末记忆自动提取回调
        let extractMemoriesCallback: @Sendable (AgentLoopHookContext) async -> Void
        // M-05: 中段记忆召回服务
        let memoryRecallService: (any MemoryRecallServiceProtocol)?
        // M-06: 后台记忆整合 Daemon callback
        let consolidationCallback: @Sendable (AgentLoopHookContext) async -> Void
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
            // M-03: 会话末记忆自动提取
            MemoryExtractionHook(callback: dependencies.extractMemoriesCallback),
            // M-05: 中段记忆召回
            MemoryRecallHook(recallService: dependencies.memoryRecallService),
            // M-06: 后台记忆整合
            MemoryConsolidationHook(callback: dependencies.consolidationCallback),
        ]
    }
}
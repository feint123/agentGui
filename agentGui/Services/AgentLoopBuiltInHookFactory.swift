import Foundation

struct AgentLoopBuiltInHookFactory {
    final class State {
        var lastRound: AgentRound?
        var memoryRuntimeProfiles: [String] = []
        var memoryRuntimeLayers: [String] = []
        var memoryRuntimeWarnings: [String] = []
        var memoryRuntimeSnapshotID: String?
        var memoryRuntimeIntentPhase: String?
        var memoryRuntimeWorkingSetCost: Int?
        var memoryRuntimeBridgeExpansionCount: Int?
        var memoryRuntimeDereferenceCount: Int?
    }

    struct Dependencies {
        let businessLogSink: BusinessLogSink?
        let memoryBootstrapLoader: (State) async throws -> AgentLoopMessagePatch?
        let createToolCallRecord: (AgentLoopHookContext, State) async throws -> ToolCall
        let updateToolCallRecord: (AgentLoopHookContext, State) async throws -> Void
        let reflectionResolver: (AgentLoopHookContext, State) async throws -> AgentLoopReflectionResolution?
    }

    func makeHooks(
        dependencies: Dependencies,
        state: State
    ) -> [any AgentLoopHook] {
        [
            StreamProjectionHook(),
            MemoryBootstrapHook { _ in
                try await dependencies.memoryBootstrapLoader(state)
            },
            ToolAuditHook(
                createRecord: { context in
                    try await dependencies.createToolCallRecord(context, state)
                },
                updateRecord: { context in
                    try await dependencies.updateToolCallRecord(context, state)
                }
            ),
            FailureClassificationHook(),
            ReflectionHandlingHook { context in
                try await dependencies.reflectionResolver(context, state)
            },
            BusinessObservabilityHook(sink: dependencies.businessLogSink)
        ]
    }
}
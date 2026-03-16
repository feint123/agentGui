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
                sink: dependencies.businessLogSink,
                createRecord: { context in
                    try await dependencies.createToolCallRecord(context, state)
                },
                updateRecord: { context in
                    try await dependencies.updateToolCallRecord(context, state)
                }
            ),
            FailureClassificationHook(),
            BusinessObservabilityHook(sink: dependencies.businessLogSink)
        ]
    }
}
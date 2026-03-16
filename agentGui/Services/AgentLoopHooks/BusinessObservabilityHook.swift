import Foundation

struct BusinessObservabilityHook: AgentLoopHook {
    let id = "business-observability"
    let order = 100
    let kind: AgentLoopHookKind = .observer
    let isRequired = false

    let sink: BusinessLogSink?

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        mappedEvent(for: stage) != nil
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        guard let event = mappedEvent(for: stage) else {
            return .continue
        }

        let logContext = BusinessLogContext(
            runID: context.runID,
            sessionID: context.sessionID.isEmpty ? nil : context.sessionID,
            workflowID: context.workflowID,
            roundIndex: context.roundIndex,
            toolName: context.pendingToolName,
            phase: context.phase
        )
        BusinessMonitor.emit(event, context: logContext, metadata: context.metadata, sink: sink)
        return .continue
    }

    private func mappedEvent(for stage: AgentLoopHookStage) -> AgentBusinessEvent? {
        switch stage {
        case .didStartRun:
            return .loopStarted
        case .didApplyBootstrap:
            return .memoryBootstrapLoaded
        case .willStartRound:
            return .roundStarted
        case .didResolveStopReason:
            return .stopReasonReceived
        case .willExecuteTool:
            return .toolExecutionStarted
        case .didExecuteTool:
            return .toolExecutionFinished
        case .prepareContinuation, .prepareResumeAfterPause:
            return .continuationInjected
        case .didFinishRun:
            return .loopFinished
        case .didFailRun:
            return .loopFailed
        default:
            return nil
        }
    }
}
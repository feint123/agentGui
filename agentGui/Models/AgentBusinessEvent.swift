import Foundation

enum AgentBusinessEvent: String, Sendable {
    case loopStarted
    case memoryBootstrapLoaded
    case memoryContextPreparationStarted
    case memoryContextPrepared
    case memoryOutcomeRecorded
    case memoryConsolidationQueued
    case memoryWriteEvaluated
    case memoryWriteRouted
    case memoryBackgroundJobStarted
    case memoryBackgroundJobFinished
    case memoryBackgroundJobFailed
    case roundStarted
    case stopReasonReceived
    case verificationGateEvaluated
    case verificationSkipped
    case verificationStarted
    case verificationCompleted
    case verifierSubagentStarted
    case verifierSubagentFinished
    case toolExecutionStarted
    case toolExecutionFinished
    case toolAuditRecorded
    case reflectionStarted
    case reflectionCompleted
    case continuationInjected
    case loopFinished
    case loopFailed
    case workflowStarted
    case workflowActivationStarted
    case workflowActivationFinished
    case workflowContractViolation
    case workflowFinished
}

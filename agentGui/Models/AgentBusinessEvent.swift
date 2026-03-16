import Foundation

enum AgentBusinessEvent: String, Sendable {
    case backgroundTaskRegistered
    case backgroundTaskTriggered
    case backgroundTaskSkipped
    case backgroundTaskDeferred
    case backgroundTaskStarted
    case backgroundTaskCompleted
    case backgroundTaskFailed
    case backgroundTaskPolicyAdjusted
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
    case toolExecutionStarted
    case toolExecutionFinished
    case toolAuditRecorded
    case continuationInjected
    case loopFinished
    case loopFailed
    case workflowStarted
    case workflowActivationStarted
    case workflowActivationFinished
    case workflowContractViolation
    case workflowFinished
}

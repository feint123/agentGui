import Foundation

enum AgentBusinessEvent: String, Sendable {
    case loopStarted
    case memoryBootstrapLoaded
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

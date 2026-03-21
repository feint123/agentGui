import Foundation

struct ExecutionSchedulingCandidate: Equatable, Sendable {
    let sessionID: String
    let jobID: UUID
    let runtimeScope: ConversationExecutionRuntimeScope?
}
import Foundation

struct ExecutionSchedulingCandidate: Equatable, Sendable {
    let sessionID: String
    let jobID: UUID
    let providerID: ConversationExecutionProviderID
    let capacityPolicy: ProviderExecutionCapacityPolicy

    init(
        sessionID: String,
        jobID: UUID,
        providerID: ConversationExecutionProviderID,
        capacityPolicy: ProviderExecutionCapacityPolicy? = nil
    ) {
        self.sessionID = sessionID
        self.jobID = jobID
        self.providerID = providerID
        self.capacityPolicy = capacityPolicy ?? .default(for: providerID)
    }
}
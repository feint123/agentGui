import Foundation

struct ExecutionSchedulingCandidate: Equatable, Sendable {
    let sessionID: String
    let jobID: UUID
    let providerReference: ExecutionProviderReference
    let capacityPolicy: ProviderExecutionCapacityPolicy

    init(
        sessionID: String,
        jobID: UUID,
        providerID: ConversationExecutionProviderID,
        capacityPolicy: ProviderExecutionCapacityPolicy? = nil
    ) {
        self.init(
            sessionID: sessionID,
            jobID: jobID,
            providerReference: providerID == .builtInAgent
                ? .builtIn
                : LegacyExternalACPProviderKey.allCases.first(where: { $0.conversationExecutionProviderID == providerID })?.compatibilityReference ?? .builtIn,
            capacityPolicy: capacityPolicy
        )
    }

    init(
        sessionID: String,
        jobID: UUID,
        providerReference: ExecutionProviderReference,
        capacityPolicy: ProviderExecutionCapacityPolicy? = nil
    ) {
        self.sessionID = sessionID
        self.jobID = jobID
        self.providerReference = providerReference
        self.capacityPolicy = capacityPolicy ?? .default(for: providerReference)
    }

    var providerID: ConversationExecutionProviderID {
        providerReference.compatibilityProviderID ?? .builtInAgent
    }
}
import Foundation

struct ProviderExecutionCapacityPolicy: Equatable, Sendable {
    let providerID: ConversationExecutionProviderID
    let maxConcurrentSessions: Int
    let maxConcurrentJobsPerSession: Int
    let allowsBackgroundExecution: Bool

    init(
        providerID: ConversationExecutionProviderID,
        maxConcurrentSessions: Int,
        maxConcurrentJobsPerSession: Int = 1,
        allowsBackgroundExecution: Bool = true
    ) {
        self.providerID = providerID
        self.maxConcurrentSessions = max(1, maxConcurrentSessions)
        self.maxConcurrentJobsPerSession = max(1, maxConcurrentJobsPerSession)
        self.allowsBackgroundExecution = allowsBackgroundExecution
    }
}

extension ProviderExecutionCapacityPolicy {
    static func `default`(for providerID: ConversationExecutionProviderID) -> ProviderExecutionCapacityPolicy {
        ProviderExecutionCapacityPolicy(
            providerID: providerID,
            maxConcurrentSessions: .max,
            maxConcurrentJobsPerSession: 1,
            allowsBackgroundExecution: true
        )
    }
}
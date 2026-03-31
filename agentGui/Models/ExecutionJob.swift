import Foundation
import SwiftData

enum ExecutionJobState: String, Codable, Sendable {
    case queued
    case admitted
    case running
    case completed
    case failed
    case cancelled
    case superseded
}

@Model
final class ExecutionJob {
    var id: UUID
    var sessionID: String
    var providerIDRaw: String
    var stateRaw: String
    var payloadJSON: String
    var sourceUserMessageID: UUID?
    var targetAgentMessageID: UUID?
    var latestAttemptID: UUID?
    var enqueuedAt: Date
    var startedAt: Date?
    var finishedAt: Date?

    init(
        sessionID: String,
        providerID: ConversationExecutionProviderID,
        payload: ExecutionPayloadDraft,
        sourceUserMessageID: UUID?,
        targetAgentMessageID: UUID?
    ) {
        self.id = UUID()
        self.sessionID = sessionID
        self.providerIDRaw = (ExecutionProviderReference.compatibilityReference(for: providerID) ?? .builtIn).persistedValue
        self.stateRaw = ExecutionJobState.queued.rawValue
        self.payloadJSON = payload.encodedJSON
        self.sourceUserMessageID = sourceUserMessageID
        self.targetAgentMessageID = targetAgentMessageID
        self.latestAttemptID = nil
        self.enqueuedAt = Date()
        self.startedAt = nil
        self.finishedAt = nil
    }

    init(
        sessionID: String,
        providerReference: ExecutionProviderReference,
        payload: ExecutionPayloadDraft,
        sourceUserMessageID: UUID?,
        targetAgentMessageID: UUID?
    ) {
        self.id = UUID()
        self.sessionID = sessionID
        self.providerIDRaw = providerReference.persistedValue
        self.stateRaw = ExecutionJobState.queued.rawValue
        self.payloadJSON = payload.encodedJSON
        self.sourceUserMessageID = sourceUserMessageID
        self.targetAgentMessageID = targetAgentMessageID
        self.latestAttemptID = nil
        self.enqueuedAt = Date()
        self.startedAt = nil
        self.finishedAt = nil
    }

}

extension ExecutionJob {
    var providerReference: ExecutionProviderReference {
        get {
            ExecutionProviderReference.decodePersisted(providerIDRaw)
        }
        set {
            providerIDRaw = newValue.persistedValue
        }
    }

    var providerID: ConversationExecutionProviderID {
        providerReference.compatibilityProviderID ?? .builtInAgent
    }

    var state: ExecutionJobState {
        get {
            ExecutionJobState(rawValue: stateRaw) ?? .queued
        }
        set {
            stateRaw = newValue.rawValue
        }
    }

    var payload: ExecutionPayloadDraft? {
        get {
            ExecutionPayloadDraft(json: payloadJSON)
        }
        set {
            payloadJSON = newValue?.encodedJSON ?? "{}"
        }
    }

    var teamContext: AgentTeamExecutionContext? {
        payload?.teamContext
    }
}
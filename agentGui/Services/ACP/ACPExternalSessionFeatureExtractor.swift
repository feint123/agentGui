import Foundation

struct ACPCommandDescriptor: Equatable, Sendable {
    var providerID: ConversationExecutionProviderID
    var remoteSessionID: String
    var name: String
    var description: String?
    var inputHint: String?
    var source: ACPCommandSource

    init(
        providerID: ConversationExecutionProviderID,
        remoteSessionID: String,
        name: String,
        description: String? = nil,
        inputHint: String? = nil,
        source: ACPCommandSource = .remoteAdvertised
    ) {
        self.providerID = providerID
        self.remoteSessionID = remoteSessionID
        self.name = name
        self.description = description
        self.inputHint = inputHint
        self.source = source
    }
}

struct ACPPlanSnapshotDraft: Equatable, Sendable {
    var providerID: ConversationExecutionProviderID
    var remoteSessionID: String
    var entries: [ACPPlanEntry]
}

enum ACPExternalSessionFeatureEvent: Equatable, Sendable {
    case replaceCommands([ACPCommandDescriptor])
    case replacePlan(ACPPlanSnapshotDraft)
}

struct ACPExternalSessionFeatureExtractor {
    func extract(
        update: ACPExternalAgentUpdate,
        providerID: ConversationExecutionProviderID,
        remoteSessionID: String
    ) -> [ACPExternalSessionFeatureEvent] {
        switch update {
        case .session(let sessionUpdate):
            return extract(sessionUpdate: sessionUpdate, providerID: providerID, remoteSessionID: remoteSessionID)
        case .permission:
            return []
        }
    }

    private func extract(
        sessionUpdate: ACPSessionUpdate,
        providerID: ConversationExecutionProviderID,
        remoteSessionID: String
    ) -> [ACPExternalSessionFeatureEvent] {
        switch sessionUpdate {
        case .availableCommandsUpdate(let payload):
            return [
                .replaceCommands(
                    payload.availableCommands.map {
                        ACPCommandDescriptor(
                            providerID: providerID,
                            remoteSessionID: remoteSessionID,
                            name: $0.name,
                            description: $0.description,
                            inputHint: $0.input?.hint
                        )
                    }
                )
            ]
        case .plan(let payload):
            return [
                .replacePlan(
                    ACPPlanSnapshotDraft(
                        providerID: providerID,
                        remoteSessionID: remoteSessionID,
                        entries: payload.entries
                    )
                )
            ]
        case .agentMessageChunk, .agentThoughtChunk, .toolCall, .toolCallUpdate, .userMessageChunk, .other:
            return []
        }
    }
}

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

struct ACPCommandSnapshotDraft: Equatable, Sendable {
    var providerID: ConversationExecutionProviderID
    var remoteSessionID: String
    var commands: [ACPCommandDescriptor]
}

enum ACPExternalSessionFeatureEvent: Equatable, Sendable {
    case replaceCommands(ACPCommandSnapshotDraft)
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
        case .sessionNotification(let notification):
            return extract(
                sessionUpdate: notification.update,
                providerID: providerID,
                remoteSessionID: notification.sessionID
            )
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
                    ACPCommandSnapshotDraft(
                        providerID: providerID,
                        remoteSessionID: remoteSessionID,
                        commands: payload.availableCommands.map {
                            ACPCommandDescriptor(
                                providerID: providerID,
                                remoteSessionID: remoteSessionID,
                                name: $0.name,
                                description: $0.description,
                                inputHint: $0.input?.hint
                            )
                        }
                    )
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

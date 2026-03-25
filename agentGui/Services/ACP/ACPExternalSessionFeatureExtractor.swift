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

struct ACPExternalSessionConfigurationDraft: Equatable, Sendable {
    var providerID: ConversationExecutionProviderID
    var remoteSessionID: String
    var configOptions: [ACPSessionConfigOption]?
    var modes: ACPSessionModeState?
}

enum ACPExternalSessionFeatureEvent: Equatable, Sendable {
    case replaceCommands(ACPCommandSnapshotDraft)
    case replacePlan(ACPPlanSnapshotDraft)
    case replaceSessionConfiguration(ACPExternalSessionConfigurationDraft)
    case updateCurrentMode(
        providerID: ConversationExecutionProviderID,
        remoteSessionID: String,
        currentModeID: String
    )
}

struct ACPExternalSessionFeatureExtractor {
    func bootstrapEvents(
        configurationSnapshot: ACPExternalAgentSessionConfigurationSnapshot,
        providerID: ConversationExecutionProviderID,
        remoteSessionID: String
    ) -> [ACPExternalSessionFeatureEvent] {
        guard !configurationSnapshot.configOptions.isEmpty || configurationSnapshot.modes != nil else {
            return []
        }

        return [
            .replaceSessionConfiguration(
                ACPExternalSessionConfigurationDraft(
                    providerID: providerID,
                    remoteSessionID: remoteSessionID,
                    configOptions: configurationSnapshot.configOptions,
                    modes: configurationSnapshot.modes
                )
            )
        ]
    }

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
        case .currentModeUpdate(let payload):
            return [
                .updateCurrentMode(
                    providerID: providerID,
                    remoteSessionID: remoteSessionID,
                    currentModeID: payload.currentModeID
                )
            ]
        case .configOptionUpdate(let payload):
            return [
                .replaceSessionConfiguration(
                    ACPExternalSessionConfigurationDraft(
                        providerID: providerID,
                        remoteSessionID: remoteSessionID,
                        configOptions: payload.configOptions,
                        modes: nil
                    )
                )
            ]
        case .agentMessageChunk, .agentThoughtChunk, .toolCall, .toolCallUpdate, .sessionInfoUpdate, .userMessageChunk, .other:
            return []
        }
    }
}

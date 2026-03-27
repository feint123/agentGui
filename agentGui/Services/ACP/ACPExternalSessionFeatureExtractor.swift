import Foundation

struct ACPCommandDescriptor: Equatable, Sendable {
    var providerReference: ExecutionProviderReference
    var providerDisplayName: String
    var remoteSessionID: String
    var name: String
    var description: String?
    var inputHint: String?
    var source: ACPCommandSource

    init(
        providerReference: ExecutionProviderReference,
        providerDisplayName: String,
        remoteSessionID: String,
        name: String,
        description: String? = nil,
        inputHint: String? = nil,
        source: ACPCommandSource = .remoteAdvertised
    ) {
        self.providerReference = providerReference
        self.providerDisplayName = providerDisplayName
        self.remoteSessionID = remoteSessionID
        self.name = name
        self.description = description
        self.inputHint = inputHint
        self.source = source
    }
}

struct ACPPlanSnapshotDraft: Equatable, Sendable {
    var providerReference: ExecutionProviderReference
    var remoteSessionID: String
    var entries: [ACPPlanEntry]
}

struct ACPCommandSnapshotDraft: Equatable, Sendable {
    var providerReference: ExecutionProviderReference
    var remoteSessionID: String
    var commands: [ACPCommandDescriptor]
}

struct ACPExternalSessionConfigurationDraft: Equatable, Sendable {
    var providerReference: ExecutionProviderReference
    var remoteSessionID: String
    var configOptions: [ACPSessionConfigOption]?
    var modes: ACPSessionModeState?
}

enum ACPExternalSessionFeatureEvent: Equatable, Sendable {
    case replaceCommands(ACPCommandSnapshotDraft)
    case replacePlan(ACPPlanSnapshotDraft)
    case replaceSessionConfiguration(ACPExternalSessionConfigurationDraft)
    case updateCurrentMode(
        providerReference: ExecutionProviderReference,
        remoteSessionID: String,
        currentModeID: String
    )
}

struct ACPExternalSessionFeatureExtractor {
    func bootstrapEvents(
        configurationSnapshot: ACPExternalAgentSessionConfigurationSnapshot,
        providerReference: ExecutionProviderReference,
        remoteSessionID: String
    ) -> [ACPExternalSessionFeatureEvent] {
        guard !configurationSnapshot.configOptions.isEmpty || configurationSnapshot.modes != nil else {
            return []
        }

        return [
            .replaceSessionConfiguration(
                ACPExternalSessionConfigurationDraft(
                    providerReference: providerReference,
                    remoteSessionID: remoteSessionID,
                    configOptions: configurationSnapshot.configOptions,
                    modes: configurationSnapshot.modes
                )
            )
        ]
    }

    func extract(
        update: ACPExternalAgentUpdate,
        providerReference: ExecutionProviderReference,
        providerDisplayName: String,
        remoteSessionID: String
    ) -> [ACPExternalSessionFeatureEvent] {
        switch update {
        case .session(let sessionUpdate):
            return extract(
                sessionUpdate: sessionUpdate,
                providerReference: providerReference,
                providerDisplayName: providerDisplayName,
                remoteSessionID: remoteSessionID
            )
        case .sessionNotification(let notification):
            return extract(
                sessionUpdate: notification.update,
                providerReference: providerReference,
                providerDisplayName: providerDisplayName,
                remoteSessionID: notification.sessionID
            )
        case .permission:
            return []
        }
    }

    private func extract(
        sessionUpdate: ACPSessionUpdate,
        providerReference: ExecutionProviderReference,
        providerDisplayName: String,
        remoteSessionID: String
    ) -> [ACPExternalSessionFeatureEvent] {
        switch sessionUpdate {
        case .availableCommandsUpdate(let payload):
            return [
                .replaceCommands(
                    ACPCommandSnapshotDraft(
                        providerReference: providerReference,
                        remoteSessionID: remoteSessionID,
                        commands: payload.availableCommands.map {
                            ACPCommandDescriptor(
                                providerReference: providerReference,
                                providerDisplayName: providerDisplayName,
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
                        providerReference: providerReference,
                        remoteSessionID: remoteSessionID,
                        entries: payload.entries
                    )
                )
            ]
        case .currentModeUpdate(let payload):
            return [
                .updateCurrentMode(
                    providerReference: providerReference,
                    remoteSessionID: remoteSessionID,
                    currentModeID: payload.currentModeID
                )
            ]
        case .configOptionUpdate(let payload):
            return [
                .replaceSessionConfiguration(
                    ACPExternalSessionConfigurationDraft(
                        providerReference: providerReference,
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

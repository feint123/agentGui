import Foundation

@MainActor
final class ACPExternalSessionFeatureStore {
    private let taskStateStore: SessionTaskStateStore
    private let planProjector: ACPPlanProjector
    private var commandsCache: [CommandCacheKey: [ACPCommandDescriptor]] = [:]
    private var sessionCommandsCache: [SessionCommandCacheKey: [ACPCommandDescriptor]] = [:]
    private var planCache: [String: ACPPlanSnapshotDraft] = [:]
    private var configurationCache: [ConfigurationCacheKey: ACPExternalAgentSessionConfigurationSnapshot] = [:]
    private var sessionConfigurationCache: [SessionConfigurationCacheKey: ACPExternalAgentSessionConfigurationSnapshot] = [:]

    init(
        taskStateStore: SessionTaskStateStore,
        planProjector: ACPPlanProjector = ACPPlanProjector()
    ) {
        self.taskStateStore = taskStateStore
        self.planProjector = planProjector
    }

    func apply(_ events: [ACPExternalSessionFeatureEvent], sessionID: String) throws {
        for event in events {
            switch event {
            case .replaceCommands(let snapshot):
                let key = CommandCacheKey(providerID: snapshot.providerID, remoteSessionID: snapshot.remoteSessionID)
                print(
                    "[ACP][feature-store] replaceCommands session=\(sessionID) provider=\(snapshot.providerID.rawValue) remoteSession=\(snapshot.remoteSessionID) count=\(snapshot.commands.count) names=\(snapshot.commands.map(\.name).joined(separator: ","))"
                )
                commandsCache[key] = snapshot.commands
                sessionCommandsCache[SessionCommandCacheKey(sessionID: sessionID, providerID: snapshot.providerID)] = snapshot.commands
            case .replacePlan(let snapshot):
                print(
                    "[ACP][feature-store] replacePlan session=\(sessionID) entries=\(snapshot.entries.count)"
                )
                planCache[sessionID] = snapshot
                try taskStateStore.savePlan(planProjector.makeExecutionPlan(from: snapshot), for: sessionID)
                try taskStateStore.saveTodoItems(planProjector.makeTodoItems(from: snapshot), for: sessionID)
            case .replaceSessionConfiguration(let snapshot):
                let configuration = mergedConfigurationSnapshot(
                    existing: currentConfigurationSnapshot(
                        sessionID: sessionID,
                        providerID: snapshot.providerID,
                        remoteSessionID: snapshot.remoteSessionID
                    ),
                    replacement: snapshot
                )
                print(
                    "[ACP][feature-store] replaceSessionConfiguration session=\(sessionID) provider=\(snapshot.providerID.rawValue) remoteSession=\(snapshot.remoteSessionID) configOptions=\(configuration.configOptions.count) hasModes=\(configuration.modes != nil)"
                )
                storeConfigurationSnapshot(
                    configuration,
                    sessionID: sessionID,
                    providerID: snapshot.providerID,
                    remoteSessionID: snapshot.remoteSessionID
                )
            case .updateCurrentMode(let providerID, let remoteSessionID, let currentModeID):
                let configuration = updatedCurrentModeSnapshot(
                    existing: currentConfigurationSnapshot(
                        sessionID: sessionID,
                        providerID: providerID,
                        remoteSessionID: remoteSessionID
                    ),
                    currentModeID: currentModeID
                )
                print(
                    "[ACP][feature-store] updateCurrentMode session=\(sessionID) provider=\(providerID.rawValue) remoteSession=\(remoteSessionID) currentMode=\(currentModeID)"
                )
                storeConfigurationSnapshot(
                    configuration,
                    sessionID: sessionID,
                    providerID: providerID,
                    remoteSessionID: remoteSessionID
                )
            }
        }
    }

    func commands(
        for providerID: ConversationExecutionProviderID,
        remoteSessionID: String
    ) -> [ACPCommandDescriptor] {
        commandsCache[CommandCacheKey(providerID: providerID, remoteSessionID: remoteSessionID)] ?? []
    }

    func commands(
        for sessionID: String,
        providerID: ConversationExecutionProviderID
    ) -> [ACPCommandDescriptor] {
        sessionCommandsCache[SessionCommandCacheKey(sessionID: sessionID, providerID: providerID)] ?? []
    }

    func plan(for sessionID: String) -> ACPPlanSnapshotDraft? {
        planCache[sessionID]
    }

    func sessionConfiguration(
        for sessionID: String,
        providerID: ConversationExecutionProviderID
    ) -> ACPExternalAgentSessionConfigurationSnapshot? {
        sessionConfigurationCache[SessionConfigurationCacheKey(sessionID: sessionID, providerID: providerID)]
    }

    func sessionConfiguration(
        for providerID: ConversationExecutionProviderID,
        remoteSessionID: String
    ) -> ACPExternalAgentSessionConfigurationSnapshot? {
        configurationCache[ConfigurationCacheKey(providerID: providerID, remoteSessionID: remoteSessionID)]
    }

    private func currentConfigurationSnapshot(
        sessionID: String,
        providerID: ConversationExecutionProviderID,
        remoteSessionID: String
    ) -> ACPExternalAgentSessionConfigurationSnapshot? {
        configurationCache[ConfigurationCacheKey(providerID: providerID, remoteSessionID: remoteSessionID)]
            ?? sessionConfigurationCache[SessionConfigurationCacheKey(sessionID: sessionID, providerID: providerID)]
    }

    private func mergedConfigurationSnapshot(
        existing: ACPExternalAgentSessionConfigurationSnapshot?,
        replacement: ACPExternalSessionConfigurationDraft
    ) -> ACPExternalAgentSessionConfigurationSnapshot {
        ACPExternalAgentSessionConfigurationSnapshot(
            configOptions: replacement.configOptions ?? existing?.configOptions ?? [],
            modes: replacement.modes ?? existing?.modes
        )
    }

    private func updatedCurrentModeSnapshot(
        existing: ACPExternalAgentSessionConfigurationSnapshot?,
        currentModeID: String
    ) -> ACPExternalAgentSessionConfigurationSnapshot {
        ACPExternalAgentSessionConfigurationSnapshot(
            configOptions: existing?.configOptions ?? [],
            modes: updatedModes(existing?.modes, currentModeID: currentModeID)
        )
    }

    private func updatedModes(
        _ existingModes: ACPSessionModeState?,
        currentModeID: String
    ) -> ACPSessionModeState {
        ACPSessionModeState(
            meta: existingModes?.meta,
            availableModes: existingModes?.availableModes ?? [],
            currentModeID: currentModeID
        )
    }

    private func storeConfigurationSnapshot(
        _ snapshot: ACPExternalAgentSessionConfigurationSnapshot,
        sessionID: String,
        providerID: ConversationExecutionProviderID,
        remoteSessionID: String
    ) {
        configurationCache[ConfigurationCacheKey(providerID: providerID, remoteSessionID: remoteSessionID)] = snapshot
        sessionConfigurationCache[SessionConfigurationCacheKey(sessionID: sessionID, providerID: providerID)] = snapshot
    }
}

private struct CommandCacheKey: Hashable {
    var providerID: ConversationExecutionProviderID
    var remoteSessionID: String
}

private struct SessionCommandCacheKey: Hashable {
    var sessionID: String
    var providerID: ConversationExecutionProviderID
}

private struct ConfigurationCacheKey: Hashable {
    var providerID: ConversationExecutionProviderID
    var remoteSessionID: String
}

private struct SessionConfigurationCacheKey: Hashable {
    var sessionID: String
    var providerID: ConversationExecutionProviderID
}

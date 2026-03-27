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
                let key = CommandCacheKey(providerReference: snapshot.providerReference, remoteSessionID: snapshot.remoteSessionID)
                print(
                    "[ACP][feature-store] replaceCommands session=\(sessionID) provider=\(snapshot.providerReference.persistedValue) remoteSession=\(snapshot.remoteSessionID) count=\(snapshot.commands.count) names=\(snapshot.commands.map(\.name).joined(separator: ","))"
                )
                commandsCache[key] = snapshot.commands
                sessionCommandsCache[SessionCommandCacheKey(sessionID: sessionID, providerReference: snapshot.providerReference)] = snapshot.commands
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
                        providerReference: snapshot.providerReference,
                        remoteSessionID: snapshot.remoteSessionID
                    ),
                    replacement: snapshot
                )
                print(
                    "[ACP][feature-store] replaceSessionConfiguration session=\(sessionID) provider=\(snapshot.providerReference.persistedValue) remoteSession=\(snapshot.remoteSessionID) configOptions=\(configuration.configOptions.count) hasModes=\(configuration.modes != nil)"
                )
                storeConfigurationSnapshot(
                    configuration,
                    sessionID: sessionID,
                    providerReference: snapshot.providerReference,
                    remoteSessionID: snapshot.remoteSessionID
                )
            case .updateCurrentMode(let providerReference, let remoteSessionID, let currentModeID):
                let configuration = updatedCurrentModeSnapshot(
                    existing: currentConfigurationSnapshot(
                        sessionID: sessionID,
                        providerReference: providerReference,
                        remoteSessionID: remoteSessionID
                    ),
                    currentModeID: currentModeID
                )
                print(
                    "[ACP][feature-store] updateCurrentMode session=\(sessionID) provider=\(providerReference.persistedValue) remoteSession=\(remoteSessionID) currentMode=\(currentModeID)"
                )
                storeConfigurationSnapshot(
                    configuration,
                    sessionID: sessionID,
                    providerReference: providerReference,
                    remoteSessionID: remoteSessionID
                )
            }
        }
    }

    func commands(
        for providerReference: ExecutionProviderReference,
        remoteSessionID: String
    ) -> [ACPCommandDescriptor] {
        commandsCache[CommandCacheKey(providerReference: providerReference, remoteSessionID: remoteSessionID)] ?? []
    }

    func commands(
        for sessionID: String,
        providerReference: ExecutionProviderReference
    ) -> [ACPCommandDescriptor] {
        sessionCommandsCache[SessionCommandCacheKey(sessionID: sessionID, providerReference: providerReference)] ?? []
    }

    func plan(for sessionID: String) -> ACPPlanSnapshotDraft? {
        planCache[sessionID]
    }

    func sessionConfiguration(
        for sessionID: String,
        providerReference: ExecutionProviderReference
    ) -> ACPExternalAgentSessionConfigurationSnapshot? {
        sessionConfigurationCache[SessionConfigurationCacheKey(sessionID: sessionID, providerReference: providerReference)]
    }

    func sessionConfiguration(
        for providerReference: ExecutionProviderReference,
        remoteSessionID: String
    ) -> ACPExternalAgentSessionConfigurationSnapshot? {
        configurationCache[ConfigurationCacheKey(providerReference: providerReference, remoteSessionID: remoteSessionID)]
    }

    private func currentConfigurationSnapshot(
        sessionID: String,
        providerReference: ExecutionProviderReference,
        remoteSessionID: String
    ) -> ACPExternalAgentSessionConfigurationSnapshot? {
        configurationCache[ConfigurationCacheKey(providerReference: providerReference, remoteSessionID: remoteSessionID)]
            ?? sessionConfigurationCache[SessionConfigurationCacheKey(sessionID: sessionID, providerReference: providerReference)]
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
        providerReference: ExecutionProviderReference,
        remoteSessionID: String
    ) {
        configurationCache[ConfigurationCacheKey(providerReference: providerReference, remoteSessionID: remoteSessionID)] = snapshot
        sessionConfigurationCache[SessionConfigurationCacheKey(sessionID: sessionID, providerReference: providerReference)] = snapshot
    }
}

private struct CommandCacheKey: Hashable {
    var providerReference: ExecutionProviderReference
    var remoteSessionID: String
}

private struct SessionCommandCacheKey: Hashable {
    var sessionID: String
    var providerReference: ExecutionProviderReference
}

private struct ConfigurationCacheKey: Hashable {
    var providerReference: ExecutionProviderReference
    var remoteSessionID: String
}

private struct SessionConfigurationCacheKey: Hashable {
    var sessionID: String
    var providerReference: ExecutionProviderReference
}

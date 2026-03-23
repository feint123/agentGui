import Foundation

@MainActor
final class ACPExternalSessionFeatureStore {
    private let taskStateStore: SessionTaskStateStore
    private let planProjector: ACPPlanProjector
    private var commandsCache: [CommandCacheKey: [ACPCommandDescriptor]] = [:]
    private var sessionCommandsCache: [SessionCommandCacheKey: [ACPCommandDescriptor]] = [:]
    private var planCache: [String: ACPPlanSnapshotDraft] = [:]

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
}

private struct CommandCacheKey: Hashable {
    var providerID: ConversationExecutionProviderID
    var remoteSessionID: String
}

private struct SessionCommandCacheKey: Hashable {
    var sessionID: String
    var providerID: ConversationExecutionProviderID
}

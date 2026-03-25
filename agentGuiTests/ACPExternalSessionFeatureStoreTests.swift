import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ACPExternalSessionFeatureStoreTests {
    @Test func storePersistsLatestSessionConfigSnapshotPerSessionAndProvider() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = ACPExternalSessionFeatureStore(
            taskStateStore: SessionTaskStateStore(modelContext: context),
            planProjector: ACPPlanProjector()
        )

        try store.apply(
            [
                .replaceSessionConfiguration(
                    ACPExternalSessionConfigurationDraft(
                        providerID: .githubCopilotCLI,
                        remoteSessionID: "remote-config-1",
                        configOptions: [sampleModelConfig(currentValue: "gpt-5")],
                        modes: sampleModes(currentModeID: "plan")
                    )
                )
            ],
            sessionID: "session-config-1"
        )

        let snapshot = try #require(
            store.sessionConfiguration(for: "session-config-1", providerID: .githubCopilotCLI)
        )
        #expect(snapshot.configOptions == [sampleModelConfig(currentValue: "gpt-5")])
        #expect(snapshot.modes == sampleModes(currentModeID: "plan"))
        #expect(
            store.sessionConfiguration(for: .githubCopilotCLI, remoteSessionID: "remote-config-1") == snapshot
        )
    }

    @Test func storeMergesInitialHandshakeSnapshotAndLiveUpdates() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = ACPExternalSessionFeatureStore(
            taskStateStore: SessionTaskStateStore(modelContext: context),
            planProjector: ACPPlanProjector()
        )

        try store.apply(
            [
                .replaceSessionConfiguration(
                    ACPExternalSessionConfigurationDraft(
                        providerID: .openCodeCLI,
                        remoteSessionID: "remote-config-2",
                        configOptions: [sampleModelConfig(currentValue: "gpt-4.1")],
                        modes: sampleModes(currentModeID: "plan")
                    )
                )
            ],
            sessionID: "session-config-2"
        )

        try store.apply(
            [
                .updateCurrentMode(
                    providerID: .openCodeCLI,
                    remoteSessionID: "remote-config-2",
                    currentModeID: "edit"
                ),
                .replaceSessionConfiguration(
                    ACPExternalSessionConfigurationDraft(
                        providerID: .openCodeCLI,
                        remoteSessionID: "remote-config-2",
                        configOptions: [sampleModelConfig(currentValue: "gpt-5")],
                        modes: nil
                    )
                )
            ],
            sessionID: "session-config-2"
        )

        let snapshot = try #require(
            store.sessionConfiguration(for: "session-config-2", providerID: .openCodeCLI)
        )
        #expect(snapshot.configOptions == [sampleModelConfig(currentValue: "gpt-5")])
        #expect(snapshot.modes?.currentModeID == "edit")
        #expect(snapshot.modes?.availableModes == sampleModes(currentModeID: "plan").availableModes)
    }

    @Test func applyReplaceCommandsUpdatesCommandCache() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = ACPExternalSessionFeatureStore(
            taskStateStore: SessionTaskStateStore(modelContext: context),
            planProjector: ACPPlanProjector()
        )

        try store.apply(
            [.replaceCommands(
                ACPCommandSnapshotDraft(
                    providerID: .openCodeCLI,
                    remoteSessionID: "remote-1",
                    commands: [
                        ACPCommandDescriptor(
                            providerID: .openCodeCLI,
                            remoteSessionID: "remote-1",
                            name: "review",
                            description: "Run review",
                            inputHint: "scope"
                        )
                    ]
                )
            )],
            sessionID: "session-1"
        )

        let commands = store.commands(for: .openCodeCLI, remoteSessionID: "remote-1")
        #expect(commands.map(\.name) == ["review"])
        #expect(commands.first?.inputHint == "scope")
    }

    @Test func applyReplacePlanWritesProjectedTaskState() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session(sessionId: "session-2", title: "ACP")
        context.insert(session)
        try context.save()

        let taskStateStore = SessionTaskStateStore(modelContext: context)
        let store = ACPExternalSessionFeatureStore(
            taskStateStore: taskStateStore,
            planProjector: ACPPlanProjector()
        )

        try store.apply(
            [.replacePlan(
                ACPPlanSnapshotDraft(
                    providerID: .openCodeCLI,
                    remoteSessionID: "remote-2",
                    entries: [
                        ACPPlanEntry(content: "Write tests", priority: .medium, status: .inProgress)
                    ]
                )
            )],
            sessionID: session.sessionId
        )

        #expect(taskStateStore.todoItems(for: session.sessionId).map(\.title) == ["Write tests"])
        #expect(taskStateStore.todoItems(for: session.sessionId).map(\.status) == [.inProgress])
        let plan = try #require(try taskStateStore.taskState(for: session.sessionId)?.plan)
        #expect(plan.steps.map(\.title) == ["Write tests"])
        #expect(plan.steps.first?.priority == "medium")
    }

    @Test func applyReplaceCommandsCachesCommandsBySessionAndProvider() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = ACPExternalSessionFeatureStore(
            taskStateStore: SessionTaskStateStore(modelContext: context),
            planProjector: ACPPlanProjector()
        )

        try store.apply(
            [.replaceCommands(
                ACPCommandSnapshotDraft(
                    providerID: .githubCopilotCLI,
                    remoteSessionID: "remote-seeded",
                    commands: [
                        ACPCommandDescriptor(
                            providerID: .githubCopilotCLI,
                            remoteSessionID: "remote-seeded",
                            name: "plan",
                            description: "Create a plan",
                            inputHint: "what to plan",
                            source: .documentedSeed
                        )
                    ]
                )
            )],
            sessionID: "session-commands"
        )

        let commands = store.commands(for: "session-commands", providerID: .githubCopilotCLI)
        #expect(commands.map(\.name) == ["plan"])
        #expect(commands.first?.source == .documentedSeed)
    }

    @Test func replacePlanUsesFullReplacementSemantics() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session(sessionId: "session-3", title: "ACP")
        context.insert(session)
        try context.save()

        let taskStateStore = SessionTaskStateStore(modelContext: context)
        let store = ACPExternalSessionFeatureStore(
            taskStateStore: taskStateStore,
            planProjector: ACPPlanProjector()
        )

        try store.apply(
            [.replacePlan(
                ACPPlanSnapshotDraft(
                    providerID: .openCodeCLI,
                    remoteSessionID: "remote-3",
                    entries: [
                        ACPPlanEntry(content: "Old step", priority: .high, status: .pending)
                    ]
                )
            )],
            sessionID: session.sessionId
        )

        try store.apply(
            [.replacePlan(
                ACPPlanSnapshotDraft(
                    providerID: .openCodeCLI,
                    remoteSessionID: "remote-3",
                    entries: []
                )
            )],
            sessionID: session.sessionId
        )

        #expect(taskStateStore.todoItems(for: session.sessionId).isEmpty)
        let plan = try #require(try taskStateStore.taskState(for: session.sessionId)?.plan)
        #expect(plan.steps.isEmpty)
    }

    @Test func replaceCommandsUsesFullReplacementSemanticsIncludingEmptyList() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = ACPExternalSessionFeatureStore(
            taskStateStore: SessionTaskStateStore(modelContext: context),
            planProjector: ACPPlanProjector()
        )

        try store.apply(
            [.replaceCommands(
                ACPCommandSnapshotDraft(
                    providerID: .openCodeCLI,
                    remoteSessionID: "remote-commands",
                    commands: [
                        ACPCommandDescriptor(
                            providerID: .openCodeCLI,
                            remoteSessionID: "remote-commands",
                            name: "review",
                            description: "Run review",
                            inputHint: "scope"
                        )
                    ]
                )
            )],
            sessionID: "session-commands"
        )

        try store.apply(
            [.replaceCommands(
                ACPCommandSnapshotDraft(
                    providerID: .openCodeCLI,
                    remoteSessionID: "remote-commands",
                    commands: []
                )
            )],
            sessionID: "session-commands"
        )

        #expect(store.commands(for: .openCodeCLI, remoteSessionID: "remote-commands").isEmpty)
        #expect(store.commands(for: "session-commands", providerID: .openCodeCLI).isEmpty)
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: AppSettings.self,
            Session.self,
            SessionTaskState.self,
            configurations: config
        )
    }

    private func sampleModelConfig(currentValue: String) -> ACPSessionConfigOption {
        ACPSessionConfigOption(
            meta: nil,
            category: .model,
            currentValue: currentValue,
            options: .ungrouped([
                ACPSessionConfigSelectOption(meta: nil, description: nil, name: "GPT 5", value: "gpt-5"),
                ACPSessionConfigSelectOption(meta: nil, description: nil, name: "GPT 4.1", value: "gpt-4.1")
            ]),
            type: "string"
        )
    }

    private func sampleModes(currentModeID: String) -> ACPSessionModeState {
        ACPSessionModeState(
            meta: nil,
            availableModes: [
                ACPSessionMode(meta: nil, description: "Planning", id: "plan", name: "Plan"),
                ACPSessionMode(meta: nil, description: "Editing", id: "edit", name: "Edit")
            ],
            currentModeID: currentModeID
        )
    }
}

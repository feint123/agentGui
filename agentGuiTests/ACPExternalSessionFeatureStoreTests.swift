import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ACPExternalSessionFeatureStoreTests {
    @Test func applyReplaceCommandsUpdatesCommandCache() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = ACPExternalSessionFeatureStore(
            taskStateStore: SessionTaskStateStore(modelContext: context),
            planProjector: ACPPlanProjector()
        )

        try store.apply(
            [.replaceCommands([
                ACPCommandDescriptor(
                    providerID: .openCodeCLI,
                    remoteSessionID: "remote-1",
                    name: "review",
                    description: "Run review",
                    inputHint: "scope"
                )
            ])],
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
            [.replaceCommands([
                ACPCommandDescriptor(
                    providerID: .githubCopilotCLI,
                    remoteSessionID: "remote-seeded",
                    name: "plan",
                    description: "Create a plan",
                    inputHint: "what to plan",
                    source: .documentedSeed
                )
            ])],
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

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: AppSettings.self,
            Session.self,
            SessionTaskState.self,
            configurations: config
        )
    }
}

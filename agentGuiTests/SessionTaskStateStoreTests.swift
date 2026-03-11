import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct SessionTaskStateStoreTests {

    @Test func todoAndVerificationReloadAfterStoreRecreation() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session(sessionId: "session-1", title: "Persisted Task State")
        context.insert(session)
        try context.save()

        let store = SessionTaskStateStore(modelContext: context)
        try store.saveTodoItems([TodoItem(title: "Persist me")], for: session.sessionId)
        try store.saveVerification(
            CompletionVerification(verified: ["build"], notVerified: []),
            for: session.sessionId
        )

        let reloadedStore = SessionTaskStateStore(modelContext: context)
        let taskState = try #require(try reloadedStore.taskState(for: session.sessionId))
        #expect(taskState.todoItems.count == 1)
        #expect(taskState.todoItems.first?.title == "Persist me")
        #expect(taskState.verification?.verified == ["build"])
    }

    @Test func taskStateBackfillsPlanFromLegacySessionField() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let plan = ExecutionPlan(
            goal: "Ship persistence",
            steps: [PlanStep(id: "1", title: "Write store")],
            assumptions: ["Schema is local"],
            successCriteria: ["Todo survives restart"]
        )
        let planData = try JSONEncoder().encode(plan)
        let session = Session(sessionId: "session-legacy", title: "Legacy")
        session.planJson = try #require(String(data: planData, encoding: .utf8))
        context.insert(session)
        try context.save()

        let store = SessionTaskStateStore(modelContext: context)
        let taskState = try #require(try store.taskState(for: session.sessionId))

        #expect(taskState.plan?.goal == "Ship persistence")
        #expect(taskState.plan?.steps.count == 1)
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
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct SessionToolbarActionTests {

    @Test func deleteAllSessionsRemovesEverySessionAndClearsSelection() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Session.self, configurations: configuration)
        let context = ModelContext(container)
        let state = WorkspaceState()

        let first = Session(sessionId: "session-1", title: "First")
        let second = Session(sessionId: "session-2", title: "Second")
        context.insert(first)
        context.insert(second)
        state.selectedSession = first
        try context.save()

        await SessionToolbarActions(modelContext: context, workspaceState: state).deleteAllSessions(batchSize: 1)

        let descriptor = FetchDescriptor<Session>()
        let remaining = try context.fetch(descriptor)

        #expect(remaining.isEmpty)
        #expect(state.selectedSession == nil)
    }
}
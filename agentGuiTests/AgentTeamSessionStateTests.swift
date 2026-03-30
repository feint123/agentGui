import SwiftData
import Testing
@testable import agentGui

@MainActor
struct AgentTeamSessionStateTests {
    @Test
    func teamStateBindsToAgentTeamSession() throws {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let session = Session(title: "修复 ACP", kind: .agentTeam)
        context.insert(session)

        let state = AgentTeamSessionState(
            session: session,
            sourceSessionID: "chat-1",
            sourceSessionTitle: "修复 ACP"
        )
        context.insert(state)

        #expect(state.session === session)
        #expect(state.status == .created)
        #expect(state.mode == .executionDelivery)
        #expect(state.sourceSessionID == "chat-1")
        #expect(state.sourceSessionTitle == "修复 ACP")
    }
}
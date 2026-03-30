import SwiftData
import Testing
@testable import agentGui

@MainActor
struct AgentTeamSessionFactoryTests {
    @Test
    func createFromChatBuildsAgentTeamSessionAndState() throws {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let source = Session(title: "当前聊天", kind: .local)
        context.insert(source)

        let result = try AgentTeamSessionFactory().create(from: source, modelContext: context)

        #expect(result.session.kind == SessionKind.agentTeam)
        #expect(result.session.title == "当前聊天 · Team")
        #expect(result.state.session === result.session)
        #expect(result.state.sourceSessionID == source.sessionId)
        #expect(result.state.sourceSessionTitle == source.title)
    }

    @Test
    func createWithoutSourceBuildsStandaloneAgentTeamSession() throws {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let result = try AgentTeamSessionFactory().create(from: nil, modelContext: context)

        #expect(result.session.kind == SessionKind.agentTeam)
        #expect(result.state.sourceSessionID.isEmpty)
        #expect(result.state.sourceSessionTitle.isEmpty)
    }
}
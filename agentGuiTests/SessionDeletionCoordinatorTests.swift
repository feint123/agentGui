import SwiftData
import Testing
@testable import agentGui

@MainActor
struct SessionDeletionCoordinatorTests {
    @Test
    func deleteRemovesAgentTeamSessionAndState() async throws {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let teamSession = Session(title: "团队壳层", kind: .agentTeam)
        let teamState = AgentTeamSessionState(session: teamSession, sourceSessionTitle: "来源会话")
        teamSession.agentTeamState = teamState
        context.insert(teamSession)
        context.insert(teamState)
        try context.save()

        try await SessionDeletionCoordinator().delete(teamSession, modelContext: context)

        let remainingSessions = try context.fetch(FetchDescriptor<Session>())
        let remainingStates = try context.fetch(FetchDescriptor<AgentTeamSessionState>())
        #expect(remainingSessions.isEmpty)
        #expect(remainingStates.isEmpty)
    }

    @Test
    func deleteStillRejectsChannelSession() async throws {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let channelSession = Session(title: "渠道镜像", kind: .channel)
        context.insert(channelSession)
        try context.save()

        await #expect(throws: SessionDeletionCoordinatorError.readOnlySession(channelSession.sessionId)) {
            try await SessionDeletionCoordinator().delete(channelSession, modelContext: context)
        }
    }
}
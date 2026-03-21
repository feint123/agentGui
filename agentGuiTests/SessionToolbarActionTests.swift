import SwiftData
import Testing
@testable import agentGui

@MainActor
struct SessionToolbarActionTests {

    @Test func cloneCurrentReadOnlySessionCreatesEditableLocalCopy() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Session.self, Message.self, configurations: configuration)
        let context = ModelContext(container)
        let state = WorkspaceState()

        let channelSession = Session.fixture(
            sessionId: "channel-1",
            title: "Feishu",
            kind: .channel,
            sourceIdentifier: "feishu:chat-1",
            sourceDisplayName: "Feishu · chat-1"
        )
        let sourceMessage = Message.userMessage(text: "来自渠道的消息", session: channelSession)
        sourceMessage.status = .completed
        context.insert(channelSession)
        context.insert(sourceMessage)
        state.selectedSession = channelSession
        try context.save()

        let cloned = try #require(
            try SessionToolbarActions(modelContext: context, workspaceState: state).cloneCurrentSessionAsLocal()
        )

        let sessions = try context.fetch(FetchDescriptor<Session>())
        let clonedMessages = try context.fetch(FetchDescriptor<Message>())
            .filter { $0.session?.sessionId == cloned.sessionId }
            .sorted { $0.sequence < $1.sequence }

        #expect(sessions.count == 2)
        #expect(cloned.sessionId != channelSession.sessionId)
        #expect(cloned.kind == .local)
        #expect(cloned.isReadOnly == false)
        #expect(cloned.sourceIdentifier.isEmpty)
        #expect(state.selectedSession?.sessionId == cloned.sessionId)
        #expect(clonedMessages.map(\.textContent) == ["来自渠道的消息"])
    }

    @Test func deleteCurrentSessionRejectsReadOnlySession() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Session.self, configurations: configuration)
        let context = ModelContext(container)
        let state = WorkspaceState()

        let channelSession = Session.fixture(sessionId: "channel-1", title: "Channel", kind: .channel)
        context.insert(channelSession)
        state.selectedSession = channelSession
        try context.save()

        let deleted = try SessionToolbarActions(modelContext: context, workspaceState: state)
            .deleteCurrentSessionIfAllowed()

        #expect(deleted == false)
        #expect(try context.fetch(FetchDescriptor<Session>()).count == 1)
        #expect(state.selectedSession?.sessionId == "channel-1")
    }

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

    @Test func deleteAllSessionsSkipsReadOnlySessions() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Session.self, configurations: configuration)
        let context = ModelContext(container)
        let state = WorkspaceState()

        let local = Session.fixture(sessionId: "local-1", title: "Local")
        let channel = Session.fixture(sessionId: "channel-1", title: "Channel", kind: .channel)
        context.insert(local)
        context.insert(channel)
        state.selectedSession = local
        try context.save()

        await SessionToolbarActions(modelContext: context, workspaceState: state).deleteAllSessions(batchSize: 1)

        let remaining = try context.fetch(FetchDescriptor<Session>())

        #expect(remaining.map(\.sessionId) == ["channel-1"])
        #expect(state.selectedSession == nil)
    }
}
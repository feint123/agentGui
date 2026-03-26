import Testing
@testable import agentGui

@MainActor
struct ChatMessageListProjectionRefreshCoordinatorTests {
    @Test
    func projectionModelTransitionsFromEmptyToContentWhenFirstMessageArrives() async {
        let session = Session.fixture(sessionId: "chat-first-send", title: "First Send")
        let model = ChatMessageListProjectionModel()
        let workspaceRoot = "/tmp/chat-first-send"

        await model.refresh(
            messages: [],
            workspaceRoot: workspaceRoot,
            showsLoadingPlaceholder: true
        )

        #expect(model.isInitialLoadInFlight == false)
        #expect(model.snapshot.rows.isEmpty)

        let firstMessage = Message.userMessage(text: "hello", session: session)
        firstMessage.status = .completed

        await model.refresh(
            messages: [firstMessage],
            workspaceRoot: workspaceRoot
        )

        #expect(model.snapshot.rows.map(\.id) == [firstMessage.id])
        #expect(
            ChatMessageListPresentationState.resolve(
                isInitialLoadInFlight: model.isInitialLoadInFlight,
                isClearingMessages: false,
                snapshot: model.snapshot
            ) == .content
        )
    }

    @Test
    func refreshSkipsRebuildWhenTriggerAndSnapshotStillMatch() {
        let session = Session.fixture(sessionId: "chat-refresh", title: "Chat Refresh")
        let userMessage = Message.userMessage(text: "hello", session: session)
        let agentMessage = Message.agentMessage(text: "world", session: session)
        userMessage.status = .completed
        agentMessage.status = .completed
        let messages = [userMessage, agentMessage]
        let workspaceRoot = "/tmp/chat-refresh"

        let snapshot = ChatMessageListSnapshotBuilder.build(
            messages: messages,
            workspaceRoot: workspaceRoot,
            previous: [:]
        )
        let trigger = ChatMessageListProjectionTrigger(
            messages: messages,
            workspaceRoot: workspaceRoot
        )

        let result = ChatMessageListProjectionRefreshCoordinator.refresh(
            previousTrigger: trigger,
            previousSnapshot: snapshot,
            messages: messages,
            workspaceRoot: workspaceRoot
        )

        #expect(result.didRefresh == false)
        #expect(result.snapshot.rows.map(\.id) == snapshot.rows.map(\.id))
        #expect(result.trigger == trigger)
    }
}
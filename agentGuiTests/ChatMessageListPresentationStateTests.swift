import Testing
@testable import agentGui

struct ChatMessageListPresentationStateTests {
    @Test func loadingStateWinsBeforeInitialSnapshotArrives() {
        let state = ChatMessageListPresentationState.resolve(
            isInitialLoadInFlight: true,
            isClearingMessages: false,
            snapshot: .empty
        )

        #expect(state == .loading)
    }

    @Test func emptyStateAppearsAfterLoadingCompletesWithoutMessages() {
        let state = ChatMessageListPresentationState.resolve(
            isInitialLoadInFlight: false,
            isClearingMessages: false,
            snapshot: .empty
        )

        #expect(state == .empty)
    }

    @Test func contentStateAppearsWhenSnapshotContainsRows() {
        let session = Session(title: "Chat")
        let message = Message.userMessage(text: "hello", session: session)
        let snapshot = ChatMessageListSnapshotBuilder.build(
            messages: [message],
            workspaceRoot: "",
            previous: [:]
        )

        let state = ChatMessageListPresentationState.resolve(
            isInitialLoadInFlight: false,
            isClearingMessages: false,
            snapshot: snapshot
        )

        #expect(state == .content)
    }
}
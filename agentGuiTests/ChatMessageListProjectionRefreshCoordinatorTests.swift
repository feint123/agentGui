import Foundation
import Testing
@testable import agentGui

@MainActor
struct ChatMessageListProjectionRefreshCoordinatorTests {

    @Test func rebuildsWhenTriggerMatchesButSnapshotRowsAreStale() async throws {
        let session = Session(title: "Fresh Session")
        let first = Message.userMessage(text: "hello", session: session)

        let staleSnapshot = ChatMessageListSnapshot.empty
        let staleTrigger = ChatMessageListProjectionTrigger(
            messages: [first],
            workspaceRoot: "/tmp/workspace"
        )

        let result = ChatMessageListProjectionRefreshCoordinator.refresh(
            previousTrigger: staleTrigger,
            previousSnapshot: staleSnapshot,
            messages: [first],
            workspaceRoot: "/tmp/workspace"
        )

        #expect(result.didRefresh)
        #expect(result.snapshot.rows.map(\.id) == [first.id])
    }

    @Test func skipsRefreshWhenTriggerAndSnapshotAreConsistent() async throws {
        let session = Session(title: "Stable Session")
        let first = Message.userMessage(text: "hello", session: session)

        let initialSnapshot = ChatMessageListSnapshotBuilder.build(
            messages: [first],
            workspaceRoot: "/tmp/workspace",
            previous: [:]
        )
        let previousTrigger = ChatMessageListProjectionTrigger(
            messages: [first],
            workspaceRoot: "/tmp/workspace"
        )

        let result = ChatMessageListProjectionRefreshCoordinator.refresh(
            previousTrigger: previousTrigger,
            previousSnapshot: initialSnapshot,
            messages: [first],
            workspaceRoot: "/tmp/workspace"
        )

        #expect(!result.didRefresh)
        #expect(result.snapshot.rows.map(\.id) == [first.id])
    }
}

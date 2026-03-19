import Foundation
import Testing
@testable import agentGui

@MainActor
struct MessageRowSnapshotTests {

    @Test func userRowSnapshotPrecomputesEditableTextAndPresentation() async throws {
        let workspaceRoot = "/Volumes/T7/文稿/Projects/agentGui"
        let filePath = workspaceRoot + "/agentGui/Views/MessageBubbleView.swift"
        let message = Message.userFixture(text: "请查看 \(filePath)")

        let snapshot = MessageRowSnapshot.make(for: message, workspaceRoot: workspaceRoot)

        let user = try #require(snapshot.user)
        #expect(snapshot.direction == .user)
        #expect(snapshot.senderName == "你")
        #expect(snapshot.editableUserText == user.bodyText)
        #expect(user.presentation.inlineItems.isEmpty == false)
    }

    @Test func userRowSnapshotSkipsMentionsWhenWorkspaceRootIsEmpty() async throws {
        let message = Message.userFixture(text: "请查看 /tmp/ws/agentGui/Views/MessageBubbleView.swift")

        let snapshot = MessageRowSnapshot.make(for: message, workspaceRoot: "")

        let user = try #require(snapshot.user)
        #expect(snapshot.editableUserText == "请查看 /tmp/ws/agentGui/Views/MessageBubbleView.swift")
        #expect(user.presentation.inlineItems == [InlineItem.text(TextRunPresentation(text: "请查看 /tmp/ws/agentGui/Views/MessageBubbleView.swift"))])
    }

    @Test func agentRowSnapshotPrecomputesFlowAndAttachments() async throws {
        let message = Message.agentFixture(text: "结果正文\n\nReferenced files:\n- /tmp/mock.png\n- /tmp/mock.pdf\n- /tmp/mock.txt")

        let snapshot = MessageRowSnapshot.make(for: message, workspaceRoot: "")

        let agent = try #require(snapshot.agent)
        #expect(snapshot.direction == .agent)
        #expect(snapshot.senderName == "Claude")
        #expect(agent.attachments.images == ["/tmp/mock.png"])
        #expect(agent.attachments.pdfs == ["/tmp/mock.pdf"])
        #expect(agent.attachments.others == ["/tmp/mock.txt"])
        #expect(agent.execution.transcript.answerText == "结果正文\n\nReferenced files:\n- /tmp/mock.png\n- /tmp/mock.pdf\n- /tmp/mock.txt")
        #expect(agent.execution.audit.steps.count == 1)
    }
}
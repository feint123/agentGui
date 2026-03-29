import Foundation
import Testing
@testable import agentGui

@MainActor
struct ChatMessageListProjectionRefreshCoordinatorTests {
    @Test
    func refreshKeyIgnoresWorkspaceRootWhenNoRowsDependOnWorkspace() {
        let session = Session.fixture(sessionId: "refresh-key-stable", title: "Refresh Key Stable")
        let userMessage = Message.userMessage(text: "hello", session: session)
        let agentMessage = Message.agentMessage(text: "world", session: session)
        userMessage.status = .completed
        agentMessage.status = .completed

        let keyA = ChatMessageListRefreshKey(
            messages: [userMessage, agentMessage],
            workspaceRoot: "/tmp/refresh-key-a"
        )
        let keyB = ChatMessageListRefreshKey(
            messages: [userMessage, agentMessage],
            workspaceRoot: "/tmp/refresh-key-b"
        )

        #expect(keyA == keyB)
    }

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

    @Test
    func buildRequestCapturesEverythingNeededForBackgroundProjection() {
        let session = Session.fixture(sessionId: "projection-input", title: "Projection Input")
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("projection-input-\(UUID().uuidString)", isDirectory: true)
        let viewsDirectory = workspaceRoot.appendingPathComponent("Views", isDirectory: true)
        let fileURL = viewsDirectory.appendingPathComponent("ChatView.swift")
        try? FileManager.default.createDirectory(at: viewsDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        defer {
            try? FileManager.default.removeItem(at: workspaceRoot)
        }

        let userMessage = Message.userMessage(text: "open \(fileURL.path)", session: session)
        userMessage.status = .completed

        let agentMessage = Message.agentMessage(text: "done", session: session)
        agentMessage.status = .completed

        let toolCall = ToolCall(toolCallId: "tool-1", kind: .execute, message: agentMessage)
        toolCall.title = "npm test"
        toolCall.terminalTaskId = "task-1"
        toolCall.terminalTaskStatus = TerminalTaskStatus.running.rawValue
        toolCall.terminalExecutionMode = TerminalExecutionMode.detached.rawValue
        agentMessage.toolCalls = [toolCall]

        let request = ChatMessageListBuildRequest.make(
            messages: [userMessage, agentMessage],
            workspaceRoot: workspaceRoot.path,
            previousCache: [:],
            generation: 1
        )

        #expect(request.generation == 1)
        #expect(request.workspaceRoot == workspaceRoot.path)
        #expect(request.messages.count == 2)
        #expect(request.messages[0].id == userMessage.id)
        #expect(request.messages[0].textContent == userMessage.textContent)
        #expect(request.messages[0].workspaceDependency?.requiresWorkspaceRoot == true)
        #expect(request.messages[1].directToolCalls.count == 1)
        #expect(request.messages[1].directToolCalls[0].terminalTaskId == "task-1")
    }
}
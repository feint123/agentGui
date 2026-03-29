import Foundation
import Testing
@testable import agentGui

@MainActor
struct ChatMessageListProjectionPerformanceTests {
    @Test
    func deepToolPayloadUpdateDoesNotInvalidateAgentRowWhenSummaryIsStable() async throws {
        let worker = ChatMessageListProjectionWorker()
        let messageID = UUID()
        let toolCallID = UUID()
        let timestamp = Date(timeIntervalSince1970: 15)
        let workspaceRoot = "/tmp/projection-performance-stable-tool"

        let initialMessages = [
            MessageRowBuildInput.fixture(
                id: messageID,
                direction: .agent,
                timestamp: timestamp,
                textContent: "completed command",
                directToolCalls: [
                    ToolCallProjectionInput(
                        id: toolCallID,
                        toolCallId: "execute-stable-1",
                        kind: .execute,
                        title: "npm test",
                        status: .success,
                        terminalOutput: "stable terminal output",
                        toolResultSummary: "Tests passed",
                        toolPayloadRef: "artifact://tests",
                        terminalTaskId: "task-stable-1",
                        terminalTaskStatus: TerminalTaskStatus.completed.rawValue,
                        terminalAgentActionsJSON: makeLargeJSONPayload(seed: "alpha"),
                        terminalExecutionMode: TerminalExecutionMode.attached.rawValue,
                        memoryConflictRecordIDs: ["conflict-a", "conflict-b"]
                    )
                ]
            )
        ]
        let initialRequest = ChatMessageListBuildRequest(
            generation: 1,
            workspaceRoot: workspaceRoot,
            messages: initialMessages,
            previousCache: [:]
        )
        let initialResult = try await worker.build(request: initialRequest)

        let updatedMessages = [
            MessageRowBuildInput.fixture(
                id: messageID,
                direction: .agent,
                timestamp: timestamp,
                textContent: "completed command",
                directToolCalls: [
                    ToolCallProjectionInput(
                        id: toolCallID,
                        toolCallId: "execute-stable-1",
                        kind: .execute,
                        title: "npm test",
                        status: .success,
                        terminalOutput: "stable terminal output",
                        toolResultSummary: "Tests passed",
                        toolPayloadRef: "artifact://tests",
                        terminalTaskId: "task-stable-1",
                        terminalTaskStatus: TerminalTaskStatus.completed.rawValue,
                        terminalAgentActionsJSON: makeLargeJSONPayload(seed: "beta"),
                        terminalExecutionMode: TerminalExecutionMode.attached.rawValue,
                        memoryConflictRecordIDs: ["conflict-c", "conflict-d", "conflict-e"]
                    )
                ]
            )
        ]
        let updatedRequest = ChatMessageListBuildRequest(
            generation: 2,
            workspaceRoot: workspaceRoot,
            messages: updatedMessages,
            previousCache: initialResult.snapshot.cache
        )
        let updatedResult = try await worker.build(request: updatedRequest)

        #expect(updatedResult.rebuiltRowIDs.isEmpty)
        #expect(updatedResult.reusedRowCount == 1)
    }

    @Test
    func largeHistoryIncrementalRefreshReusesOnlyStreamingTailRow() async throws {
        let worker = ChatMessageListProjectionWorker()
        let workspaceRoot = "/tmp/projection-performance"
        let initialMessages = makeHistoryInputs(count: 1_000, tailText: "draft-0")
        let initialRequest = ChatMessageListBuildRequest(
            generation: 1,
            workspaceRoot: workspaceRoot,
            messages: initialMessages,
            previousCache: [:]
        )

        let initialResult = try await worker.build(request: initialRequest)

        var updatedMessages = initialMessages
        let tail = updatedMessages.removeLast()
        updatedMessages.append(
            MessageRowBuildInput.fixture(
                id: tail.id,
                direction: tail.direction,
                status: tail.status,
                timestamp: tail.timestamp,
                textContent: "draft-1",
                errorMessage: tail.errorMessage,
                directToolCalls: tail.directToolCalls,
                rounds: tail.rounds,
                workspaceDependency: tail.workspaceDependency
            )
        )

        let incrementalRequest = ChatMessageListBuildRequest(
            generation: 2,
            workspaceRoot: workspaceRoot,
            messages: updatedMessages,
            previousCache: initialResult.snapshot.cache
        )
        let incrementalResult = try await worker.build(request: incrementalRequest)

        #expect(incrementalResult.rebuiltRowIDs == [tail.id])
        #expect(incrementalResult.reusedRowCount == initialMessages.count - 1)
    }

    @Test
    func workspaceRootChangeRebuildsOnlyDependentRows() async throws {
        let worker = ChatMessageListProjectionWorker()
        let workspaceA = "/tmp/projection-performance-a"
        let workspaceB = "/tmp/projection-performance-b"
        let dependentID = UUID()
        let stableUserID = UUID()
        let agentID = UUID()
        let timestamp = Date(timeIntervalSince1970: 10)

        let initialMessages = [
            MessageRowBuildInput.fixture(
                id: dependentID,
                direction: .user,
                timestamp: timestamp,
                textContent: "open Views/ChatView.swift",
                workspaceDependency: WorkspaceDependencyFingerprint(
                    workspaceRoot: workspaceA,
                    requiresWorkspaceRoot: true
                )
            ),
            MessageRowBuildInput.fixture(
                id: stableUserID,
                direction: .user,
                timestamp: timestamp.addingTimeInterval(1),
                textContent: "hello"
            ),
            MessageRowBuildInput.fixture(
                id: agentID,
                direction: .agent,
                timestamp: timestamp.addingTimeInterval(2),
                textContent: "done"
            )
        ]
        let initialRequest = ChatMessageListBuildRequest(
            generation: 1,
            workspaceRoot: workspaceA,
            messages: initialMessages,
            previousCache: [:]
        )
        let initialResult = try await worker.build(request: initialRequest)

        let updatedMessages = [
            MessageRowBuildInput.fixture(
                id: dependentID,
                direction: .user,
                timestamp: timestamp,
                textContent: "open Views/ChatView.swift",
                workspaceDependency: WorkspaceDependencyFingerprint(
                    workspaceRoot: workspaceB,
                    requiresWorkspaceRoot: true
                )
            ),
            initialMessages[1],
            initialMessages[2]
        ]
        let updatedRequest = ChatMessageListBuildRequest(
            generation: 2,
            workspaceRoot: workspaceB,
            messages: updatedMessages,
            previousCache: initialResult.snapshot.cache
        )
        let updatedResult = try await worker.build(request: updatedRequest)

        #expect(updatedResult.rebuiltRowIDs == [dependentID])
        #expect(updatedResult.reusedRowCount == 2)
    }

    @Test
    func executeToolPlannerUpdatesInvalidateProjectedRow() async throws {
        let worker = ChatMessageListProjectionWorker()
        let messageID = UUID()
        let toolCallID = UUID()
        let timestamp = Date(timeIntervalSince1970: 20)
        let initialMessages = [
            MessageRowBuildInput.fixture(
                id: messageID,
                direction: .agent,
                timestamp: timestamp,
                textContent: "running command",
                directToolCalls: [
                    ToolCallProjectionInput(
                        id: toolCallID,
                        toolCallId: "execute-1",
                        kind: .execute,
                        title: "npm test",
                        status: .inProgress,
                        terminalTaskId: "task-1",
                        terminalTaskStatus: TerminalTaskStatus.running.rawValue,
                        terminalInteractionPhase: TerminalInteractionPhase.planning.rawValue,
                        terminalPlannerSummary: "Planning next step",
                        terminalExecutionMode: TerminalExecutionMode.attached.rawValue
                    )
                ]
            )
        ]
        let initialRequest = ChatMessageListBuildRequest(
            generation: 1,
            workspaceRoot: "/tmp/projection-performance-c",
            messages: initialMessages,
            previousCache: [:]
        )
        let initialResult = try await worker.build(request: initialRequest)

        let updatedMessages = [
            MessageRowBuildInput.fixture(
                id: messageID,
                direction: .agent,
                timestamp: timestamp,
                textContent: "running command",
                directToolCalls: [
                    ToolCallProjectionInput(
                        id: toolCallID,
                        toolCallId: "execute-1",
                        kind: .execute,
                        title: "npm test",
                        status: .inProgress,
                        terminalTaskId: "task-1",
                        terminalTaskStatus: TerminalTaskStatus.running.rawValue,
                        terminalInteractionPhase: TerminalInteractionPhase.autoExecuting.rawValue,
                        terminalPlannerSummary: "Executing auto plan",
                        terminalExecutionMode: TerminalExecutionMode.attached.rawValue
                    )
                ]
            )
        ]
        let updatedRequest = ChatMessageListBuildRequest(
            generation: 2,
            workspaceRoot: "/tmp/projection-performance-c",
            messages: updatedMessages,
            previousCache: initialResult.snapshot.cache
        )
        let updatedResult = try await worker.build(request: updatedRequest)

        #expect(updatedResult.rebuiltRowIDs == [messageID])
        #expect(updatedResult.reusedRowCount == 0)
        #expect(updatedResult.snapshot.rows.first?.agent?.execution.theater.cards.first?.subtitle == "Executing auto plan")
    }

    @Test
    func subagentAuditMetadataUpdatesInvalidateProjectedRow() async throws {
        let worker = ChatMessageListProjectionWorker()
        let messageID = UUID()
        let toolCallID = UUID()
        let timestamp = Date(timeIntervalSince1970: 25)

        let initialMessages = [
            MessageRowBuildInput.fixture(
                id: messageID,
                direction: .agent,
                timestamp: timestamp,
                textContent: "subagent finished",
                directToolCalls: [
                    ToolCallProjectionInput(
                        id: toolCallID,
                        toolCallId: "subagent-1",
                        kind: .subagent,
                        title: "delegate",
                        status: .success,
                        subagentTask: "Review diff",
                        subagentResultKind: "structured",
                        subagentMessageMetadata: [
                            MetadataPair(key: "verificationPassed", value: "true"),
                            MetadataPair(key: "verificationSummary", value: "Verifier stable"),
                            MetadataPair(key: "source", value: "run-a")
                        ]
                    )
                ]
            )
        ]
        let initialRequest = ChatMessageListBuildRequest(
            generation: 1,
            workspaceRoot: "/tmp/projection-performance-subagent-metadata",
            messages: initialMessages,
            previousCache: [:]
        )
        let initialResult = try await worker.build(request: initialRequest)

        let updatedMessages = [
            MessageRowBuildInput.fixture(
                id: messageID,
                direction: .agent,
                timestamp: timestamp,
                textContent: "subagent finished",
                directToolCalls: [
                    ToolCallProjectionInput(
                        id: toolCallID,
                        toolCallId: "subagent-1",
                        kind: .subagent,
                        title: "delegate",
                        status: .success,
                        subagentTask: "Review diff",
                        subagentResultKind: "structured",
                        subagentMessageMetadata: [
                            MetadataPair(key: "verificationPassed", value: "true"),
                            MetadataPair(key: "verificationSummary", value: "Verifier stable"),
                            MetadataPair(key: "source", value: "run-b")
                        ]
                    )
                ]
            )
        ]
        let updatedRequest = ChatMessageListBuildRequest(
            generation: 2,
            workspaceRoot: "/tmp/projection-performance-subagent-metadata",
            messages: updatedMessages,
            previousCache: initialResult.snapshot.cache
        )
        let updatedResult = try await worker.build(request: updatedRequest)

        #expect(updatedResult.rebuiltRowIDs == [messageID])
        #expect(updatedResult.reusedRowCount == 0)
    }

    @Test
    func subagentResultKindBadgeUpdatesInvalidateProjectedRowWhenSummaryIsStable() async throws {
        let worker = ChatMessageListProjectionWorker()
        let messageID = UUID()
        let toolCallID = UUID()
        let timestamp = Date(timeIntervalSince1970: 26)
        let metadata = [
            MetadataPair(key: "verificationPassed", value: "true"),
            MetadataPair(key: "verificationSummary", value: "Verifier stable")
        ]

        let initialMessages = [
            MessageRowBuildInput.fixture(
                id: messageID,
                direction: .agent,
                timestamp: timestamp,
                textContent: "subagent finished",
                directToolCalls: [
                    ToolCallProjectionInput(
                        id: toolCallID,
                        toolCallId: "subagent-2",
                        kind: .subagent,
                        title: "delegate",
                        status: .success,
                        subagentTask: "Review diff",
                        subagentResultKind: "structured",
                        subagentMessageMetadata: metadata
                    )
                ]
            )
        ]
        let initialRequest = ChatMessageListBuildRequest(
            generation: 1,
            workspaceRoot: "/tmp/projection-performance-subagent-kind",
            messages: initialMessages,
            previousCache: [:]
        )
        let initialResult = try await worker.build(request: initialRequest)

        let updatedMessages = [
            MessageRowBuildInput.fixture(
                id: messageID,
                direction: .agent,
                timestamp: timestamp,
                textContent: "subagent finished",
                directToolCalls: [
                    ToolCallProjectionInput(
                        id: toolCallID,
                        toolCallId: "subagent-2",
                        kind: .subagent,
                        title: "delegate",
                        status: .success,
                        subagentTask: "Review diff",
                        subagentResultKind: "text",
                        subagentMessageMetadata: metadata
                    )
                ]
            )
        ]
        let updatedRequest = ChatMessageListBuildRequest(
            generation: 2,
            workspaceRoot: "/tmp/projection-performance-subagent-kind",
            messages: updatedMessages,
            previousCache: initialResult.snapshot.cache
        )
        let updatedResult = try await worker.build(request: updatedRequest)

        #expect(updatedResult.rebuiltRowIDs == [messageID])
        #expect(updatedResult.reusedRowCount == 0)
    }
}

private func makeHistoryInputs(count: Int, tailText: String) -> [MessageRowBuildInput] {
    let baseTime = Date(timeIntervalSince1970: 1_000)

    return (0..<count).map { index in
        MessageRowBuildInput.fixture(
            id: UUID(),
            direction: index.isMultiple(of: 2) ? .user : .agent,
            timestamp: baseTime.addingTimeInterval(TimeInterval(index)),
            textContent: index == count - 1 ? tailText : "message-\(index)"
        )
    }
}

private func makeLargeJSONPayload(seed: String) -> String {
    let item = "{\"step\":\"\(seed)\"}"
    return String(repeating: item, count: 200)
}

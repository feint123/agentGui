import Foundation
import SwiftAnthropic
import Testing
@testable import agentGui

@MainActor
struct AgentLoopToolExecutionCoordinatorTests {

    @Test func interceptorWinsOverBuiltInRouting() async {
        let coordinator = AgentLoopToolExecutionCoordinator(dependencies: .fixture())
        let pendingTool = AgentLoopPendingTool(id: "call-1", name: "run_subagent", partialJson: "{\"agent_name\":\"worker\",\"task\":\"fix\"}")
        let record = ToolCall.fixture(toolCallId: "call-1", kind: .execute)

        let outcome = await coordinator.execute(
            pendingTool: pendingTool,
            record: record,
            interceptor: { _, _ in .success("intercepted") }
        )

        #expect(outcome.result.text == "intercepted")
        #expect(outcome.record.subagentResultKind == nil)
    }

    @Test func runSubagentRoutingPersistsSubagentAuditMetadata() async {
        let coordinator = AgentLoopToolExecutionCoordinator(
            dependencies: .fixture(
                runSubagent: { _, _ in
                    .text("done", sender: "worker", metadata: ["rounds": "2"])
                }
            )
        )
        let pendingTool = AgentLoopPendingTool(id: "call-2", name: "run_subagent", partialJson: "{\"agent_name\":\"worker\",\"task\":\"fix\"}")
        let record = ToolCall.fixture(toolCallId: "call-2", kind: .execute)

        let outcome = await coordinator.execute(pendingTool: pendingTool, record: record)

        #expect(outcome.result.text == "done")
        #expect(outcome.record.subagentAgentName == "worker")
        #expect(outcome.record.subagentResultKind == "text")
        #expect(outcome.record.subagentMessageMetadata?["rounds"] == "2")
    }

    @Test func startWorkflowRoutingUsesWorkflowExecutor() async {
        let coordinator = AgentLoopToolExecutionCoordinator(
            dependencies: .fixture(
                startWorkflow: { _ in .success("workflow-started") }
            )
        )
        let pendingTool = AgentLoopPendingTool(id: "call-3", name: "start_workflow", partialJson: "{\"workflow_id\":\"qa\"}")
        let record = ToolCall.fixture(toolCallId: "call-3", kind: .execute)

        let outcome = await coordinator.execute(pendingTool: pendingTool, record: record)

        #expect(outcome.result.text == "workflow-started")
    }

    @Test func foregroundBashStartsAndFinishesObservation() async {
        final class Probe {
            var started = false
            var finished = false
        }

        let probe = Probe()
        let coordinator = AgentLoopToolExecutionCoordinator(
            dependencies: .fixture(
                executeTool: { _, _ in .success("bash-done") },
                normalizeBashRequest: { _ in
                    BashToolRequest(
                        command: "pwd",
                        taskId: "task-1",
                        executionMode: .foreground,
                        input: nil,
                        signal: nil,
                        goalHint: nil,
                        scanPolicy: .adaptive,
                        autoReplyPolicy: .safeOnly,
                        timeout: nil,
                        restart: false
                    )
                },
                startForegroundBashObservation: { _, _ in
                    probe.started = true
                    return Task { }
                },
                finishBashObservation: { _, _, _ in
                    probe.finished = true
                }
            )
        )
        let pendingTool = AgentLoopPendingTool(id: "call-4", name: "bash", partialJson: "{\"command\":\"pwd\"}")
        let record = ToolCall.fixture(toolCallId: "call-4", kind: .execute)

        let outcome = await coordinator.execute(pendingTool: pendingTool, record: record)

        #expect(outcome.result.text == "bash-done")
        #expect(probe.started)
        #expect(probe.finished)
    }

    @Test func genericToolsFallBackToDefaultExecutor() async {
        let coordinator = AgentLoopToolExecutionCoordinator(
            dependencies: .fixture(
                executeTool: { name, _ in .success("default:\(name)") }
            )
        )
        let pendingTool = AgentLoopPendingTool(id: "call-5", name: "web_fetch", partialJson: "{\"url\":\"https://example.com\"}")
        let record = ToolCall.fixture(toolCallId: "call-5", kind: .execute)

        let outcome = await coordinator.execute(pendingTool: pendingTool, record: record)

        #expect(outcome.result.text == "default:web_fetch")
    }
}

private extension AgentLoopToolExecutionCoordinator.Dependencies {
    static func fixture(
        runSubagent: @escaping (MessageResponse.Content.Input, ToolCall) async -> AgentMessage = { _, _ in .text("subagent", sender: "worker") },
        startWorkflow: @escaping (MessageResponse.Content.Input) async -> ToolExecutionResult = { _ in .success("workflow") },
        executeTool: @escaping (String, MessageResponse.Content.Input) async -> ToolExecutionResult = { name, _ in .success(name) },
        normalizeBashRequest: @escaping (MessageResponse.Content.Input) throws -> BashToolRequest = { _ in
            BashToolRequest(
                command: "pwd",
                taskId: nil,
                executionMode: .foreground,
                input: nil,
                signal: nil,
                goalHint: nil,
                scanPolicy: .adaptive,
                autoReplyPolicy: .safeOnly,
                timeout: nil,
                restart: false
            )
        },
        startForegroundBashObservation: @escaping (BashToolRequest, ToolCall) async -> Task<Void, Never>? = { _, _ in nil },
        finishBashObservation: @escaping (BashToolRequest, ToolCall, ToolExecutionResult) async -> Void = { _, _, _ in },
        populateStoryMemoryAuditFields: @escaping (ToolCall, AgentMessage) -> Void = { _, _ in }
    ) -> AgentLoopToolExecutionCoordinator.Dependencies {
        .init(
            runSubagent: runSubagent,
            startWorkflow: startWorkflow,
            executeTool: executeTool,
            normalizeBashRequest: normalizeBashRequest,
            startForegroundBashObservation: startForegroundBashObservation,
            finishBashObservation: finishBashObservation,
            populateStoryMemoryAuditFields: populateStoryMemoryAuditFields
        )
    }
}
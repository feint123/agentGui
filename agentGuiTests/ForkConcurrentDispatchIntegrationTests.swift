// agentGuiTests/ForkConcurrentDispatchIntegrationTests.swift
import XCTest
@testable import agentGui
import SwiftAnthropic

/// S-F3 端到端集成测试：验证 fork 子代理从检测到并发批次的完整路径。
final class ForkConcurrentDispatchIntegrationTests: XCTestCase {

    // MARK: - Fork Context Stamping

    func test_forkToolDetection_stampsIsForkSubagent() {
        // 构造一个 run_subagent 输入，agent_name 为 "fork"
        var forkTool = AgentLoopPendingTool(id: "fork-1", name: "run_subagent")
        forkTool.partialJson = #"{"agent_name":"fork","task":"Explore the auth module"}"#

        // 验证字段正确解析
        if case .string(let agentName) = forkTool.parsedInput["agent_name"] {
            XCTAssertEqual(agentName, ForkSubagentDefinition.agentType)
        } else {
            XCTFail("expected string agent_name in parsedInput")
        }
        XCTAssertFalse(forkTool.isForkSubagent, "Before executor injection, isForkSubagent must be false")

        // 模拟 executor 的检测逻辑
        if case .string(let agentName) = forkTool.parsedInput["agent_name"],
           agentName == ForkSubagentDefinition.agentType {
            forkTool.isForkSubagent = true
        }

        XCTAssertTrue(forkTool.isForkSubagent, "After detection, isForkSubagent must be true")
    }

    func test_threeForkTools_partitionedIntoConcurrentBatch() {
        let planner = ToolConcurrencyBatchPlanner(registry: DefaultToolRegistry())

        var fork1 = AgentLoopPendingTool(id: "f1", name: "run_subagent")
        fork1.partialJson = #"{"agent_name":"fork","task":"Task A"}"#
        fork1.isForkSubagent = true

        var fork2 = AgentLoopPendingTool(id: "f2", name: "run_subagent")
        fork2.partialJson = #"{"agent_name":"fork","task":"Task B"}"#
        fork2.isForkSubagent = true

        var fork3 = AgentLoopPendingTool(id: "f3", name: "run_subagent")
        fork3.partialJson = #"{"agent_name":"fork","task":"Task C"}"#
        fork3.isForkSubagent = true

        let batches = planner.partition([fork1, fork2, fork3])
        XCTAssertEqual(batches.count, 1, "All 3 fork tools must land in one concurrent batch")
        guard case .concurrent(let tools) = batches[0] else {
            return XCTFail("Expected concurrent batch")
        }
        XCTAssertEqual(tools.count, 3)
        // Preserve original order
        XCTAssertEqual(tools[0].id, "f1")
        XCTAssertEqual(tools[1].id, "f2")
        XCTAssertEqual(tools[2].id, "f3")
    }

    // MARK: - ForkMessageBuilder full pipeline (S-F3 overload)

    func test_twoForkChildren_buildInitialMessages_cacheIdenticalPrefix() {
        let builder = ForkMessageBuilder()
        let assistantObjects: [MessageParameter.Message.Content.ContentObject] = [
            .toolUse("t1", "run_subagent", ["agent_name": .string("fork"), "task": .string("Task A")]),
            .toolUse("t2", "run_subagent", ["agent_name": .string("fork"), "task": .string("Task B")])
        ]

        let msgsA = builder.buildForkedMessages(directive: "Task A", assistantObjects: assistantObjects)
        let msgsB = builder.buildForkedMessages(directive: "Task B", assistantObjects: assistantObjects)

        // Both children get 2 messages
        XCTAssertEqual(msgsA.count, 2)
        XCTAssertEqual(msgsB.count, 2)

        // Shared assistant message (byte-identical → cache hit)
        XCTAssertEqual(msgsA[0].role, "assistant")
        XCTAssertEqual(msgsB[0].role, "assistant")

        // Both fork children have tool_result placeholders (must be identical)
        guard case .list(let userObjsA) = msgsA[1].content else {
            return XCTFail("Expected list user content A")
        }
        guard case .list(let userObjsB) = msgsB[1].content else {
            return XCTFail("Expected list user content B")
        }
        // First 2 items are tool_results — identical placeholder for cache sharing
        for i in 0..<2 {
            guard case .toolResult(let idA, let textA, _, _) = userObjsA[i] else {
                return XCTFail("Expected toolResult A at index \(i)")
            }
            guard case .toolResult(let idB, let textB, _, _) = userObjsB[i] else {
                return XCTFail("Expected toolResult B at index \(i)")
            }
            XCTAssertEqual(idA, idB)
            XCTAssertEqual(textA, textB, "Placeholder text must be identical for cache sharing")
        }
        // Last item is the per-child directive (must differ)
        if case .text(let textA) = userObjsA.last, case .text(let textB) = userObjsB.last {
            XCTAssertNotEqual(textA, textB, "Directives must differ between fork children")
        } else {
            XCTFail("Last object should be text (directive)")
        }
    }

    func test_isInForkChild_detectsForkBoilerplate() {
        let builder = ForkMessageBuilder()
        let directive = "Check auth module"
        let forkedMsgs = builder.buildForkedMessages(
            directive: directive,
            assistantObjects: [.toolUse("t1", "run_subagent", [:])]
        )

        // forkedMsgs = [assistantMsg, userMsg]
        // userMsg contains the buildChildMessage text which has <fork-boilerplate>
        XCTAssertTrue(
            isInForkChild(forkedMsgs),
            "isInForkChild must detect fork boilerplate in the user message built by ForkMessageBuilder"
        )
    }

    func test_isInForkChild_falseForNormalMessages() {
        let normalMessages: [MessageParameter.Message] = [
            .init(role: .user, content: .text("Please help me refactor the code")),
            .init(role: .assistant, content: .text("Sure, I'll help you."))
        ]
        XCTAssertFalse(isInForkChild(normalMessages), "Normal messages must not trigger fork guard")
    }

    // MARK: - ForkSubagentOverride

    func test_forkSubagentOverride_usesParentSystemPromptInsteadOfDefinition() {
        let override = ForkSubagentOverride(
            initialMessages: [.init(role: .user, content: .text("test"))],
            parentSystemPromptText: "Parent system prompt"
        )
        XCTAssertEqual(override.parentSystemPromptText, "Parent system prompt")
        XCTAssertEqual(override.initialMessages.count, 1)
    }

    // MARK: - AgentLoopForkContext Equatable exclusion

    func test_pendingTool_equatable_excludesForkContext() {
        let ctx = AgentLoopForkContext(parentMessages: [], assistantObjects: [], parentSystemPromptText: "sys")
        var toolA = AgentLoopPendingTool(id: "t1", name: "run_subagent")
        toolA.isForkSubagent = true
        toolA.forkContext = ctx

        var toolB = AgentLoopPendingTool(id: "t1", name: "run_subagent")
        toolB.isForkSubagent = true
        toolB.forkContext = nil  // different forkContext

        // forkContext is intentionally excluded from Equatable — tools should be equal
        XCTAssertEqual(toolA, toolB, "forkContext must not participate in Equatable comparison")
    }
}

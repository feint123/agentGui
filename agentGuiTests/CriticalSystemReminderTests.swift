// agentGuiTests/CriticalSystemReminderTests.swift
import XCTest
import SwiftAnthropic
@testable import agentGui

// MARK: - CriticalSystemReminderTests
//
// 验证 S-A5 的核心行为：
// 1. buildSubagentFirstTurnMessage 根据 criticalReminder 拼接首轮消息
// 2. AgentLoopRunRequest 正确携带 criticalReminder
// 3. verifier 代理定义包含预期的 criticalReminder 文本

final class CriticalSystemReminderTests: XCTestCase {

    // MARK: - buildSubagentFirstTurnMessage

    func test_nilReminder_returnsTaskUnchanged() {
        let result = ClaudeService.buildSubagentFirstTurnMessage(
            task: "Verify the build passes.",
            criticalReminder: nil
        )
        XCTAssertEqual(result, "Verify the build passes.")
    }

    func test_emptyReminder_returnsTaskUnchanged() {
        let result = ClaudeService.buildSubagentFirstTurnMessage(
            task: "Verify the build passes.",
            criticalReminder: ""
        )
        XCTAssertEqual(result, "Verify the build passes.",
            "空字符串 reminder 不应注入")
    }

    func test_reminder_isPrependedToTask() {
        let reminder = "CRITICAL: READ-ONLY. Do not edit files."
        let task = "Check if feature X is implemented."
        let result = ClaudeService.buildSubagentFirstTurnMessage(
            task: task,
            criticalReminder: reminder
        )
        XCTAssertTrue(result.hasPrefix(reminder),
            "reminder 必须出现在消息开头")
        XCTAssertTrue(result.hasSuffix(task),
            "task 必须保留在消息末尾")
    }

    func test_reminder_separatorIsDoubleNewline() {
        let reminder = "CRITICAL: Stay read-only."
        let task = "Explore the src/ directory."
        let result = ClaudeService.buildSubagentFirstTurnMessage(
            task: task,
            criticalReminder: reminder
        )
        let expected = "CRITICAL: Stay read-only.\n\nExplore the src/ directory."
        XCTAssertEqual(result, expected,
            "reminder 与 task 之间分隔符必须是 \\n\\n")
    }

    // MARK: - AgentLoopRunRequest critical reminder field

    func test_agentLoopRunRequest_defaultCriticalReminderIsNil() {
        // 使用最简化的 stub 验证 criticalReminder 默认值
        let request = AgentLoopRunRequest(
            service: AnthropicServiceFactory.service(apiKey: "test", betaHeaders: [String]?.none),
            modelId: "claude-sonnet-4-6",
            tools: [],
            system: nil,
            maxRounds: 10,
            toolExecutionContext: .subagent,
            toolApprovalMode: .bypassApprovals,
            runSource: "test",
            runLabel: nil,
            requestedBudgetSeconds: nil
            // criticalReminder 不传，应默认为 nil
        )
        XCTAssertNil(request.criticalReminder,
            "criticalReminder 在不传参时应为 nil")
    }

    func test_agentLoopRunRequest_storesCriticalReminder() {
        let reminder = "CRITICAL: This is VERIFICATION-ONLY."
        let request = AgentLoopRunRequest(
            service: AnthropicServiceFactory.service(apiKey: "test", betaHeaders: [String]?.none),
            modelId: "claude-sonnet-4-6",
            tools: [],
            system: nil,
            maxRounds: 10,
            toolExecutionContext: .subagent,
            toolApprovalMode: .bypassApprovals,
            runSource: "test",
            runLabel: "verifier",
            requestedBudgetSeconds: nil,
            criticalReminder: reminder
        )
        XCTAssertEqual(request.criticalReminder, reminder)
    }

    // MARK: - verifier agent definition

    func test_verifierAgentDefinition_hasExpectedReminder() throws {
        let loader = AgentDefinitionLoader()
        guard let url = Bundle(for: type(of: self)).url(
            forResource: "verifier",
            withExtension: "agent.md",
            subdirectory: "Agents"
        ) else {
            // 在 test bundle 中资源路径可能不同，尝试 source 路径 fallback
            try XCTSkipIf(true, "verifier.agent.md 在 test bundle 中不可达，跳过")
            return
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        let doc = try loader.parseDocument(named: "verifier.agent.md", raw: raw)

        XCTAssertNotNil(doc.criticalReminder,
            "verifier 代理必须有 criticalReminder")
        let reminder = doc.criticalReminder!
        XCTAssertTrue(
            reminder.contains("VERIFICATION") || reminder.contains("CRITICAL"),
            "verifier 的 criticalReminder 应包含 VERIFICATION 或 CRITICAL 关键词"
        )
        XCTAssertTrue(
            reminder.contains("VERDICT"),
            "verifier 的 criticalReminder 应包含 VERDICT 关键词（要求 agent 以 verdict 结尾）"
        )
    }

    func test_verifierWorkflowRole_hasCriticalReminder() throws {
        let role = WorkflowRoleDefinition.verifier
        XCTAssertNotNil(role.criticalReminder,
            "WorkflowRoleDefinition.verifier 应携带 criticalReminder")
    }
}

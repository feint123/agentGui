// agentGuiTests/SkillForkExecutionTests.swift
import XCTest
import SwiftAnthropic
@testable import agentGui

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Stub subagent loop runner
// ─────────────────────────────────────────────────────────────────────────────

/// 测试用 stub：不执行真实 API，直接返回预设文本和轮次。
final class StubSkillSubagentRunner: SkillSubagentRunning, @unchecked Sendable {
    var capturedTask: String?
    var capturedAllowedTools: [String]?
    var capturedModelId: String?
    var returnText: String = "stub result"

    func runSkillSubagent(
        task: String,
        allowedTools: [String],
        modelId: String
    ) async throws -> String {
        capturedTask = task
        capturedAllowedTools = allowedTools
        capturedModelId = modelId
        return returnText
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SkillForkExecutor unit tests
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class SkillForkExecutionTests: XCTestCase {

    // 辅助方法：构造带 fork context 的 skill
    private func makeForkSkill(
        directoryName: String = "code-review",
        allowedTools: [String] = [],
        model: String? = nil
    ) -> Skill {
        Skill.fixture(
            directoryName: directoryName,
            name: directoryName,
            executionContext: .fork,
            allowedTools: allowedTools,
            model: model
        )
    }

    // ── 1. 基础 fork 路径：传入 task 正确，返回子代理文本
    func test_fork_basic_returnsSubagentResult() async throws {
        let stub = StubSkillSubagentRunner()
        stub.returnText = "Review complete: 3 issues found"
        let executor = SkillForkExecutor(runner: stub, defaultModelId: "claude-opus-4-5")

        let skill = makeForkSkill()
        let result = try await executor.execute(
            skill: skill,
            processedContent: "Please review the code.",
            parentModelId: "claude-opus-4-5"
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("Review complete"))
        XCTAssertEqual(stub.capturedTask, "Please review the code.")
    }

    // ── 2. allowedTools 传递给 runner
    func test_fork_withAllowedTools_passesThemToRunner() async throws {
        let stub = StubSkillSubagentRunner()
        let executor = SkillForkExecutor(runner: stub, defaultModelId: "claude-haiku-4-5")

        let skill = makeForkSkill(allowedTools: ["bash", "str_replace_based_edit_tool"])
        _ = try await executor.execute(
            skill: skill,
            processedContent: "Run tests.",
            parentModelId: "claude-haiku-4-5"
        )

        XCTAssertEqual(stub.capturedAllowedTools, ["bash", "str_replace_based_edit_tool"])
    }

    // ── 3. skill.model 覆盖父 agent 模型
    func test_fork_modelOverride_usesSkillModel() async throws {
        let stub = StubSkillSubagentRunner()
        let executor = SkillForkExecutor(runner: stub, defaultModelId: "claude-opus-4-5")

        let skill = makeForkSkill(model: "claude-haiku-4-5")
        _ = try await executor.execute(
            skill: skill,
            processedContent: "Do something.",
            parentModelId: "claude-opus-4-5"
        )

        XCTAssertEqual(stub.capturedModelId, "claude-haiku-4-5")
    }

    // ── 4. 无 model override 时继承父 agent 模型
    func test_fork_noModelOverride_inheritsParentModel() async throws {
        let stub = StubSkillSubagentRunner()
        let executor = SkillForkExecutor(runner: stub, defaultModelId: "claude-opus-4-5")

        let skill = makeForkSkill()   // model = nil
        _ = try await executor.execute(
            skill: skill,
            processedContent: "Do something.",
            parentModelId: "claude-sonnet-4-5"
        )

        XCTAssertEqual(stub.capturedModelId, "claude-sonnet-4-5")
    }

    // ── 5. runner 抛出错误时，返回 isError=true 的 ToolExecutionResult
    func test_fork_runnerThrows_returnsErrorResult() async throws {
        struct RunnerError: Error {}
        final class ThrowingRunner: SkillSubagentRunning, @unchecked Sendable {
            func runSkillSubagent(task: String, allowedTools: [String], modelId: String) async throws -> String {
                throw RunnerError()
            }
        }
        let executor = SkillForkExecutor(runner: ThrowingRunner(), defaultModelId: "claude-opus-4-5")
        let skill = makeForkSkill()
        let result = try await executor.execute(
            skill: skill,
            processedContent: "Fail.",
            parentModelId: "claude-opus-4-5"
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("code-review"))
    }

    // ── 6. fork result header 格式正确
    func test_fork_resultHeader_containsSkillName() async throws {
        let stub = StubSkillSubagentRunner()
        stub.returnText = "All tests passed."
        let executor = SkillForkExecutor(runner: stub, defaultModelId: "claude-opus-4-5")

        let skill = makeForkSkill(directoryName: "run-tests")
        let result = try await executor.execute(
            skill: skill,
            processedContent: "Run the test suite.",
            parentModelId: "claude-opus-4-5"
        )

        XCTAssertTrue(result.text.hasPrefix("[Skill fork result: run-tests]"),
                      "Expected header prefix, got: \(result.text.prefix(50))")
    }

    // ── 7. allowedTools 为空时，runner 收到空数组（不限制）
    func test_fork_noAllowedTools_passesEmptyArray() async throws {
        let stub = StubSkillSubagentRunner()
        let executor = SkillForkExecutor(runner: stub, defaultModelId: "claude-opus-4-5")

        let skill = makeForkSkill(allowedTools: [])
        _ = try await executor.execute(
            skill: skill,
            processedContent: "Do work.",
            parentModelId: "claude-opus-4-5"
        )

        XCTAssertEqual(stub.capturedAllowedTools, [])
    }
}

// agentGuiTests/SkillInvocationProcessorTests.swift
import XCTest
import SwiftAnthropic
@testable import agentGui

// ─────────────────────────────────────────────
// MARK: - InMemory SkillService stub
// ─────────────────────────────────────────────

/// 轻量的 stub：不读磁盘，直接在内存中返回预设内容。
final class StubSkillContentProvider: SkillContentProviding, @unchecked Sendable {
    var skills: [Skill] = []
    var contentByDirectory: [String: String] = [:]

    func skillsList() async -> [Skill] { skills }

    func readSkillContent(name: String) async -> String? {
        guard let skill = skills.first(where: { $0.name == name || $0.directoryName == name }) else {
            return nil
        }
        return contentByDirectory[skill.directoryName]
    }
}

// ─────────────────────────────────────────────
// MARK: - SkillInvocationProcessorTests
// ─────────────────────────────────────────────

@MainActor
final class SkillInvocationProcessorTests: XCTestCase {

    private func makeProvider(skill: Skill, content: String) -> StubSkillContentProvider {
        let p = StubSkillContentProvider()
        p.skills = [skill]
        p.contentByDirectory[skill.directoryName] = content
        return p
    }

    // 正常 inline：返回替换后的内容
    func test_invoke_inline_returnsExpandedContent() async {
        let skill = Skill.fixture(
            directoryName: "review-pr",
            name: "review-pr",
            description: "Review a PR"
        )
        let provider = makeProvider(skill: skill, content: "Review PR $ARGUMENTS now.")
        let processor = SkillInvocationProcessor(provider: provider, sessionId: "s1")

        let result = await processor.invoke(skillName: "review-pr", args: "123")

        guard case .success(let r) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertTrue(r.content.contains("Review PR 123 now."))
        XCTAssertEqual(r.commandName, "review-pr")
        XCTAssertTrue(r.allowedTools.isEmpty)
    }

    // allowedTools 被传入结果
    func test_invoke_withAllowedTools_returnsThem() async {
        let skill = Skill.fixture(
            directoryName: "safe-skill",
            allowedTools: ["bash", "str_replace_based_edit_tool"]
        )
        let provider = makeProvider(skill: skill, content: "Do safe things.")
        let processor = SkillInvocationProcessor(provider: provider, sessionId: "s1")

        let result = await processor.invoke(skillName: "safe-skill", args: nil)

        guard case .success(let r) = result else { return XCTFail() }
        XCTAssertEqual(r.allowedTools, ["bash", "str_replace_based_edit_tool"])
    }

    // disableModelInvocation = true → 返回 .disabled
    func test_invoke_disabledSkill_returnsDisabled() async {
        let skill = Skill.fixture(directoryName: "protected", disableModelInvocation: true)
        let provider = makeProvider(skill: skill, content: "secret")
        let processor = SkillInvocationProcessor(provider: provider, sessionId: "s1")

        let result = await processor.invoke(skillName: "protected", args: nil)

        guard case .disabled(let name) = result else {
            return XCTFail("Expected .disabled, got \(result)")
        }
        XCTAssertEqual(name, "protected")
    }

    // 未知 skill → 返回 .notFound
    func test_invoke_unknownSkill_returnsNotFound() async {
        let provider = StubSkillContentProvider()
        let processor = SkillInvocationProcessor(provider: provider, sessionId: "s1")

        let result = await processor.invoke(skillName: "ghost", args: nil)

        guard case .notFound(let name) = result else {
            return XCTFail("Expected .notFound, got \(result)")
        }
        XCTAssertEqual(name, "ghost")
    }

    // 内容读取失败 → 返回 .unreadable
    func test_invoke_unreadableContent_returnsUnreadable() async {
        let skill = Skill.fixture(directoryName: "broken")
        let provider = StubSkillContentProvider()
        provider.skills = [skill]
        // 不写 contentByDirectory → readSkillContent 返回 nil
        let processor = SkillInvocationProcessor(provider: provider, sessionId: "s1")

        let result = await processor.invoke(skillName: "broken", args: nil)

        guard case .unreadable(let name) = result else {
            return XCTFail("Expected .unreadable, got \(result)")
        }
        XCTAssertEqual(name, "broken")
    }

    // model override 透传
    func test_invoke_modelOverride_returnedInResult() async {
        let skill = Skill.fixture(directoryName: "fast-skill", model: "claude-haiku-4-5")
        let provider = makeProvider(skill: skill, content: "Be fast.")
        let processor = SkillInvocationProcessor(provider: provider, sessionId: "s1")

        let result = await processor.invoke(skillName: "fast-skill", args: nil)

        guard case .success(let r) = result else { return XCTFail() }
        XCTAssertEqual(r.modelOverride, "claude-haiku-4-5")
    }

    // 前导斜杠被规范化
    func test_invoke_leadingSlashNormalized() async {
        let skill = Skill.fixture(directoryName: "commit")
        let provider = makeProvider(skill: skill, content: "Commit.")
        let processor = SkillInvocationProcessor(provider: provider, sessionId: "s1")

        let result = await processor.invoke(skillName: "/commit", args: nil)

        guard case .success = result else {
            return XCTFail("Expected success with normalized name, got \(result)")
        }
    }

    func test_invoke_bundledSkill_returnsBundledContent() async {
        let skill = Skill.fixture(
            directoryName: "bundled-invoke",
            name: "bundled-invoke",
            description: "Bundled invocation test",
            loadedFrom: .bundled
        )
        let provider = makeProvider(skill: skill, content: "Bundled prompt content.")
        let processor = SkillInvocationProcessor(provider: provider, sessionId: "s-bundled")

        let result = await processor.invoke(skillName: "bundled-invoke", args: nil)

        guard case .success(let r) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertTrue(r.content.contains("Bundled prompt content."))
        XCTAssertEqual(r.commandName, "bundled-invoke")
    }
}

// ─────────────────────────────────────────────
// MARK: - SkillInvocationDispatchIntegrationTests
// ─────────────────────────────────────────────

/// dispatch 集成测试：验证 SkillInvocationProcessor 与 ToolExecutionResult 的衔接
@MainActor
final class SkillInvocationDispatchIntegrationTests: XCTestCase {

    // 成功情形：结果文本包含 skill 内容
    func test_successOutcome_yieldsSuccessResult() async {
        let outcome = SkillInvocationOutcome.success(
            SkillInvocationSuccess(
                commandName: "commit",
                content: "Commit your changes now.",
                allowedTools: [],
                modelOverride: nil
            )
        )
        let result = ToolExecutionResult(fromSkillInvocationOutcome: outcome)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("Commit your changes now."))
    }

    // notFound → 错误结果
    func test_notFoundOutcome_yieldsErrorResult() async {
        let outcome = SkillInvocationOutcome.notFound("ghost-skill")
        let result = ToolExecutionResult(fromSkillInvocationOutcome: outcome)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("ghost-skill"))
    }

    // disabled → 错误结果
    func test_disabledOutcome_yieldsErrorResult() async {
        let outcome = SkillInvocationOutcome.disabled("protected")
        let result = ToolExecutionResult(fromSkillInvocationOutcome: outcome)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("protected"))
    }

    // allowedTools 包含在 text 中（软约束，供模型参考）
    func test_successWithAllowedTools_textContainsToolList() async {
        let outcome = SkillInvocationOutcome.success(
            SkillInvocationSuccess(
                commandName: "safe",
                content: "Do safe things.",
                allowedTools: ["bash", "read_file"],
                modelOverride: nil
            )
        )
        let result = ToolExecutionResult(fromSkillInvocationOutcome: outcome)
        XCTAssertTrue(result.text.contains("bash"))
        XCTAssertTrue(result.text.contains("read_file"))
    }
}

// ─────────────────────────────────────────────
// MARK: - SkillInvocationToolSchemaTests
// ─────────────────────────────────────────────

@MainActor
final class SkillInvocationToolSchemaTests: XCTestCase {

    private func toolNames(from tools: [MessageParameter.Tool]) -> [String] {
        tools.compactMap { tool in
            extractName(from: Mirror(reflecting: tool))
        }
    }

    private func extractName(from mirror: Mirror) -> String? {
        for child in mirror.children {
            if child.label == "name", let name = child.value as? String { return name }
            let childMirror = Mirror(reflecting: child.value)
            if let name = extractName(from: childMirror) { return name }
        }
        return nil
    }

    // skill_invoke schema 在有 enabledSkills 时出现在工具列表中
    func test_buildTools_withEnabledSkills_containsSkillInvoke() {
        let service = ClaudeService()
        let settings = AppSettings.testFixture()
        let skill = Skill.fixture()
        let tools = service.buildTools(modelId: "claude-opus-4-5", settings: settings, enabledSkills: [skill])
        let names = toolNames(from: tools)
        XCTAssertTrue(names.contains("skill_invoke"), "Expected skill_invoke in \(names)")
    }

    // 没有 enabledSkills 时，skill_invoke 不出现
    func test_buildTools_withoutEnabledSkills_noSkillInvoke() {
        let service = ClaudeService()
        let settings = AppSettings.testFixture()
        let tools = service.buildTools(modelId: "claude-opus-4-5", settings: settings, enabledSkills: [])
        let names = toolNames(from: tools)
        XCTAssertFalse(names.contains("skill_invoke"))
    }
}

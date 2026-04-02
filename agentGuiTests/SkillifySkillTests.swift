// agentGuiTests/SkillifySkillTests.swift
import XCTest
import SwiftAnthropic
@testable import agentGui

final class SkillifySkillTests: XCTestCase {

    private var registry: BuiltInSkillRegistry!

    override func setUp() {
        super.setUp()
        registry = BuiltInSkillRegistry()
        registerSkillifySkill(into: registry)
    }

    // MARK: - 注册验证

    func test_registration_skillAppearsInRegistry() {
        let skills = registry.allSkills()
        XCTAssertTrue(
            skills.contains(where: { $0.directoryName == "skillify" }),
            "skillify 应出现在 allSkills() 中"
        )
    }

    func test_registration_loadedFromBundled() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "skillify" })!
        XCTAssertEqual(skill.loadedFrom, .bundled)
    }

    func test_registration_userInvocableTrue() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "skillify" })!
        XCTAssertTrue(skill.userInvocable)
    }

    func test_registration_disableModelInvocationFalse() {
        // agentGui 版：允许模型主动调用，去掉 ANT 的 disableModelInvocation guard
        let skill = registry.allSkills().first(where: { $0.directoryName == "skillify" })!
        XCTAssertFalse(skill.disableModelInvocation)
    }

    func test_registration_hasAllowedTools() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "skillify" })!
        XCTAssertFalse(skill.allowedTools.isEmpty, "skillify 应声明所需工具权限")
    }

    func test_registration_hasWhenToUse() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "skillify" })!
        XCTAssertNotNil(skill.whenToUse)
        XCTAssertFalse(skill.whenToUse!.isEmpty)
    }

    func test_registration_hasArgumentHint() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "skillify" })!
        XCTAssertNotNil(skill.argumentHint)
    }

    func test_registration_executionContextInline() {
        // skillify 需要中途用户确认，使用 inline 模式
        let skill = registry.allSkills().first(where: { $0.directoryName == "skillify" })!
        XCTAssertEqual(skill.executionContext, .inline)
    }

    // MARK: - Prompt 内容验证

    func test_promptContent_containsAnalyzeSessionSection() async {
        let content = await registry.promptContent(skillName: "skillify")
        XCTAssertNotNil(content)
        XCTAssertTrue(
            content!.contains("Analyze the Session") || content!.contains("分析本次会话"),
            "prompt 应包含会话分析步骤"
        )
    }

    func test_promptContent_containsInterviewUserSection() async {
        let content = await registry.promptContent(skillName: "skillify")
        XCTAssertNotNil(content)
        XCTAssertTrue(
            content!.contains("Interview") || content!.contains("问答") || content!.contains("AskUserQuestion"),
            "prompt 应包含用户问答步骤"
        )
    }

    func test_promptContent_containsWriteSkillMDSection() async {
        let content = await registry.promptContent(skillName: "skillify")
        XCTAssertNotNil(content)
        XCTAssertTrue(
            content!.contains("SKILL.md"),
            "prompt 应包含 SKILL.md 写入步骤"
        )
    }

    func test_promptContent_argumentsPlaceholderPresent() async {
        let content = await registry.promptContent(skillName: "skillify")
        XCTAssertNotNil(content)
        // 若 args 有可选描述，prompt 应有相应占位符
        XCTAssertTrue(
            content!.contains("$ARGUMENTS") || content!.contains("{{userDescriptionBlock}}"),
            "prompt 中应含可选描述占位符"
        )
    }

    // MARK: - extractUserMessages

    func test_extractUserMessages_filterUserRole() {
        let msgs: [MessageParameter.Message] = [
            .init(role: .user, content: .text("hello")),
            .init(role: .assistant, content: .text("world")),
            .init(role: .user, content: .text("second")),
        ]
        let result = SkillifyPromptBuilder.extractUserMessages(from: msgs)
        XCTAssertEqual(result, ["hello", "second"])
    }

    func test_extractUserMessages_skipsEmptyText() {
        let msgs: [MessageParameter.Message] = [
            .init(role: .user, content: .text("")),
            .init(role: .user, content: .text("  ")),
            .init(role: .user, content: .text("valid")),
        ]
        let result = SkillifyPromptBuilder.extractUserMessages(from: msgs)
        XCTAssertEqual(result, ["valid"])
    }

    func test_extractUserMessages_emptyMessages_returnsEmpty() {
        let result = SkillifyPromptBuilder.extractUserMessages(from: [])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - SkillService 集成（快速路径验证）

    func test_skillifyAppearsInSkillServiceWhenRegistered() async {
        // 使用独立 registry 模拟注册，验证 SkillService 合并逻辑
        let localRegistry = BuiltInSkillRegistry()
        registerSkillifySkill(into: localRegistry)

        let bundledSkills = localRegistry.allSkills()
        XCTAssertTrue(
            bundledSkills.contains(where: { $0.directoryName == "skillify" && $0.loadedFrom == .bundled }),
            "skillify 应在 bundled skills 中，供 SkillService.availableSkills 合并"
        )
    }
}

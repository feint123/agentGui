// agentGuiTests/VerifySkillTests.swift
import XCTest
@testable import agentGui

// MARK: - Test Helpers

/// SkillContentProviding 的测试替身，从 BuiltInSkillRegistry 中读取内容。
private struct StubSkillContentProvider: SkillContentProviding {
    let registry: BuiltInSkillRegistry

    func skillsList() async -> [Skill] {
        registry.allSkills()
    }

    func readSkillContent(name: String) async -> String? {
        await registry.promptContent(skillName: name)
    }
}

// MARK: - VerifySkillTests

final class VerifySkillTests: XCTestCase {

    private var registry: BuiltInSkillRegistry!

    override func setUp() {
        super.setUp()
        registry = BuiltInSkillRegistry()
        registerVerifySkill(into: registry)
    }

    override func tearDown() {
        registry.clearForTesting()
        registry = nil
        super.tearDown()
    }

    // MARK: - 注册验证

    func test_registration_skillAppearsInRegistry() {
        let skills = registry.allSkills()
        XCTAssertTrue(
            skills.contains(where: { $0.directoryName == "verify" }),
            "verify 应出现在 allSkills() 中"
        )
    }

    func test_registration_loadedFromBundled() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "verify" })!
        XCTAssertEqual(skill.loadedFrom, .bundled)
    }

    func test_registration_userInvocableTrue() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "verify" })!
        XCTAssertTrue(skill.userInvocable)
    }

    func test_registration_executionContextInline() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "verify" })!
        XCTAssertEqual(skill.executionContext, .inline)
    }

    func test_registration_descriptionNonEmpty() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "verify" })!
        XCTAssertFalse(skill.description.isEmpty, "description 不能为空")
    }

    func test_registration_whenToUseNonEmpty() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "verify" })!
        XCTAssertNotNil(skill.whenToUse)
        XCTAssertFalse(skill.whenToUse!.isEmpty, "whenToUse 不能为空")
    }

    // MARK: - Prompt 内容验证

    func test_promptContent_noArgs_containsVerifyHeader() async {
        let content = await registry.promptContent(skillName: "verify")
        XCTAssertNotNil(content)
        XCTAssertTrue(
            content!.contains("Verify"),
            "prompt 应包含 'Verify' 标题"
        )
    }

    func test_promptContent_noArgs_containsBuildStep() async {
        let content = await registry.promptContent(skillName: "verify")
        XCTAssertNotNil(content)
        XCTAssertTrue(
            content!.contains("Build"),
            "prompt 应包含 Build 步骤说明"
        )
    }

    func test_promptContent_noArgs_containsTestStep() async {
        let content = await registry.promptContent(skillName: "verify")
        XCTAssertNotNil(content)
        XCTAssertTrue(
            content!.contains("Test"),
            "prompt 应包含 Test 步骤说明"
        )
    }

    func test_promptContent_noArgs_containsManualCheckStep() async {
        let content = await registry.promptContent(skillName: "verify")
        XCTAssertNotNil(content)
        XCTAssertTrue(
            content!.contains("Manual") || content!.contains("ask_user_question"),
            "prompt 应包含手动确认步骤"
        )
    }

    func test_promptContent_containsArgumentsPlaceholder() async {
        // $ARGUMENTS 占位符由 SkillArgumentSubstitution 在调用时替换；
        // prompt 模板本身应包含该占位符（以便替换机制生效）。
        let content = await registry.promptContent(skillName: "verify")
        XCTAssertNotNil(content)
        XCTAssertTrue(
            content!.contains("$ARGUMENTS"),
            "prompt 模板应包含 $ARGUMENTS 占位符"
        )
    }

    // MARK: - SkillArgumentSubstitution 集成验证

    func test_argumentSubstitution_replacesArgumentsPlaceholder() async {
        let rawContent = await registry.promptContent(skillName: "verify")!
        let syntheticDir = URL(fileURLWithPath: "/tmp")
        let result = SkillArgumentSubstitution.substitute(
            content: rawContent,
            args: "login flow",
            skillDirectory: syntheticDir,
            sessionId: "test-session"
        )
        XCTAssertFalse(
            result.contains("$ARGUMENTS"),
            "替换后不应再包含原始 $ARGUMENTS"
        )
        XCTAssertTrue(
            result.contains("login flow"),
            "替换后应包含传入的 args 内容"
        )
    }

    func test_argumentSubstitution_emptyArgs_leavesSilentlyEmpty() async {
        let rawContent = await registry.promptContent(skillName: "verify")!
        let syntheticDir = URL(fileURLWithPath: "/tmp")
        let result = SkillArgumentSubstitution.substitute(
            content: rawContent,
            args: nil,
            skillDirectory: syntheticDir,
            sessionId: "test-session"
        )
        // $ARGUMENTS 替换为空字符串时，prompt 应仍然合法可用
        XCTAssertFalse(result.isEmpty, "替换后内容不能为空")
    }

    // MARK: - 共享 Registry 集成

    func test_sharedRegistry_registrationDoesNotCrash() {
        // 直接注册到 .shared，验证注册路径的完整性（测试后清理）
        let sharedRegistry = BuiltInSkillRegistry.shared
        registerVerifySkill(into: sharedRegistry)
        let skill = sharedRegistry.allSkills().first(where: { $0.directoryName == "verify" })
        XCTAssertNotNil(skill, "verify 应可成功注册到 BuiltInSkillRegistry.shared")
        sharedRegistry.clearForTesting()
    }

    // MARK: - SkillInvocationProcessor 集成

    func test_invocationProcessor_verifySkill_found() async {
        let provider = StubSkillContentProvider(registry: registry)
        let processor = SkillInvocationProcessor(provider: provider, sessionId: "test-session")
        let outcome = await processor.invoke(skillName: "verify", args: nil)
        guard case .success(let result) = outcome else {
            XCTFail("Expected success, got \(outcome)")
            return
        }
        XCTAssertEqual(result.commandName, "verify")
        XCTAssertFalse(result.content.isEmpty)
    }

    func test_invocationProcessor_verifySkill_withArgs_injectsArgs() async {
        let provider = StubSkillContentProvider(registry: registry)
        let processor = SkillInvocationProcessor(provider: provider, sessionId: "test-session")
        let outcome = await processor.invoke(skillName: "verify", args: "login flow")
        guard case .success(let result) = outcome else {
            XCTFail("Expected success, got \(outcome)")
            return
        }
        XCTAssertTrue(
            result.content.contains("login flow"),
            "content 应包含传入的 args 字符串"
        )
        XCTAssertFalse(
            result.content.contains("$ARGUMENTS"),
            "content 不应包含未替换的占位符"
        )
    }

    func test_invocationProcessor_verifySkill_noAllowedToolsRestriction() async {
        let provider = StubSkillContentProvider(registry: registry)
        let processor = SkillInvocationProcessor(provider: provider, sessionId: "test-session")
        let outcome = await processor.invoke(skillName: "verify", args: nil)
        guard case .success(let result) = outcome else {
            XCTFail("Expected success, got \(outcome)")
            return
        }
        XCTAssertTrue(
            result.allowedTools.isEmpty,
            "verify 不限制工具集，allowedTools 应为空"
        )
    }
}

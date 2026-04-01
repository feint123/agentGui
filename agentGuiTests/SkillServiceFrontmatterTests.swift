import XCTest
@testable import agentGui

/// Unit tests for SkillService.parseFrontmatter() after S-A1 manifest extension.
/// Tests exercise the nonisolated static parseFrontmatter(at:) via scanSkills() on a
/// real temp directory — no mock needed.
final class SkillServiceFrontmatterTests: XCTestCase {

    private var tmpDir: URL!
    private var skillDir: URL!
    private var skillMD: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "SkillServiceFrontmatterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        skillDir = tmpDir.appending(path: "test-skill", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        skillMD = skillDir.appending(path: "SKILL.md")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Helpers

    private func writeSkillMD(_ content: String) throws {
        try content.write(to: skillMD, atomically: true, encoding: .utf8)
    }

    private func scanSkills() async -> [Skill] {
        let service = await SkillService(skillsDirectory: tmpDir)
        await service.loadSkills()
        return await service.availableSkills
    }

    // MARK: - when_to_use

    func test_parseFrontmatter_whenToUse() async throws {
        try writeSkillMD("""
            ---
            name: code-review
            description: Reviews code quality
            when_to_use: 当用户请求代码审查时使用
            ---
            # Code Review
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.whenToUse, "当用户请求代码审查时使用")
    }

    // MARK: - argument-hint

    func test_parseFrontmatter_argumentHint() async throws {
        try writeSkillMD("""
            ---
            name: pr-review
            description: Reviews a PR
            argument-hint: PR number or URL
            ---
            # PR Review
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.argumentHint, "PR number or URL")
    }

    // MARK: - arguments (argumentNames)

    func test_parseFrontmatter_argumentNames_list() async throws {
        try writeSkillMD("""
            ---
            name: branch-deploy
            description: Deploys a branch
            arguments:
              - branch
              - environment
            ---
            # Branch Deploy
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.argumentNames, ["branch", "environment"])
    }

    func test_parseFrontmatter_argumentNames_inline() async throws {
        try writeSkillMD("""
            ---
            name: single-arg
            description: Takes one arg
            arguments: [ticket]
            ---
            # Single Arg
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.argumentNames, ["ticket"])
    }

    // MARK: - allowed-tools

    func test_parseFrontmatter_allowedTools() async throws {
        try writeSkillMD("""
            ---
            name: read-only
            description: Read only skill
            allowed-tools: [read_file, grep_search, glob_search]
            ---
            # Read Only
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.allowedTools, ["read_file", "grep_search", "glob_search"])
    }

    func test_parseFrontmatter_allowedTools_empty_byDefault() async throws {
        try writeSkillMD("""
            ---
            name: minimal
            description: No tools declared
            ---
            # Minimal
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.allowedTools, [])
    }

    // MARK: - model

    func test_parseFrontmatter_model() async throws {
        try writeSkillMD("""
            ---
            name: fast-skill
            description: Uses haiku
            model: claude-haiku-4-5
            ---
            # Fast Skill
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.model, "claude-haiku-4-5")
    }

    func test_parseFrontmatter_model_inherit_isNil() async throws {
        try writeSkillMD("""
            ---
            name: inherit-model
            description: Inherits model
            model: inherit
            ---
            # Inherit Model
            """)
        let skills = await scanSkills()
        // "inherit" 关键字应被解析为 nil（继承当前模型）
        XCTAssertNil(skills.first?.model)
    }

    // MARK: - effort

    func test_parseFrontmatter_effort_low() async throws {
        try writeSkillMD("""
            ---
            name: quick-skill
            description: Low effort
            effort: low
            ---
            # Quick Skill
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.effort, .low)
    }

    func test_parseFrontmatter_effort_max() async throws {
        try writeSkillMD("""
            ---
            name: deep-skill
            description: Max effort
            effort: max
            ---
            # Deep Skill
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.effort, .max)
    }

    func test_parseFrontmatter_effort_invalid_isNil() async throws {
        try writeSkillMD("""
            ---
            name: bad-effort
            description: Invalid effort level
            effort: critical
            ---
            # Bad Effort
            """)
        let skills = await scanSkills()
        // 无效值应静默退回 nil（不 crash）
        XCTAssertNil(skills.first?.effort)
    }

    // MARK: - context (executionContext)

    func test_parseFrontmatter_context_fork() async throws {
        try writeSkillMD("""
            ---
            name: isolated-skill
            description: Runs forked
            context: fork
            ---
            # Isolated Skill
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.executionContext, .fork)
    }

    func test_parseFrontmatter_context_default_isInline() async throws {
        try writeSkillMD("""
            ---
            name: normal-skill
            description: No context declared
            ---
            # Normal Skill
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.executionContext, .inline)
    }

    // MARK: - user-invocable

    func test_parseFrontmatter_userInvocable_false() async throws {
        try writeSkillMD("""
            ---
            name: hidden-skill
            description: Not user invocable
            user-invocable: false
            ---
            # Hidden Skill
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.userInvocable, false)
    }

    func test_parseFrontmatter_userInvocable_default_isTrue() async throws {
        try writeSkillMD("""
            ---
            name: default-invocable
            description: Default user-invocable
            ---
            # Default Invocable
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.userInvocable, true)
    }

    // MARK: - disable-model-invocation

    func test_parseFrontmatter_disableModelInvocation_true() async throws {
        try writeSkillMD("""
            ---
            name: manual-only
            description: Only manually invocable
            disable-model-invocation: true
            ---
            # Manual Only
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.disableModelInvocation, true)
    }

    func test_parseFrontmatter_disableModelInvocation_default_isFalse() async throws {
        try writeSkillMD("""
            ---
            name: normal-invoke
            description: Model can call this
            ---
            # Normal Invoke
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.disableModelInvocation, false)
    }

    // MARK: - version

    func test_parseFrontmatter_version() async throws {
        try writeSkillMD("""
            ---
            name: versioned-skill
            description: Has a version
            version: "2.1.0"
            ---
            # Versioned Skill
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.version, "2.1.0")
    }

    // MARK: - paths

    func test_parseFrontmatter_paths_list() async throws {
        try writeSkillMD("""
            ---
            name: swift-only
            description: Only for Swift files
            paths:
              - "**/*.swift"
              - "**/*.swiftui"
            ---
            # Swift Only
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.paths, ["**/*.swift", "**/*.swiftui"])
    }

    func test_parseFrontmatter_paths_nil_by_default() async throws {
        try writeSkillMD("""
            ---
            name: all-paths
            description: Available everywhere
            ---
            # All Paths
            """)
        let skills = await scanSkills()
        XCTAssertNil(skills.first?.paths)
    }

    // MARK: - agent

    func test_parseFrontmatter_agent() async throws {
        try writeSkillMD("""
            ---
            name: specialized
            description: Uses a specific agent
            agent: code-reviewer
            ---
            # Specialized
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.agent, "code-reviewer")
    }

    // MARK: - loadedFrom default

    func test_skill_loadedFrom_default_isUser() async throws {
        try writeSkillMD("""
            ---
            name: default-source
            description: Loaded from default skills dir
            ---
            # Default Source
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.loadedFrom, .user)
    }

    // MARK: - Full manifest roundtrip

    func test_parseFrontmatter_fullManifest() async throws {
        try writeSkillMD("""
            ---
            name: Complete Skill
            description: A fully specified skill
            when_to_use: 当用户需要完整演示时
            argument-hint: Describe the target
            arguments:
              - target
              - mode
            allowed-tools: [read_file, write_file]
            model: claude-sonnet-4-5
            effort: high
            context: fork
            agent: researcher
            user-invocable: true
            disable-model-invocation: false
            version: "1.0.0"
            paths:
              - "src/**"
            ---
            # Complete
            """)
        let skills = await scanSkills()
        let skill = try XCTUnwrap(skills.first)

        XCTAssertEqual(skill.name,                   "Complete Skill")
        XCTAssertEqual(skill.description,            "A fully specified skill")
        XCTAssertEqual(skill.whenToUse,              "当用户需要完整演示时")
        XCTAssertEqual(skill.argumentHint,           "Describe the target")
        XCTAssertEqual(skill.argumentNames,          ["target", "mode"])
        XCTAssertEqual(skill.allowedTools,           ["read_file", "write_file"])
        XCTAssertEqual(skill.model,                  "claude-sonnet-4-5")
        XCTAssertEqual(skill.effort,                 .high)
        XCTAssertEqual(skill.executionContext,        .fork)
        XCTAssertEqual(skill.agent,                  "researcher")
        XCTAssertTrue(skill.userInvocable)
        XCTAssertFalse(skill.disableModelInvocation)
        XCTAssertEqual(skill.version,                "1.0.0")
        XCTAssertEqual(skill.paths,                  ["src/**"])
    }

    // MARK: - Backward compatibility

    func test_existingFrontmatterStillParses() async throws {
        // 原有仅含 name/description 的 frontmatter 应继续正常解析
        try writeSkillMD("""
            ---
            name: legacy-skill
            description: Old skill without new fields
            ---
            # Legacy
            """)
        let skills = await scanSkills()
        XCTAssertEqual(skills.first?.name,        "legacy-skill")
        XCTAssertEqual(skills.first?.description, "Old skill without new fields")
        // All new fields fall back to defaults
        XCTAssertNil(skills.first?.whenToUse)
        XCTAssertEqual(skills.first?.allowedTools,      [])
        XCTAssertEqual(skills.first?.argumentNames,     [])
        XCTAssertEqual(skills.first?.executionContext,  .inline)
        XCTAssertTrue(skills.first?.userInvocable      ?? false)
        XCTAssertFalse(skills.first?.disableModelInvocation ?? true)
        XCTAssertNil(skills.first?.effort)
        XCTAssertNil(skills.first?.paths)
        XCTAssertEqual(skills.first?.loadedFrom,        .user)
    }

    // MARK: - hasReferenceFiles

    func test_hasReferenceFiles_false_whenOnlySkillMD() async throws {
        try writeSkillMD("""
            ---
            name: no-extras
            description: Only SKILL.md
            ---
            # No Extras
            """)
        // skill 目录中只有 SKILL.md
        let skills = await scanSkills()
        XCTAssertFalse(skills.first?.hasReferenceFiles ?? true)
    }

    func test_hasReferenceFiles_true_whenExtraFileExists() async throws {
        try writeSkillMD("""
            ---
            name: with-schema
            description: Has a reference schema
            ---
            # With Schema
            """)
        // 在 skill 目录中额外写一个参考文件
        let schemaFile = skillDir.appending(path: "schema.json")
        try "{}".write(to: schemaFile, atomically: true, encoding: .utf8)

        let skills = await scanSkills()
        XCTAssertTrue(skills.first?.hasReferenceFiles ?? false)
    }
}

// agentGuiTests/BuiltInSkillRegistryTests.swift
import XCTest
@testable import agentGui

final class BuiltInSkillRegistryTests: XCTestCase {

    private var registry: BuiltInSkillRegistry!

    override func setUp() {
        super.setUp()
        registry = BuiltInSkillRegistry()  // 独立实例，不依赖 .shared
    }

    // MARK: - register & allSkills

    func test_register_singleSkill_appearsInAllSkills() {
        let def = BuiltInSkillDefinition(
            name: "test-skill",
            description: "A test built-in skill",
            getPromptContent: { "Hello, world!" }
        )
        registry.register(def)

        let skills = registry.allSkills()
        XCTAssertEqual(skills.count, 1)
        XCTAssertEqual(skills[0].name, "test-skill")
        XCTAssertEqual(skills[0].description, "A test built-in skill")
    }

    func test_register_setsLoadedFromBundled() {
        registry.register(BuiltInSkillDefinition(
            name: "bundled-skill",
            description: "Desc",
            getPromptContent: { "" }
        ))
        let skill = registry.allSkills()[0]
        XCTAssertEqual(skill.loadedFrom, .bundled)
    }

    func test_register_setsDirectoryNameFromName() {
        registry.register(BuiltInSkillDefinition(
            name: "my-skill",
            description: "Desc",
            getPromptContent: { "" }
        ))
        let skill = registry.allSkills()[0]
        XCTAssertEqual(skill.directoryName, "my-skill")
    }

    func test_register_multipleSkills_allAppear() {
        for i in 1...3 {
            registry.register(BuiltInSkillDefinition(
                name: "skill-\(i)",
                description: "Skill \(i)",
                getPromptContent: { "Content \(i)" }
            ))
        }
        XCTAssertEqual(registry.allSkills().count, 3)
    }

    func test_register_duplicateName_lastWins() {
        registry.register(BuiltInSkillDefinition(
            name: "dup",
            description: "First",
            getPromptContent: { "First content" }
        ))
        registry.register(BuiltInSkillDefinition(
            name: "dup",
            description: "Second",
            getPromptContent: { "Second content" }
        ))
        let skills = registry.allSkills()
        XCTAssertEqual(skills.count, 1)
        XCTAssertEqual(skills[0].description, "Second")
    }

    // MARK: - Skill struct fields from definition

    func test_register_withAllFields_allMappedToSkill() {
        registry.register(BuiltInSkillDefinition(
            name: "full-skill",
            description: "Full",
            whenToUse: "When you need it",
            argumentHint: "branch name",
            argumentNames: ["branch"],
            allowedTools: ["Bash", "Read"],
            model: "claude-haiku-4-5",
            effort: .low,
            executionContext: .fork,
            agent: "code-reviewer",
            userInvocable: false,
            disableModelInvocation: true,
            version: "1.0",
            getPromptContent: { "prompt" }
        ))
        let skill = registry.allSkills()[0]
        XCTAssertEqual(skill.whenToUse, "When you need it")
        XCTAssertEqual(skill.argumentHint, "branch name")
        XCTAssertEqual(skill.argumentNames, ["branch"])
        XCTAssertEqual(skill.allowedTools, ["Bash", "Read"])
        XCTAssertEqual(skill.model, "claude-haiku-4-5")
        XCTAssertEqual(skill.effort, .low)
        XCTAssertEqual(skill.executionContext, .fork)
        XCTAssertEqual(skill.agent, "code-reviewer")
        XCTAssertFalse(skill.userInvocable)
        XCTAssertTrue(skill.disableModelInvocation)
        XCTAssertEqual(skill.version, "1.0")
        XCTAssertEqual(skill.loadedFrom, .bundled)
    }

    func test_register_defaultFields_areConservativeSafe() {
        registry.register(BuiltInSkillDefinition(
            name: "minimal",
            description: "Minimal",
            getPromptContent: { "" }
        ))
        let skill = registry.allSkills()[0]
        XCTAssertNil(skill.whenToUse)
        XCTAssertNil(skill.argumentHint)
        XCTAssertTrue(skill.argumentNames.isEmpty)
        XCTAssertTrue(skill.allowedTools.isEmpty)
        XCTAssertNil(skill.model)
        XCTAssertNil(skill.effort)
        XCTAssertEqual(skill.executionContext, .inline)
        XCTAssertNil(skill.agent)
        XCTAssertTrue(skill.userInvocable)
        XCTAssertFalse(skill.disableModelInvocation)
        XCTAssertNil(skill.version)
    }

    // MARK: - Synthetic URL

    func test_register_syntheticURLContainsSkillName() {
        registry.register(BuiltInSkillDefinition(
            name: "url-test",
            description: "Desc",
            getPromptContent: { "" }
        ))
        let skill = registry.allSkills()[0]
        XCTAssertTrue(skill.contentURL.path.contains("url-test"))
        XCTAssertTrue(skill.path.path.contains("url-test"))
    }

    func test_register_twoSkills_haveDifferentURLs() {
        registry.register(BuiltInSkillDefinition(name: "a", description: "A", getPromptContent: { "" }))
        registry.register(BuiltInSkillDefinition(name: "b", description: "B", getPromptContent: { "" }))
        let skills = registry.allSkills()
        XCTAssertNotEqual(skills[0].contentURL, skills[1].contentURL)
    }

    // MARK: - isEnabled gate

    func test_allSkills_returnsDisabledSkill_whenIsEnabledReturnsTrue() {
        registry.register(BuiltInSkillDefinition(
            name: "conditional",
            description: "Conditionally enabled",
            isEnabled: { true },
            getPromptContent: { "" }
        ))
        XCTAssertEqual(registry.allSkills().count, 1)
    }

    func test_allSkills_excludesSkill_whenIsEnabledReturnsFalse() {
        registry.register(BuiltInSkillDefinition(
            name: "disabled",
            description: "Always disabled",
            isEnabled: { false },
            getPromptContent: { "" }
        ))
        XCTAssertEqual(registry.allSkills().count, 0)
    }

    func test_allSkills_includesSkill_whenIsEnabledIsNil() {
        registry.register(BuiltInSkillDefinition(
            name: "always-on",
            description: "No condition",
            isEnabled: nil,
            getPromptContent: { "" }
        ))
        XCTAssertEqual(registry.allSkills().count, 1)
    }

    // MARK: - promptContent

    func test_promptContent_returnsContentFromClosure() async {
        registry.register(BuiltInSkillDefinition(
            name: "content-skill",
            description: "Desc",
            getPromptContent: { "The prompt body." }
        ))
        let content = await registry.promptContent(skillName: "content-skill")
        XCTAssertEqual(content, "The prompt body.")
    }

    func test_promptContent_returnsNil_forUnknownSkill() async {
        let content = await registry.promptContent(skillName: "nonexistent")
        XCTAssertNil(content)
    }

    func test_promptContent_asyncClosure_isAwaitedCorrectly() async {
        registry.register(BuiltInSkillDefinition(
            name: "async-skill",
            description: "Desc",
            getPromptContent: {
                // Simulate async work (no real delay needed; just confirms async chain)
                return "async result"
            }
        ))
        let content = await registry.promptContent(skillName: "async-skill")
        XCTAssertEqual(content, "async result")
    }

    // MARK: - clearForTesting

    func test_clearForTesting_removesAllDefinitions() {
        registry.register(BuiltInSkillDefinition(name: "x", description: "X", getPromptContent: { "" }))
        XCTAssertEqual(registry.allSkills().count, 1)
        registry.clearForTesting()
        XCTAssertEqual(registry.allSkills().count, 0)
    }
}

// MARK: - SkillServiceBundledMergeTests

final class SkillServiceBundledMergeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        BuiltInSkillRegistry.shared.clearForTesting()
    }

    override func tearDown() {
        super.tearDown()
        // 确保 shared registry 在测试间干净
        BuiltInSkillRegistry.shared.clearForTesting()
    }

    func test_loadSkills_bundledSkillAppearsInAvailableSkills() async {
        BuiltInSkillRegistry.shared.register(BuiltInSkillDefinition(
            name: "bundled-merge-test",
            description: "Bundled skill for merge test",
            getPromptContent: { "content" }
        ))

        let service = await SkillService(
            skillsDirectory: URL(fileURLWithPath: "/tmp/nonexistent-skills-\(UUID().uuidString)")
        )
        await service.loadSkills()

        let names = await service.availableSkills.map(\.directoryName)
        XCTAssertTrue(names.contains("bundled-merge-test"),
                      "bundled skill should appear in availableSkills; got: \(names)")
    }

    func test_loadSkills_bundledSkill_hasLoadedFromBundled() async {
        BuiltInSkillRegistry.shared.register(BuiltInSkillDefinition(
            name: "source-check",
            description: "Source check",
            getPromptContent: { "" }
        ))

        let service = await SkillService(
            skillsDirectory: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        )
        await service.loadSkills()

        let skill = await service.availableSkills.first { $0.directoryName == "source-check" }
        XCTAssertNotNil(skill)
        XCTAssertEqual(skill?.loadedFrom, .bundled)
    }

    func test_loadSkills_diskSkillWinsOverBundledWithSameName() async {
        // 准备一个同名磁盘技能
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "diskWins-\(UUID().uuidString)", directoryHint: .isDirectory)
        let skillDir = tmpDir.appending(path: "overlap-skill", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let skillMD = """
        ---
        name: overlap-skill
        description: Disk version
        ---
        Disk content
        """
        try! skillMD.write(to: skillDir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        BuiltInSkillRegistry.shared.register(BuiltInSkillDefinition(
            name: "overlap-skill",
            description: "Bundled version",
            getPromptContent: { "bundled content" }
        ))

        let service = await SkillService(skillsDirectory: tmpDir)
        await service.loadSkills()

        let skills = await service.availableSkills.filter { $0.directoryName == "overlap-skill" }
        XCTAssertEqual(skills.count, 1, "No duplicate should appear")
        // 磁盘版优先
        XCTAssertEqual(skills[0].loadedFrom, .user, "Disk (user) skill should win over bundled")

        try? FileManager.default.removeItem(at: tmpDir)
    }

    func test_readSkillContent_bundledSkill_returnsRegistryContent() async {
        BuiltInSkillRegistry.shared.register(BuiltInSkillDefinition(
            name: "content-read-test",
            description: "Content test",
            getPromptContent: { "The bundled prompt body." }
        ))

        let service = await SkillService(
            skillsDirectory: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        )
        await service.loadSkills()

        let content = await service.readSkillContent(name: "content-read-test")
        XCTAssertEqual(content, "The bundled prompt body.")
    }

    func test_readSkillContent_bundledSkill_isCachedOnSecondCall() async {
        let callCount = LockIsolated(0)
        BuiltInSkillRegistry.shared.register(BuiltInSkillDefinition(
            name: "cache-test",
            description: "Cache test",
            getPromptContent: {
                callCount.withLock { $0 += 1 }
                return "cached content"
            }
        ))

        let service = await SkillService(
            skillsDirectory: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        )
        await service.loadSkills()

        _ = await service.readSkillContent(name: "cache-test")
        _ = await service.readSkillContent(name: "cache-test")
        // 闭包只应被调用一次（第二次走缓存）
        XCTAssertEqual(callCount.value, 1)
    }

    func test_enabledSkills_bundledSkill_alwaysIncluded_evenIfNotInEnabledNames() async {
        BuiltInSkillRegistry.shared.register(BuiltInSkillDefinition(
            name: "always-included",
            description: "Always included bundled skill",
            getPromptContent: { "" }
        ))

        let service = await SkillService(
            skillsDirectory: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        )
        await service.loadSkills()

        // 空的 enabledNames（没有任何 disk skill 启用）
        let enabled = await service.enabledSkills(enabledNames: [])
        let names = enabled.map(\.directoryName)
        XCTAssertTrue(names.contains("always-included"),
                      "bundled skill must appear in enabledSkills regardless of enabledNames; got: \(names)")
    }

    func test_enabledSkills_bundledSkill_includedAlongsideDiskSkills() async {
        // 准备一个磁盘技能
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "enabled-mix-\(UUID().uuidString)", directoryHint: .isDirectory)
        let skillDir = tmpDir.appending(path: "disk-skill", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let md = "---\nname: disk-skill\ndescription: Disk skill\n---\nContent"
        try! md.write(to: skillDir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        BuiltInSkillRegistry.shared.register(BuiltInSkillDefinition(
            name: "bundled-in-mix",
            description: "Bundled in mix",
            getPromptContent: { "" }
        ))

        let service = await SkillService(skillsDirectory: tmpDir)
        await service.loadSkills()

        let enabled = await service.enabledSkills(enabledNames: ["disk-skill"])
        let names = enabled.map(\.directoryName)
        XCTAssertTrue(names.contains("disk-skill"))
        XCTAssertTrue(names.contains("bundled-in-mix"),
                      "bundled skill must always be included; got: \(names)")

        try? FileManager.default.removeItem(at: tmpDir)
    }
}

// MARK: - LockIsolated helper (thread-safe counter for tests)

private final class LockIsolated<Value>: @unchecked Sendable {
    private var _value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self._value = value
    }

    var value: Value {
        lock.withLock { _value }
    }

    @discardableResult
    func withLock<T>(_ closure: (inout Value) throws -> T) rethrows -> T {
        try lock.withLock { try closure(&_value) }
    }
}

# Skill S-A1: 扩展 SkillManifest Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 `Skill.swift` 从 5 个基础字段扩展为完整的 skill manifest，新增 14 个执行控制字段，并同步扩展 `SkillService` 的 frontmatter 解析，为后续所有 Skill 系统 feature（S-A2 ～ S-G2）提供数据基础。

**Architecture:** 新增两个新枚举文件（`SkillEnums.swift`），就地扩展 `Skill.swift` 和 `SkillService.swift`；frontmatter 解析函数扩展为完整返回结构体；所有新字段缺失时退回安全默认值（向后兼容）。测试文件统一放在 `agentGuiTests/SkillManifestTests.swift` 和 `agentGuiTests/SkillServiceFrontmatterTests.swift`。

**Tech Stack:** Swift 6, XCTest, Foundation (no new dependencies)

**Claude Code 对照源文件:**
- `src/skills/loadSkillsDir.ts` → `parseSkillFrontmatterFields()` — 所有 frontmatter 字段的解析逻辑
- `src/skills/bundledSkills.ts` → `BundledSkillDefinition` — loadedFrom/executionContext/userInvocable 字段定义
- `src/utils/effort.ts` → `EFFORT_LEVELS` — effort 枚举值：`low | medium | high | max`

---

## 背景：当前 Skill 数据结构

**当前 `agentGui/Models/Skill.swift` 只有 5 个字段：**

```swift
struct Skill: Identifiable, Hashable, Sendable {
    var id: String { directoryName }
    let directoryName: String
    let name: String
    let description: String
    let path: URL
    let contentURL: URL
}
```

**当前 `SkillService.parseFrontmatter()` 只解析 `name:` 和 `description:` 两个字段。**

---

## Task 1: 新增 Skill 辅助枚举

**Files:**
- Create: `agentGui/Models/SkillEnums.swift`
- Create: `agentGuiTests/SkillManifestTests.swift`

### Step 1: 写失败测试（枚举 rawValue roundtrip）

在 `agentGuiTests/SkillManifestTests.swift` 中创建：

```swift
import XCTest
@testable import agentGui

final class SkillManifestTests: XCTestCase {

    // MARK: - SkillExecutionContext

    func test_executionContext_rawValueRoundTrip() {
        XCTAssertEqual(SkillExecutionContext(rawValue: "inline"), .inline)
        XCTAssertEqual(SkillExecutionContext(rawValue: "fork"),   .fork)
        XCTAssertNil(SkillExecutionContext(rawValue: "unknown"))
    }

    func test_executionContext_default_isInline() {
        // Skill constructed without explicit context should default to .inline
        let skill = Skill.fixture()
        XCTAssertEqual(skill.executionContext, .inline)
    }

    // MARK: - SkillSource

    func test_skillSource_rawValueRoundTrip() {
        XCTAssertEqual(SkillSource(rawValue: "user"),    .user)
        XCTAssertEqual(SkillSource(rawValue: "project"), .project)
        XCTAssertEqual(SkillSource(rawValue: "managed"), .managed)
        XCTAssertEqual(SkillSource(rawValue: "bundled"), .bundled)
        XCTAssertNil(SkillSource(rawValue: "unknown"))
    }

    func test_skillSource_default_isUser() {
        let skill = Skill.fixture()
        XCTAssertEqual(skill.loadedFrom, .user)
    }

    // MARK: - EffortLevel

    func test_effortLevel_rawValueRoundTrip() {
        XCTAssertEqual(EffortLevel(rawValue: "low"),    .low)
        XCTAssertEqual(EffortLevel(rawValue: "medium"), .medium)
        XCTAssertEqual(EffortLevel(rawValue: "high"),   .high)
        XCTAssertEqual(EffortLevel(rawValue: "max"),    .max)
        XCTAssertNil(EffortLevel(rawValue: "critical"))
    }

    func test_effortLevel_default_isNil() {
        let skill = Skill.fixture()
        XCTAssertNil(skill.effort)
    }
}

// MARK: - Test Fixtures

private extension Skill {
    /// Minimal valid Skill for tests — uses default values for all new fields.
    static func fixture(
        directoryName: String = "test-skill",
        name: String = "Test Skill",
        description: String = "A test skill",
        path: URL = URL(fileURLWithPath: "/tmp/test-skill"),
        contentURL: URL = URL(fileURLWithPath: "/tmp/test-skill/SKILL.md")
    ) -> Skill {
        Skill(
            directoryName: directoryName,
            name: name,
            description: description,
            path: path,
            contentURL: contentURL
        )
    }
}
```

### Step 2: 运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-skill-s-a1-derived \
  -only-testing:agentGuiTests/SkillManifestTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：编译错误 — `SkillExecutionContext`、`SkillSource`、`EffortLevel` 类型未定义；`Skill.fixture()` 不存在。

### Step 3: 实现三个枚举

创建 `agentGui/Models/SkillEnums.swift`：

```swift
//
//  SkillEnums.swift
//  agentGui
//

import Foundation

/// 技能执行上下文：inline 将 prompt 展开到当前对话；fork 在独立子代理中运行。
/// 对应 SKILL.md frontmatter 的 `context:` 字段。
enum SkillExecutionContext: String, Codable, Sendable, CaseIterable {
    /// 默认：将技能 prompt 作为新 user message 注入当前会话继续执行。
    case inline
    /// 在独立子代理 session 中执行，结果以工具结果形式返回给主 agent。
    case fork
}

/// 技能加载来源，决定去重优先级和 UI 标注。
/// 优先级从高到低：managed > user > project（深→浅）> bundled。
enum SkillSource: String, Codable, Sendable, CaseIterable {
    /// 来自 `~/.claude/skills/`
    case user
    /// 来自 workspace 目录或其祖先目录下的 `.claude/skills/`
    case project
    /// 来自管理员下发的 `~/.claude/managed/.claude/skills/`
    case managed
    /// 与 app 一起打包的内置技能（不依赖磁盘文件）
    case bundled
}

/// 技能 effort 等级，与模型的 `thinking` budget 对应。
/// 对应 SKILL.md frontmatter 的 `effort:` 字段。
/// 值与 Claude Code src/utils/effort.ts 的 EFFORT_LEVELS 保持一致。
enum EffortLevel: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high
    case max
}
```

### Step 4: 扩展 Skill struct，添加新字段并补充默认值初始化

修改 `agentGui/Models/Skill.swift`，将结构体替换为完整版本（见 Task 2 Step 3）。此时先只添加字段，不改 SkillService 的构造调用，确保枚举测试先绿。

注意：`Skill.fixture()` 中提供的默认成员初始化要求 Skill struct 为 memberwise（即所有新字段都有默认值，或通过带默认参数的 init 支持）。

**修改 `agentGui/Models/Skill.swift`：**

```swift
//
//  Skill.swift
//  agentGui
//

import Foundation

/// A locally installed skill discovered from the skills directory.
struct Skill: Identifiable, Hashable, Sendable {

    // MARK: - 基础字段（已有）

    /// 目录名 — 用作稳定唯一标识符
    var id: String { directoryName }
    let directoryName: String
    /// frontmatter `name:` 的展示名称；缺失时退回 directoryName
    let name: String
    /// frontmatter `description:` 的简短描述
    let description: String
    /// skill 目录的 URL
    let path: URL
    /// skill 目录内 SKILL.md 的 URL
    let contentURL: URL

    // MARK: - 执行控制字段（新增，S-A1）

    /// frontmatter `when_to_use:` — 模型路由提示，帮助 model 决策何时主动调用该 skill
    let whenToUse: String?
    /// frontmatter `argument-hint:` — 在 SkillsView 和 SkillInvocationTool 中展示的参数说明
    let argumentHint: String?
    /// frontmatter `arguments:` — 命名参数列表，用于 S-D2 命名参数替换
    let argumentNames: [String]
    /// frontmatter `allowed-tools:` — skill 执行期间可用的工具白名单
    let allowedTools: [String]
    /// frontmatter `model:` — 覆盖 main loop 模型；nil 表示继承当前模型
    let model: String?
    /// frontmatter `effort:` — 覆盖 thinking budget；nil 表示继承当前设置
    let effort: EffortLevel?
    /// frontmatter `context:` — 执行上下文（inline 或 fork）；默认 inline
    let executionContext: SkillExecutionContext
    /// frontmatter `agent:` — 指定执行该 skill 的 agent 类型
    let agent: String?
    /// frontmatter `user-invocable:` — 用户是否可手动调用；默认 true
    let userInvocable: Bool
    /// frontmatter `disable-model-invocation:` — 禁止模型通过 SkillInvocationTool 主动调用；默认 false
    let disableModelInvocation: Bool
    /// frontmatter `version:` — 版本标签，用于 SkillsView 显示和冲突检测（S-G2）
    let version: String?
    /// frontmatter `paths:` — 条件激活 glob 模式列表；nil 表示始终可用（S-A4）
    let paths: [String]?

    // MARK: - 运行时元数据（新增，S-A1）

    /// skill 目录内除 SKILL.md 之外是否有其他参考文件（S-E2 懒加载用）
    let hasReferenceFiles: Bool
    /// 该技能的加载来源（user / project / managed / bundled）
    let loadedFrom: SkillSource
}

// MARK: - Memberwise init with defaults for new fields

extension Skill {
    init(
        directoryName: String,
        name: String,
        description: String,
        path: URL,
        contentURL: URL,
        whenToUse: String? = nil,
        argumentHint: String? = nil,
        argumentNames: [String] = [],
        allowedTools: [String] = [],
        model: String? = nil,
        effort: EffortLevel? = nil,
        executionContext: SkillExecutionContext = .inline,
        agent: String? = nil,
        userInvocable: Bool = true,
        disableModelInvocation: Bool = false,
        version: String? = nil,
        paths: [String]? = nil,
        hasReferenceFiles: Bool = false,
        loadedFrom: SkillSource = .user
    ) {
        self.directoryName = directoryName
        self.name = name
        self.description = description
        self.path = path
        self.contentURL = contentURL
        self.whenToUse = whenToUse
        self.argumentHint = argumentHint
        self.argumentNames = argumentNames
        self.allowedTools = allowedTools
        self.model = model
        self.effort = effort
        self.executionContext = executionContext
        self.agent = agent
        self.userInvocable = userInvocable
        self.disableModelInvocation = disableModelInvocation
        self.version = version
        self.paths = paths
        self.hasReferenceFiles = hasReferenceFiles
        self.loadedFrom = loadedFrom
    }
}
```

> **注意：** 由于 Skill 在 `SkillService.scanSkills()` 中只用了原有 5 个字段的 memberwise init 调用，扩展后那些调用依然编译通过（新字段全部有缺省值）。无需同时修改 SkillService。

### Step 5: 运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-skill-s-a1-derived \
  -only-testing:agentGuiTests/SkillManifestTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：所有 `SkillManifestTests` 通过，无编译错误。

### Step 6: Commit

```bash
git add agentGui/Models/SkillEnums.swift agentGui/Models/Skill.swift agentGuiTests/SkillManifestTests.swift
git commit -m "feat(S-A1): add SkillExecutionContext/SkillSource/EffortLevel enums and extend Skill struct with 14 new manifest fields"
```

---

## Task 2: 扩展 SkillService frontmatter 解析器

**Files:**
- Modify: `agentGui/Services/SkillService.swift`
- Create: `agentGuiTests/SkillServiceFrontmatterTests.swift`

### Step 1: 写失败测试（新字段 frontmatter 解析）

创建 `agentGuiTests/SkillServiceFrontmatterTests.swift`：

```swift
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
}
```

### Step 2: 运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-skill-s-a1-derived \
  -only-testing:agentGuiTests/SkillServiceFrontmatterTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：多数测试断言失败——新字段均为默认值，因为 `parseFrontmatter` 尚未解析这些字段。

### Step 3: 扩展 `parseFrontmatter` 的返回类型与解析逻辑

在 `agentGui/Services/SkillService.swift` 中，将私有解析函数从返回 `(name: String?, description: String?)` 扩展为返回新结构体。

**3a. 在 `SkillService` 类之前（文件顶部，import 之后）定义内部解析结构体：**

```swift
/// SkillService 内部使用的 frontmatter 解析结果，包含所有 S-A1 新字段。
/// 不对外暴露，消费方直接通过 Skill 的属性访问。
private struct SkillFrontmatterResult {
    var name: String?
    var description: String?
    // 新增字段
    var whenToUse: String?
    var argumentHint: String?
    var argumentNames: [String] = []
    var allowedTools: [String] = []
    var model: String?
    var effort: EffortLevel?
    var executionContext: SkillExecutionContext = .inline
    var agent: String?
    var userInvocable: Bool = true
    var disableModelInvocation: Bool = false
    var version: String?
    var paths: [String]?
}
```

**3b. 替换 `parseFrontmatter(at:)` 函数签名和实现：**

将现有函数签名从：
```swift
nonisolated private static func parseFrontmatter(at url: URL) -> (name: String?, description: String?)
```
改为：
```swift
nonisolated private static func parseFrontmatter(at url: URL) -> SkillFrontmatterResult
```

新的完整实现：

```swift
nonisolated private static func parseFrontmatter(at url: URL) -> SkillFrontmatterResult {
    var result = SkillFrontmatterResult()

    guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
        print("[SkillService]   parseFrontmatter: failed to read \(url.path)")
        return result
    }

    let lines = raw.components(separatedBy: "\n")
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
        print("[SkillService]   parseFrontmatter: no frontmatter in \(url.lastPathComponent)")
        return result
    }

    var inFrontmatter = false
    var collectingField: String? = nil  // 当前正在收集多行值的字段名
    var collectedLines: [String] = []

    for (i, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if i == 0 { inFrontmatter = true; continue }
        if trimmed == "---" && inFrontmatter {
            // 结束 frontmatter，flush 多行收集
            flushCollectedLines(&result, field: collectingField, lines: collectedLines)
            break
        }
        guard inFrontmatter else { break }

        // 续行（以两个空格或 Tab 开头，或以 "  - " 开头的列表项）
        if let field = collectingField,
           (line.hasPrefix("  ") || line.hasPrefix("\t")) {
            let item = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
            if !item.isEmpty { collectedLines.append(item) }
            continue
        } else if collectingField != nil {
            // 续行结束，flush
            flushCollectedLines(&result, field: collectingField, lines: collectedLines)
            collectingField = nil
            collectedLines = []
        }

        // 解析 key: value
        guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
        let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
        let rawValue = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

        switch key {
        case "name":
            result.name = removeQuotes(rawValue)

        case "description":
            if rawValue.isEmpty {
                collectingField = "description"
                collectedLines = []
            } else {
                result.description = removeQuotes(rawValue)
            }

        case "when_to_use":
            result.whenToUse = removeQuotes(rawValue).nonEmptyOrNil

        case "argument-hint":
            result.argumentHint = removeQuotes(rawValue).nonEmptyOrNil

        case "arguments":
            // 支持行内 [a, b] 或多行列表
            if rawValue.hasPrefix("[") {
                result.argumentNames = parseInlineList(rawValue)
            } else if rawValue.isEmpty {
                collectingField = "arguments"
                collectedLines = []
            } else {
                result.argumentNames = [removeQuotes(rawValue)]
            }

        case "allowed-tools":
            if rawValue.hasPrefix("[") {
                result.allowedTools = parseInlineList(rawValue)
            } else if rawValue.isEmpty {
                collectingField = "allowed-tools"
                collectedLines = []
            } else {
                result.allowedTools = [removeQuotes(rawValue)]
            }

        case "model":
            let m = removeQuotes(rawValue)
            result.model = m == "inherit" ? nil : m.nonEmptyOrNil

        case "effort":
            result.effort = EffortLevel(rawValue: removeQuotes(rawValue).lowercased())
            if result.effort == nil && !rawValue.isEmpty {
                print("[SkillService]   parseFrontmatter: invalid effort '\(rawValue)' in \(url.lastPathComponent)")
            }

        case "context":
            result.executionContext = SkillExecutionContext(rawValue: removeQuotes(rawValue)) ?? .inline

        case "agent":
            result.agent = removeQuotes(rawValue).nonEmptyOrNil

        case "user-invocable":
            result.userInvocable = parseBool(rawValue, default: true)

        case "disable-model-invocation":
            result.disableModelInvocation = parseBool(rawValue, default: false)

        case "version":
            result.version = removeQuotes(rawValue).nonEmptyOrNil

        case "paths":
            if rawValue.hasPrefix("[") {
                result.paths = parseInlineList(rawValue).nonEmptyOrNil
            } else if rawValue.isEmpty {
                collectingField = "paths"
                collectedLines = []
            } else {
                result.paths = [removeQuotes(rawValue)]
            }

        default:
            break
        }
    }

    return result
}

// MARK: - Frontmatter parsing helpers (nonisolated static)

nonisolated private static func flushCollectedLines(
    _ result: inout SkillFrontmatterResult,
    field: String?,
    lines: [String]
) {
    guard let field, !lines.isEmpty else { return }
    switch field {
    case "description":   result.description = lines.joined(separator: " ")
    case "arguments":     result.argumentNames = lines
    case "allowed-tools": result.allowedTools = lines
    case "paths":         result.paths = lines.nonEmptyOrNil
    default: break
    }
}

/// Parses a YAML inline list like `[a, b, c]` or `[read_file, write_file]`.
nonisolated private static func parseInlineList(_ raw: String) -> [String] {
    let stripped = raw.trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    return stripped
        .components(separatedBy: ",")
        .map { removeQuotes($0.trimmingCharacters(in: .whitespaces)) }
        .filter { !$0.isEmpty }
}

/// Parses a YAML boolean value (`true`/`false`/`yes`/`no`), returning `defaultValue` if unrecognized.
nonisolated private static func parseBool(_ raw: String, default defaultValue: Bool) -> Bool {
    switch raw.lowercased() {
    case "true", "yes", "1":  return true
    case "false", "no", "0":  return false
    default:                   return defaultValue
    }
}
```

**3c. 在同文件顶部（或 SkillService.swift 的 extension String 区段）添加辅助属性：**

```swift
private extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}

private extension Array {
    var nonEmptyOrNil: [Element]? { isEmpty ? nil : self }
}
```

**3d. 更新 `scanSkills()` 中的 `Skill` 构造调用，将解析结果传入新字段：**

在 `scanSkills(in:)` 的 `contents.compactMap` 闭包中，将：

```swift
let (name, description) = parseFrontmatter(at: skillFile)
// ...
return Skill(
    directoryName: dirName,
    name: name ?? dirName,
    description: description ?? "",
    path: url,
    contentURL: skillFile
)
```

替换为：

```swift
let fm_result = parseFrontmatter(at: skillFile)
let dirName = url.lastPathComponent

// 检测参考文件（hasReferenceFiles）
let otherFiles = (try? fm.contentsOfDirectory(
    at: url,
    includingPropertiesForKeys: nil,
    options: [.skipsHiddenFiles]
))?.filter { $0.lastPathComponent != "SKILL.md" } ?? []
let hasReferenceFiles = !otherFiles.isEmpty

print("[SkillService]   loaded skill: dir=\(dirName) name=\(fm_result.name ?? "(nil)") desc=\(fm_result.description?.prefix(60) ?? "(nil)")")

return Skill(
    directoryName: dirName,
    name: fm_result.name ?? dirName,
    description: fm_result.description ?? "",
    path: url,
    contentURL: skillFile,
    whenToUse: fm_result.whenToUse,
    argumentHint: fm_result.argumentHint,
    argumentNames: fm_result.argumentNames,
    allowedTools: fm_result.allowedTools,
    model: fm_result.model,
    effort: fm_result.effort,
    executionContext: fm_result.executionContext,
    agent: fm_result.agent,
    userInvocable: fm_result.userInvocable,
    disableModelInvocation: fm_result.disableModelInvocation,
    version: fm_result.version,
    paths: fm_result.paths,
    hasReferenceFiles: hasReferenceFiles,
    loadedFrom: .user
)
```

### Step 4: 运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-skill-s-a1-derived \
  -only-testing:agentGuiTests/SkillServiceFrontmatterTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：所有 `SkillServiceFrontmatterTests` 通过。

### Step 5: 确认无回归

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-skill-s-a1-derived \
  -only-testing:agentGuiTests/SkillManifestTests \
  -only-testing:agentGuiTests/SkillServiceFrontmatterTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：两个测试套件全部通过，无编译错误。

### Step 6: Commit

```bash
git add agentGui/Services/SkillService.swift agentGuiTests/SkillServiceFrontmatterTests.swift
git commit -m "feat(S-A1): extend SkillService parseFrontmatter to parse all 14 new manifest fields"
```

---

## Task 3: hasReferenceFiles 专项测试

**Files:**
- Modify: `agentGuiTests/SkillServiceFrontmatterTests.swift`（追加测试）

### Step 1: 追加 hasReferenceFiles 测试

在 `SkillServiceFrontmatterTests` 中追加：

```swift
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
```

### Step 2: 运行，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-skill-s-a1-derived \
  -only-testing:agentGuiTests/SkillServiceFrontmatterTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：新增的两个 `hasReferenceFiles` 测试通过。

### Step 3: Commit

```bash
git add agentGuiTests/SkillServiceFrontmatterTests.swift
git commit -m "test(S-A1): add hasReferenceFiles tests for SkillService"
```

---

## Task 4: 验证现有 Skill 用例不受影响（回归验证）

**Files:** 无修改（只运行已有测试）

### Step 1: 运行涉及 SkillService 的全项目测试

> 如项目没有专门的 SkillService 测试，运行 Quality Smoke 任务代替。

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-skill-s-a1-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|BUILD FAILED|error:" | head -50
```

预期：Build 成功，全部测试通过，无回归。

### Step 2: 检查编译警告

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-skill-s-a1-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "warning:|error:" | grep -v "^ld:"
```

预期：无新增编译警告。

### Step 3: Commit（回归通过确认 commit）

```bash
git add -p  # 确认无意外变更
git commit -m "test(S-A1): regression clean — all existing tests pass after manifest extension"
```

---

## 验收清单

| 验收标准 | 覆盖 Task |
|---------|----------|
| `SkillExecutionContext`、`SkillSource`、`EffortLevel` 枚举的 rawValue roundtrip 全通过 | Task 1 |
| `Skill` struct 包含所有 14 个新字段，缺失字段退回默认值 | Task 1 |
| `parseFrontmatter` 正确解析 `when_to_use`、`argument-hint`、`arguments`（列表 + 行内）| Task 2 |
| `parseFrontmatter` 正确解析 `allowed-tools`（列表 + 行内）| Task 2 |
| `model: inherit` 被解析为 `nil`；有效 modelId 保留字符串 | Task 2 |
| `effort` 的四个枚举值均可解析；无效值静默退回 `nil` | Task 2 |
| `context: fork` → `.fork`；无 context 字段 → `.inline` | Task 2 |
| `user-invocable: false` 正确解析；默认值 `true` | Task 2 |
| `disable-model-invocation: true` 正确解析；默认值 `false` | Task 2 |
| `version`、`paths`、`agent` 字段正确解析 | Task 2 |
| 完整 frontmatter roundtrip 测试通过 | Task 2 |
| 原有仅含 name/description 的 frontmatter 仍正常加载（向后兼容）| Task 2 |
| 多文件目录 `hasReferenceFiles = true`；纯 SKILL.md 目录 → `false` | Task 3 |
| 全项目测试无回归 | Task 4 |

---

## 重要注意事项

1. **不修改 SkillsView**：S-G1 会负责 SkillsView 的 UI 更新，本 feature 只改数据层。
2. **不修改 system prompt 注入**：S-B1 会重构 skill 的 system prompt 渲染，本 feature 只改 Skill 模型。
3. **`loadedFrom` 硬编码为 `.user`**：S-A2 实现项目级技能扫描后，会根据来源目录动态设置此字段。
4. **多行 YAML 解析仅支持简单列表**：本实现不处理嵌套 YAML 对象（如 `hooks:`），这些字段在后续 feature（S-C3）中展开。遇到无法解析的字段静默跳过，不 crash。
5. **`SkillFrontmatterResult` 为 private struct**：不暴露为 public API，外部通过 `Skill` 属性访问解析结果。

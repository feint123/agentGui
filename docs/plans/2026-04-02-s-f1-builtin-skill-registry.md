# S-F1 Built-in Skill Registry 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 建立 agentGui 内置技能注册机制（`BuiltInSkillRegistry`），允许 Swift 代码在启动时以编程方式注册内置技能，并无缝整合进现有 `SkillService.availableSkills` 流水线。

**Architecture:** 新建 `BuiltInSkillRegistry`（write-once 启动注册 + read-heavy 运行时查询），通过三处 `SkillService` 扩展接入：① `loadSkills()` 合并 bundled skills；② `readSkillContent()` 走 registry 内容路径；③ `enabledSkills()` 对 bundled skills 免检。`BuiltInSkillDefinition` 通过 `@Sendable () async -> String` 闭包提供 prompt 内容，使 `Skill` 结构体保持纯值类型。

**Tech Stack:** Swift 6, SwiftUI, SwiftData，现有 `SkillService` / `Skill` / `SkillCatalogPromptRenderer` / `SkillInvocationProcessor`

---

## 背景与约束

### 已完成的依赖

| 特性 | 文件 | 状态 |
|------|------|------|
| S-A1 Skill Manifest | `agentGui/Models/Skill.swift` | ✅ 已实现，含 `loadedFrom: SkillSource`（`.bundled` case 已存在） |
| S-A2 多源加载 | `agentGui/Services/SkillService.swift` | ✅ user + project 已实现 |
| S-B1/B2 SkillCatalogPromptRenderer | `agentGui/Services/SkillCatalogPromptRenderer.swift` | ✅ 已实现，已对 `.bundled` 作优先保留处理 |
| SkillInvocationProcessor | `agentGui/Services/SkillInvocationProcessor.swift` | ✅ 已实现 |
| SkillArgumentSubstitution | `agentGui/Services/SkillArgumentSubstitution.swift` | ✅ 已实现 |
| Test Fixture | `agentGuiTests/TestSupport/SkillTestFixtures.swift` | ✅ 支持 `loadedFrom: .bundled` |

### 尚不存在的部分（本 Feature 范围）

- `agentGui/Services/BuiltInSkillRegistry.swift` ← 本 Feature 主产出
- `agentGuiTests/BuiltInSkillRegistryTests.swift` ← 测试文件
- `SkillService.swift` 的三处修改
- `SkillService.loadSkills` 的新测试（追加到现有测试文件）

### Claude Code 对标

源文件：`src/skills/bundledSkills.ts`  
关键设计：
- `BundledSkillDefinition` → `BuiltInSkillDefinition`（Swift 等价）
- `registerBundledSkill()` → `BuiltInSkillRegistry.shared.register()`
- `getBundledSkills()` → `BuiltInSkillRegistry.shared.allSkills()`
- 内容通过 `getPromptForCommand` 闭包（Swift：`@Sendable () async -> String`）提供
- Bundled skills 的 `loadedFrom == "bundled"`，不受用户开关控制

### 关键设计决策

**合并优先级：** 磁盘技能（user/project）优先于 bundled。  
`loadAllSkills` 最终顺序：`mergeAndDeduplicate(userSkills + projectSkills)` 结果 + `.bundled` skills。  
同名磁盘技能覆盖 bundled 技能（第一个 directoryName 胜出）。

**Synthetic URL：** Bundled skills 使用 `URL(fileURLWithPath: "/bundled/<directoryName>/SKILL.md")` 作为 `contentURL` 占位符（该路径在真实系统不存在，不会与磁盘技能冲突；`mergeAndDeduplicate` 的 realpath 去重不会误识别为重复）。

**线程安全：** `BuiltInSkillRegistry` 采用 `final class` + `@unchecked Sendable`。注册只在 App 启动时发生（串行），之后只读。

---

## 测试运行命令

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-derived \
  -only-testing:agentGuiTests/BuiltInSkillRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:|SUCCEEDED|FAILED"
```

全 Skill 测试（回归）：

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-derived \
  -only-testing:agentGuiTests/BuiltInSkillRegistryTests \
  -only-testing:agentGuiTests/SkillManifestTests \
  -only-testing:agentGuiTests/SkillServiceFrontmatterTests \
  -only-testing:agentGuiTests/SkillInvocationProcessorTests \
  -only-testing:agentGuiTests/SkillCatalogPromptRendererTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:|SUCCEEDED|FAILED"
```

---

## Task 1：创建 `BuiltInSkillRegistry.swift`

**Files:**
- Create: `agentGui/Services/BuiltInSkillRegistry.swift`

### Step 1: 写失败测试（驱动接口设计）

创建 `agentGuiTests/BuiltInSkillRegistryTests.swift`：

```swift
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
```

### Step 2: 运行测试，验证编译失败（类型不存在）

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-derived \
  -only-testing:agentGuiTests/BuiltInSkillRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|SUCCEEDED|FAILED" | head -20
```

预期：`error: cannot find type 'BuiltInSkillRegistry' in scope`

### Step 3: 实现 `BuiltInSkillRegistry.swift`

```swift
//
//  BuiltInSkillRegistry.swift
//  agentGui
//

import Foundation

// MARK: - BuiltInSkillDefinition

/// Programmatic definition for a skill shipped with the app binary.
/// Mirrors `BundledSkillDefinition` in Claude Code `src/skills/bundledSkills.ts`.
struct BuiltInSkillDefinition: Sendable {
    let name: String
    let description: String

    // 执行控制（全部可选，对照 S-A1 Skill 字段）
    let whenToUse: String?
    let argumentHint: String?
    let argumentNames: [String]
    let allowedTools: [String]
    let model: String?
    let effort: EffortLevel?
    let executionContext: SkillExecutionContext
    let agent: String?
    let userInvocable: Bool
    let disableModelInvocation: Bool
    let version: String?

    /// 条件启用：返回 false 时，`allSkills()` 不包含该技能。nil 表示始终启用。
    let isEnabled: (@Sendable () -> Bool)?

    /// 技能内容提供器（返回原始 prompt 模板，含 $ARGUMENTS 等占位符）。
    let getPromptContent: @Sendable () async -> String

    init(
        name: String,
        description: String,
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
        isEnabled: (@Sendable () -> Bool)? = nil,
        getPromptContent: @escaping @Sendable () async -> String
    ) {
        self.name = name
        self.description = description
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
        self.isEnabled = isEnabled
        self.getPromptContent = getPromptContent
    }
}

// MARK: - BuiltInSkillRegistry

/// Registry for skills shipped with the app binary.
///
/// Write pattern: `register()` is called only at app startup (serial),
/// before any concurrent reads. `@unchecked Sendable` is therefore safe
/// for the stored dictionary.
///
/// Usage:
/// ```swift
/// // At app startup:
/// BuiltInSkillRegistry.shared.register(mySkillDefinition)
///
/// // In SkillService:
/// let bundled = BuiltInSkillRegistry.shared.allSkills()
/// ```
final class BuiltInSkillRegistry: @unchecked Sendable {

    // MARK: - Shared Instance

    static let shared = BuiltInSkillRegistry()

    // MARK: - Private Storage

    /// Keyed by `name` for O(1) lookup in `promptContent()`.
    private var definitions: [String: BuiltInSkillDefinition] = [:]

    // MARK: - Init

    init() {}

    // MARK: - Registration

    /// Registers a built-in skill definition.
    /// If a definition with the same `name` already exists, it is replaced.
    /// Call only at app startup (serial context) before any async access.
    func register(_ definition: BuiltInSkillDefinition) {
        definitions[definition.name] = definition
    }

    // MARK: - Query

    /// Returns all enabled built-in skills as `Skill` value types.
    /// Skills with `isEnabled` returning `false` are excluded.
    func allSkills() -> [Skill] {
        definitions.values
            .filter { $0.isEnabled?() ?? true }
            .map(Self.makeSkill(from:))
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Returns the raw prompt template for a registered skill, or nil if not found.
    func promptContent(skillName: String) async -> String? {
        guard let def = definitions[skillName] else { return nil }
        return await def.getPromptContent()
    }

    // MARK: - Testing Support

    /// Removes all registered definitions. Only call from test tearDown.
    func clearForTesting() {
        definitions.removeAll()
    }

    // MARK: - Private Helpers

    /// Maps a `BuiltInSkillDefinition` to a `Skill` value type.
    /// Uses a synthetic non-existent file URL as placeholder for `contentURL`;
    /// the real content is always fetched via `promptContent(skillName:)`.
    private static func makeSkill(from def: BuiltInSkillDefinition) -> Skill {
        // Synthetic paths: /bundled/<name>/ won't exist on any real macOS system,
        // so mergeAndDeduplicate won't confuse them with disk-based skills.
        let syntheticDir = URL(fileURLWithPath: "/bundled/\(def.name)", isDirectory: true)
        let syntheticContent = syntheticDir.appending(path: "SKILL.md")

        return Skill(
            directoryName: def.name,
            name: def.name,
            description: def.description,
            path: syntheticDir,
            contentURL: syntheticContent,
            whenToUse: def.whenToUse,
            argumentHint: def.argumentHint,
            argumentNames: def.argumentNames,
            allowedTools: def.allowedTools,
            model: def.model,
            effort: def.effort,
            executionContext: def.executionContext,
            agent: def.agent,
            userInvocable: def.userInvocable,
            disableModelInvocation: def.disableModelInvocation,
            version: def.version,
            paths: nil,
            hasReferenceFiles: false,
            loadedFrom: .bundled
        )
    }
}
```

### Step 4: 运行测试，验证全通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-derived \
  -only-testing:agentGuiTests/BuiltInSkillRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:|SUCCEEDED|FAILED"
```

预期：`Test Suite 'BuiltInSkillRegistryTests' passed`（全部测试通过）

### Step 5: 提交

```bash
cd /Volumes/T7/文稿/Projects/agentGui
git add agentGui/Services/BuiltInSkillRegistry.swift \
        agentGuiTests/BuiltInSkillRegistryTests.swift
git commit -m "feat(SF1): add BuiltInSkillRegistry with BuiltInSkillDefinition"
```

---

## Task 2：`SkillService.loadSkills()` 合并 bundled skills

**Files:**
- Modify: `agentGui/Services/SkillService.swift`（`loadAllSkills` 静态方法）

### Step 1: 写失败测试

`SkillService` 当前无与 bundled 相关的测试。在 `BuiltInSkillRegistryTests.swift` 末尾新增一段（或另建测试文件），**直接测试合并行为**：

```swift
// 追加到 BuiltInSkillRegistryTests.swift，新 class：

final class SkillServiceBundledMergeTests: XCTestCase {

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
}
```

### Step 2: 运行测试，验证失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-derived \
  -only-testing:agentGuiTests/BuiltInSkillRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:|SUCCEEDED|FAILED"
```

预期：`test_loadSkills_bundledSkillAppearsInAvailableSkills` 失败（bundled skill 不在列表中）

### Step 3: 修改 `SkillService.loadAllSkills`

找到 `loadAllSkills` 方法，在返回前追加 bundled skills 合并：

```swift
// 修改前（SkillService.swift 约 374 行附近）：
nonisolated private static func loadAllSkills(
    userSkillsDir: URL,
    workspaceURL: URL?
) -> [Skill] {
    let userSkills = scanSkills(in: userSkillsDir, source: .user)

    var projectSkills: [Skill] = []
    if let workspace = workspaceURL {
        let projectDirs = projectSkillDirs(startingAt: workspace)
        for dir in projectDirs {
            let skills = scanSkills(in: dir, source: .project)
            projectSkills.append(contentsOf: skills)
        }
    }

    let merged = mergeAndDeduplicate(userSkills + projectSkills)
    return merged.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
}

// 修改后：
nonisolated private static func loadAllSkills(
    userSkillsDir: URL,
    workspaceURL: URL?
) -> [Skill] {
    let userSkills = scanSkills(in: userSkillsDir, source: .user)

    var projectSkills: [Skill] = []
    if let workspace = workspaceURL {
        let projectDirs = projectSkillDirs(startingAt: workspace)
        for dir in projectDirs {
            let skills = scanSkills(in: dir, source: .project)
            projectSkills.append(contentsOf: skills)
        }
    }

    // 磁盘技能（user + project）优先合并去重
    let diskMerged = mergeAndDeduplicate(userSkills + projectSkills)

    // Bundled skills 追加（已存在同名磁盘技能时跳过）
    let diskNames = Set(diskMerged.map(\.directoryName))
    let bundledSkills = BuiltInSkillRegistry.shared.allSkills().filter {
        !diskNames.contains($0.directoryName)
    }

    let all = diskMerged + bundledSkills
    return all.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
}
```

> **注意：** `loadAllSkills` 是 `nonisolated static` 方法，在 `Task.detached` 中执行（非 `@MainActor` 上下文）。访问 `BuiltInSkillRegistry.shared` 是安全的，因为 registry 是 `@unchecked Sendable`，注册在启动时完成。

### Step 4: 运行测试，验证通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-derived \
  -only-testing:agentGuiTests/BuiltInSkillRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:|SUCCEEDED|FAILED"
```

预期：全部通过，包括 `test_loadSkills_diskSkillWinsOverBundledWithSameName`

### Step 5: 提交

```bash
git add agentGui/Services/SkillService.swift \
        agentGuiTests/BuiltInSkillRegistryTests.swift
git commit -m "feat(SF1): merge bundled skills into SkillService.loadAllSkills"
```

---

## Task 3：`SkillService.readSkillContent()` 支持 bundled 内容路径

**Files:**
- Modify: `agentGui/Services/SkillService.swift`（`readSkillContent` 方法）

### Step 1: 写失败测试

追加到 `BuiltInSkillRegistryTests.swift` 的 `SkillServiceBundledMergeTests`：

```swift
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
    var callCount = 0
    BuiltInSkillRegistry.shared.register(BuiltInSkillDefinition(
        name: "cache-test",
        description: "Cache test",
        getPromptContent: {
            callCount += 1
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
    XCTAssertEqual(callCount, 1)
}
```

### Step 2: 运行测试，验证失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-derived \
  -only-testing:agentGuiTests/BuiltInSkillRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:|SUCCEEDED|FAILED"
```

预期：`test_readSkillContent_bundledSkill_returnsRegistryContent` 失败（返回 nil，因为磁盘文件不存在）

### Step 3: 修改 `SkillService.readSkillContent`

找到 `readSkillContent(name:)` 方法（约第 57 行），在缓存检查之后、`Task.detached` 磁盘读取之前，插入 bundled 分支：

```swift
// 修改前（约第 57-86 行）：
func readSkillContent(name: String) async -> String? {
    guard let skill = availableSkills.first(where: { $0.name == name || $0.directoryName == name }) else {
        print("[SkillService]  read_skill: '\(name)' not found. available=\(availableSkills.map(\.name))")
        return nil
    }
    let key = skill.directoryName
    if let cached = contentCache[key] {
        print("[SkillService] read_skill '\(name)' — returned from cache (\(cached.count) chars)")
        return cached
    }

    let loaded = await Task.detached(priority: .utility) {
        Self.loadSkillContent(skill)
    }.value

    guard let loaded else {
        print("[SkillService]  read_skill '\(name)' — failed to read \(skill.contentURL.path)")
        return nil
    }

    contentCache[loaded.cacheKey] = loaded.content
    print("[SkillService] read_skill '\(name)' — loaded \(loaded.content.count) chars from \(skill.contentURL.path)")
    return loaded.content
}

// 修改后（在缓存命中检查之后、Task.detached 之前插入分支）：
func readSkillContent(name: String) async -> String? {
    guard let skill = availableSkills.first(where: { $0.name == name || $0.directoryName == name }) else {
        print("[SkillService]  read_skill: '\(name)' not found. available=\(availableSkills.map(\.name))")
        return nil
    }
    let key = skill.directoryName
    if let cached = contentCache[key] {
        print("[SkillService] read_skill '\(name)' — returned from cache (\(cached.count) chars)")
        return cached
    }

    // Bundled skills: get content from registry, skip disk read
    if skill.loadedFrom == .bundled {
        let content = await BuiltInSkillRegistry.shared.promptContent(skillName: skill.directoryName)
        guard let content else {
            print("[SkillService]  read_skill '\(name)' — bundled content not found in registry")
            return nil
        }
        contentCache[key] = content
        print("[SkillService] read_skill '\(name)' — loaded \(content.count) chars from bundled registry")
        return content
    }

    let loaded = await Task.detached(priority: .utility) {
        Self.loadSkillContent(skill)
    }.value

    guard let loaded else {
        print("[SkillService]  read_skill '\(name)' — failed to read \(skill.contentURL.path)")
        return nil
    }

    contentCache[loaded.cacheKey] = loaded.content
    print("[SkillService] read_skill '\(name)' — loaded \(loaded.content.count) chars from \(skill.contentURL.path)")
    return loaded.content
}
```

### Step 4: 运行测试，验证通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-derived \
  -only-testing:agentGuiTests/BuiltInSkillRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:|SUCCEEDED|FAILED"
```

预期：全部通过

### Step 5: 提交

```bash
git add agentGui/Services/SkillService.swift
git commit -m "feat(SF1): route bundled skill content through BuiltInSkillRegistry"
```

---

## Task 4：`SkillService.enabledSkills()` 对 bundled 免检

**Files:**
- Modify: `agentGui/Services/SkillService.swift`（`enabledSkills(enabledNames:)` 方法）

`enabledSkills` 目前只返回 `enabledNames` 中包含的技能。Bundled skills 不受用户开关控制，应始终出现。

### Step 1: 写失败测试

追加到 `SkillServiceBundledMergeTests`：

```swift
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
```

### Step 2: 运行测试，验证失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-derived \
  -only-testing:agentGuiTests/BuiltInSkillRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:|SUCCEEDED|FAILED"
```

预期：`test_enabledSkills_bundledSkill_alwaysIncluded_evenIfNotInEnabledNames` 失败

### Step 3: 修改 `enabledSkills(enabledNames:)`

```swift
// 修改前：
func enabledSkills(enabledNames: [String]) -> [Skill] {
    guard !enabledNames.isEmpty else { return [] }
    return availableSkills.filter { enabledNames.contains($0.directoryName) }
}

// 修改后：
func enabledSkills(enabledNames: [String]) -> [Skill] {
    return availableSkills.filter {
        $0.loadedFrom == .bundled || enabledNames.contains($0.directoryName)
    }
}
```

> **注意：** 移除了 `guard !enabledNames.isEmpty else { return [] }` 短路—— bundled skills 即使 `enabledNames` 为空也应出现。

### Step 4: 运行测试，验证通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-derived \
  -only-testing:agentGuiTests/BuiltInSkillRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:|SUCCEEDED|FAILED"
```

预期：全部通过

### Step 5: 提交

```bash
git add agentGui/Services/SkillService.swift
git commit -m "feat(SF1): bundled skills bypass enabledNames check in enabledSkills()"
```

---

## Task 5：全套 Skill 测试回归验证

### Step 1: 运行完整 Skill 回归测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-derived \
  -only-testing:agentGuiTests/BuiltInSkillRegistryTests \
  -only-testing:agentGuiTests/SkillManifestTests \
  -only-testing:agentGuiTests/SkillServiceFrontmatterTests \
  -only-testing:agentGuiTests/SkillInvocationProcessorTests \
  -only-testing:agentGuiTests/SkillCatalogPromptRendererTests \
  -only-testing:agentGuiTests/SkillArgumentSubstitutionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:|SUCCEEDED|FAILED"
```

预期：所有测试套件通过，无回归失败

### Step 2: SkillInvocationProcessor 端到端验证

确认 `BuiltInSkillRegistry` 注册的技能可以被 `SkillInvocationProcessor` 正确调用（通过 `SkillsStubContentProvider` 模式测试，不需要新增大量代码——仅验证 `loadedFrom == .bundled` 的 skill 走同样的 `invoke` 路径）。

检查 `SkillInvocationProcessorTests` 中是否已有 bundled skill fixture 的测试。若无，在 `SkillInvocationProcessorTests.swift` 中追加：

```swift
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
```

运行：
```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-derived \
  -only-testing:agentGuiTests/SkillInvocationProcessorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:|SUCCEEDED|FAILED"
```

### Step 3: 提交最终验证

```bash
git add agentGuiTests/SkillInvocationProcessorTests.swift
git commit -m "test(SF1): verify bundled skill flows through SkillInvocationProcessor"
```

---

## Task 6：Xcode 项目注册新文件（如需）

**Files:**
- Modify: `agentGui.xcodeproj/project.pbxproj`（由 Xcode 自动管理）

如果 `BuiltInSkillRegistry.swift` 创建后在 Xcode 中没有被自动加入编译目标，需手动将其加入 `agentGui` target：

1. 在 Xcode 中打开 `agentGui.xcodeproj`
2. 在 Project Navigator 中确认 `BuiltInSkillRegistry.swift` 在 `agentGui/Services/` 下
3. 若文件未加入 target，选中文件 → File Inspector → Target Membership → 勾选 `agentGui`

同样确认 `BuiltInSkillRegistryTests.swift` 已加入 `agentGuiTests` target。

编译验证：
```bash
xcodebuild build \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

---

## 验收标准汇总

| 标准 | 验证方式 |
|------|---------|
| `BuiltInSkillRegistry` 可注册 `BuiltInSkillDefinition` | `BuiltInSkillRegistryTests` 全通过 |
| 注册的技能出现在 `allSkills()`，`loadedFrom == .bundled` | `test_register_setsLoadedFromBundled` |
| `isEnabled: { false }` 的技能被 `allSkills()` 过滤 | `test_allSkills_excludesSkill_whenIsEnabledReturnsFalse` |
| `SkillService.loadSkills()` 后 bundled skill 出现在 `availableSkills` | `test_loadSkills_bundledSkillAppearsInAvailableSkills` |
| 磁盘同名技能优先于 bundled | `test_loadSkills_diskSkillWinsOverBundledWithSameName` |
| `readSkillContent` 通过 registry 获取 bundled 内容（不读磁盘）| `test_readSkillContent_bundledSkill_returnsRegistryContent` |
| bundled 内容在 service 内被缓存，闭包不重复调用 | `test_readSkillContent_bundledSkill_isCachedOnSecondCall` |
| `enabledSkills([])` 仍包含 bundled skill | `test_enabledSkills_bundledSkill_alwaysIncluded_evenIfNotInEnabledNames` |
| 现有 Skill 测试无回归 | 完整回归测试套件通过 |

---

## 注意事项

### Swift 6 并发安全

- `BuiltInSkillRegistry` 标注 `@unchecked Sendable`：注册只在 App 启动时串行完成，之后只读。
- `getPromptContent: @Sendable () async -> String`：闭包标注 `@Sendable`，确保捕获的值可跨 actor 边界传递。
- `BuiltInSkillRegistry.shared.allSkills()` 在 `loadAllSkills`（nonisolated 上下文）中调用是安全的。

### `enabledSkills` 行为变更

移除了 `guard !enabledNames.isEmpty else { return [] }` 短路。调用方（`ClaudeService` 等）如果之前依赖空列表返回空结果，现在会收到 bundled skills。请确认调用方能处理包含 bundled skills 的非空列表（已有 `SkillCatalogPromptRenderer` 正确处理 bundled skills）。

调用 `enabledSkills` 的位置：
```bash
grep -r "enabledSkills" agentGui/ --include="*.swift"
```
运行此命令确认所有调用点，逐一检查是否需要适配。

### 测试隔离

`SkillServiceBundledMergeTests` 访问 `BuiltInSkillRegistry.shared`，必须在 `tearDown` 中调用 `BuiltInSkillRegistry.shared.clearForTesting()` 防止测试间污染。每个测试方法开始前也可加 `setUp` 清理。

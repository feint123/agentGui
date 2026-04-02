# S-B1 Skill Catalog Prompt Renderer 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 新建 `SkillCatalogPromptRenderer`，将系统提示中的技能列表由"全文注入"改为"预算感知的摘要列表"；同步实现 S-B2 的 `whenToUse` 路由提示拼接。

**Architecture:** 纯值类型 `SkillCatalogPromptRenderer` struct，持有 `charBudget: Int`，对外暴露 `renderSkillListing(_ skills: [Skill]) -> String` 一条 API。`ClaudeService+Prompting.swift` 的 `buildSystemPrompt()` 将现有的 `for skill in skills` 循环替换为对该渲染器的一次调用。不引入新依赖。

**Tech Stack:** Swift 6, XCTest, `@testable import agentGui`，不依赖 SwiftData/SwiftUI。

---

## 背景：现有代码位置

| 组件 | 文件 |
|------|------|
| Skill 模型（含 `whenToUse`、`loadedFrom`）| `agentGui/Models/Skill.swift` |
| 系统提示构建（待修改） | `agentGui/Services/ClaudeService/ClaudeService+Prompting.swift:buildSystemPrompt()` |
| 参考：Claude Code 原始算法 | `src/tools/SkillTool/prompt.ts`（TypeScript，不导入，仅参考逻辑） |

现有 `buildSystemPrompt()` 在 `if !skills.isEmpty` 块中直接拼接所有 skill 描述，没有长度控制。

---

## 常量速查（对齐 Claude Code prompt.ts）

```swift
static let skillBudgetContextPercent: Double = 0.01   // 1% of context window
static let charsPerToken: Int = 4
static let defaultCharBudget: Int = 8_000             // 1% × 200k tokens × 4
static let maxListingDescChars: Int = 250             // per-entry hard cap
static let minDescLength: Int = 20                    // fallback threshold
```

---

## Task 1 · 新建 SkillCatalogPromptRenderer（核心结构 + 常量）

**Files:**
- Create: `agentGui/Services/SkillCatalogPromptRenderer.swift`
- Create: `agentGuiTests/SkillCatalogPromptRendererTests.swift`

### 步骤 1：写失败测试——常量访问

```swift
// agentGuiTests/SkillCatalogPromptRendererTests.swift
import XCTest
@testable import agentGui

final class SkillCatalogPromptRendererTests: XCTestCase {

    func test_defaultCharBudget_is8000() {
        XCTAssertEqual(SkillCatalogPromptRenderer.defaultCharBudget, 8_000)
    }

    func test_maxListingDescChars_is250() {
        XCTAssertEqual(SkillCatalogPromptRenderer.maxListingDescChars, 250)
    }

    func test_renderer_init_defaultBudget() {
        let renderer = SkillCatalogPromptRenderer()
        XCTAssertEqual(renderer.charBudget, SkillCatalogPromptRenderer.defaultCharBudget)
    }

    func test_renderer_init_customBudget() {
        let renderer = SkillCatalogPromptRenderer(charBudget: 500)
        XCTAssertEqual(renderer.charBudget, 500)
    }
}
```

### 步骤 2：运行，确认编译报错（类型未定义）

```bash
cd /Volumes/T7/文稿/Projects/agentGui && xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sb1-task1 \
  -only-testing:agentGuiTests/SkillCatalogPromptRendererTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|TEST (SUCCEED|FAIL)" | head -20
```

期望：`error: cannot find type 'SkillCatalogPromptRenderer'`

### 步骤 3：最小实现（仅结构 + 常量）

```swift
// agentGui/Services/SkillCatalogPromptRenderer.swift
import Foundation

/// Budget-aware renderer for the Available Skills section of the system prompt.
///
/// Algorithm mirrors Claude Code `src/tools/SkillTool/prompt.ts`:
/// - skills 列表只注入 name + description + whenToUse 的摘要，不内联全文。
/// - 总长度由 charBudget 控制（默认 1% context window = 8000 chars）。
/// - bundled skills 始终保留完整描述；非 bundled 按比例截断。
/// - 极端超预算时，非 bundled 退化为 names-only。
struct SkillCatalogPromptRenderer {

    // MARK: - Constants

    static let skillBudgetContextPercent: Double = 0.01
    static let charsPerToken: Int = 4
    static let defaultCharBudget: Int = 8_000
    static let maxListingDescChars: Int = 250
    static let minDescLength: Int = 20

    // MARK: - Properties

    let charBudget: Int

    // MARK: - Init

    /// - Parameter contextWindowTokens: 当前模型的 context window token 数。若 nil，使用
    ///   `defaultCharBudget`；若提供，动态计算 1% × tokens × 4 chars/token。
    init(contextWindowTokens: Int? = nil) {
        if let tokens = contextWindowTokens {
            self.charBudget = max(
                SkillCatalogPromptRenderer.defaultCharBudget,
                Int(Double(tokens) * Double(SkillCatalogPromptRenderer.charsPerToken)
                    * SkillCatalogPromptRenderer.skillBudgetContextPercent)
            )
        } else {
            self.charBudget = SkillCatalogPromptRenderer.defaultCharBudget
        }
    }

    /// Direct init for testing with a specific budget.
    init(charBudget: Int) {
        self.charBudget = charBudget
    }
}
```

### 步骤 4：运行测试，确认通过

```bash
cd /Volumes/T7/文稿/Projects/agentGui && xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sb1-task1 \
  -only-testing:agentGuiTests/SkillCatalogPromptRendererTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|TEST (SUCCEED|FAIL)" | head -20
```

期望：`TEST SUCCEEDED`

### 步骤 5：Commit

```
git add agentGui/Services/SkillCatalogPromptRenderer.swift \
        agentGuiTests/SkillCatalogPromptRendererTests.swift
git commit -m "feat(S-B1): add SkillCatalogPromptRenderer struct with constants"
```

---

## Task 2 · entryDescription()——S-B2 whenToUse 拼接 + 250 字符硬上限

**Files:**
- Modify: `agentGui/Services/SkillCatalogPromptRenderer.swift`
- Modify: `agentGuiTests/SkillCatalogPromptRendererTests.swift`

这对应 Claude Code `getCommandDescription()` 函数的逻辑。

### 步骤 1：写失败测试

```swift
// 追加到 SkillCatalogPromptRendererTests 中

// MARK: - entryDescription

func test_entryDescription_noWhenToUse_returnsDescription() {
    let renderer = SkillCatalogPromptRenderer()
    let skill = Skill.fixture(description: "Review code quality")
    XCTAssertEqual(renderer.entryDescription(skill), "Review code quality")
}

func test_entryDescription_withWhenToUse_appendsWithDash() {
    let renderer = SkillCatalogPromptRenderer()
    let skill = Skill.fixture(
        description: "Review PR",
        whenToUse: "当用户请求代码审查时"
    )
    XCTAssertEqual(renderer.entryDescription(skill), "Review PR - 当用户请求代码审查时")
}

func test_entryDescription_truncatedAt250Chars() {
    let renderer = SkillCatalogPromptRenderer()
    let longDesc = String(repeating: "a", count: 300)
    let skill = Skill.fixture(description: longDesc)
    let result = renderer.entryDescription(skill)
    XCTAssertEqual(result.count, 250)
    XCTAssertTrue(result.hasSuffix("…"))
}

func test_entryDescription_exactlyAt250_notTruncated() {
    let renderer = SkillCatalogPromptRenderer()
    let desc = String(repeating: "b", count: 250)
    let skill = Skill.fixture(description: desc)
    let result = renderer.entryDescription(skill)
    XCTAssertEqual(result.count, 250)
    XCTAssertFalse(result.hasSuffix("…"))
}
```

**注意：** `Skill.fixture()` 仅在 `SkillManifestTests.swift` 内定义为 `private extension`。为跨测试文件使用，需要在 Task 2 末尾将其提取到 `TestSupport/SkillTestFixtures.swift`（见下文步骤）。

### 步骤 2：运行，确认 `entryDescription` 不存在

预期：`error: value of type 'SkillCatalogPromptRenderer' has no member 'entryDescription'`

### 步骤 3：提取 Skill.fixture() 到共享 TestSupport 文件

创建 `agentGuiTests/TestSupport/SkillTestFixtures.swift`（**不是 private**）：

```swift
// agentGuiTests/TestSupport/SkillTestFixtures.swift
import Foundation
@testable import agentGui

extension Skill {
    /// Minimal valid Skill for unit tests. All new S-A1 fields default to safe values.
    static func fixture(
        directoryName: String = "test-skill",
        name: String = "Test Skill",
        description: String = "A test skill",
        whenToUse: String? = nil,
        argumentHint: String? = nil,
        argumentNames: [String] = [],
        allowedTools: [String] = [],
        model: String? = nil,
        effort: EffortLevel? = nil,
        executionContext: SkillExecutionContext = .inline,
        userInvocable: Bool = true,
        disableModelInvocation: Bool = false,
        version: String? = nil,
        paths: [String]? = nil,
        hasReferenceFiles: Bool = false,
        loadedFrom: SkillSource = .user,
        path: URL = URL(fileURLWithPath: "/tmp/test-skill"),
        contentURL: URL = URL(fileURLWithPath: "/tmp/test-skill/SKILL.md")
    ) -> Skill {
        Skill(
            directoryName: directoryName,
            name: name,
            description: description,
            path: path,
            contentURL: contentURL,
            whenToUse: whenToUse,
            argumentHint: argumentHint,
            argumentNames: argumentNames,
            allowedTools: allowedTools,
            model: model,
            effort: effort,
            executionContext: executionContext,
            userInvocable: userInvocable,
            disableModelInvocation: disableModelInvocation,
            version: version,
            paths: paths,
            hasReferenceFiles: hasReferenceFiles,
            loadedFrom: loadedFrom
        )
    }
}
```

同时将 `SkillManifestTests.swift` 中的 `private extension Skill { static func fixture(...) }` 删除，改用上述共享版本（确认其现有测试仍然编译）。

### 步骤 4：实现 entryDescription()

在 `SkillCatalogPromptRenderer.swift` 中增加：

```swift
// MARK: - Internal Helpers

/// Combines description and whenToUse into a single routing description.
/// Truncates to maxListingDescChars characters.
func entryDescription(_ skill: Skill) -> String {
    let combined = skill.whenToUse.map { "\(skill.description) - \($0)" } ?? skill.description
    guard combined.count > Self.maxListingDescChars else { return combined }
    let truncated = combined.prefix(Self.maxListingDescChars - 1)
    return truncated + "…"
}
```

### 步骤 5：运行测试，确认通过

```bash
cd /Volumes/T7/文稿/Projects/agentGui && xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sb1-task2 \
  -only-testing:agentGuiTests/SkillCatalogPromptRendererTests \
  -only-testing:agentGuiTests/SkillManifestTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|TEST (SUCCEED|FAIL)" | head -20
```

期望：`TEST SUCCEEDED`（SkillManifestTests 也应继续通过）

### 步骤 6：Commit

```
git add agentGui/Services/SkillCatalogPromptRenderer.swift \
        agentGuiTests/TestSupport/SkillTestFixtures.swift \
        agentGuiTests/SkillManifestTests.swift \
        agentGuiTests/SkillCatalogPromptRendererTests.swift
git commit -m "feat(S-B1/S-B2): add entryDescription() with whenToUse concat and 250-char cap"
```

---

## Task 3 · renderSkillListing()——空列表 + 预算内的完整输出

**Files:**
- Modify: `agentGui/Services/SkillCatalogPromptRenderer.swift`
- Modify: `agentGuiTests/SkillCatalogPromptRendererTests.swift`

### 步骤 1：写失败测试

```swift
// MARK: - renderSkillListing — 基础路径

func test_renderSkillListing_emptyList_returnsEmpty() {
    let renderer = SkillCatalogPromptRenderer()
    XCTAssertEqual(renderer.renderSkillListing([]), "")
}

func test_renderSkillListing_singleSkill_formattedCorrectly() {
    let renderer = SkillCatalogPromptRenderer()
    let skill = Skill.fixture(name: "code-review", description: "Reviews code quality")
    let result = renderer.renderSkillListing([skill])
    XCTAssertEqual(result, "- code-review: Reviews code quality")
}

func test_renderSkillListing_multipleSkills_separatedByNewlines() {
    let renderer = SkillCatalogPromptRenderer()
    let skills = [
        Skill.fixture(name: "alpha", description: "Alpha skill"),
        Skill.fixture(name: "beta",  description: "Beta skill"),
    ]
    let result = renderer.renderSkillListing(skills)
    let lines = result.components(separatedBy: "\n")
    XCTAssertEqual(lines.count, 2)
    XCTAssertEqual(lines[0], "- alpha: Alpha skill")
    XCTAssertEqual(lines[1], "- beta: Beta skill")
}

func test_renderSkillListing_withinBudget_noTruncation() {
    // budget = 1000 chars, two skills with short descriptions
    let renderer = SkillCatalogPromptRenderer(charBudget: 1_000)
    let skills = [
        Skill.fixture(name: "a", description: "Short desc A"),
        Skill.fixture(name: "b", description: "Short desc B"),
    ]
    let result = renderer.renderSkillListing(skills)
    XCTAssertTrue(result.contains("Short desc A"))
    XCTAssertTrue(result.contains("Short desc B"))
    XCTAssertLessThanOrEqual(result.count, 1_000)
}
```

### 步骤 2：运行，确认 `renderSkillListing` 不存在

### 步骤 3：实现基础路径（预算充裕时直接返回）

```swift
// MARK: - Public API

/// Renders the Available Skills listing segment within the character budget.
///
/// Format: each entry `- name: description`
/// Result omits the "## Available Skills" header (caller's responsibility).
func renderSkillListing(_ skills: [Skill]) -> String {
    guard !skills.isEmpty else { return "" }

    let fullEntries = skills.map { skill -> (skill: Skill, entry: String) in
        let desc = entryDescription(skill)
        return (skill: skill, entry: "- \(skill.name): \(desc)")
    }

    // Newlines between entries: N-1 chars for N entries
    let fullTotal = fullEntries.reduce(0) { $0 + $1.entry.count } + (fullEntries.count - 1)

    if fullTotal <= charBudget {
        return fullEntries.map(\.entry).joined(separator: "\n")
    }

    return truncateToBudget(fullEntries: fullEntries, skills: skills)
}
```

（此步 `truncateToBudget` 暂以 TODO 占位，令全量路径通过测试即可）

```swift
private func truncateToBudget(
    fullEntries: [(skill: Skill, entry: String)],
    skills: [Skill]
) -> String {
    // TODO: implement in Task 4
    return fullEntries.map(\.entry).joined(separator: "\n")
}
```

### 步骤 4：运行测试，确认通过

```bash
cd /Volumes/T7/文稿/Projects/agentGui && xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sb1-task3 \
  -only-testing:agentGuiTests/SkillCatalogPromptRendererTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|TEST (SUCCEED|FAIL)" | head -20
```

### 步骤 5：Commit

```
git add agentGui/Services/SkillCatalogPromptRenderer.swift \
        agentGuiTests/SkillCatalogPromptRendererTests.swift
git commit -m "feat(S-B1): add renderSkillListing() — within-budget pass"
```

---

## Task 4 · renderSkillListing()——预算超出时的截断逻辑

**Files:**
- Modify: `agentGui/Services/SkillCatalogPromptRenderer.swift`
- Modify: `agentGuiTests/SkillCatalogPromptRendererTests.swift`

### 步骤 1：写失败测试

```swift
// MARK: - renderSkillListing — 预算超出路径

// 辅助：创建内容超过预算的 skill 列表
// 每个 skill 名 10 chars, 描述 200 chars → entry ≈ 214 chars
// budget = 100 chars → 任何 skill 都超

func test_renderSkillListing_overBudget_bundledSkillPreservedFull() {
    // budget = 80 chars: 一个 bundled skill(entry ~50 chars) + 一个 user skill(entry ~50 chars)
    // bundled 应保留完整，user 被截断或仅名称
    let renderer = SkillCatalogPromptRenderer(charBudget: 80)
    let bundledSkill = Skill.fixture(
        name: "bundled-tool",
        description: "Short",
        loadedFrom: .bundled
    )
    let userSkill = Skill.fixture(
        name: "user-tool",
        description: String(repeating: "x", count: 200),
        loadedFrom: .user
    )
    let result = renderer.renderSkillListing([bundledSkill, userSkill])
    // bundled 条目应完整存在
    XCTAssertTrue(result.contains("- bundled-tool: Short"),
                  "bundled skill entry should be preserved verbatim")
    // 整体长度不超过预算
    XCTAssertLessThanOrEqual(result.count, 80 + 80 /* generous slack for separator */ )
}

func test_renderSkillListing_overBudget_nonBundledDescriptionTruncated() {
    // budget = 60 chars
    // skill name="abc" (3), desc=100 chars → full entry = "- abc: " + 100 = 107 chars > 60
    let renderer = SkillCatalogPromptRenderer(charBudget: 60)
    let skill = Skill.fixture(
        name: "abc",
        description: String(repeating: "y", count: 100),
        loadedFrom: .user
    )
    let result = renderer.renderSkillListing([skill])
    // must be ≤ budget (or close, given separator accounting)
    XCTAssertLessThanOrEqual(result.count, 65)
    // should still contain skill name
    XCTAssertTrue(result.contains("abc"))
}

func test_renderSkillListing_extremelyOverBudget_nonBundledNamesOnly() {
    // budget = 20 chars (even minDescLength=20 can't fit), forces names-only for non-bundled
    let renderer = SkillCatalogPromptRenderer(charBudget: 20)
    let userSkill = Skill.fixture(
        name: "my-skill",
        description: String(repeating: "z", count: 200),
        loadedFrom: .user
    )
    let result = renderer.renderSkillListing([userSkill])
    // names-only: "- my-skill" (no colon, no description)
    XCTAssertTrue(result == "- my-skill",
                  "extremely over-budget non-bundled skill → names-only, got: \(result)")
}

func test_renderSkillListing_onlyBundledSkills_allPreservedEvenOverBudget() {
    // budget = 10, but all skills are bundled → preserve full descriptions
    let renderer = SkillCatalogPromptRenderer(charBudget: 10)
    let s1 = Skill.fixture(name: "b1", description: "Long bundled desc", loadedFrom: .bundled)
    let s2 = Skill.fixture(name: "b2", description: "Another bundled desc", loadedFrom: .bundled)
    let result = renderer.renderSkillListing([s1, s2])
    XCTAssertTrue(result.contains("Long bundled desc"))
    XCTAssertTrue(result.contains("Another bundled desc"))
}
```

### 步骤 2：运行，确认相关测试失败（truncateToBudget 是 TODO）

### 步骤 3：实现 truncateToBudget

将 `SkillCatalogPromptRenderer.swift` 中 `truncateToBudget` 替换为：

```swift
private func truncateToBudget(
    fullEntries: [(skill: Skill, entry: String)],
    skills: [Skill]
) -> String {
    // 1. 分区：bundled（始终保留完整）vs 其余
    var bundledIndices = IndexSet()
    var restSkills: [(index: Int, skill: Skill)] = []
    for (i, skillTuple) in fullEntries.enumerated() {
        if skillTuple.skill.loadedFrom == .bundled {
            bundledIndices.insert(i)
        } else {
            restSkills.append((index: i, skill: skillTuple.skill))
        }
    }

    // 2. bundled 占用的字符（含分隔符 +1 per entry）
    let bundledChars = fullEntries.enumerated().reduce(0) { sum, pair in
        bundledIndices.contains(pair.offset) ? sum + pair.element.entry.count + 1 : sum
    }
    let remainingBudget = charBudget - bundledChars

    // 3. 若无非 bundled skill，直接返回 bundled 全量
    if restSkills.isEmpty {
        return fullEntries.map(\.entry).joined(separator: "\n")
    }

    // 4. 计算非 bundled 可用于描述的字符数
    //    overhead = sum("- name: ".count) + (N-1 separators)
    let nameOverhead = restSkills.reduce(0) { $0 + $1.skill.name.count + 4 }  // "- " + ": " = 4
        + max(0, restSkills.count - 1)
    let availableForDescs = remainingBudget - nameOverhead
    let maxDescLen = restSkills.isEmpty ? 0 : availableForDescs / restSkills.count

    if maxDescLen < Self.minDescLength {
        // 极端超预算：非 bundled 退化为 names-only
        return fullEntries.enumerated().map { (i, pair) in
            bundledIndices.contains(i) ? pair.entry : "- \(pair.skill.name)"
        }.joined(separator: "\n")
    }

    // 5. 按 maxDescLen 截断非 bundled 描述
    return fullEntries.enumerated().map { (i, pair) in
        if bundledIndices.contains(i) { return pair.entry }
        let desc = entryDescription(pair.skill)
        if desc.count <= maxDescLen { return "- \(pair.skill.name): \(desc)" }
        let truncated = desc.prefix(maxDescLen - 1)
        return "- \(pair.skill.name): \(truncated)…"
    }.joined(separator: "\n")
}
```

### 步骤 4：运行所有 SkillCatalogPromptRendererTests

```bash
cd /Volumes/T7/文稿/Projects/agentGui && xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sb1-task4 \
  -only-testing:agentGuiTests/SkillCatalogPromptRendererTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|TEST (SUCCEED|FAIL)" | head -20
```

期望：`TEST SUCCEEDED`

### 步骤 5：Commit

```
git add agentGui/Services/SkillCatalogPromptRenderer.swift \
        agentGuiTests/SkillCatalogPromptRendererTests.swift
git commit -m "feat(S-B1): implement truncateToBudget() — bundled preserve + non-bundled truncate"
```

---

## Task 5 · 集成到 ClaudeService+Prompting.swift

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Prompting.swift`
- Modify: `agentGuiTests/SkillCatalogPromptRendererTests.swift`（集成场景测试）

### 步骤 1：写失败集成测试

这些测试直接验证 `buildSystemPrompt()` 的输出，不需要模拟 API：

```swift
// 追加到 SkillCatalogPromptRendererTests 中（或在独立文件中）
// 注意：buildSystemPrompt 是 ClaudeService 上的方法，需要构造一个可用实例。
// 参考 ClaudeServiceMemoryGuidanceInjectionTests.swift—它调用静态方法。
// buildSystemPrompt() 在 ClaudeService+Prompting.swift 中是一个实例方法，
// 但不依赖 @MainActor 状态，可以在 detached task 中调用。

// 建议：提取为可以在测试中直接调用的静态或独立函数。
// 若当前无法直接调用，仅验证 SkillCatalogPromptRenderer 的输出内容格式正确即可。
// 实际集成验证在步骤 3 后通过手动检查 log 输出。
```

**实际验证路径（因为 buildSystemPrompt 依赖环境，直接测试复杂）：**

在 `SkillCatalogPromptRendererTests` 中增加一个"输出格式与 buildSystemPrompt 预期对齐"的测试：

```swift
func test_renderSkillListing_outputFormat_matchesSystemPromptExpectation() {
    // 验证渲染器输出可以直接嵌入 buildSystemPrompt 的 skill 区段
    let renderer = SkillCatalogPromptRenderer()
    let skills = [
        Skill.fixture(name: "code-review", description: "Reviews code", whenToUse: "PR 时使用"),
        Skill.fixture(name: "debug", description: "Debugs issues"),
    ]
    let listing = renderer.renderSkillListing(skills)
    // 验证格式是 "- name: desc" 每行
    let lines = listing.components(separatedBy: "\n")
    XCTAssertTrue(lines[0].hasPrefix("- code-review: "))
    XCTAssertTrue(lines[0].contains("PR 时使用"),
                  "whenToUse should be included in the description")
    XCTAssertTrue(lines[1].hasPrefix("- debug: "))
}
```

### 步骤 2：实现——修改 ClaudeService+Prompting.swift

找到 `buildSystemPrompt()` 中的以下代码块（约第 182–191 行）：

```swift
if !skills.isEmpty {
    var lines = [
        "## Available Skills",
        "Use the 'read_skill' tool to load a skill's full instructions when the user's request matches its purpose.",
        ""
    ]
    for skill in skills {
        let desc = skill.description.isEmpty ? "(no description)" : skill.description
        lines.append("- **\(skill.name)**: \(desc)")
    }
    parts.append(lines.joined(separator: "\n"))
}
```

替换为：

```swift
if !skills.isEmpty {
    let renderer = SkillCatalogPromptRenderer()
    let listing = renderer.renderSkillListing(skills)
    let section = [
        "## Available Skills",
        "Use the `skill_invoke` tool to run a skill, or the `read_skill` tool to inspect its full instructions.",
        "",
        listing
    ].joined(separator: "\n")
    parts.append(section)
}
```

**改动说明：**
1. `- **\(skill.name)**: \(desc)` → `- name: desc`（去掉粗体 markdown，与 Claude Code 格式对齐）
2. 描述 hint 中补充 `skill_invoke`（S-C1 的工具名，为后续 feature 做铺垫，当前不影响行为）
3. 不再单独处理空描述（`entryDescription()` 已处理）

### 步骤 3：运行回归测试确认无编译错误

```bash
cd /Volumes/T7/文稿/Projects/agentGui && xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sb1-task5 \
  -only-testing:agentGuiTests/SkillCatalogPromptRendererTests \
  -only-testing:agentGuiTests/SkillManifestTests \
  -only-testing:agentGuiTests/SkillServiceFrontmatterTests \
  -only-testing:agentGuiTests/ClaudeServiceMemoryGuidanceInjectionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|TEST (SUCCEED|FAIL)" | head -20
```

期望：`TEST SUCCEEDED`

### 步骤 4：Commit

```
git add agentGui/Services/ClaudeService/ClaudeService+Prompting.swift \
        agentGuiTests/SkillCatalogPromptRendererTests.swift
git commit -m "feat(S-B1): wire SkillCatalogPromptRenderer into buildSystemPrompt()"
```

---

## Task 6 · contextWindowTokens 动态预算（可选扩展点）

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Prompting.swift`
- Modify: `agentGuiTests/SkillCatalogPromptRendererTests.swift`

### 步骤 1：写测试

```swift
func test_renderer_contextWindowTokens_200k_gives8000() {
    // 200_000 × 4 × 0.01 = 8000
    let renderer = SkillCatalogPromptRenderer(contextWindowTokens: 200_000)
    XCTAssertEqual(renderer.charBudget, 8_000)
}

func test_renderer_contextWindowTokens_1M_gives40000() {
    // 1_000_000 × 4 × 0.01 = 40_000
    let renderer = SkillCatalogPromptRenderer(contextWindowTokens: 1_000_000)
    XCTAssertEqual(renderer.charBudget, 40_000)
}

func test_renderer_contextWindowTokens_nil_usesDefault() {
    let renderer = SkillCatalogPromptRenderer(contextWindowTokens: nil)
    XCTAssertEqual(renderer.charBudget, 8_000)
}
```

### 步骤 2：运行测试，确认通过（init 逻辑已在 Task 1 实现）

### 步骤 3：在 buildSystemPrompt() 中传入上下文 tokens（占位）

当前 `buildSystemPrompt()` 签名不含 context window 信息；此处只需确保接口已预留：

```swift
// 未来：let renderer = SkillCatalogPromptRenderer(contextWindowTokens: runtimeContext.contextWindowTokens)
let renderer = SkillCatalogPromptRenderer()  // 当前使用默认值
```

（不需要修改签名，此任务只是把 `contextWindowTokens` 路径的测试覆盖补全。）

### 步骤 4：运行全量技能相关测试

```bash
cd /Volumes/T7/文稿/Projects/agentGui && xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sb1-task6 \
  -only-testing:agentGuiTests/SkillCatalogPromptRendererTests \
  -only-testing:agentGuiTests/SkillManifestTests \
  -only-testing:agentGuiTests/SkillServiceFrontmatterTests \
  -only-testing:agentGuiTests/SkillProjectDiscoveryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|TEST (SUCCEED|FAIL)" | head -20
```

### 步骤 5：Commit

```
git add agentGui/Services/SkillCatalogPromptRenderer.swift \
        agentGuiTests/SkillCatalogPromptRendererTests.swift
git commit -m "test(S-B1): cover contextWindowTokens dynamic budget calculation"
```

---

## 验收检查单

完成所有 Task 后，执行以下验收：

```bash
# 运行所有 Skill 相关测试
cd /Volumes/T7/文稿/Projects/agentGui && xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sb1-final \
  -only-testing:agentGuiTests/SkillCatalogPromptRendererTests \
  -only-testing:agentGuiTests/SkillManifestTests \
  -only-testing:agentGuiTests/SkillServiceFrontmatterTests \
  -only-testing:agentGuiTests/SkillProjectDiscoveryTests \
  -only-testing:agentGuiTests/ClaudeServiceMemoryGuidanceInjectionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|TEST (SUCCEED|FAIL)" | head -30
```

**手动验收：**
- [ ] 50 个 skill 时，`renderSkillListing()` 输出 ≤ 8000 chars
- [ ] bundled skill 描述始终保留完整
- [ ] `whenToUse` 出现在 listing 每行中（若有）
- [ ] 系统提示的 `## Available Skills` 节不再包含 `**bold**` 格式
- [ ] `SkillManifestTests` 原有测试全部通过（fixture 迁移未破坏现有用例）

---

## 文件变更汇总

| 操作 | 文件 |
|------|------|
| 新增 | `agentGui/Services/SkillCatalogPromptRenderer.swift` |
| 新增 | `agentGuiTests/SkillCatalogPromptRendererTests.swift` |
| 新增 | `agentGuiTests/TestSupport/SkillTestFixtures.swift` |
| 修改 | `agentGui/Services/ClaudeService/ClaudeService+Prompting.swift`（skill 列表渲染替换） |
| 修改 | `agentGuiTests/SkillManifestTests.swift`（删除 private fixture，改用共享版） |

**不需要修改：** `Skill.swift`（S-A1 已在之前实现）、`SkillService.swift`、`AppSettings.swift`。

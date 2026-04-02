# Feature M-01: Memory Semantic Type Annotation System

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 RMS 体系中添加 Claude Code 式的四类型语义分类（user / feedback / project / reference），并将配套的类型指导 prompt 注入 agent system prompt，从而让 agent 在写入记忆时能依据明确的 when_to_save / how_to_use / body_structure 规范做出更高质量的记忆保存决策。

**Architecture:** 新增 `MemorySemanticType` 枚举和无状态的 `MemoryTypeGuidanceComposer`（nonisolated struct），后者生成 `## Types of memory` 与 `## What NOT to save` 两个 Markdown 节并直接注入 `buildSystemPrompt`。`RMSInsight` 增加可选字段 `semanticType`，向后兼容现有 JSON。不涉及 SwiftData / 文件存储迁移。

**Tech Stack:** Swift 6.0+, XCTest, `agentGui` target, `agentGuiTests` target

---

## 参考文件（只读，不修改）

| 文件 | 用途 |
|------|------|
| `/Users/feint/Downloads/claude-code-source-code-main/src/memdir/memoryTypes.ts` | 四类型全文 prompt 权威来源（`TYPES_SECTION_INDIVIDUAL` + `WHAT_NOT_TO_SAVE_SECTION`） |
| `agentGui/Models/RMSInsight.swift` | 当前 insight 模型，需添加 `semanticType` 字段 |
| `agentGui/Services/ClaudeService/ClaudeService+Prompting.swift` | `buildSystemPrompt()` 注入点 |
| `agentGui/Models/MemoryScope.swift` | 理解 scope 作为旁证 |

---

## Task 1: `MemorySemanticType` 枚举

**Files:**
- Create: `agentGui/Models/MemorySemanticType.swift`
- Create: `agentGuiTests/MemorySemanticTypeTests.swift`

### Step 1: 写失败测试

```swift
// agentGuiTests/MemorySemanticTypeTests.swift
import XCTest
@testable import agentGui

final class MemorySemanticTypeTests: XCTestCase {

    func test_allCasesExist() {
        // 确保四个语义类型都存在
        let all: [MemorySemanticType] = [.user, .feedback, .project, .reference]
        XCTAssertEqual(all.count, 4)
    }

    func test_rawValues_matchClaudeCodeSpec() {
        XCTAssertEqual(MemorySemanticType.user.rawValue,      "user")
        XCTAssertEqual(MemorySemanticType.feedback.rawValue,  "feedback")
        XCTAssertEqual(MemorySemanticType.project.rawValue,   "project")
        XCTAssertEqual(MemorySemanticType.reference.rawValue, "reference")
    }

    func test_codable_roundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for type_ in MemorySemanticType.allCases {
            let data = try encoder.encode(type_)
            let decoded = try decoder.decode(MemorySemanticType.self, from: data)
            XCTAssertEqual(decoded, type_)
        }
    }

    func test_init_fromRawValue_returnsNil_forUnknown() {
        XCTAssertNil(MemorySemanticType(rawValue: "unknown"))
        XCTAssertNil(MemorySemanticType(rawValue: ""))
    }
}
```

### Step 2: 运行测试，确认编译失败（类型不存在）

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/MemorySemanticTypeTests \
  -derivedDataPath /tmp/agentGui-m01-task1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
期望：编译错误 `cannot find type 'MemorySemanticType'`

### Step 3: 实现 `MemorySemanticType.swift`

```swift
// agentGui/Models/MemorySemanticType.swift
import Foundation

/// 对齐 Claude Code `memoryTypes.ts` 的四类型语义分类。
///
/// 这四个类型捕捉那些**无法从当前项目状态推导**出来的上下文：
/// 代码模式、架构、git 历史、文件结构等可随时 grep/read 得到的内容
/// 不应保存为记忆。
///
/// 每个 case 的完整 prompt 指导（when_to_save / how_to_use /
/// body_structure / examples）由 `MemoryTypeGuidanceComposer` 生成。
enum MemorySemanticType: String, Codable, Equatable, Sendable, CaseIterable {
    /// 用户身份、偏好、专业背景。始终私有。
    case user

    /// 用户给出的行为纠正或确认。记录失败 AND 成功。
    case feedback

    /// 项目进展、目标、决策、deadline、事故。偏向团队共享。
    case project

    /// 指向外部系统的引用（Linear/Grafana/Slack 等）。
    case reference
}
```

### Step 4: 运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/MemorySemanticTypeTests \
  -derivedDataPath /tmp/agentGui-m01-task1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
期望：`** TEST SUCCEEDED **`

### Step 5: 注册到 Xcode project（如 pbxproj 未自动收录）

在 Xcode 中将两个新文件加入 target，或手动检查 `project.pbxproj` 中是否出现对应路径。

### Step 6: Commit

```bash
git add agentGui/Models/MemorySemanticType.swift \
        agentGuiTests/MemorySemanticTypeTests.swift
git commit -m "feat(memory): add MemorySemanticType enum (user/feedback/project/reference)"
```

---

## Task 2: `MemoryTypeGuidanceComposer`

**Files:**
- Create: `agentGui/Services/Memory/MemoryTypeGuidanceComposer.swift`
- Create: `agentGuiTests/MemoryTypeGuidanceComposerTests.swift`

> **背景**：`MemoryTypeGuidanceComposer` 对齐 Claude Code `buildMemoryLines()` 中的
> `TYPES_SECTION_INDIVIDUAL` 和 `WHAT_NOT_TO_SAVE_SECTION` 内容，生成两个 Markdown 节，
> 后续注入 system prompt。nonisolated struct，无副作用，无 I/O。

### Step 1: 写失败测试

```swift
// agentGuiTests/MemoryTypeGuidanceComposerTests.swift
import XCTest
@testable import agentGui

final class MemoryTypeGuidanceComposerTests: XCTestCase {

    private let composer = MemoryTypeGuidanceComposer()

    // MARK: - typesSection

    func test_typesSection_containsH2Header() {
        let section = composer.typesSection()
        XCTAssertTrue(section.contains("## Types of memory"),
                      "应包含 H2 标题")
    }

    func test_typesSection_containsAllFourTypeNames() {
        let section = composer.typesSection()
        XCTAssertTrue(section.contains("<name>user</name>"),      "缺少 user 类型")
        XCTAssertTrue(section.contains("<name>feedback</name>"),  "缺少 feedback 类型")
        XCTAssertTrue(section.contains("<name>project</name>"),   "缺少 project 类型")
        XCTAssertTrue(section.contains("<name>reference</name>"), "缺少 reference 类型")
    }

    func test_typesSection_containsWhenToSave_forUser() {
        let section = composer.typesSection()
        XCTAssertTrue(section.contains("<when_to_save>"),
                      "应包含 when_to_save 标签")
    }

    func test_typesSection_containsHowToUse_forEachType() {
        let section = composer.typesSection()
        let tagCount = section.components(separatedBy: "<how_to_use>").count - 1
        XCTAssertEqual(tagCount, 4, "四种类型都应有 how_to_use，实际 \(tagCount) 个")
    }

    func test_typesSection_containsExamples() {
        let section = composer.typesSection()
        XCTAssertTrue(section.contains("<examples>"), "应包含 examples 标签")
    }

    func test_typesSection_feedbackContainsBodyStructure() {
        let section = composer.typesSection()
        XCTAssertTrue(section.contains("<body_structure>"),
                      "feedback 和 project 类型应有 body_structure")
    }

    // MARK: - whatNotToSaveSection

    func test_whatNotToSaveSection_containsH2Header() {
        let section = composer.whatNotToSaveSection()
        XCTAssertTrue(section.contains("## What NOT to save in memory"))
    }

    func test_whatNotToSaveSection_mentionsCodePatterns() {
        let section = composer.whatNotToSaveSection()
        XCTAssertTrue(section.contains("Code patterns"),
                      "应明确排除代码模式等可推导内容")
    }

    func test_whatNotToSaveSection_mentionsGitHistory() {
        let section = composer.whatNotToSaveSection()
        XCTAssertTrue(section.contains("Git history") || section.contains("git log"),
                      "应明确排除 git 历史")
    }

    // MARK: - compose（整合输出）

    func test_compose_returnsBothSections() {
        let full = composer.compose()
        XCTAssertTrue(full.contains("## Types of memory"))
        XCTAssertTrue(full.contains("## What NOT to save in memory"))
    }

    func test_compose_typesSection_precedesWhatNotToSave() {
        let full = composer.compose()
        let typesRange    = full.range(of: "## Types of memory")!
        let whatNotRange  = full.range(of: "## What NOT to save in memory")!
        XCTAssertLessThan(typesRange.lowerBound, whatNotRange.lowerBound,
                          "Types 节应在 What NOT to save 节之前")
    }

    func test_compose_isNotEmpty() {
        XCTAssertFalse(composer.compose().isEmpty)
    }
}
```

### Step 2: 运行测试，确认编译失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/MemoryTypeGuidanceComposerTests \
  -derivedDataPath /tmp/agentGui-m01-task2 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
期望：编译错误 `cannot find type 'MemoryTypeGuidanceComposer'`

### Step 3: 实现 `MemoryTypeGuidanceComposer.swift`

> 内容直接对齐 `TYPES_SECTION_INDIVIDUAL` 和 `WHAT_NOT_TO_SAVE_SECTION`，
> 保留 XML 结构标签（`<types>` / `<type>` / `<name>` 等）使 Claude 模型
> 能正确解析类型指导。

```swift
// agentGui/Services/Memory/MemoryTypeGuidanceComposer.swift
import Foundation

/// 生成 memory 类型指导的两个 Markdown 节，供注入 agent system prompt。
///
/// 内容对齐 Claude Code `memoryTypes.ts` 中的
/// `TYPES_SECTION_INDIVIDUAL` 与 `WHAT_NOT_TO_SAVE_SECTION`。
///
/// nonisolated struct，无 I/O，无副作用，可在任意并发上下文调用。
struct MemoryTypeGuidanceComposer: Sendable {

    /// 生成完整的 `## Types of memory` 节。
    func typesSection() -> String {
        """
        ## Types of memory

        There are several discrete types of memory that you can store in your memory system:

        <types>
        <type>
            <name>user</name>
            <description>Contain information about the user's role, goals, responsibilities, and knowledge. Great user memories help you tailor your future behavior to the user's preferences and perspective. Your goal in reading and writing these memories is to build up an understanding of who the user is and how you can be most helpful to them specifically. For example, you should collaborate with a senior software engineer differently than a student who is coding for the very first time. Keep in mind, that the aim here is to be helpful to the user. Avoid writing memories about the user that could be viewed as a negative judgement or that are not relevant to the work you're trying to accomplish together.</description>
            <when_to_save>When you learn any details about the user's role, preferences, responsibilities, or knowledge</when_to_save>
            <how_to_use>When your work should be informed by the user's profile or perspective. For example, if the user is asking you to explain a part of the code, you should answer that question in a way that is tailored to the specific details that they will find most valuable or that helps them build their mental model in relation to domain knowledge they already have.</how_to_use>
            <examples>
            user: I'm a data scientist investigating what logging we have in place
            assistant: [saves user memory: user is a data scientist, currently focused on observability/logging]

            user: I've been writing Go for ten years but this is my first time touching the React side of this repo
            assistant: [saves user memory: deep Go expertise, new to React and this project's frontend — frame frontend explanations in terms of backend analogues]
            </examples>
        </type>
        <type>
            <name>feedback</name>
            <description>Guidance the user has given you about how to approach work — both what to avoid and what to keep doing. These are a very important type of memory to read and write as they allow you to remain coherent and responsive to the way you should approach work in the project. Record from failure AND success: if you only save corrections, you will avoid past mistakes but drift away from approaches the user has already validated, and may grow overly cautious.</description>
            <when_to_save>Any time the user corrects your approach ("no not that", "don't", "stop doing X") OR confirms a non-obvious approach worked ("yes exactly", "perfect, keep doing that", accepting an unusual choice without pushback). Corrections are easy to notice; confirmations are quieter — watch for them. In both cases, save what is applicable to future conversations, especially if surprising or not obvious from the code. Include *why* so you can judge edge cases later.</when_to_save>
            <how_to_use>Let these memories guide your behavior so that the user does not need to offer the same guidance twice.</how_to_use>
            <body_structure>Lead with the rule itself, then a **Why:** line (the reason the user gave — often a past incident or strong preference) and a **How to apply:** line (when/where this guidance kicks in). Knowing *why* lets you judge edge cases instead of blindly following the rule.</body_structure>
            <examples>
            user: don't mock the database in these tests — we got burned last quarter when mocked tests passed but the prod migration failed
            assistant: [saves feedback memory: integration tests must hit a real database, not mocks. Reason: prior incident where mock/prod divergence masked a broken migration]

            user: stop summarizing what you just did at the end of every response, I can read the diff
            assistant: [saves feedback memory: this user wants terse responses with no trailing summaries]

            user: yeah the single bundled PR was the right call here, splitting this one would've just been churn
            assistant: [saves feedback memory: for refactors in this area, user prefers one bundled PR over many small ones. Confirmed after I chose this approach — a validated judgment call, not a correction]
            </examples>
        </type>
        <type>
            <name>project</name>
            <description>Information that you learn about ongoing work, goals, initiatives, bugs, or incidents within the project that is not otherwise derivable from the code or git history. Project memories help you understand the broader context and motivation behind the work the user is doing within this working directory.</description>
            <when_to_save>When you learn who is doing what, why, or by when. These states change relatively quickly so try to keep your understanding of this up to date. Always convert relative dates in user messages to absolute dates when saving (e.g., "Thursday" → "2026-03-05"), so the memory remains interpretable after time passes.</when_to_save>
            <how_to_use>Use these memories to more fully understand the details and nuance behind the user's request and make better informed suggestions.</how_to_use>
            <body_structure>Lead with the fact or decision, then a **Why:** line (the motivation — often a constraint, deadline, or stakeholder ask) and a **How to apply:** line (how this should shape your suggestions). Project memories decay fast, so the why helps future-you judge whether the memory is still load-bearing.</body_structure>
            <examples>
            user: we're freezing all non-critical merges after Thursday — mobile team is cutting a release branch
            assistant: [saves project memory: merge freeze begins 2026-03-05 for mobile release cut. Flag any non-critical PR work scheduled after that date]

            user: the reason we're ripping out the old auth middleware is that legal flagged it for storing session tokens in a way that doesn't meet the new compliance requirements
            assistant: [saves project memory: auth middleware rewrite is driven by legal/compliance requirements around session token storage, not tech-debt cleanup — scope decisions should favor compliance over ergonomics]
            </examples>
        </type>
        <type>
            <name>reference</name>
            <description>Stores pointers to where information can be found in external systems. These memories allow you to remember where to look to find up-to-date information outside of the project directory.</description>
            <when_to_save>When you learn about resources in external systems and their purpose. For example, that bugs are tracked in a specific project in Linear or that feedback can be found in a specific Slack channel.</when_to_save>
            <how_to_use>When the user references an external system or information that may be in an external system.</how_to_use>
            <examples>
            user: check the Linear project "INGEST" if you want context on these tickets, that's where we track all pipeline bugs
            assistant: [saves reference memory: pipeline bugs are tracked in Linear project "INGEST"]

            user: the Grafana board at grafana.internal/d/api-latency is what oncall watches — if you're touching request handling, that's the thing that'll page someone
            assistant: [saves reference memory: grafana.internal/d/api-latency is the oncall latency dashboard — check it when editing request-path code]
            </examples>
        </type>
        </types>
        """
    }

    /// 生成 `## What NOT to save in memory` 节。
    func whatNotToSaveSection() -> String {
        """
        ## What NOT to save in memory

        - Code patterns, conventions, architecture, file paths, or project structure — these can be derived by reading the current project state.
        - Git history, recent changes, or who-changed-what — `git log` / `git blame` are authoritative.
        - Debugging solutions or fix recipes — the fix is in the code; the commit message has the context.
        - Anything already documented in CLAUDE.md files.
        - Ephemeral task details: in-progress work, temporary state, current conversation context.

        These exclusions apply even when the user explicitly asks you to save. If they ask you to save a PR list or activity summary, ask what was *surprising* or *non-obvious* about it — that is the part worth keeping.
        """
    }

    /// 拼接 typesSection + whatNotToSaveSection，生成完整的记忆类型指导块。
    func compose() -> String {
        [typesSection(), whatNotToSaveSection()].joined(separator: "\n\n")
    }
}
```

### Step 4: 运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/MemoryTypeGuidanceComposerTests \
  -derivedDataPath /tmp/agentGui-m01-task2 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
期望：`** TEST SUCCEEDED **`

### Step 5: Commit

```bash
git add agentGui/Services/Memory/MemoryTypeGuidanceComposer.swift \
        agentGuiTests/MemoryTypeGuidanceComposerTests.swift
git commit -m "feat(memory): add MemoryTypeGuidanceComposer with four-type prompt sections"
```

---

## Task 3: 为 `RMSInsight` 添加 `semanticType` 字段

**Files:**
- Modify: `agentGui/Models/RMSInsight.swift`
- Create: `agentGuiTests/RMSInsightSemanticTypeTests.swift`

> 字段设为 `Optional`（`MemorySemanticType?`），default `nil`，保证现有 JSON
> 文件零改动即可反序列化成功（旧记录缺失该字段时 Swift Codable 自动填 nil）。

### Step 1: 写失败测试

```swift
// agentGuiTests/RMSInsightSemanticTypeTests.swift
import XCTest
@testable import agentGui

final class RMSInsightSemanticTypeTests: XCTestCase {

    // 仅测试新增字段，其余 RMSInsight 行为不在此处覆盖

    func test_defaultSemanticType_isNil() {
        let insight = RMSInsight(
            id: "test-1",
            kind: .constraint,
            summary: "Always run tests before merging",
            appliesWhen: "coding",
            changesDecision: "Run tests first",
            evidenceRefs: [],
            confidence: 0.9
        )
        XCTAssertNil(insight.semanticType)
    }

    func test_semanticType_canBeSetToFeedback() {
        var insight = RMSInsight(
            id: "test-2",
            kind: .counterexample,
            summary: "Don't mock DB in integration tests",
            appliesWhen: "testing",
            changesDecision: "Use real DB",
            evidenceRefs: [],
            confidence: 0.85
        )
        insight.semanticType = .feedback
        XCTAssertEqual(insight.semanticType, .feedback)
    }

    func test_codable_roundTrip_withSemanticType() throws {
        var insight = RMSInsight(
            id: "test-3",
            kind: .tactic,
            summary: "Use xcodebuild targeted runs",
            appliesWhen: "xcodebuild",
            changesDecision: "Use focused test",
            evidenceRefs: [],
            confidence: 0.75
        )
        insight.semanticType = .project

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(insight)
        let decoded = try decoder.decode(RMSInsight.self, from: data)
        XCTAssertEqual(decoded.semanticType, .project)
    }

    func test_codable_roundTrip_withoutSemanticType_nilPreserved() throws {
        // 模拟旧 JSON：无 semanticType 字段
        let json = """
        {
            "id": "legacy-id",
            "kind": "constraint",
            "summary": "Some old constraint",
            "appliesWhen": "coding",
            "changesDecision": "Do X instead",
            "evidenceRefs": [],
            "confidence": 0.8
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let insight = try decoder.decode(RMSInsight.self, from: json)
        XCTAssertNil(insight.semanticType,
                     "旧 JSON 缺少 semanticType 字段时应反序列化为 nil")
    }
}
```

### Step 2: 运行测试，确认失败（字段不存在）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/RMSInsightSemanticTypeTests \
  -derivedDataPath /tmp/agentGui-m01-task3 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
期望：编译错误 `value of type 'RMSInsight' has no member 'semanticType'`

### Step 3: 在 `RMSInsight.swift` 添加 `semanticType` 字段

在 `var updatedAt: Date?` 之后（文件末尾的属性声明区）添加：

```swift
    /// 对齐 Claude Code 四类型分类的语义标注。
    ///
    /// 可选字段，`nil` 表示旧数据或尚未分类。
    /// 不影响 `RMSInsightKind` 的已有行为。
    var semanticType: MemorySemanticType?
```

同时在 `init(...)` 参数列表末尾添加：

```swift
        semanticType: MemorySemanticType? = nil,
```

以及 init 体内：

```swift
        self.semanticType = semanticType
```

> **注意**：`RMSInsight` 已实现 `Codable`，Swift 自动处理可选字段的缺失（旧 JSON
> 无此 key 时解码为 nil），无需手写 `CodingKeys` 或自定义 `init(from:)`。

### Step 4: 运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/RMSInsightSemanticTypeTests \
  -derivedDataPath /tmp/agentGui-m01-task3 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
期望：`** TEST SUCCEEDED **`

### Step 5: 确认现有编译不破坏

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-m01-build \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
期望：`** BUILD SUCCEEDED **`

### Step 6: Commit

```bash
git add agentGui/Models/RMSInsight.swift \
        agentGuiTests/RMSInsightSemanticTypeTests.swift
git commit -m "feat(memory): add optional semanticType to RMSInsight (backward-compatible)"
```

---

## Task 4: 将类型指导注入 `buildSystemPrompt`

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Prompting.swift`
- Create: `agentGuiTests/ClaudeServiceMemoryGuidanceInjectionTests.swift`

> 在 `buildSystemPrompt()` 的 `parts` 数组中插入 `MemoryTypeGuidanceComposer().compose()`，
> 位置在现有 Planning Protocol 节之后（末尾）。
> 用 `## Memory System` 作为外层 H2 标题包装，保持 system prompt 分节一致性。

### Step 1: 写失败测试

```swift
// agentGuiTests/ClaudeServiceMemoryGuidanceInjectionTests.swift
import XCTest
@testable import agentGui

/// 验证 buildSystemPrompt 包含记忆类型指导
/// NOTE: 仅测试输出字符串内容，不依赖 SwiftData / 网络
final class ClaudeServiceMemoryGuidanceInjectionTests: XCTestCase {

    // 使用最小化 AppSettings（仅需 init 可执行）
    private let settings = AppSettings()

    func test_buildSystemPrompt_containsMemorySystemHeader() {
        let prompt = ClaudeService.buildSystemPromptForTest(settings: settings)
        XCTAssertTrue(prompt.contains("## Memory System"),
                      "system prompt 应包含 ## Memory System 节")
    }

    func test_buildSystemPrompt_containsTypesOfMemoryHeader() {
        let prompt = ClaudeService.buildSystemPromptForTest(settings: settings)
        XCTAssertTrue(prompt.contains("## Types of memory"),
                      "system prompt 应包含四类型指导节")
    }

    func test_buildSystemPrompt_containsWhatNotToSaveHeader() {
        let prompt = ClaudeService.buildSystemPromptForTest(settings: settings)
        XCTAssertTrue(prompt.contains("## What NOT to save in memory"),
                      "system prompt 应包含 What NOT to save 节")
    }

    func test_buildSystemPrompt_containsUserTypeTag() {
        let prompt = ClaudeService.buildSystemPromptForTest(settings: settings)
        XCTAssertTrue(prompt.contains("<name>user</name>"))
    }

    func test_buildSystemPrompt_containsFeedbackTypeTag() {
        let prompt = ClaudeService.buildSystemPromptForTest(settings: settings)
        XCTAssertTrue(prompt.contains("<name>feedback</name>"))
    }

    func test_buildSystemPrompt_memorySection_appearsAfterPlanningProtocol() {
        let prompt = ClaudeService.buildSystemPromptForTest(settings: settings)
        guard let planningRange = prompt.range(of: "## Planning Protocol"),
              let memoryRange   = prompt.range(of: "## Memory System") else {
            XCTFail("找不到 Planning Protocol 或 Memory System 节")
            return
        }
        XCTAssertGreaterThan(memoryRange.lowerBound, planningRange.lowerBound,
                             "Memory System 节应出现在 Planning Protocol 节之后")
    }
}
```

> **说明**：`ClaudeService.buildSystemPromptForTest(settings:)` 是一个 static 测试辅助方法（下一步添加）。
> `AppSettings()` 的 init 在 `@MainActor` 上；测试中用 `@MainActor` 标记或在 Swift 6 测试中通过 `await MainActor.run` 调用。
>
> **如果 `AppSettings` 不可在测试中简单初始化**：在测试文件中改用
> `buildSystemPrompt(skills: [], workingDirectory: "/tmp", settings: AppSettings())` 直接调用——
> 参考现有测试如 `ContextWindowBudgetTrackerTests` 中不依赖 SwiftData 的写法。

### Step 2: 运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ClaudeServiceMemoryGuidanceInjectionTests \
  -derivedDataPath /tmp/agentGui-m01-task4 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
期望：编译或测试失败（`buildSystemPromptForTest` 不存在，或 prompt 缺少 Memory System）

### Step 3: 在 `ClaudeService+Prompting.swift` 注入记忆指导

在 `buildSystemPrompt()` 函数内，`return parts.joined(separator: "\n\n")` 之前添加：

```swift
        // Memory type guidance（对齐 Claude Code memoryTypes.ts）
        let memoryGuidance = MemoryTypeGuidanceComposer().compose()
        parts.append("## Memory System\n\n\(memoryGuidance)")
```

然后在同文件（`extension ClaudeService`）末尾添加测试辅助方法：

```swift
    /// 测试专用：以最小参数调用 buildSystemPrompt，无需 SwiftData 上下文。
    @MainActor
    static func buildSystemPromptForTest(settings: AppSettings) -> String {
        // 使用一个临时的最小化 ClaudeService 实例
        // buildSystemPrompt 是 instance method，创建一个轻量实例
        // 注意：如果构造 ClaudeService 本身有副作用，改用协议/依赖注入方式暴露
        // 此处仅做输出验证，不发起任何网络请求
        let service = ClaudeService(
            settings: settings,
            modelContext: nil
        )
        return service.buildSystemPrompt(
            skills: [],
            workingDirectory: "/tmp",
            settings: settings
        )
    }
```

> **如果 `ClaudeService.init` 参数不匹配**：查阅 `ClaudeService` 主文件后
> 选取最小合法 init，或将 `buildSystemPrompt` 重构为 static 函数接受依赖注入。
> 核心目标是让测试能调用 `buildSystemPrompt` 而不需要真实的 SwiftData container。
>
> **替代方案**（更健壮）：将 memory guidance 注入提取为顶层 pure function：
> ```swift
> // 在 ClaudeService+Prompting.swift 中
> static func memoryGuidanceSection() -> String {
>     "## Memory System\n\n\(MemoryTypeGuidanceComposer().compose())"
> }
> ```
> 然后在测试中直接验证 `ClaudeService.memoryGuidanceSection()` 的内容，
> 避免构造完整 ClaudeService 实例的复杂度。

### Step 4: 运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ClaudeServiceMemoryGuidanceInjectionTests \
  -derivedDataPath /tmp/agentGui-m01-task4 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
期望：`** TEST SUCCEEDED **`

### Step 5: 运行完整 Task 1-4 测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/MemorySemanticTypeTests \
  -only-testing:agentGuiTests/MemoryTypeGuidanceComposerTests \
  -only-testing:agentGuiTests/RMSInsightSemanticTypeTests \
  -only-testing:agentGuiTests/ClaudeServiceMemoryGuidanceInjectionTests \
  -derivedDataPath /tmp/agentGui-m01-final \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```
期望：4 套测试全部 PASS。

### Step 6: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+Prompting.swift \
        agentGuiTests/ClaudeServiceMemoryGuidanceInjectionTests.swift
git commit -m "feat(memory): inject MemoryTypeGuidanceComposer into buildSystemPrompt"
```

---

## 收尾：完整回归验证

确保已有测试不受影响：

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m01-regression \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|FAILED|PASSED|error:" | tail -30
```

如发现 `FAILED`，根据具体错误修复（不应有，因所有改动均向后兼容）。

---

## 不在本 Feature 范围内

- SwiftData migration（明确排除）
- MEMORY.md 索引文件层（→ M-02）
- 自动 Extract 服务（→ M-03）
- MemoryRecord 的 semanticType（MemoryRecord 与 RMSInsight 是两套体系，本 feature 只改 RMSInsight）
- Team scope 的 `<scope>` 标注（→ M-09）

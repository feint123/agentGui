# S-C1: SkillInvocationTool（inline 模式）实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 新增 `skill_invoke` 内置工具，让模型可以在 agent loop 内通过工具调用主动触发 skill，把 skill 全文注入当前会话并携带 allowedTools / model 元数据，替代纯被动的 `read_skill` 路径。

**Architecture:** 纯 Swift 实现，不依赖新框架。分三层：① `SkillArgumentSubstitution` 纯值类型负责 `$ARGUMENTS` 等变量替换；② `SkillInvocationProcessor` 纯值类型封装 skill 查找、校验、内容加载和元数据组装；③ 在 `ClaudeService+ToolDispatch` 和 `ClaudeService+ToolBuilder` 中连接现有 dispatch 与 tool schema 注册路径。`allowedTools` 在本 feature 范围内以文本元数据形式返回给模型（软约束）；硬约束的运行时工具过滤由后续 S-C4 实现。

**Tech Stack:** Swift 6, SwiftAnthropic, XCTest，现有 `SkillService` / `Skill` / `ClaudeService` 类

---

## 背景与上下文

### 相关源码位置

| 文件 | 角色 |
|-------|------|
| `agentGui/Models/Skill.swift` | Skill 数据模型（已有完整 S-A1 字段） |
| `agentGui/Models/SkillEnums.swift` | SkillExecutionContext / SkillSource / EffortLevel |
| `agentGui/Services/SkillService.swift` | 技能目录扫描、内容读取、缓存 |
| `agentGui/Services/SkillCatalogPromptRenderer.swift` | 技能列表 → system prompt 字段渲染 |
| `agentGui/Services/ClaudeService/ClaudeService+ToolBuilder.swift` | `buildTools()` — 组装传给 API 的 tool schema 列表；`read_skill` 在此注册 |
| `agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift` | `executeTool()` — 按工具名分发执行；`case "read_skill":` 在此处理 |
| `agentGui/Services/ClaudeService/ClaudeService+Prompting.swift` L183 | system prompt 已引用 `skill_invoke` 工具名 |
| `agentGuiTests/TestSupport/SkillTestFixtures.swift` | `Skill.fixture()` — 单元测试公共 fixture |

### Claude Code 对标文件

- `src/tools/SkillTool/SkillTool.ts` — `call()` inline 分支（L617–762）
- `src/tools/SkillTool/prompt.ts` — `getPrompt()` 工具描述模板
- `src/skills/loadSkillsDir.ts` — `substituteArguments()` 变量替换逻辑

### 关键差异说明

Claude Code 的 `skill_invoke` 通过 `newMessages` 机制把 skill prompt 注入为额外的 user message；agentGui 没有此机制。本方案的等价实现：**工具返回 skill 全文作为 `ToolExecutionResult`，模型在 `tool_result` block 中读取后按其指令继续执行**。行为一致；架构符合 agentGui agent loop 惯例。

---

## 任务清单

---

### Task 1: SkillArgumentSubstitution — 参数替换（S-D1 基础）

> **为什么先做这个：** `skill_invoke` 需要把 skill 内容中的 `$ARGUMENTS` / `${ARGUMENTS}` 替换为调用参数。将此逻辑单独提取为可独立测试的值类型。

**Files:**
- Create: `agentGui/Services/SkillArgumentSubstitution.swift`
- Create: `agentGuiTests/SkillArgumentSubstitutionTests.swift`

**注意：** 新 Swift 文件创建后需在 Xcode 中加入目标（agentGui + agentGuiTests）。

---

**Step 1: 写失败测试**

```swift
// agentGuiTests/SkillArgumentSubstitutionTests.swift
import XCTest
@testable import agentGui

final class SkillArgumentSubstitutionTests: XCTestCase {

    private func sub(_ content: String, args: String? = nil,
                     skillDir: String = "/tmp/my-skill",
                     sessionId: String = "test-session") -> String {
        SkillArgumentSubstitution.substitute(
            content: content,
            args: args,
            skillDirectory: URL(fileURLWithPath: skillDir),
            sessionId: sessionId
        )
    }

    // $ARGUMENTS 替换
    func test_arguments_dollarSign() {
        XCTAssertEqual(sub("Review $ARGUMENTS", args: "PR #123"), "Review PR #123")
    }

    func test_arguments_curlyBrace() {
        XCTAssertEqual(sub("Review ${ARGUMENTS}", args: "PR #123"), "Review PR #123")
    }

    func test_arguments_nil_replacedWithEmpty() {
        XCTAssertEqual(sub("Review $ARGUMENTS for issues", args: nil), "Review  for issues")
    }

    func test_arguments_empty_replacedWithEmpty() {
        XCTAssertEqual(sub("Task: $ARGUMENTS.", args: ""), "Task: .")
    }

    // ${CLAUDE_SKILL_DIR} 替换
    func test_skillDir_substituted() {
        let result = sub("cd ${CLAUDE_SKILL_DIR} && bash run.sh", skillDir: "/home/user/.claude/skills/foo")
        XCTAssertEqual(result, "cd /home/user/.claude/skills/foo && bash run.sh")
    }

    // ${CLAUDE_SESSION_ID} 替换
    func test_sessionId_substituted() {
        let result = sub("Session: ${CLAUDE_SESSION_ID}", sessionId: "abc-123")
        XCTAssertEqual(result, "Session: abc-123")
    }

    // 无占位符时内容原样返回
    func test_noPlaceholder_unchanged() {
        let content = "No placeholders here."
        XCTAssertEqual(sub(content, args: "ignored"), content)
    }

    // 多次出现都被替换
    func test_multipleOccurrences() {
        let result = sub("$ARGUMENTS and also $ARGUMENTS", args: "hello")
        XCTAssertEqual(result, "hello and also hello")
    }
}
```

**Step 2: 运行测试确认失败**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SkillArgumentSubstitutionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：`error: cannot find type 'SkillArgumentSubstitution'`

**Step 3: 实现最小代码**

```swift
// agentGui/Services/SkillArgumentSubstitution.swift
import Foundation

/// 对 skill SKILL.md 内容执行变量替换，完成 $ARGUMENTS 和内置变量展开。
///
/// 对应 Claude Code `src/skills/loadSkillsDir.ts` → `substituteArguments()`。
enum SkillArgumentSubstitution {

    /// 将 content 中的所有已知占位符替换为具体值。
    ///
    /// 替换列表：
    /// - `$ARGUMENTS` / `${ARGUMENTS}`  → args（nil 时为空字符串）
    /// - `${CLAUDE_SKILL_DIR}`           → skillDirectory 的绝对路径
    /// - `${CLAUDE_SESSION_ID}`          → sessionId
    nonisolated static func substitute(
        content: String,
        args: String?,
        skillDirectory: URL,
        sessionId: String
    ) -> String {
        let argsValue = args ?? ""
        return content
            .replacingOccurrences(of: "${ARGUMENTS}", with: argsValue)
            .replacingOccurrences(of: "$ARGUMENTS", with: argsValue)
            .replacingOccurrences(of: "${CLAUDE_SKILL_DIR}", with: skillDirectory.path)
            .replacingOccurrences(of: "${CLAUDE_SESSION_ID}", with: sessionId)
    }
}
```

**Step 4: 运行测试确认通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SkillArgumentSubstitutionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

期望：`** TEST SUCCEEDED **`

**Step 5: Commit**

```bash
git add agentGui/Services/SkillArgumentSubstitution.swift \
        agentGuiTests/SkillArgumentSubstitutionTests.swift
git commit -m "feat(skill): add SkillArgumentSubstitution for \$ARGUMENTS and built-in variable substitution (S-D1)"
```

---

### Task 2: SkillInvocationProcessor — 核心调用逻辑

> **做什么：** 封装 `skill_invoke` 工具的业务逻辑：查找 skill → 校验 `disableModelInvocation` → 读取内容 → 变量替换 → 组装结果元数据。与 `ClaudeService` 解耦，独立可测。

**Files:**
- Create: `agentGui/Services/SkillInvocationProcessor.swift`
- Create: `agentGuiTests/SkillInvocationProcessorTests.swift`

---

**Step 1: 写失败测试**

```swift
// agentGuiTests/SkillInvocationProcessorTests.swift
import XCTest
@testable import agentGui

// ─────────────────────────────────────────────
// MARK: - InMemory SkillService stub
// ─────────────────────────────────────────────

/// 轻量的 stub：不读磁盘，直接在内存中返回预设内容。
final class StubSkillContentProvider: SkillContentProviding {
    var skills: [Skill] = []
    var contentByDirectory: [String: String] = [:]

    func availableSkills() -> [Skill] { skills }

    func readSkillContent(name: String) async -> String? {
        guard let skill = skills.first(where: { $0.name == name || $0.directoryName == name }) else {
            return nil
        }
        return contentByDirectory[skill.directoryName]
    }
}

// ─────────────────────────────────────────────
// MARK: - Tests
// ─────────────────────────────────────────────

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
        XCTAssertNil(r.allowedTools.isEmpty ? Optional<[String]>.none : r.allowedTools)
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
}
```

**Step 2: 运行测试确认失败**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SkillInvocationProcessorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：`error: cannot find type 'SkillInvocationProcessor'` 以及 `SkillContentProviding`

**Step 3: 实现 SkillContentProviding 协议与 SkillInvocationProcessor**

```swift
// agentGui/Services/SkillInvocationProcessor.swift
import Foundation

// MARK: - Protocol

/// Skill 内容访问协议，使 SkillInvocationProcessor 可脱离 SkillService 单独测试。
protocol SkillContentProviding: Sendable {
    func availableSkills() -> [Skill]
    func readSkillContent(name: String) async -> String?
}

// MARK: - SkillService conformance

extension SkillService: SkillContentProviding {
    func availableSkills() -> [Skill] { availableSkills }
}

// MARK: - Result types

/// `skill_invoke` 工具的调用结果。
enum SkillInvocationOutcome: Sendable {
    /// 成功：已加载并替换完毕，可直接返回给模型。
    case success(SkillInvocationSuccess)
    /// Skill 不存在。
    case notFound(String)
    /// Skill 设置了 disableModelInvocation = true，禁止模型主动调用。
    case disabled(String)
    /// Skill 存在但内容无法读取（文件缺失或读写权限问题）。
    case unreadable(String)
}

struct SkillInvocationSuccess: Sendable {
    /// Skill 的规范目录名，用于日志和工具结果展示。
    let commandName: String
    /// 经过 $ARGUMENTS 等变量替换后的 skill 全文。
    let content: String
    /// Skill 声明的工具白名单（空表示不限制）。
    let allowedTools: [String]
    /// Skill 声明的模型覆盖（nil 表示继承当前模型）。
    let modelOverride: String?
}

// MARK: - Processor

/// 封装 `skill_invoke` 工具的业务逻辑。纯计算，无副作用（除了 async 内容读取）。
///
/// 对应 Claude Code `SkillTool.ts` → `call()` inline 分支。
struct SkillInvocationProcessor: Sendable {
    private let provider: any SkillContentProviding
    private let sessionId: String

    init(provider: any SkillContentProviding, sessionId: String) {
        self.provider = provider
        self.sessionId = sessionId
    }

    /// 执行 skill 调用的完整流程：查找 → 校验 → 读取内容 → 变量替换 → 组装结果。
    ///
    /// - Parameters:
    ///   - skillName: 用户/模型传入的技能名称（支持前导斜杠，会自动规范化）。
    ///   - args:      调用参数字符串（用于 $ARGUMENTS 替换）。
    func invoke(skillName: String, args: String?) async -> SkillInvocationOutcome {
        // 规范化：移除前导斜杠
        let normalizedName = skillName.hasPrefix("/") ? String(skillName.dropFirst()) : skillName

        // 查找 skill（先按 name 后按 directoryName）
        let skills = provider.availableSkills()
        guard let skill = skills.first(where: { $0.name == normalizedName || $0.directoryName == normalizedName }) else {
            return .notFound(normalizedName)
        }

        // disableModelInvocation 检查
        guard !skill.disableModelInvocation else {
            return .disabled(skill.directoryName)
        }

        // 读取内容
        guard let rawContent = await provider.readSkillContent(name: skill.directoryName) else {
            return .unreadable(skill.directoryName)
        }

        // 变量替换（$ARGUMENTS + 内置变量）
        let processedContent = SkillArgumentSubstitution.substitute(
            content: rawContent,
            args: args,
            skillDirectory: skill.path,
            sessionId: sessionId
        )

        return .success(SkillInvocationSuccess(
            commandName: skill.directoryName,
            content: processedContent,
            allowedTools: skill.allowedTools,
            modelOverride: skill.model
        ))
    }
}
```

**Step 4: 运行测试确认通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SkillInvocationProcessorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Test Suite"
```

期望：`** TEST SUCCEEDED **`，所有 7 个测试通过

**Step 5: Commit**

```bash
git add agentGui/Services/SkillInvocationProcessor.swift \
        agentGuiTests/SkillInvocationProcessorTests.swift
git commit -m "feat(skill): add SkillInvocationProcessor with SkillContentProviding protocol (S-C1)"
```

---

### Task 3: 注册 skill_invoke 工具 Schema

> **做什么：** 在 `ClaudeService+ToolBuilder.swift` 的 `buildTools()` 中，当有启用 skill 时，把 `skill_invoke` tool schema 注册到传给 API 的 tool 列表，使模型可以在 agent loop 中调用它。

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+ToolBuilder.swift:59–75`（`read_skill` 块内）

---

**Step 1: 写失败测试**

新增到 `agentGuiTests/SkillInvocationProcessorTests.swift` 的 `SkillInvocationToolSchemaTests` test class：

```swift
// 追加到 agentGuiTests/SkillInvocationProcessorTests.swift

final class SkillInvocationToolSchemaTests: XCTestCase {

    // skill_invoke schema 在有 enabledSkills 时出现在工具列表中
    func test_buildTools_withEnabledSkills_containsSkillInvoke() {
        // 创建一个最小的 ClaudeService 用于测试 buildTools()
        // 注意：buildTools 是同步方法，不需要完整的 AnthropicService
        let service = ClaudeService()
        let settings = AppSettings.fixture()
        let skill = Skill.fixture()
        let tools = service.buildTools(modelId: "claude-opus-4-5", settings: settings, enabledSkills: [skill])
        let toolNames = tools.compactMap { tool -> String? in
            if case .custom(let name, _, _, _, _) = tool { return name }
            return nil
        }
        XCTAssertTrue(toolNames.contains("skill_invoke"), "Expected skill_invoke in \(toolNames)")
    }

    // 没有 enabledSkills 时，skill_invoke 不出现
    func test_buildTools_withoutEnabledSkills_noSkillInvoke() {
        let service = ClaudeService()
        let settings = AppSettings.fixture()
        let tools = service.buildTools(modelId: "claude-opus-4-5", settings: settings, enabledSkills: [])
        let toolNames = tools.compactMap { tool -> String? in
            if case .custom(let name, _, _, _, _) = tool { return name }
            return nil
        }
        XCTAssertFalse(toolNames.contains("skill_invoke"))
    }
}
```

> **注：** `AppSettings.fixture()` 可能需要补充。若尚无此 fixture，可用 `AppSettings()` 代替，或在测试 setup 前 in-memory 创建一个 SwiftData container。参考 `SkillCatalogPromptRendererTests.swift` 中的 settings 构建方式。

**Step 2: 运行测试确认失败**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SkillInvocationToolSchemaTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：测试失败，`skill_invoke` 不在工具列表中

**Step 3: 在 buildTools 中补充 skill_invoke 注册**

打开 `agentGui/Services/ClaudeService/ClaudeService+ToolBuilder.swift`，找到 `read_skill` 块（约 L59）：

```swift
// 现有代码（约 L59-75）
if !enabledSkills.isEmpty {
    tools.append(makeEphemeralTool(
        name: "read_skill",
        description: "Load the full instructions of a skill by name. Use when the user's request matches a skill's purpose.",
        inputSchema: .init(
            type: .object,
            properties: [
                "name": .init(
                    type: .string,
                    description: "The skill name, e.g. 'brainstorming'"
                )
            ],
            required: ["name"]
        )
    ))
}
```

在 `read_skill` 的 `tools.append(...)` 之后，`}` 收尾括号之前，追加 `skill_invoke` 注册：

```swift
if !enabledSkills.isEmpty {
    tools.append(makeEphemeralTool(
        name: "read_skill",
        description: "Load the full instructions of a skill by name. Use when the user's request matches a skill's purpose.",
        inputSchema: .init(
            type: .object,
            properties: [
                "name": .init(
                    type: .string,
                    description: "The skill name, e.g. 'brainstorming'"
                )
            ],
            required: ["name"]
        )
    ))

    tools.append(makeEphemeralTool(
        name: "skill_invoke",
        description: """
        Execute a skill within the main conversation.

        When users ask you to perform tasks, check if any available skill matches. \
        If a skill's purpose matches the user's request, invoke it BEFORE generating \
        any other response about the task.

        How to invoke:
        - skill: the skill's name (e.g. "commit", "review-pr", "pdf")
        - args: optional arguments string (passed to the skill as $ARGUMENTS)

        Available skills are listed in the system prompt under "## Available Skills". \
        Do NOT invoke a skill that is already running. \
        If skill has already been invoked this turn (you see skill instructions in a \
        prior tool_result), follow those instructions directly instead of calling again.
        """,
        inputSchema: .init(
            type: .object,
            properties: [
                "skill": .init(
                    type: .string,
                    description: "The skill name. E.g., \"commit\", \"review-pr\", or \"pdf\""
                ),
                "args": .init(
                    type: .string,
                    description: "Optional arguments for the skill, passed as $ARGUMENTS"
                )
            ],
            required: ["skill"]
        )
    ))
}
```

**Step 4: 运行测试确认通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SkillInvocationToolSchemaTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

期望：`** TEST SUCCEEDED **`

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService/ClaudeService+ToolBuilder.swift \
        agentGuiTests/SkillInvocationProcessorTests.swift
git commit -m "feat(skill): register skill_invoke tool schema in buildTools alongside read_skill (S-C1)"
```

---

### Task 4: 连接工具分发（ToolDispatch）

> **做什么：** 在 `ClaudeService+ToolDispatch.swift` 的两处 `switch name` 中分别添加 `case "skill_invoke":` 分支，调用 `SkillInvocationProcessor` 并把结果转换为 `ToolExecutionResult`。

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift`（两处 `case "read_skill"` 附近）

---

**Step 1: 写失败测试**

> 注意：`ClaudeService+ToolDispatch.swift` 的 `executeTool` 方法依赖 SwiftData `ModelContext`，在单元测试中直接调用会复杂。本 task 的测试策略是：通过 `SkillInvocationProcessor` 的集成测试 + 通过 `read_skill` 的现有分发模式确认 `skill_invoke` 代码路径可执行。

在 `agentGuiTests/SkillInvocationProcessorTests.swift` 追加：

```swift
/// dispatch 集成测试：验证 SkillInvocationProcessor 与 ToolExecutionResult 的衔接
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
```

**Step 2: 运行测试确认失败**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SkillInvocationDispatchIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：`error: type 'ToolExecutionResult' has no member 'init(fromSkillInvocationOutcome:)'`

**Step 3: 为 ToolExecutionResult 添加 skill 转换 factory**

在 `agentGui/Services/ClaudeService/ClaudeService+ToolExecutionResult.swift` 末尾追加：

```swift
// MARK: - SkillInvocationOutcome conversion

extension ToolExecutionResult {

    /// 将 SkillInvocationOutcome 转换为 API 层的 ToolExecutionResult。
    ///
    /// inline 成功情形：
    /// - 主体：skill 内容（供模型作为执行指令读取）
    /// - 若有 allowedTools：在末尾附加软约束提示
    /// - 若有 modelOverride：在末尾附加模型提示
    ///
    /// 失败情形：返回 isError = true 的可读错误消息。
    init(fromSkillInvocationOutcome outcome: SkillInvocationOutcome) {
        switch outcome {
        case .success(let r):
            var parts: [String] = [r.content]
            if !r.allowedTools.isEmpty {
                parts.append("\n[Skill note: Prefer using only these tools for this skill: \(r.allowedTools.joined(separator: ", "))]")
            }
            if let model = r.modelOverride {
                parts.append("[Skill note: This skill prefers model: \(model)]")
            }
            self = ToolExecutionResult(parts.joined(separator: "\n"))

        case .notFound(let name):
            self = .failure("Error: skill '\(name)' not found. Check available skills in the system prompt.")

        case .disabled(let name):
            self = .failure("Error: skill '\(name)' has model invocation disabled (disable-model-invocation: true).")

        case .unreadable(let name):
            self = .failure("Error: skill '\(name)' content could not be loaded.")
        }
    }
}
```

**Step 4: 在 ToolDispatch 两处 switch 中添加 case**

`ClaudeService+ToolDispatch.swift` 中有**两处** `executeTool` 方法（带 `Session` 参数和带 `sessionId` 参数），均需添加。找到各方法中的 `case "read_skill":` 块，在其**后面**插入：

```swift
case "skill_invoke":
    guard let skillName = input["skill"]?.stringValue else {
        return .missingParameter("skill")
    }
    let skillArgs = input["args"]?.stringValue
    let processor = SkillInvocationProcessor(
        provider: skillService ?? NullSkillContentProvider(),
        sessionId: sessionId
    )
    let outcome = await processor.invoke(skillName: skillName, args: skillArgs)
    return ToolExecutionResult(fromSkillInvocationOutcome: outcome)
```

并在 `SkillInvocationProcessor.swift` 末尾追加空 fallback provider：

```swift
// MARK: - Null Object

/// SkillService 不可用时的 fallback，保证 SkillInvocationProcessor 不需要处理可选类型。
struct NullSkillContentProvider: SkillContentProviding {
    func availableSkills() -> [Skill] { [] }
    func readSkillContent(name: String) async -> String? { nil }
}
```

> `sessionId` 在两处 `executeTool` 中均可直接使用（第二个重载有同名参数；第一个重载通过 `session.sessionId` 获取）。第一个重载（带 Session）中使用 `session?.sessionId ?? ""`。

**Step 5: 运行测试确认通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SkillInvocationDispatchIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

期望：`** TEST SUCCEEDED **`

**Step 6: Commit**

```bash
git add agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift \
        agentGui/Services/ClaudeService/ClaudeService+ToolExecutionResult.swift \
        agentGui/Services/SkillInvocationProcessor.swift \
        agentGuiTests/SkillInvocationProcessorTests.swift
git commit -m "feat(skill): wire skill_invoke dispatch in ToolDispatch + ToolExecutionResult conversion (S-C1)"
```

---

### Task 5: 验证 system prompt 与 skill_invoke 工具名一致

> **做什么：** 核查 `ClaudeService+Prompting.swift` 中 system prompt 的 skill 相关段落，确认引用 `skill_invoke` 的措辞与 Task 3 注册的工具描述一致，无需修改时记录验证结果。

**Files:**
- Read: `agentGui/Services/ClaudeService/ClaudeService+Prompting.swift:179–200`

---

**Step 1: 阅读当前 system prompt skill 段落**

```bash
sed -n '175,205p' agentGui/Services/ClaudeService/ClaudeService+Prompting.swift
```

当前（截至 2026-04-02）已有：
```
Use the `skill_invoke` tool to run a skill, or the `read_skill` tool to inspect its full instructions.
```

**Step 2: 验证 SkillService.swift 公开 availableSkills 属性**

`SkillService` 是 `@Observable @MainActor final class`，`availableSkills` 是存储属性。`SkillContentProviding` 协议要求一个 `availableSkills() -> [Skill]` 函数。名称冲突需处理：把协议方法重命名为避免冲突，或声明 `extension SkillService: SkillContentProviding` 时做桥接。

```bash
grep -n "func availableSkills\|var availableSkills" agentGui/Services/SkillService.swift
```

若输出是 `var availableSkills: [Skill] = []`（存储属性），则在协议 conformance extension 中：

```swift
// 追加到 SkillInvocationProcessor.swift 底部的 extension SkillService 中
extension SkillService: SkillContentProviding {
    func availableSkills() -> [Skill] { self.availableSkills }
}
```

> **冲突规避：** 协议方法名与存储属性名相同时，Swift 会报错（`Property 'availableSkills' with type '[Skill]' cannot satisfy requirement with type '() -> [Skill]'`）。若发生此冲突，将协议方法改为 `func skillsList() -> [Skill]`，同步修改协议及其所有 conformances（stub + NullSkillContentProvider + 实现），并同步更新 SkillInvocationProcessor 中的调用。

**Step 3: Build 验证无编译错误**

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED"
```

期望：`BUILD SUCCEEDED`

**Step 4: Commit（如有调整）**

```bash
git add agentGui/Services/SkillInvocationProcessor.swift
git commit -m "fix(skill): resolve SkillContentProviding conformance for SkillService (S-C1)"
```

---

### Task 6: 全量测试套件验证

> **做什么：** 运行所有 skill 相关单元测试，确认新功能无回归，所有已有 skill 测试仍然通过。

**Files:** 无修改

---

**Step 1: 运行所有 Skill 测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sc1-final \
  -only-testing:agentGuiTests/SkillArgumentSubstitutionTests \
  -only-testing:agentGuiTests/SkillInvocationProcessorTests \
  -only-testing:agentGuiTests/SkillInvocationToolSchemaTests \
  -only-testing:agentGuiTests/SkillInvocationDispatchIntegrationTests \
  -only-testing:agentGuiTests/SkillManifestTests \
  -only-testing:agentGuiTests/SkillServiceFrontmatterTests \
  -only-testing:agentGuiTests/SkillProjectDiscoveryTests \
  -only-testing:agentGuiTests/SkillCatalogPromptRendererTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

期望：`** TEST SUCCEEDED **`，所有 skill 测试通过

**Step 2: 运行 smoke test（可选，确认大范围无回归）**

```bash
# 按需执行，参考 .vscode/tasks.json 中的 "Quality Smoke" 任务
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

**Step 3: Final commit + tag**

```bash
git add -A
git commit -m "feat(skill): S-C1 SkillInvocationTool inline mode complete

- SkillArgumentSubstitution: \$ARGUMENTS / built-in var substitution
- SkillInvocationProcessor: skill lookup, disableModelInvocation guard, content loading
- skill_invoke tool registered in buildTools alongside read_skill
- ToolDispatch: case 'skill_invoke' wired in both executeTool overloads
- ToolExecutionResult: fromSkillInvocationOutcome factory with allowedTools soft-hint
- NullSkillContentProvider: fallback when SkillService unavailable
"
```

---

## 总结：新增/修改文件

| 文件 | 操作 | 任务 |
|------|------|------|
| `agentGui/Services/SkillArgumentSubstitution.swift` | **新增** | T1 |
| `agentGui/Services/SkillInvocationProcessor.swift` | **新增** | T2, T4 |
| `agentGui/Services/ClaudeService/ClaudeService+ToolBuilder.swift` | 修改（追加 skill_invoke 注册） | T3 |
| `agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift` | 修改（两处 case "skill_invoke"） | T4 |
| `agentGui/Services/ClaudeService/ClaudeService+ToolExecutionResult.swift` | 修改（追加 init(fromSkillInvocationOutcome:)） | T4 |
| `agentGuiTests/SkillArgumentSubstitutionTests.swift` | **新增** | T1 |
| `agentGuiTests/SkillInvocationProcessorTests.swift` | **新增** | T2, T3, T4 |

---

## 不在本计划范围内（后续 features）

| Feature | 描述 |
|---------|------|
| S-C2 | Fork 执行模式（`context: fork`，子代理） |
| S-C3 | Skill 权限系统（allowedTools confirm sheet） |
| S-C4 | allowedTools 硬约束（运行时工具过滤）|
| S-C5 | 模型与 effort 等级覆盖（运行时切换模型） |
| S-D2 | 命名参数替换（`arguments: [branch, ticket]` frontmatter） |
| S-F1 | 内置技能注册表 |

---

## 已知注意事项

1. **Xcode 项目文件注册：** 每个新 `.swift` 文件创建后需在 Xcode 中的 agentGui + agentGuiTests Target 中手动 Add Files，否则编译时找不到类型。
2. **SkillService 协议冲突：** Task 5 Step 2 详述了 `availableSkills` 属性名与协议方法名冲突的处理方式，务必先解决再运行构建。
3. **两处 executeTool 都要改：** `ClaudeService+ToolDispatch.swift` 有两个 `executeTool` 重载，均需添加 `case "skill_invoke":`，漏掉一处会导致部分调用路径静默失败（返回 `.unknownTool`）。
4. **软约束 vs 硬约束：** S-C1 的 `allowedTools` 实现是文本提示（软约束）。运行时工具过滤由 S-C4 实现，两者互不阻塞。

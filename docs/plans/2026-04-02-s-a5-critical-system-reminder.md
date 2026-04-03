# S-A5 CriticalSystemReminder 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在子代理每个 API 轮次的 user message 中自动注入 `criticalReminder` 文本，使代理在多轮对话中持续遵守关键约束（如 verifier 代理必须用 VERDICT 结尾且不得写文件）。

**Architecture:** `criticalReminder` 字段已通过 S-A1 在 `AgentDefinitionDocument` → `AgentRuntimeDefinition` → `WorkflowRoleDefinition` 完成解析链路。S-A5 需要在 `AgentLoopRunRequest` 中增加传递通道，并在两个注入点实现实际注入：(1) `runSubagentLoop` 的首轮 task message；(2) `AgentLoopRoundExecutor.applyPhaseOutcome` 的每个后续 tool-result user message。

**Tech Stack:** Swift 6, SwiftAnthropic，无新增依赖。

---

## 参考文件

| 角色 | 文件 |
|------|------|
| Claude Code 参考 | `src/utils/attachments.ts` → `getCriticalSystemReminderAttachment` |
| Claude Code 参考 | `src/tools/AgentTool/built-in/verificationAgent.ts` → `criticalSystemReminder_EXPERIMENTAL` |
| 注入通道（新增字段）| `agentGui/Models/AgentLoopRunRequest.swift` |
| 首轮注入点 | `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift` |
| 后续轮次注入点 | `agentGui/Services/AgentLoopRoundExecutor.swift` |
| verifier 定义更新 | `agentGui/Resources/Agents/verifier.agent.md` |
| 新增测试 | `agentGuiTests/CriticalSystemReminderTests.swift` |

## 前置确认（已由 S-A1 完成，无需重做）

- `AgentDefinitionDocument.criticalReminder: String?` 已声明 ✓
- `AgentDefinitionLoader` 已解析 `critical-reminder` 字段 ✓  
- `AgentRuntimeDefinition.criticalReminder` 已在 `make(from:)` 中传递 ✓
- `WorkflowRoleDefinition.criticalReminder: String?` 已声明 ✓
- `AgentDefinitionLoaderOpenAgentTests` 已覆盖 `critical-reminder` 解析 ✓

---

## Task 1: 向 `AgentLoopRunRequest` 添加 `criticalReminder` 字段

**Files:**
- Modify: `agentGui/Models/AgentLoopRunRequest.swift`

**Step 1: 写失败测试**

在 `agentGuiTests/CriticalSystemReminderTests.swift`（此文件尚不存在，Task 4 创建）先跳过此步，直接实现。

**Step 2: 修改 `AgentLoopRunRequest`**

在 `agentGui/Models/AgentLoopRunRequest.swift` 末尾字段后添加新字段：

```swift
struct AgentLoopRunRequest {
    let service: any AnthropicService
    let modelId: String
    let tools: [MessageParameter.Tool]
    let system: MessageParameter.System?
    let maxRounds: Int
    let toolExecutionContext: ToolContext
    let toolApprovalMode: ToolApprovalMode
    let runSource: String
    let runLabel: String?
    let requestedBudgetSeconds: TimeInterval?
    /// 每轮 user-message 前重新注入的短提醒（nil = 不注入）。由 S-A5 引入。
    let criticalReminder: String?
}
```

> **注意：** Swift 结构体的 memberwise initializer 要求所有属性都要匹配。`criticalReminder` 没有默认值，因此需要为其添加一个带默认值的自定义 `init`，以确保其他 4 个调用点（`ClaudeService+AgenticLoop.swift`、`BackgroundAgentLoopAdapter.swift`）不需要修改。添加以下 `init`：

```swift
init(
    service: any AnthropicService,
    modelId: String,
    tools: [MessageParameter.Tool],
    system: MessageParameter.System?,
    maxRounds: Int,
    toolExecutionContext: ToolContext,
    toolApprovalMode: ToolApprovalMode,
    runSource: String,
    runLabel: String?,
    requestedBudgetSeconds: TimeInterval?,
    criticalReminder: String? = nil
) {
    self.service = service
    self.modelId = modelId
    self.tools = tools
    self.system = system
    self.maxRounds = maxRounds
    self.toolExecutionContext = toolExecutionContext
    self.toolApprovalMode = toolApprovalMode
    self.runSource = runSource
    self.runLabel = runLabel
    self.requestedBudgetSeconds = requestedBudgetSeconds
    self.criticalReminder = criticalReminder
}
```

**Step 3: 编译验证（无需运行测试）**

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tail -5
```

预期输出：`BUILD SUCCEEDED`（其他 4 个调用点因为 `criticalReminder` 有默认值 `nil` 而不受影响）

**Step 4: Commit**

```bash
git add agentGui/Models/AgentLoopRunRequest.swift
git commit -m "feat(s-a5): add criticalReminder field to AgentLoopRunRequest"
```

---

## Task 2: 提取首轮注入辅助函数并在 `runSubagentLoop` 中使用

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift`

**Step 1: 写失败测试**

在 `agentGuiTests/CriticalSystemReminderTests.swift` 提前写下（见 Task 4），暂时跳过以先实现。

**Step 2: 在 `ClaudeService` extension 中添加静态辅助函数**

在 `ClaudeService+Subagent.swift` 中，`applyTrailerToOutput` 方法之后添加：

```swift
// MARK: - S-A5 CriticalReminder first-turn injection

/// 根据 criticalReminder 构建首轮 task 消息文本。
/// - Parameters:
///   - task: 子代理的原始任务描述
///   - criticalReminder: 每轮提醒文本（nil = 不注入）
/// - Returns: 若 reminder 非空，返回 "reminder\n\n task"；否则原样返回 task。
nonisolated static func buildSubagentFirstTurnMessage(
    task: String,
    criticalReminder: String?
) -> String {
    guard let reminder = criticalReminder, !reminder.isEmpty else { return task }
    return "\(reminder)\n\n\(task)"
}
```

**Step 3: 在 `runSubagentLoop` 中使用辅助函数并传递 `criticalReminder` 给 request**

找到 `runSubagentLoop` 中以下代码段：

```swift
var loopMessages: [MessageParameter.Message] = [.init(role: .user, content: .text(task))]
let system = makeEphemeralSystemPrompt(definition.systemPrompt)
let request = AgentLoopRunRequest(
    service: service,
    modelId: resolvedModelId,
    tools: buildSubagentTools(definition: definition, settings: settings),
    system: system,
    maxRounds: definition.maxRounds,
    toolExecutionContext: .subagent,
    toolApprovalMode: .bypassApprovals,
    runSource: "subagent",
    runLabel: definition.name,
    requestedBudgetSeconds: nil
)
```

替换为：

```swift
let firstTurnContent = ClaudeService.buildSubagentFirstTurnMessage(
    task: task,
    criticalReminder: definition.criticalReminder
)
var loopMessages: [MessageParameter.Message] = [.init(role: .user, content: .text(firstTurnContent))]
let system = makeEphemeralSystemPrompt(definition.systemPrompt)
let request = AgentLoopRunRequest(
    service: service,
    modelId: resolvedModelId,
    tools: buildSubagentTools(definition: definition, settings: settings),
    system: system,
    maxRounds: definition.maxRounds,
    toolExecutionContext: .subagent,
    toolApprovalMode: .bypassApprovals,
    runSource: "subagent",
    runLabel: definition.name,
    requestedBudgetSeconds: nil,
    criticalReminder: definition.criticalReminder
)
```

**Step 4: 编译验证**

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tail -5
```

预期输出：`BUILD SUCCEEDED`

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService/ClaudeService+Subagent.swift
git commit -m "feat(s-a5): inject criticalReminder into first-turn task message"
```

---

## Task 3: 在 `AgentLoopRoundExecutor` 的后续轮次注入 `criticalReminder`

**Files:**
- Modify: `agentGui/Services/AgentLoopRoundExecutor.swift`

**背景:**

在子代理执行第 2 轮及以后，用户消息由 `applyPhaseOutcome` 构建，格式为 `.list(toolResultObjects)`。`criticalReminder` 需要作为一个 `.text(reminder)` ContentObject 追加到 `toolResultObjects` 末尾，与 Claude Code `attachments.ts` 的 `getCriticalSystemReminderAttachment` 行为对等。

**Step 1: 找到注入点**

在 `AgentLoopRoundExecutor.swift` 中，找到 `applyPhaseOutcome` 函数内以下代码（约第 514–516 行）：

```swift
        messages.append(.init(role: .assistant, content: .list(assistantObjects)))
        messages.append(.init(role: .user, content: .list(toolResultObjects)))
        await recordEpistemicInputEnvelope(
```

**Step 2: 插入注入逻辑**

在两行 `messages.append` 之间插入 reminder 注入：

```swift
        messages.append(.init(role: .assistant, content: .list(assistantObjects)))
        if let reminder = request.criticalReminder, !reminder.isEmpty {
            toolResultObjects.append(.text(reminder))
        }
        messages.append(.init(role: .user, content: .list(toolResultObjects)))
        await recordEpistemicInputEnvelope(
```

> **说明：** 注入发生在 `assistantObjects`（包含 `tool_use` 块）追加之后、`toolResultObjects`（包含 `tool_result` 块）追加之前。Reminder 作为 `.text` 在 `toolResultObjects` 末尾，与 Claude Code 中 `critical_system_reminder` attachment 位置语义对齐。若 `toolResultObjects` 为空（理论上不会发生），注入不影响行为。

**Step 3: 编译验证**

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tail -5
```

预期输出：`BUILD SUCCEEDED`

**Step 4: Commit**

```bash
git add agentGui/Services/AgentLoopRoundExecutor.swift
git commit -m "feat(s-a5): inject criticalReminder into subsequent tool-result user messages"
```

---

## Task 4: 编写单元测试

**Files:**
- Create: `agentGuiTests/CriticalSystemReminderTests.swift`

**测试覆盖范围:**

| 测试用例 | 验证目标 |
|----------|---------|
| `test_nilReminder_returnsTaskUnchanged` | nil reminder → 首轮消息等于原始 task |
| `test_emptyReminder_returnsTaskUnchanged` | 空字符串 reminder → 不注入 |
| `test_reminder_isPrependedToTask` | 非空 reminder → "reminder\n\ntask" |
| `test_reminder_separatorIsDoubleNewline` | 分隔符必须是 `\n\n` |
| `test_agentLoopRunRequest_defaultCriticalReminderIsNil` | `AgentLoopRunRequest` 的 `criticalReminder` 默认值为 nil |
| `test_agentLoopRunRequest_storesCriticalReminder` | 非 nil reminder 正确存储于 request |
| `test_verifierAgentDefinition_hasExpectedReminder` | verifier.agent.md 加载后 `criticalReminder` 与预期文本匹配 |

**Step 1: 创建测试文件**

```swift
// agentGuiTests/CriticalSystemReminderTests.swift
import XCTest
@testable import agentGui

// MARK: - CriticalSystemReminderTests
//
// 验证 S-A5 的核心行为：
// 1. buildSubagentFirstTurnMessage 根据 criticalReminder 拼接首轮消息
// 2. AgentLoopRunRequest 正确携带 criticalReminder
// 3. verifier 代理定义包含预期的 criticalReminder 文本

final class CriticalSystemReminderTests: XCTestCase {

    // MARK: - buildSubagentFirstTurnMessage

    func test_nilReminder_returnsTaskUnchanged() {
        let result = ClaudeService.buildSubagentFirstTurnMessage(
            task: "Verify the build passes.",
            criticalReminder: nil
        )
        XCTAssertEqual(result, "Verify the build passes.")
    }

    func test_emptyReminder_returnsTaskUnchanged() {
        let result = ClaudeService.buildSubagentFirstTurnMessage(
            task: "Verify the build passes.",
            criticalReminder: ""
        )
        XCTAssertEqual(result, "Verify the build passes.",
            "空字符串 reminder 不应注入")
    }

    func test_reminder_isPrependedToTask() {
        let reminder = "CRITICAL: READ-ONLY. Do not edit files."
        let task = "Check if feature X is implemented."
        let result = ClaudeService.buildSubagentFirstTurnMessage(
            task: task,
            criticalReminder: reminder
        )
        XCTAssertTrue(result.hasPrefix(reminder),
            "reminder 必须出现在消息开头")
        XCTAssertTrue(result.hasSuffix(task),
            "task 必须保留在消息末尾")
    }

    func test_reminder_separatorIsDoubleNewline() {
        let reminder = "CRITICAL: Stay read-only."
        let task = "Explore the src/ directory."
        let result = ClaudeService.buildSubagentFirstTurnMessage(
            task: task,
            criticalReminder: reminder
        )
        let expected = "CRITICAL: Stay read-only.\n\nExplore the src/ directory."
        XCTAssertEqual(result, expected,
            "reminder 与 task 之间分隔符必须是 \\n\\n")
    }

    // MARK: - AgentLoopRunRequest critical reminder field

    func test_agentLoopRunRequest_defaultCriticalReminderIsNil() {
        // 使用最简化的 stub 验证 criticalReminder 默认值
        let request = AgentLoopRunRequest(
            service: MockAnthropicService(),
            modelId: "claude-sonnet-4-6",
            tools: [],
            system: nil,
            maxRounds: 10,
            toolExecutionContext: .subagent,
            toolApprovalMode: .bypassApprovals,
            runSource: "test",
            runLabel: nil,
            requestedBudgetSeconds: nil
            // criticalReminder 不传，应默认为 nil
        )
        XCTAssertNil(request.criticalReminder,
            "criticalReminder 在不传参时应为 nil")
    }

    func test_agentLoopRunRequest_storesCriticalReminder() {
        let reminder = "CRITICAL: This is VERIFICATION-ONLY."
        let request = AgentLoopRunRequest(
            service: MockAnthropicService(),
            modelId: "claude-sonnet-4-6",
            tools: [],
            system: nil,
            maxRounds: 10,
            toolExecutionContext: .subagent,
            toolApprovalMode: .bypassApprovals,
            runSource: "test",
            runLabel: "verifier",
            requestedBudgetSeconds: nil,
            criticalReminder: reminder
        )
        XCTAssertEqual(request.criticalReminder, reminder)
    }

    // MARK: - verifier agent definition

    func test_verifierAgentDefinition_hasExpectedReminder() throws {
        let loader = AgentDefinitionLoader()
        guard let url = Bundle(for: type(of: self)).url(
            forResource: "verifier",
            withExtension: "agent.md",
            subdirectory: "Agents"
        ) else {
            // 在 test bundle 中资源路径可能不同，尝试 source 路径 fallback
            try XCTSkipIf(true, "verifier.agent.md 在 test bundle 中不可达，跳过")
            return
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        let doc = try loader.parseDocument(named: "verifier.agent.md", raw: raw)

        XCTAssertNotNil(doc.criticalReminder,
            "verifier 代理必须有 criticalReminder")
        let reminder = doc.criticalReminder!
        XCTAssertTrue(
            reminder.contains("VERIFICATION") || reminder.contains("CRITICAL"),
            "verifier 的 criticalReminder 应包含 VERIFICATION 或 CRITICAL 关键词"
        )
        XCTAssertTrue(
            reminder.contains("VERDICT"),
            "verifier 的 criticalReminder 应包含 VERDICT 关键词（要求 agent 以 verdict 结尾）"
        )
    }

    func test_verifierWorkflowRole_hasCriticalReminder() throws {
        let role = WorkflowRoleDefinition.verifier
        XCTAssertNotNil(role.criticalReminder,
            "WorkflowRoleDefinition.verifier 应携带 criticalReminder")
    }
}
```

> **关于 `MockAnthropicService`：** 检查项目中是否已有 mock。如果没有，在同一文件末尾添加最小化 mock：

```swift
// MARK: - Test Doubles

private final class MockAnthropicService: AnthropicService {
    func createMessage(
        _ parameter: MessageParameter,
        stream: Bool
    ) async throws -> MessageResponse {
        throw NSError(domain: "mock", code: 0)
    }
    func streamMessage(
        _ parameter: MessageParameter
    ) async throws -> AsyncThrowingStream<MessageStreamResponse, Error> {
        throw NSError(domain: "mock", code: 0)
    }
}
```

> **注意：** 若项目中已有 `MockAnthropicService` 或同等 stub，直接引用，不重复定义。

**Step 2: 运行测试（期望部分失败）**

在 Task 4 执行时，`test_verifierAgentDefinition_hasExpectedReminder` 和 `test_verifierWorkflowRole_hasCriticalReminder` 会失败，因为 `verifier.agent.md` 尚未添加 `critical-reminder` 字段（Task 5 完成后才会通过）。其余测试应通过。

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sa5-derived \
  -only-testing:agentGuiTests/CriticalSystemReminderTests \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "Test (Case|Suite|FAIL|PASS|error)"
```

预期：除 verifier 相关的 2 个测试外，其余应 PASS。

**Step 3: 将测试文件加入 Xcode 工程**

> **重要：** 新建的 Swift 测试文件需要手动加入 `agentGuiTests` target 的编译成员列表，否则不会参与编译和执行。
>
> 在 Xcode 中：打开 `agentGui.xcodeproj` → 选中 `agentGuiTests` group → `File > Add Files to "agentGui"` → 选择 `CriticalSystemReminderTests.swift` → 确认 Target Membership 勾选 `agentGuiTests`。
>
> 或者通过手动编辑 `agentGui.xcodeproj/project.pbxproj` 添加（参考其他测试文件的 UUID 模式）。

**Step 4: Commit**

```bash
git add agentGuiTests/CriticalSystemReminderTests.swift
git commit -m "test(s-a5): add CriticalSystemReminderTests"
```

---

## Task 5: 更新 `verifier.agent.md` 添加 `critical-reminder` 字段

**Files:**
- Modify: `agentGui/Resources/Agents/verifier.agent.md`

**背景:** 根据 Claude Code `verificationAgent.ts` 的原始文本，verifier 代理的 criticalReminder 为：

> "CRITICAL: This is a VERIFICATION-ONLY task. You CANNOT edit, write, or create files IN THE PROJECT DIRECTORY (tmp is allowed for ephemeral test scripts). You MUST end with VERDICT: PASS, VERDICT: FAIL, or VERDICT: PARTIAL."

**Step 1: 写失败测试**（已在 Task 4 写好）

**Step 2: 修改 `verifier.agent.md`**

在 frontmatter 区域，`output-contract: verification_report` 行之后添加 `critical-reminder` 字段：

```yaml
---
name: verifier
display-name: 验证者
description: 审阅执行结果与证据，排序未决 claim、指出缺失证据，并建议下一步验证 探针。
argument-hint: Describe the completion claims, the evidence observed so far, and which open questions still matter most.
tools: [read_only_editor, web, shell]
max-turns: 50
user-invocable: false
subagent-invocable: true
output-contract: verification_report
critical-reminder: "CRITICAL: This is VERIFICATION-ONLY. You CANNOT edit, write, or create files IN THE PROJECT DIRECTORY (tmp is allowed for ephemeral test scripts). You MUST end with VERDICT: PASS, VERDICT: FAIL, or VERDICT: PARTIAL."
---
```

**Step 3: 运行测试验证通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sa5-derived \
  -only-testing:agentGuiTests/CriticalSystemReminderTests \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "Test (Case|Suite|FAIL|PASS|error)"
```

预期：全部 PASS（包括 `test_verifierAgentDefinition_hasExpectedReminder` 和 `test_verifierWorkflowRole_hasCriticalReminder`）

**Step 4: 运行已有 S-A1 相关测试，确认回归无误**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sa5-derived \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  -only-testing:agentGuiTests/OneShotSubagentTrailerTests \
  -only-testing:agentGuiTests/SubagentModelResolverTests \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "Test (Case|Suite|FAIL|PASS|error)"
```

预期：全部 PASS

**Step 5: Commit**

```bash
git add agentGui/Resources/Agents/verifier.agent.md
git commit -m "feat(s-a5): add critical-reminder to verifier agent definition"
```

---

## Task 6: 全量回归测试与 PR 准备

**Step 1: 运行所有 S-A 相关测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sa5-final \
  -only-testing:agentGuiTests/CriticalSystemReminderTests \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  -only-testing:agentGuiTests/OneShotSubagentTrailerTests \
  -only-testing:agentGuiTests/SubagentModelResolverTests \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "Test (Suite|FAIL|PASS|error|executed)"
```

预期：全部 PASS，0 failures。

**Step 2: Final commit message**

```bash
git log --oneline -6
```

应看到：
```
feat(s-a5): add critical-reminder to verifier agent definition
test(s-a5): add CriticalSystemReminderTests
feat(s-a5): inject criticalReminder into subsequent tool-result user messages
feat(s-a5): inject criticalReminder into first-turn task message
feat(s-a5): add criticalReminder field to AgentLoopRunRequest
```

---

## Diff 汇总

| 文件 | 变更类型 | 改动摘要 |
|------|---------|---------|
| `agentGui/Models/AgentLoopRunRequest.swift` | 修改 | 新增 `criticalReminder: String?` 字段 + 带默认值的 init |
| `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift` | 修改 | `buildSubagentFirstTurnMessage` 静态辅助函数；`runSubagentLoop` 使用辅助函数处理首轮消息并传递 `criticalReminder` 给 request |
| `agentGui/Services/AgentLoopRoundExecutor.swift` | 修改 | `applyPhaseOutcome` 内在 `.list(toolResultObjects)` append 前检查 `request.criticalReminder` 并追加 `.text(reminder)` |
| `agentGui/Resources/Agents/verifier.agent.md` | 修改 | frontmatter 新增 `critical-reminder:` 字段 |
| `agentGuiTests/CriticalSystemReminderTests.swift` | 新建 | 7 个测试用例覆盖辅助函数、request 字段、verifier 定义 |

**总变更规模：** ~60 行（不含测试文件约 95 行）

---

## 陷阱与注意事项

1. **`MockAnthropicService` 重复定义：** 先搜索 `agentGuiTests/` 中是否已有相同协议的 mock 实现，避免 "redeclaration" 编译错误。若有，直接使用已有类型名。

2. **verifier.agent.md 的 YAML 引号：** `critical-reminder` 的值包含冒号（`VERDICT: PASS`），YAML 解析器可能把它当成 key-value 对。本项目使用自定义 frontmatter 解析器（`AgentDefinitionLoader.parseFrontmatter`），采用 `key: value`（行首 key）模式，值中的冒号不需要引号，但若解析器遇到歧义，用双引号包裹整个字符串（参见 Task 5 示例）。验证方法：运行 Task 5 Step 3 的 verifier 加载测试。

3. **TestBundle 资源路径：** `test_verifierAgentDefinition_hasExpectedReminder` 使用了 `Bundle(for: type(of: self))` 找 `.agent.md` 文件。如果测试 bundle 没有 copy resource phase，该测试会跳过（`XCTSkipIf`）而不是失败，属于已知限制。`test_verifierWorkflowRole_hasCriticalReminder` 通过 `AgentCatalog.shared` 访问，更可靠。

4. **注入顺序：** `toolResultObjects` 末尾追加 `.text(reminder)` 而非插入首位。这与 Claude Code `getAttachments` 中 `critical_system_reminder` 在 attachment 列表末尾的位置一致。

5. **`@MainActor` 限制：** `AgentLoopRoundExecutor` 是 `@MainActor struct`，注入逻辑是同步操作，直接修改局部变量 `toolResultObjects`，不需要 `await`，无并发问题。

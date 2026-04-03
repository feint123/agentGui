# S-F2 ForkMessageBuilder 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现 S-F2 `ForkMessageBuilder`，让 `run_subagent` 在省略 `agent_name` 时进入 implicit fork 路径：子代理继承父代理完整上下文，生成 byte-identical 前缀消息以最大化 prompt cache 命中，并通过 `isInForkChild` 防止递归 fork。

**Architecture:** 在现有 S-F1（`ForkSubagentDefinition` + `isInForkChild`）与 S-C2（`SubagentBackgroundExecutor`）基础上，新增 `ForkMessageBuilder` 负责构造 fork child 消息；在 `AgentLoopRoundExecutor` 提供父轮次 assistant 消息快照给工具执行层；在 `run_subagent` 解析层将 `agent_name` 改为可选并增加 implicit fork 分支；fork 子代理统一走后台执行（与 Claude Code 交互模型一致），并为 S-F3 并发批次调度提供 `isForkSubagent` 标记输入。

**Tech Stack:** Swift 6, SwiftAnthropic (`MessageParameter.Message`), XCTest

**Dependencies:** S-F1（已完成）, S-C2（已完成）, F-C1（批次规划器已存在）

**参考源码:**
- `/Users/feint/Downloads/claude-code-source-code-main/src/tools/AgentTool/forkSubagent.ts`
- `/Users/feint/Downloads/claude-code-source-code-main/src/constants/xml.ts`

---

## 背景与对齐策略

### 与 Claude Code 对标的关键行为

1. 省略 `subagent_type` 时触发 fork（agentGui 对应：省略 `agent_name`）。
2. `buildForkedMessages()` 产物必须满足：
   - `[..., assistant(all_tool_use blocks), user(tool_result placeholders + directive)]`
   - 所有 fork child 的 placeholder 文本完全一致：`Fork started — processing in background`
   - child 间仅 directive 文本不同，确保 API request prefix 最大化共享。
3. `buildChildMessage()` 注入 `<fork-boilerplate>` 标签和硬性规则。
4. `isInForkChild()` 命中时禁止再次 fork。

### agentGui 当前缺口

1. `run_subagent` schema 仍要求 `agent_name`（`ToolRegistry.runSubagentDefinition`）。
2. `ClaudeService+Subagent.executeRunSubagentTool` 缺少 implicit fork 路径，且直接报 `missing 'agent_name' parameter`。
3. 运行路径没有把「父回合 assistant 完整消息 + 所有 tool_use」传入 subagent 启动逻辑。
4. 尚无 `ForkMessageBuilder.swift` 和对应测试。

---

## 文件变更清单

### 新建

- `agentGui/Services/SubagentGovernance/ForkMessageBuilder.swift`
- `agentGuiTests/ForkMessageBuilderTests.swift`

### 修改

- `agentGui/Services/SubagentGovernance/ForkSubagentDefinition.swift`
- `agentGui/Services/ToolRegistry.swift`
- `agentGui/Services/AgentLoopToolExecutionCoordinator.swift`
- `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`
- `agentGui/Services/AgentLoopRoundExecutor.swift`
- `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift`
- `agentGui/Services/ClaudeService/ClaudeService+ToolCallRecord.swift`
- `agentGui/Services/SubagentGovernance/SubagentProgressTracker.swift`
- `agentGuiTests/SubagentCoordinatorIntegrationTests.swift`

---

## 设计决策

### 决策 1: `agent_name` 改为可选，省略即 implicit fork

- 保持向后兼容：现有 `explore/worker/verifier` 调用不变。
- 当 `agent_name` 缺失或空字符串时：
  - 若 `isInForkChild(messages)` 为 `true`，拒绝执行并返回明确错误（防递归）。
  - 否则按 `ForkSubagentDefinition` 走 fork 路径。

### 决策 2: Fork child 统一后台执行

- 与 Claude Code 对齐，fork 默认后台运行。
- 即使输入未显式设置 `run_in_background`，fork 路径内部强制后台。
- 返回值仍使用 S-C2 的 `{"status":"async_launched"...}` 占位结果。

### 决策 3: 父 assistant 消息在 `AgentLoopRoundExecutor` 组装

`buildForkedMessages` 需要父轮次完整 assistant 内容。该信息在 `RoundOutcome` 最完整，因此在 `AgentLoopRoundExecutor` 生成并通过协调器传递。

建议新增中间结构：

```swift
struct ForkParentContext: Sendable {
    let parentHistory: [MessageParameter.Message]
    let assistantMessage: MessageParameter.Message
}
```

`assistantMessage` 组装规则：
- 包含 `outcome.assistantObjects`
- 若 `outcome.currentRoundText` 非空，追加 `.text`
- 追加本轮 `pendingTools` 的 `.toolUse`（完整保留所有 tool_use）

> 注意：这一步的目标不是改变主线程消息写回行为，而是为 fork builder 生成对齐 Claude Code 的“完整 assistant 块”。

### 决策 4: 新增 `FORK_DIRECTIVE_PREFIX` 常量

在 `ForkSubagentDefinition.swift` 增加：

```swift
let FORK_DIRECTIVE_PREFIX = "Your directive: "
```

与 Claude Code `src/constants/xml.ts` 对齐，后续 UI 渲染器可依此折叠 boilerplate。

---

## Task 1: 新建 `ForkMessageBuilderTests.swift`（先写失败测试）

**Files:**
- Create: `agentGuiTests/ForkMessageBuilderTests.swift`

### Step 1.1 编写测试用例

```swift
import XCTest
import SwiftAnthropic
@testable import agentGui

final class ForkMessageBuilderTests: XCTestCase {

    func test_buildForkedMessages_withToolUses_returnsAssistantAndUserMessages() {
        let assistant = MessageParameter.Message(
            role: .assistant,
            content: .list([
                .text("I will delegate."),
                .toolUse("tu-1", "run_subagent", ["task": .string("A")]),
                .toolUse("tu-2", "run_subagent", ["task": .string("B")])
            ])
        )

        let result = ForkMessageBuilder().buildForkedMessages(
            directive: "Analyze auth flow",
            parentHistory: [],
            assistantMessage: assistant
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].role, .assistant)
        XCTAssertEqual(result[1].role, .user)
    }

    func test_buildForkedMessages_placeholderIsIdenticalForAllToolResults() {
        let assistant = MessageParameter.Message(
            role: .assistant,
            content: .list([
                .toolUse("tu-1", "run_subagent", ["task": .string("A")]),
                .toolUse("tu-2", "run_subagent", ["task": .string("B")])
            ])
        )

        let result = ForkMessageBuilder().buildForkedMessages(
            directive: "Find callsites",
            parentHistory: [],
            assistantMessage: assistant
        )

        guard case .list(let userBlocks) = result[1].content else {
            return XCTFail("expected user .list")
        }

        let placeholders = userBlocks.compactMap { block -> String? in
            guard case .toolResult(_, let inner) = block else { return nil }
            guard case .text(let text)? = inner.first else { return nil }
            return text
        }

        XCTAssertEqual(placeholders.count, 2)
        XCTAssertTrue(placeholders.allSatisfy { $0 == FORK_PLACEHOLDER_RESULT })
    }

    func test_buildForkedMessages_whenNoToolUse_fallsBackToSingleUserMessage() {
        let assistant = MessageParameter.Message(
            role: .assistant,
            content: .list([.text("no tool calls")])
        )

        let result = ForkMessageBuilder().buildForkedMessages(
            directive: "Summarize architecture",
            parentHistory: [],
            assistantMessage: assistant
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].role, .user)
    }

    func test_buildChildMessage_containsBoilerplateTagAndDirectivePrefix() {
        let text = ForkMessageBuilder.buildChildMessage(directive: "Trace regression")
        XCTAssertTrue(text.contains("<\(FORK_BOILERPLATE_TAG)>"))
        XCTAssertTrue(text.contains(FORK_DIRECTIVE_PREFIX))
        XCTAssertTrue(text.contains("STOP. READ THIS FIRST."))
    }

    func test_buildForkedMessages_keepsParentHistoryPrefix() {
        let history: [MessageParameter.Message] = [
            .init(role: .user, content: .text("parent user")),
            .init(role: .assistant, content: .text("parent assistant"))
        ]
        let assistant = MessageParameter.Message(
            role: .assistant,
            content: .list([.toolUse("tu-1", "run_subagent", ["task": .string("A")])])
        )

        let result = ForkMessageBuilder().buildForkedMessages(
            directive: "Do X",
            parentHistory: history,
            assistantMessage: assistant
        )

        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0].role, .user)
        XCTAssertEqual(result[1].role, .assistant)
        XCTAssertEqual(result[2].role, .assistant)
        XCTAssertEqual(result[3].role, .user)
    }
}
```

### Step 1.2 运行测试（预期失败）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf2-task1 \
  -only-testing:agentGuiTests/ForkMessageBuilderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```

预期：编译失败（`ForkMessageBuilder` 未定义）。

---

## Task 2: 实现 `ForkMessageBuilder.swift`

**Files:**
- Create: `agentGui/Services/SubagentGovernance/ForkMessageBuilder.swift`
- Modify: `agentGui/Services/SubagentGovernance/ForkSubagentDefinition.swift`（新增 `FORK_DIRECTIVE_PREFIX`）

### Step 2.1 实现结构与 API

```swift
import Foundation
import SwiftAnthropic

struct ForkMessageBuilder {

    func buildForkedMessages(
        directive: String,
        parentHistory: [MessageParameter.Message],
        assistantMessage: MessageParameter.Message
    ) -> [MessageParameter.Message] { ... }

    static func buildChildMessage(directive: String) -> String { ... }
}
```

### Step 2.2 关键实现要求

1. 从 `assistantMessage.content` 中提取全部 `.toolUse` blocks。
2. 若无 tool_use：返回 `[.init(role: .user, content: .text(buildChildMessage(...)))]`。
3. 有 tool_use：
   - 构造一个 user `.list`：
     - 每个 `tool_use_id` 对应 `.toolResult(id, [.text(FORK_PLACEHOLDER_RESULT)])`
     - 末尾追加 `.text(buildChildMessage(directive:))`
   - 返回：`parentHistory + [assistantMessage, userMessage]`
4. `buildChildMessage` 文本应包含：
   - `<fork-boilerplate>...</fork-boilerplate>`
   - `STOP. READ THIS FIRST.`
   - 必须以 `FORK_DIRECTIVE_PREFIX + directive` 作为尾段。

### Step 2.3 运行测试（预期通过）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf2-task2 \
  -only-testing:agentGuiTests/ForkMessageBuilderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```

---

## Task 3: `run_subagent` schema 与路由接入 implicit fork

**Files:**
- Modify: `agentGui/Services/ToolRegistry.swift`
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift`
- Modify: `agentGui/Services/ClaudeService/ClaudeService+ToolCallRecord.swift`
- Modify: `agentGui/Services/SubagentGovernance/SubagentProgressTracker.swift`

### Step 3.1 Schema 改造

- `ToolRegistry.runSubagentDefinition()`:
  - `required` 从 `["agent_name", "task"]` 改为 `["task"]`。
  - `agent_name` description 增加：省略时触发 implicit fork。

### Step 3.2 子代理入口改造

在 `ClaudeService+Subagent.executeRunSubagentTool` 中新增决策：

1. 读取 `agent_name`（允许缺失）。
2. 若缺失：进入 fork 分支，不再报错 `missing 'agent_name' parameter`。
3. 若存在：沿用原有 named subagent 路径。

建议新增函数：

```swift
func resolveSubagentDefinition(
    agentName: String?,
    parentMessages: [MessageParameter.Message]
) throws -> ResolvedSubagentMode
```

其中：

```swift
enum ResolvedSubagentMode {
    case named(WorkflowRoleDefinition)
    case implicitFork
}
```

### Step 3.3 ToolCall 与进度文案兜底

- `ClaudeService+ToolCallRecord.swift`：`run_subagent` 在 `agent_name` 为空时，title 使用 `子代理: fork`。
- `SubagentProgressTracker`：`run_subagent` 活动描述从空名兜底为 `fork`，避免 UI 出现空字符串。

---

## Task 4: 传递父上下文并调用 ForkMessageBuilder

**Files:**
- Modify: `agentGui/Services/AgentLoopRoundExecutor.swift`
- Modify: `agentGui/Services/AgentLoopToolExecutionCoordinator.swift`
- Modify: `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift`

### Step 4.1 扩展协调器依赖签名

将 `launchSubagent` 闭包签名扩展一个可选 fork 上下文参数：

```swift
let launchSubagent: (
  MessageResponse.Content.Input,
  ToolCall,
  (String) -> WorkflowRoleDefinition?,
  SubagentBackgroundExecutor,
  ModelContext?,
  ForkParentContext?
) async -> SubagentLaunchResult
```

### Step 4.2 在 `AgentLoopRoundExecutor` 组装 `ForkParentContext`

在 `executeSerialTool` 与并发分支中，为 `run_subagent` 构造：

- `parentHistory = messages`
- `assistantMessage = MessageParameter.Message(role: .assistant, content: .list(...))`

其中 `.list(...)` 必须包含本轮全部 `tool_use`（而非仅当前 pending tool）。

### Step 4.3 在 Builder 中接入 fork 启动参数

`AgentLoopToolExecutionCoordinatorBuilder` 内：

- 当 `agent_name` 缺失时，走 implicit fork。
- 使用 `ForkMessageBuilder.buildForkedMessages(...)` 构造 child 初始消息。
- 调用 `runSubagentLoop` 新增重载：支持 `initialMessages` 覆盖默认首轮单消息路径。

建议给 `runSubagentLoop` 增加参数：

```swift
initialMessagesOverride: [MessageParameter.Message]? = nil
```

当该参数存在时，跳过 `buildSubagentFirstTurnMessage` 的默认构造。

---

## Task 5: 防递归 fork 与后台行为保证

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift`
- Modify: `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`

### Step 5.1 防递归

- implicit fork 前调用 `isInForkChild(parentMessages)`。
- 若命中，返回错误：
  - `Fork subagent cannot spawn another fork subagent.`

### Step 5.2 强制后台

- implicit fork 路径无条件设置 `shouldRunBackground = true`。
- 即便 `run_in_background` 未传入，也应返回 async launch receipt。

---

## Task 6: 集成测试与回归

**Files:**
- Modify: `agentGuiTests/SubagentCoordinatorIntegrationTests.swift`
- (可选) Create: `agentGuiTests/ToolRegistryRunSubagentSchemaTests.swift`

### Step 6.1 新增集成测试用例

1. `test_runSubagent_withoutAgentName_usesImplicitForkAndReturnsAsyncLaunched`
2. `test_runSubagent_inForkChild_rejectsRecursiveFork`
3. `test_runSubagent_namedAgent_stillWorks`
4. `test_runSubagent_schema_taskOnlyRequired`

### Step 6.2 运行聚焦测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf2-regression \
  -only-testing:agentGuiTests/ForkMessageBuilderTests \
  -only-testing:agentGuiTests/ForkSubagentDefinitionTests \
  -only-testing:agentGuiTests/SubagentCoordinatorIntegrationTests \
  -only-testing:agentGuiTests/ToolRegistryTests \
  CODE_SIGNING_ALLOWED=NO
```

如 `ToolRegistryTests` 不存在，用现有覆盖 run_subagent schema 的测试文件替代。

---

## 验收标准

1. `run_subagent` 缺失 `agent_name` 时不报参数错误，触发 implicit fork。
2. fork child 的初始消息满足 `parentHistory + assistant + user(placeholders + directive)` 结构。
3. placeholder 文本在同一轮多个 fork child 完全一致（byte-identical）。
4. fork child 上下文命中 `<fork-boilerplate>` 时再次 fork 被拒绝。
5. named subagent（explore/worker/verifier）路径无回归。
6. implicit fork 默认后台执行，返回 `async_launched` receipt。

---

## 风险与回滚

### 风险 1: assistant message 组装偏差导致 cache miss

- 缓解：`ForkMessageBuilderTests` 断言消息结构；新增调试日志输出 hash。
- 回滚：保留 named subagent 路径，暂时禁用 implicit fork（仅恢复 required `agent_name`）。

### 风险 2: schema 改造影响现有提示词行为

- 缓解：保持 `agent_name` 字段可传且优先；仅缺失时走新路径。

### 风险 3: 递归 guard 误判

- 缓解：仅扫描 user role + fork tag，复用 S-F1 `isInForkChild`。

---

## Commit 建议

```bash
git add agentGui/Services/SubagentGovernance/ForkMessageBuilder.swift \
        agentGuiTests/ForkMessageBuilderTests.swift \
        agentGui/Services/SubagentGovernance/ForkSubagentDefinition.swift
git commit -m "feat(S-F2): add ForkMessageBuilder and fork directive boilerplate"

git add agentGui/Services/ToolRegistry.swift \
        agentGui/Services/AgentLoopToolExecutionCoordinator.swift \
        agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift \
        agentGui/Services/AgentLoopRoundExecutor.swift \
        agentGui/Services/ClaudeService/ClaudeService+Subagent.swift \
        agentGui/Services/ClaudeService/ClaudeService+ToolCallRecord.swift \
        agentGui/Services/SubagentGovernance/SubagentProgressTracker.swift
git commit -m "feat(S-F2): support implicit fork route in run_subagent"

git add agentGuiTests/SubagentCoordinatorIntegrationTests.swift
git commit -m "test(S-F2): add implicit fork integration coverage"
```

---

## 与后续 Feature 的接口约定

1. 给 S-F3：`AgentLoopPendingTool.isForkSubagent` 在 fork 场景要被显式标记，供并发批次规划使用。
2. 给 S-H2：`ForkMessageBuilder.buildWorktreeNotice(...)` 可在后续追加，本计划先预留 API。
3. 给 UI：`FORK_DIRECTIVE_PREFIX` 保持稳定，后续可做 transcript 折叠显示。

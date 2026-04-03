# S-F1 ForkSubagentDefinition 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 新增 `ForkSubagentDefinition`，表示继承父代理完整对话上下文的特殊 fork 子代理类型，并实现 `isInForkChild` 防递归守卫，为后续 S-F2（ForkMessageBuilder）和 S-F3（Fork 并发调度器）打好基础。

**Architecture:** 在现有 `WorkflowRoleDefinition` / `AgentCatalog` / `AgentLoopPendingTool` 体系上叠加：新增独立的 `ForkSubagentDefinition` 值类型作为 fork 语义的单一真实源；通过扩展 `AgentLoopPendingTool` 增加 `isForkSubagent: Bool` 注解，为 `ToolConcurrencyBatchPlanner`（F-C1）预留 S-F3 的接入点；实现 `isInForkChild` 扫描历史消息以防止递归 fork。不修改已有的 `runSubagentLoop` 执行逻辑，不创建任何新文件夹。

**Tech Stack:** Swift 6, SwiftAnthropic (`MessageParameter.Message.Content.ContentObject`), XCTest

**Dependencies:** S-A1（`WorkflowRoleDefinition` 开放字段已实现）, S-C2（`SubagentBackgroundExecutor` / `AgentLoopPendingTool` 已实现）, F-C1（`ToolConcurrencyBatchPlanner` 已实现，保留 S-F3 注释）

**参考源码:** `claude-code-source-code-main/src/tools/AgentTool/forkSubagent.ts`

---

## 背景与关键设计决策

### Fork 子代理与普通子代理的核心区别

| 维度 | 普通子代理 (`run_subagent agent_name: explore`) | Fork 子代理 |
|------|------|------|
| 系统提示 | 使用代理自身的 `systemPrompt`（来自 `.agent.md`） | **继承父代理的已渲染系统提示**（byte-identical，命中 prompt cache） |
| 消息历史 | 从单条 user task 消息开始 | **继承父代理的完整对话历史 + 当前 assistant 消息** |
| 工具集 | 来自 `.agent.md` `tools` 字段 | **继承父代理完整工具集**（`tools: ["*"]`，cache-identical） |
| 模型 | 按 `model-preference` 解析 | **继承父代理模型**（`model: inherit`，token 长度对等） |
| 权限模式 | 代理自身的 `permissionMode` | **`bubble`（权限提示冒泡到父代理终端）** |
| 防递归 | 无需要 | **需要**：fork child 不可再 fork |
| 注册到 AgentCatalog | 是 | **否**：不是可命名代理，隐式触发 |

### 触发条件（Claude Code 原语）

在 Claude Code 中，fork 由"省略 `subagent_type` 参数 + feature gate 开启"触发。在 agentGui 中，**S-F1 仅定义 ForkSubagentDefinition 和防守机制**，不改动触发逻辑。触发逻辑由 S-F2 实现。本计划范围：

1. `ForkSubagentDefinition` — fork 代理所有静态属性的单一真实源
2. `isInForkChild(_:)` — 防递归守卫：检测消息历史中是否已包含 fork boilerplate 标记
3. `AgentLoopPendingTool.isForkSubagent` — 并发调度注解（为 S-F3 预留）
4. 常量 `FORK_SUBAGENT_TYPE` / `FORK_BOILERPLATE_TAG` / `FORK_PLACEHOLDER_RESULT`

### Fork Boilerplate 标记机制

Claude Code 使用 `<fork-boilerplate>` XML 标记注入到 fork child 的第一条 user message 中（见 `buildChildMessage()`）。`isInForkChild` 通过扫描 messages 数组中是否存在包含此标记的文本来判断当前代理是否已在 fork child 中运行。

agentGui 中 `MessageParameter.Message.Content` 分两种：
- `.text(String)` — 纯文本
- `.list([ContentObject])` — 复合内容（含 `.text(String)`, `.toolUse(id, name, input)`, `.toolResult(id, [ContentObject])` 等）

`isInForkChild` 需要递归扫描这两种格式。

---

## 新增文件

```text
agentGui/Services/SubagentGovernance/ForkSubagentDefinition.swift   ← 主实现
agentGuiTests/ForkSubagentDefinitionTests.swift                     ← 单元测试
```

## 修改文件

```text
agentGui/Services/AgentLoopRoundStreamAssembler.swift   ← 给 AgentLoopPendingTool 增加 isForkSubagent
agentGui/Services/ToolGovernance/ToolConcurrencyBatchPlanner.swift  ← 更新 S-F3 预留注释
```

---

## Task 1: 新增常量与 `ForkSubagentDefinition`

**Files:**
- Create: `agentGui/Services/SubagentGovernance/ForkSubagentDefinition.swift`
- Test: `agentGuiTests/ForkSubagentDefinitionTests.swift`

### Step 1: 写失败测试

```swift
// agentGuiTests/ForkSubagentDefinitionTests.swift
import XCTest
import SwiftAnthropic
@testable import agentGui

final class ForkSubagentDefinitionTests: XCTestCase {

    // MARK: - Constants

    func test_forkSubagentType_isLiteralFork() {
        XCTAssertEqual(FORK_SUBAGENT_TYPE, "fork")
    }

    func test_forkBoilerplateTag_isNonEmpty() {
        XCTAssertFalse(FORK_BOILERPLATE_TAG.isEmpty)
    }

    func test_forkPlaceholderResult_isNonEmpty() {
        XCTAssertFalse(FORK_PLACEHOLDER_RESULT.isEmpty)
    }

    // MARK: - ForkSubagentDefinition 静态属性

    func test_forkDefinition_agentType() {
        XCTAssertEqual(ForkSubagentDefinition.agentType, FORK_SUBAGENT_TYPE)
    }

    func test_forkDefinition_modelPreference_isInherit() {
        XCTAssertEqual(ForkSubagentDefinition.modelPreference, .inherit)
    }

    func test_forkDefinition_tools_containsWildcard() {
        XCTAssertTrue(ForkSubagentDefinition.tools.contains("*"))
    }

    func test_forkDefinition_permissionMode_isBubble() {
        XCTAssertEqual(ForkSubagentDefinition.permissionMode, "bubble")
    }

    func test_forkDefinition_maxTurns_isLarge() {
        // fork 代理需要处理完整任务，maxTurns 应 >= 100
        XCTAssertGreaterThanOrEqual(ForkSubagentDefinition.maxTurns, 100)
    }

    func test_forkDefinition_permitsForking_isFalse() {
        // fork child 不可再 fork
        XCTAssertFalse(ForkSubagentDefinition.permitsFork)
    }

    /// ForkSubagentDefinition 不应出现在 AgentCatalog 中（不可命名 invoke）
    func test_forkDefinition_notRegisteredInCatalog() {
        let catalog = AgentCatalog.shared
        XCTAssertNil(catalog.find(named: FORK_SUBAGENT_TYPE))
    }
}
```

### Step 2: 运行测试确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-task1 \
  -only-testing:agentGuiTests/ForkSubagentDefinitionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

期望：编译错误（ForkSubagentDefinition 未定义）

### Step 3: 实现 `ForkSubagentDefinition.swift`

```swift
// agentGui/Services/SubagentGovernance/ForkSubagentDefinition.swift
//
// S-F1: Fork subagent type definition.
// Encodes all static properties of a fork child agent — the actual "inherit
// parent context" mechanics are handled by ForkMessageBuilder (S-F2).
//
// Reference: src/tools/AgentTool/forkSubagent.ts → FORK_AGENT
//

import Foundation

// MARK: - Constants

/// Synthetic agent type identifier used for analytics when the fork path fires.
/// Matches Claude Code's `FORK_SUBAGENT_TYPE = 'fork'`.
let FORK_SUBAGENT_TYPE = "fork"

/// XML tag injected into the fork child's first user message to signal "this is a fork context".
/// `isInForkChild` scans for this tag to prevent recursive forks.
/// Matches Claude Code's `FORK_BOILERPLATE_TAG`.
let FORK_BOILERPLATE_TAG = "fork-boilerplate"

/// Placeholder text used for all tool_result blocks in the fork prefix message.
/// Must be identical across all fork children to maximise prompt cache sharing.
/// Matches Claude Code's `FORK_PLACEHOLDER_RESULT`.
let FORK_PLACEHOLDER_RESULT = "Fork started — processing in background"

// MARK: - ForkSubagentDefinition

/// Static definition for the fork subagent type.
///
/// A fork child:
/// - Inherits the parent's already-rendered system prompt (byte-identical for cache)
/// - Inherits the parent's full conversation history + current assistant message
/// - Inherits the parent's tool pool (tools: ["*"], useExactTools = true)
/// - Uses the parent's model (model-preference: inherit)
/// - Surfaces permission prompts to the parent terminal (permissionMode: "bubble")
/// - Cannot itself fork (permitsFork = false)
///
/// Fork children are **not** registered in AgentCatalog — they are triggered
/// implicitly by ForkMessageBuilder (S-F2), not by naming an agent type.
///
/// Reference: `FORK_AGENT` constant in `forkSubagent.ts`
enum ForkSubagentDefinition {

    /// Synthetic agent type name (matches `FORK_SUBAGENT_TYPE`).
    static let agentType: String = FORK_SUBAGENT_TYPE

    /// Model selection: always inherit the parent agent's model.
    /// Fork children need full context window parity with the parent.
    static let modelPreference: SubagentModelPreference = .inherit

    /// Tool specification: wildcard, resolved to parent's exact tool pool at call time.
    static let tools: [String] = ["*"]

    /// Permission mode: "bubble" surfaces permission prompts to the parent's terminal.
    static let permissionMode: String = "bubble"

    /// Maximum turns for a fork child. Generous budget since forks handle
    /// complete subtasks independently (Claude Code uses 200).
    static let maxTurns: Int = 200

    /// Fork children must not themselves spawn further fork children.
    /// Enforced at call time by `isInForkChild(_:)`.
    static let permitsFork: Bool = false

    /// Human-readable description used in logs and UI hints.
    static let whenToUse: String = """
        Implicit fork — inherits full conversation context. \
        Not selectable via agent_name; triggered by ForkMessageBuilder (S-F2).
        """
}
```

### Step 4: 运行测试确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-task1 \
  -only-testing:agentGuiTests/ForkSubagentDefinitionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

期望：`Test Suite ... passed`（7 个 test case 全绿）

### Step 5: Commit

```bash
cd /Volumes/T7/文稿/Projects/agentGui
git add agentGui/Services/SubagentGovernance/ForkSubagentDefinition.swift \
        agentGuiTests/ForkSubagentDefinitionTests.swift
git commit -m "feat(S-F1): add ForkSubagentDefinition constants and static type"
```

---

## Task 2: 实现 `isInForkChild(_:)` 防递归守卫

**Files:**
- Modify: `agentGui/Services/SubagentGovernance/ForkSubagentDefinition.swift`（增加函数）
- Modify: `agentGuiTests/ForkSubagentDefinitionTests.swift`（增加测试 class）

### Step 1: 写失败测试

在 `ForkSubagentDefinitionTests.swift` 末尾追加以下测试 class（不替换已有内容）：

```swift
// MARK: - isInForkChild

final class IsInForkChildTests: XCTestCase {

    // MARK: 辅助方法

    /// 构造包含 fork boilerplate 标记的 .text 消息
    private func forkBotMessage() -> MessageParameter.Message {
        let content = "...\n<\(FORK_BOILERPLATE_TAG)>\nSTOP. READ THIS FIRST.\n</\(FORK_BOILERPLATE_TAG)>\n..."
        return MessageParameter.Message(role: .user, content: .text(content))
    }

    /// 构造纯文本（非 fork）user 消息
    private func plainUserMsg(_ text: String = "hello") -> MessageParameter.Message {
        MessageParameter.Message(role: .user, content: .text(text))
    }

    /// 构造 .list 格式的 user 消息，包含一个文本块
    private func listUserMsg(text: String) -> MessageParameter.Message {
        MessageParameter.Message(
            role: .user,
            content: .list([.text(text)])
        )
    }

    /// 构造 .list 格式的 user 消息，包含一个 toolResult 块（内含文本）
    private func toolResultMsg(text: String, toolUseId: String = "tc-1") -> MessageParameter.Message {
        MessageParameter.Message(
            role: .user,
            content: .list([
                .toolResult(toolUseId, [.text(text)])
            ])
        )
    }

    // MARK: 空消息列表

    func test_emptyMessages_returnsFalse() {
        XCTAssertFalse(isInForkChild([]))
    }

    // MARK: 无 boilerplate 消息

    func test_plainMessages_returnsFalse() {
        let msgs = [plainUserMsg("do some work"), plainUserMsg("continue")]
        XCTAssertFalse(isInForkChild(msgs))
    }

    // MARK: .text 消息含 boilerplate

    func test_textMessageWithBoilerplate_returnsTrue() {
        let msgs = [forkBotMessage()]
        XCTAssertTrue(isInForkChild(msgs))
    }

    // MARK: .list 文本块含 boilerplate

    func test_listTextBlockWithBoilerplate_returnsTrue() {
        let tag = "<\(FORK_BOILERPLATE_TAG)>"
        let msgs = [listUserMsg(text: "Scope: \(tag) done")]
        XCTAssertTrue(isInForkChild(msgs))
    }

    // MARK: .list toolResult 块内文本含 boilerplate

    func test_toolResultBlockWithBoilerplate_returnsTrue() {
        let tag = "<\(FORK_BOILERPLATE_TAG)>"
        let msgs = [toolResultMsg(text: "result \(tag) end")]
        XCTAssertTrue(isInForkChild(msgs))
    }

    // MARK: assistant 消息中的 boilerplate 不应触发守卫

    func test_assistantMessageWithBoilerplate_returnsFalse() {
        // isInForkChild 只检查 user 消息
        let content = "<\(FORK_BOILERPLATE_TAG)>STOP</\(FORK_BOILERPLATE_TAG)>"
        let msg = MessageParameter.Message(role: .assistant, content: .text(content))
        XCTAssertFalse(isInForkChild([msg]))
    }

    // MARK: 混合消息列表

    func test_mixedMessages_detectsBoilerplate() {
        let msgs: [MessageParameter.Message] = [
            plainUserMsg("task"),
            MessageParameter.Message(role: .assistant, content: .text("thinking...")),
            forkBotMessage(),
            plainUserMsg("continue"),
        ]
        XCTAssertTrue(isInForkChild(msgs))
    }

    // MARK: boilerplate 在最后一条消息时仍能检测

    func test_boilerplateInLastMessage_returnsTrue() {
        let msgs = [
            plainUserMsg("a"),
            plainUserMsg("b"),
            forkBotMessage(),
        ]
        XCTAssertTrue(isInForkChild(msgs))
    }
}
```

### Step 2: 运行测试确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-task2 \
  -only-testing:agentGuiTests/IsInForkChildTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

期望：编译错误（`isInForkChild` 未定义）

### Step 3: 实现 `isInForkChild`

在 `ForkSubagentDefinition.swift` 末尾追加：

```swift
// MARK: - Recursive Fork Guard

/// Returns `true` when the message history contains a fork-boilerplate tag,
/// indicating the current agent is already running as a fork child.
///
/// Fork children keep the full parent tool pool (including `run_subagent`) for
/// cache-identical tool definitions, but must NOT spawn further forks. This
/// guard detects the injected `<fork-boilerplate>` tag that ForkMessageBuilder
/// (S-F2) inserts into the child's first user message.
///
/// Only scans user-role messages (assistant messages may echo the tag innocuously).
///
/// Reference: `isInForkChild()` in `forkSubagent.ts`
///
/// - Parameter messages: The `messages` array from the current agent loop.
/// - Returns: `true` if a fork-boilerplate tag is found in any user message.
func isInForkChild(_ messages: [MessageParameter.Message]) -> Bool {
    let openTag = "<\(FORK_BOILERPLATE_TAG)>"
    for message in messages {
        guard message.role == .user else { continue }
        if messageContainsForkTag(message.content, openTag: openTag) {
            return true
        }
    }
    return false
}

// MARK: - Private helpers

/// Recursively searches a `MessageParameter.Message.Content` for the fork tag.
private func messageContainsForkTag(
    _ content: MessageParameter.Message.Content,
    openTag: String
) -> Bool {
    switch content {
    case .text(let text):
        return text.contains(openTag)
    case .list(let objects):
        return objects.contains { contentObjectContainsForkTag($0, openTag: openTag) }
    }
}

/// Recursively searches a single `ContentObject` for the fork tag.
private func contentObjectContainsForkTag(
    _ object: MessageParameter.Message.Content.ContentObject,
    openTag: String
) -> Bool {
    switch object {
    case .text(let text):
        return text.contains(openTag)
    case .toolResult(_, let innerObjects):
        return innerObjects.contains { contentObjectContainsForkTag($0, openTag: openTag) }
    default:
        // .toolUse, .thinking, .image, etc. cannot contain fork boilerplate
        return false
    }
}
```

> **注意：** SwiftAnthropic `MessageParameter.Message` 的 `role` 是 `MessageParameter.Message.Role`（`.user` / `.assistant`），`content` 是 `MessageParameter.Message.Content`（`.text(String)` 或 `.list([ContentObject])`）。`ContentObject` 的 `.toolResult` case 签名需与 `AgentLoopRoundExecutor.swift` 中实际使用的签名对齐（见该文件中 `toolResult(id, [ContentObject])` 用法）。如果 ContentObject 枚举的具体 case 名称与此处不符，根据实际 SwiftAnthropic API 调整。

### Step 4: 运行测试确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-task2 \
  -only-testing:agentGuiTests/IsInForkChildTests \
  -only-testing:agentGuiTests/ForkSubagentDefinitionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

期望：所有测试绿色

### Step 5: Commit

```bash
git add agentGui/Services/SubagentGovernance/ForkSubagentDefinition.swift \
        agentGuiTests/ForkSubagentDefinitionTests.swift
git commit -m "feat(S-F1): implement isInForkChild recursive fork guard"
```

---

## Task 3: `AgentLoopPendingTool` 增加 `isForkSubagent` 注解

**Files:**
- Modify: `agentGui/Services/AgentLoopRoundStreamAssembler.swift`（给 `AgentLoopPendingTool` 增加字段）
- Modify: `agentGuiTests/ForkSubagentDefinitionTests.swift`（增加注解测试）

### 背景

`ToolConcurrencyBatchPlanner`（F-C1）文件中已有预留注释：

```swift
// S-F3 reservation: fork-mode subagents should be classified as concurrency-safe
// by inspecting tool.subagentType (or an equivalent annotation on AgentLoopPendingTool).
// if tool.subagentType == .fork { /* treat as safe */ }
```

S-F1 在 `AgentLoopPendingTool` 上增加 `isForkSubagent: Bool` 字段（默认 `false`），S-F3 将在 `ToolConcurrencyBatchPlanner` 中检查此字段实现并发调度。本阶段只加字段，不改调度逻辑。

### Step 1: 写失败测试

在 `ForkSubagentDefinitionTests.swift` 末尾追加：

```swift
// MARK: - AgentLoopPendingTool.isForkSubagent

final class AgentLoopPendingToolForkAnnotationTests: XCTestCase {

    func test_defaultPendingTool_isForkSubagent_isFalse() {
        let tool = AgentLoopPendingTool(id: "t1", name: "bash")
        XCTAssertFalse(tool.isForkSubagent)
    }

    func test_forkAnnotatedTool_isForkSubagent_isTrue() {
        var tool = AgentLoopPendingTool(id: "t2", name: "run_subagent")
        tool.isForkSubagent = true
        XCTAssertTrue(tool.isForkSubagent)
    }

    func test_forkAnnotation_doesNotAffectEquality_byDefault() {
        // 两个完全相同的工具（isForkSubagent 均为默认 false）应该相等
        let a = AgentLoopPendingTool(id: "t3", name: "bash")
        let b = AgentLoopPendingTool(id: "t3", name: "bash")
        XCTAssertEqual(a, b)
    }
}
```

### Step 2: 运行测试确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-task3 \
  -only-testing:agentGuiTests/AgentLoopPendingToolForkAnnotationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：编译错误（`isForkSubagent` 不存在）

### Step 3: 修改 `AgentLoopPendingTool`

在 `agentGui/Services/AgentLoopRoundStreamAssembler.swift` 的 `AgentLoopPendingTool` 结构体中，在 `var partialJson: String = ""` 之后加入新字段：

```swift
struct AgentLoopPendingTool: Equatable {
    let id: String
    let name: String
    var partialJson: String = ""

    /// S-F1: Set to `true` when this pending tool represents a fork-mode subagent call.
    /// Used by ToolConcurrencyBatchPlanner (S-F3) to mark fork subagents as concurrency-safe,
    /// enabling parallel execution of multiple fork children in the same batch.
    var isForkSubagent: Bool = false

    // ... 已有代码保持不变
```

> **注意：** `isForkSubagent` 不参与 `Equatable` 的自动合成（Swift 对 stored property 自动合成，若加了此字段会影响相等性）。观察测试 `test_forkAnnotation_doesNotAffectEquality_byDefault`：两个工具的 `isForkSubagent` 均为 `false`，自动合成的 `==` 会相等。如果未来需要"不参与相等比较"，需手动实现 `==`。本阶段使用自动合成即可（`false == false`）。

### Step 4: 运行测试确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-task3 \
  -only-testing:agentGuiTests/AgentLoopPendingToolForkAnnotationTests \
  -only-testing:agentGuiTests/ForkSubagentDefinitionTests \
  -only-testing:agentGuiTests/IsInForkChildTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：所有测试绿色

### Step 5: 更新 `ToolConcurrencyBatchPlanner` 注释

将 `ToolConcurrencyBatchPlanner.swift` 中 S-F3 预留注释更新为更精确的引用：

将：
```swift
    /// - Note (S-F3 reservation): When the Fork concurrent subagent dispatcher
    ///   (S-F3 in `2026-04-01-subagent-capability-enhancement-design.md`) is implemented,
    ///   fork-mode subagents should be classified as concurrency-safe here by inspecting
    ///   `tool.subagentType` (or an equivalent annotation on `AgentLoopPendingTool`).  
    ///   Add a branch before the `isConcurrencySafe` check, e.g.:
    ///   ```swift
    ///   if tool.subagentType == .fork { /* treat as safe */ }
    ///   ```
```

替换为：
```swift
    /// - Note (S-F3 reservation): When the Fork concurrent subagent dispatcher
    ///   (S-F3 in `2026-04-01-subagent-capability-enhancement-design.md`) is implemented,
    ///   fork-mode subagents should be classified as concurrency-safe here by checking
    ///   `tool.isForkSubagent` (added in S-F1 / `AgentLoopPendingTool`).
    ///   Add a branch before the `isConcurrencySafe` check:
    ///   ```swift
    ///   if tool.isForkSubagent { /* treat as concurrency-safe */ }
    ///   ```
```

### Step 6: 运行完整回归测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-task3-regression \
  -only-testing:agentGuiTests/ForkSubagentDefinitionTests \
  -only-testing:agentGuiTests/IsInForkChildTests \
  -only-testing:agentGuiTests/AgentLoopPendingToolForkAnnotationTests \
  -only-testing:agentGuiTests/ToolConcurrencyBatchPlannerTests \
  -only-testing:agentGuiTests/ToolConcurrencyBatchIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

期望：所有测试绿色，无回归

### Step 7: Commit

```bash
git add agentGui/Services/AgentLoopRoundStreamAssembler.swift \
        agentGui/Services/ToolGovernance/ToolConcurrencyBatchPlanner.swift \
        agentGuiTests/ForkSubagentDefinitionTests.swift
git commit -m "feat(S-F1): add isForkSubagent annotation to AgentLoopPendingTool, update S-F3 reservation note"
```

---

## Task 4: 最终集成验证与 Xcode 项目文件注册

### Step 1: 确认新文件已加入 Xcode 项目

新文件 `ForkSubagentDefinition.swift` 和 `ForkSubagentDefinitionTests.swift` 需要在 `agentGui.xcodeproj/project.pbxproj` 中注册。在 Xcode 中打开项目，右键 `SubagentGovernance` 组 → "Add Files to agentGui..."，将两个文件加入对应的 target（主 app target 和 Tests target）。

或者通过 git diff 确认 `project.pbxproj` 已包含这两个文件路径。

### Step 2: 运行完整 S-F1 测试套件

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf1-final \
  -only-testing:agentGuiTests/ForkSubagentDefinitionTests \
  -only-testing:agentGuiTests/IsInForkChildTests \
  -only-testing:agentGuiTests/AgentLoopPendingToolForkAnnotationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|passed|failed|error"
```

期望：
```
Test Suite 'ForkSubagentDefinitionTests' passed
Test Suite 'IsInForkChildTests' passed  
Test Suite 'AgentLoopPendingToolForkAnnotationTests' passed
```

### Step 3: 确认无构建警告

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-sf1-build \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "warning:|error:" | grep -v "^$"
```

新增代码不应引入任何编译警告。

### Step 4: Final Commit

```bash
git add agentGui.xcodeproj/project.pbxproj
git commit -m "feat(S-F1): register ForkSubagentDefinition files in Xcode project"
```

---

## 验收检查清单

| 项目 | 验证方式 |
|------|----------|
| `FORK_SUBAGENT_TYPE == "fork"` | `test_forkSubagentType_isLiteralFork` |
| `ForkSubagentDefinition.modelPreference == .inherit` | `test_forkDefinition_modelPreference_isInherit` |
| `ForkSubagentDefinition.tools == ["*"]` | `test_forkDefinition_tools_containsWildcard` |
| `ForkSubagentDefinition.permissionMode == "bubble"` | `test_forkDefinition_permissionMode_isBubble` |
| `ForkSubagentDefinition.maxTurns >= 100` | `test_forkDefinition_maxTurns_isLarge` |
| `ForkSubagentDefinition.permitsFork == false` | `test_forkDefinition_permitsForking_isFalse` |
| fork 类型不出现在 AgentCatalog | `test_forkDefinition_notRegisteredInCatalog` |
| 空消息列表 → `isInForkChild` = false | `test_emptyMessages_returnsFalse` |
| 无 boilerplate 消息 → false | `test_plainMessages_returnsFalse` |
| `.text` 消息含 boilerplate → true | `test_textMessageWithBoilerplate_returnsTrue` |
| `.list` 文本块含 boilerplate → true | `test_listTextBlockWithBoilerplate_returnsTrue` |
| `.toolResult` 块含 boilerplate → true | `test_toolResultBlockWithBoilerplate_returnsTrue` |
| assistant 消息含 boilerplate → false | `test_assistantMessageWithBoilerplate_returnsFalse` |
| 混合消息列表正确检测 | `test_mixedMessages_detectsBoilerplate` |
| `AgentLoopPendingTool.isForkSubagent` 默认 false | `test_defaultPendingTool_isForkSubagent_isFalse` |
| 可手动设置为 true | `test_forkAnnotatedTool_isForkSubagent_isTrue` |
| 现有 BatchPlanner 测试无回归 | `ToolConcurrencyBatchPlannerTests` / `IntegrationTests` 全绿 |

---

## 不在 S-F1 范围内

以下内容由后续 feature 实现，S-F1 不涉及：

| 内容 | 归属 Feature |
|------|-------------|
| `buildForkedMessages()` — 构建 fork child 的消息历史（含 placeholder tool_results + directive） | S-F2 |
| `buildChildMessage()` — 生成 fork child 的 boilerplate 提示文本 | S-F2 |
| `buildWorktreeNotice()` — worktree 隔离通知文本 | S-F2 |
| fork 触发逻辑（`agent_name` 缺失时路由到 fork path） | S-F2 |
| `ToolConcurrencyBatchPlanner` 并发调度（`isForkSubagent` 判断分支） | S-F3 |
| worktree 隔离执行 | S-H1 / S-H2 |

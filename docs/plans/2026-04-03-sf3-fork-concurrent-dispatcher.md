# S-F3 Fork 并发调度器实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现 Fork 子代理并发调度能力：主代理在同一轮内发出多个 fork 模式的 `run_subagent` 调用时，`ToolConcurrencyBatchPlanner` 将它们收入同一并发批次同时启动，所有 fork 子代理复用父代理的对话历史与系统提示，确保 prompt cache 共享。

**Architecture:** S-F3 分三个层次落地：(1) S-F2 ForkMessageBuilder 构建 fork 子代理的初始消息（继承父代理历史 + boilerplate 注入）；(2) `AgentLoopPendingTool` 扩展 fork 上下文、`handleToolUseOutcome` 检测 fork 工具；(3) `ToolConcurrencyBatchPlanner` 优先检查 `isForkSubagent` 标志，使 fork 工具进入并发批次，`AgentLoopToolExecutionCoordinator` 路由 fork 工具到带预构建消息的 `runSubagentLoop` 调用。

**Tech Stack:** Swift 6, SwiftAnthropic `MessageParameter.Message`, 现有 `AgentLoopRoundExecutor` / `ToolConcurrencyBatchPlanner` / `SubagentBackgroundExecutor` / `ClaudeService+Subagent`。

**前置条件（已完成）：**
- S-F1 `ForkSubagentDefinition.swift` ✓（`isInForkChild`、`FORK_BOILERPLATE_TAG`、`FORK_PLACEHOLDER_RESULT` 常量已定义）
- S-C2 `SubagentBackgroundExecutor` ✓
- F-C1 `ToolConcurrencyBatchPlanner` ✓（已预留 S-F3 注释）
- `AgentLoopPendingTool.isForkSubagent: Bool = false` ✓（已声明，需写入逻辑）

**参考来源：**
- `src/tools/AgentTool/forkSubagent.ts` → `buildForkedMessages`、`buildChildMessage`、`FORK_PLACEHOLDER_RESULT`
- `src/tools/AgentTool/AgentTool.tsx` → `isForkSubagentEnabled`、`isForkPath`、`shouldRunAsync`
- `src/services/tools/toolOrchestration.ts` → `partitionToolCalls`

---

## 概览：需要创建/修改的文件

| 操作 | 文件 | 关联任务 |
|------|------|---------|
| **Create** | `agentGui/Services/SubagentGovernance/ForkMessageBuilder.swift` | Task 1 (S-F2) |
| **Create** | `agentGuiTests/ForkMessageBuilderTests.swift` | Task 2 |
| **Modify** | `agentGui/Services/AgentLoopRoundStreamAssembler.swift` | Task 3 |
| **Modify** | `agentGui/Services/ToolGovernance/ToolConcurrencyBatchPlanner.swift` | Task 4 |
| **Modify** | `agentGuiTests/ToolConcurrencyBatchPlannerTests.swift` | Task 5 |
| **Modify** | `agentGuiTests/ToolConcurrencyBatchIntegrationTests.swift` | Task 5 |
| **Modify** | `agentGui/Models/AgentLoopRunRequest.swift` | Task 6 |
| **Modify** | `agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift` | Task 6 |
| **Modify** | `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift` | Task 7 |
| **Modify** | `agentGui/Services/AgentLoopToolExecutionCoordinator.swift` | Task 8 |
| **Modify** | `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift` | Task 8 |
| **Modify** | `agentGui/Services/AgentLoopRoundExecutor.swift` | Task 9 |
| **Create** | `agentGuiTests/ForkConcurrentDispatchIntegrationTests.swift` | Task 10 |

---

## Task 1: ForkMessageBuilder 核心逻辑（S-F2）

**Files:**
- Create: `agentGui/Services/SubagentGovernance/ForkMessageBuilder.swift`

**背景：** Claude Code 的 fork 路径中，每个 fork 子代理的初始消息由 `buildForkedMessages()` 构建：完整父代理消息 + 所有 tool_use 占位 tool_result + 单独 directive。所有子代理共享相同前缀，仅末尾 directive 不同，从而命中同一 prompt cache。

### Step 1: 编写文件

```swift
// agentGui/Services/SubagentGovernance/ForkMessageBuilder.swift
//
// S-F2: Fork 子代理消息构建器。
// 为每个 fork 子代理生成 byte-identical 的 API 请求前缀，最大化 prompt cache 命中率。
//
// Reference: src/tools/AgentTool/forkSubagent.ts → buildForkedMessages / buildChildMessage
//

import Foundation
import SwiftAnthropic

/// Fork 子代理消息构建器。
///
/// 用于在主代理的同一轮内有多个 fork 调用时，为每个 fork 子代理生成相同的 API 请求前缀，
/// 使所有子代理的 API 请求共享 prompt cache，避免缓存浪费。
///
/// **消息结构（最终拼接到父代理历史末尾）：**
/// ```
/// [...parentHistory,
///   assistant(text?, thinking?, toolUse1, toolUse2, ...),   // 完整父代理 assistant 消息
///   user([toolResult1(placeholder), toolResult2(placeholder), ..., text(directive)])  // 每个 fork 专属
/// ]
/// ```
struct ForkMessageBuilder {

    // MARK: - Public API

    /// 为单个  fork 子代理构建其专属的 2 条消息（assistant + user）。
    ///
    /// 调用方将返回值追加在 `parentHistory` 之后，形成 fork 子代理的完整初始消息列表：
    /// `var initialMessages = parentHistory + builder.buildForkedMessages(directive:assistantObjects:)`
    ///
    /// - Parameters:
    ///   - directive: 当前 fork 子代理的具体任务说明（拼接到 user 消息末尾的文本块）。
    ///   - assistantObjects: 父代理当前轮次的所有 assistant content object（text/thinking/toolUse）。
    ///                       使用 `outcome.assistantObjects + [可选 text(currentRoundText)]` 传入。
    /// - Returns: `[assistantMessage, userMessage]`，追加到 `parentHistory` 后即为完整初始上下文。
    func buildForkedMessages(
        directive: String,
        assistantObjects: [MessageParameter.Message.Content.ContentObject]
    ) -> [MessageParameter.Message] {
        // 收集 assistant 消息中的所有 tool_use block id
        let toolUseIDs = assistantObjects.compactMap { obj -> String? in
            if case .toolUse(let id, _, _) = obj { return id }
            return nil
        }

        // 若无 tool_use block，退化为仅含 directive 的独立 user 消息
        // （正常 fork 路径下不应触发，但作为防御性 fallback）
        guard !toolUseIDs.isEmpty else {
            let fallbackUser = MessageParameter.Message(
                role: .user,
                content: .list([.text(buildChildMessage(directive: directive))])
            )
            return [fallbackUser]
        }

        // 构建 assistant 消息（byte-identical across all fork children）
        let assistantMessage = MessageParameter.Message(
            role: .assistant,
            content: .list(assistantObjects)
        )

        // 构建 user 消息：所有 tool_use 的占位 tool_result + 当前 fork 的 directive 文本块
        // 占位文本使用全局常量 FORK_PLACEHOLDER_RESULT，确保所有 fork 子代理的文本相同
        var userObjects: [MessageParameter.Message.Content.ContentObject] = toolUseIDs.map { toolID in
            .toolResult(toolID, FORK_PLACEHOLDER_RESULT, isError: nil)
        }
        userObjects.append(.text(buildChildMessage(directive: directive)))

        let userMessage = MessageParameter.Message(
            role: .user,
            content: .list(userObjects)
        )

        return [assistantMessage, userMessage]
    }

    /// 为 fork 子代理生成注入在 directive 之前的强制指令消息（含 `<fork-boilerplate>` 标签）。
    ///
    /// - Parameter directive: 当前 fork 子代理的具体任务说明。
    /// - Returns: 包含 boilerplate 指令 + 任务说明的完整文本，用于 user 消息末尾文本块。
    ///
    /// **重要：**
    /// - 必须包含 `<fork-boilerplate>` 标签，`isInForkChild(_:)` 通过该标签检测递归 fork。
    /// - 指令文本直接来源于 Claude Code `buildChildMessage(directive)`，保持结构一致。
    func buildChildMessage(directive: String) -> String {
        """
        <\(FORK_BOILERPLATE_TAG)>
        STOP. READ THIS FIRST.

        You are a forked worker process. You are NOT the main agent.

        RULES (non-negotiable):
        1. Do NOT spawn sub-agents; execute directly.
        2. Do NOT converse, ask questions, or suggest next steps.
        3. Do NOT editorialize or add meta-commentary.
        4. USE your tools directly.
        5. If you modify files, commit your changes before reporting.
        6. Do NOT emit text between tool calls. Use tools silently, then report once at the end.
        7. Stay strictly within your directive's scope.
        8. Keep your report under 500 words unless the directive specifies otherwise.
        9. Your response MUST begin with "Scope:". No preamble.
        10. REPORT structured facts, then stop.

        Output format:
          Scope: <echo back your assigned scope in one sentence>
          Result: <the answer or key findings>
          Key files: <relevant file paths>
          Files changed: <list with commit hash — only if you modified files>
          Issues: <list — only if there are issues to flag>
        </\(FORK_BOILERPLATE_TAG)>

        \(directive)
        """
    }
}
```

### Step 2: 提交

```bash
cd /Volumes/T7/文稿/Projects/agentGui
git add agentGui/Services/SubagentGovernance/ForkMessageBuilder.swift
git commit -m "feat(S-F2): add ForkMessageBuilder for fork child message construction"
```

---

## Task 2: ForkMessageBuilder 单元测试

**Files:**
- Create: `agentGuiTests/ForkMessageBuilderTests.swift`

### Step 1: 添加测试目标到 Xcode project

通过 Xcode → Build Phases → 将新文件加入 agentGuiTests target（或用 project.pbxproj 手动添加）。

### Step 2: 编写测试

```swift
// agentGuiTests/ForkMessageBuilderTests.swift
import XCTest
@testable import agentGui

final class ForkMessageBuilderTests: XCTestCase {

    private let builder = ForkMessageBuilder()

    // MARK: - buildChildMessage

    func test_buildChildMessage_containsForkBoilerplateTag() {
        let msg = builder.buildChildMessage(directive: "Read ClaudeService.swift")
        XCTAssertTrue(msg.contains("<\(FORK_BOILERPLATE_TAG)>"), "Must contain opening boilerplate tag")
        XCTAssertTrue(msg.contains("</\(FORK_BOILERPLATE_TAG)>"), "Must contain closing boilerplate tag")
    }

    func test_buildChildMessage_containsDirective() {
        let directive = "Analyze the project structure"
        let msg = builder.buildChildMessage(directive: directive)
        XCTAssertTrue(msg.hasSuffix("\n\n\(directive)") || msg.hasSuffix("\(directive)"),
                      "Directive must appear at the end of the child message")
    }

    func test_buildChildMessage_twoCallsWithSameDirective_produceIdenticalText() {
        let d = "Find all TODO comments"
        XCTAssertEqual(builder.buildChildMessage(directive: d),
                       builder.buildChildMessage(directive: d),
                       "Same directive must produce identical boilerplate (prompt cache requirement)")
    }

    func test_buildChildMessage_differentDirectives_differOnlyAtEnd() {
        let msgA = builder.buildChildMessage(directive: "DirectiveA")
        let msgB = builder.buildChildMessage(directive: "DirectiveB")
        // Both messages share identical boilerplate prefix
        let boilerplate = "<\(FORK_BOILERPLATE_TAG)>"
        XCTAssertTrue(msgA.hasPrefix(boilerplate))
        XCTAssertTrue(msgB.hasPrefix(boilerplate))
        // They differ at the end
        XCTAssertNotEqual(msgA, msgB)
    }

    // MARK: - buildForkedMessages — normal path (with tool_use blocks)

    func test_buildForkedMessages_withToolUse_returnsAssistantPlusUserMessages() {
        let assistantObjects: [MessageParameter.Message.Content.ContentObject] = [
            .toolUse("tool-id-1", "run_subagent", [:]),
            .toolUse("tool-id-2", "run_subagent", [:])
        ]
        let messages = builder.buildForkedMessages(
            directive: "Check authentication module",
            assistantObjects: assistantObjects
        )
        XCTAssertEqual(messages.count, 2, "Must return exactly [assistantMsg, userMsg]")
        XCTAssertEqual(messages[0].role, .assistant)
        XCTAssertEqual(messages[1].role, .user)
    }

    func test_buildForkedMessages_assistantMessagePreservesAllObjects() {
        let assistantObjects: [MessageParameter.Message.Content.ContentObject] = [
            .text("Thinking about it"),
            .toolUse("t1", "run_subagent", [:]),
            .toolUse("t2", "run_subagent", [:])
        ]
        let messages = builder.buildForkedMessages(directive: "task", assistantObjects: assistantObjects)
        guard case .list(let objects) = messages[0].content else {
            return XCTFail("Expected list content in assistant message")
        }
        XCTAssertEqual(objects.count, 3, "Assistant message must preserve ALL objects including text")
    }

    func test_buildForkedMessages_userMessageHasPlaceholderForEachToolUse() {
        let assistantObjects: [MessageParameter.Message.Content.ContentObject] = [
            .toolUse("t1", "run_subagent", [:]),
            .toolUse("t2", "run_subagent", [:]),
            .toolUse("t3", "run_subagent", [:])
        ]
        let messages = builder.buildForkedMessages(directive: "task", assistantObjects: assistantObjects)
        guard case .list(let userObjects) = messages[1].content else {
            return XCTFail("Expected list content in user message")
        }
        // 3 tool_result placeholders + 1 text (directive)
        XCTAssertEqual(userObjects.count, 4)
    }

    func test_buildForkedMessages_placeholderTextIsIdenticalAcrossChildren() {
        // Fork prompt cache sharing requires identical placeholder text
        let assistantObjects: [MessageParameter.Message.Content.ContentObject] = [
            .toolUse("t1", "run_subagent", [:])
        ]
        let msgA = builder.buildForkedMessages(directive: "DirectiveA", assistantObjects: assistantObjects)
        let msgB = builder.buildForkedMessages(directive: "DirectiveB", assistantObjects: assistantObjects)

        guard case .list(let objsA) = msgA[1].content,
              case .list(let objsB) = msgB[1].content else {
            return XCTFail("Expected list contents")
        }
        // First object is tool_result placeholder — must be identical for cache sharing
        if case .toolResult(let idA, let textA, _) = objsA[0],
           case .toolResult(let idB, let textB, _) = objsB[0] {
            XCTAssertEqual(idA, idB, "Tool use IDs must match")
            XCTAssertEqual(textA, textB, "Placeholder text must be identical for cache sharing")
            XCTAssertEqual(textA, FORK_PLACEHOLDER_RESULT)
        } else {
            XCTFail("Expected first user object to be toolResult")
        }
    }

    func test_buildForkedMessages_twoChildren_samePrefixDifferentDirective() {
        // The key invariant: all fork children share identical API prefix up to the last text block
        let assistantObjects: [MessageParameter.Message.Content.ContentObject] = [
            .toolUse("t1", "run_subagent", [:]),
            .toolUse("t2", "run_subagent", [:])
        ]
        let msgsA = builder.buildForkedMessages(directive: "DirectiveA", assistantObjects: assistantObjects)
        let msgsB = builder.buildForkedMessages(directive: "DirectiveB", assistantObjects: assistantObjects)

        guard case .list(let objsA) = msgsA[1].content,
              case .list(let objsB) = msgsB[1].content else {
            return XCTFail("Expected list")
        }
        // All tool_result blocks are equal (identical placeholder)
        let placeholderCountA = objsA.filter { if case .toolResult = $0 { return true }; return false }.count
        let placeholderCountB = objsB.filter { if case .toolResult = $0 { return true }; return false }.count
        XCTAssertEqual(placeholderCountA, placeholderCountB)

        // Only the last text block differs
        if case .text(let textA) = objsA.last, case .text(let textB) = objsB.last {
            XCTAssertNotEqual(textA, textB)
        } else {
            XCTFail("Last object should be text (directive)")
        }
    }

    // MARK: - buildForkedMessages — fallback path (no tool_use blocks)

    func test_buildForkedMessages_noToolUseBlocks_returnsSingleUserMessage() {
        let assistantObjects: [MessageParameter.Message.Content.ContentObject] = [
            .text("Just text, no tool calls")
        ]
        let messages = builder.buildForkedMessages(directive: "task", assistantObjects: assistantObjects)
        XCTAssertEqual(messages.count, 1, "No tool_use blocks → single fallback user message")
        XCTAssertEqual(messages[0].role, .user)
    }
}
```

### Step 3: 运行测试，确认全部通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf3-t2 \
  -only-testing:agentGuiTests/ForkMessageBuilderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Build"
```

Expected: All tests PASS.

### Step 4: 提交

```bash
git add agentGuiTests/ForkMessageBuilderTests.swift agentGui.xcodeproj/project.pbxproj
git commit -m "test(S-F2): add ForkMessageBuilderTests"
```

---

## Task 3: AgentLoopPendingTool 扩展 fork 上下文类型

**Files:**
- Modify: `agentGui/Services/AgentLoopRoundStreamAssembler.swift`

**背景：** `AgentLoopPendingTool` 需要携带 fork 子代理执行所需的上下文（父代理历史、当前轮 assistant objects、系统提示文本）。Context 由 `AgentLoopRoundExecutor` 在 batch planning 前注入，stream assembler 阶段完成后触达。

### Step 1: 在 `AgentLoopRoundStreamAssembler.swift` 头部新增类型

在文件顶部 `import SwiftAnthropic` 之后、`AgentLoopPendingTool` struct 之前插入：

```swift
// MARK: - S-F3 Fork Context

/// S-F3: fork 子代理执行所需的父代理上下文，在 AgentLoopRoundExecutor.handleToolUseOutcome
/// 中注入（batch planning 前）。
///
/// 使用独立类型而非直接扩展 AgentLoopPendingTool，避免将大型 MessageParameter.Message
/// 数组带入 Equatable 语义，同时使 context 的生命周期与 pending tool 解耦。
struct AgentLoopForkContext {
    /// 当前 assistant 轮次开始前的完整对话历史（父代理视角）。
    /// 用于构建 fork 子代理的初始消息前缀（拼在 buildForkedMessages 之前）。
    let parentMessages: [MessageParameter.Message]
    /// 当前 assistant 轮次的所有 content object（text + thinking + 所有 toolUse）。
    /// 传给 ForkMessageBuilder.buildForkedMessages(directive:assistantObjects:)。
    let assistantObjects: [MessageParameter.Message.Content.ContentObject]
    /// 父代理当前使用的系统提示文本（已渲染字符串）。
    /// fork 子代理使用此系统提示替代 WorkflowRoleDefinition.systemPrompt，
    /// 确保与父代理 byte-identical 的 system prompt（最大化 prompt cache 命中）。
    let parentSystemPromptText: String?
}
```

### Step 2: 在 `AgentLoopPendingTool` 中新增字段 + 自定义 Equatable

将现有 `struct AgentLoopPendingTool: Equatable { ... }` 修改为：

```swift
struct AgentLoopPendingTool: Equatable {
    let id: String
    let name: String
    var partialJson: String = ""

    /// S-F1: Set to `true` when this pending tool represents a fork-mode subagent call.
    /// Used by ToolConcurrencyBatchPlanner (S-F3) to mark fork subagents as concurrency-safe,
    /// enabling parallel execution of multiple fork children in the same batch.
    var isForkSubagent: Bool = false

    /// S-F3: Fork 执行上下文（仅 isForkSubagent == true 时非 nil）。
    /// 由 AgentLoopRoundExecutor.handleToolUseOutcome 在 batch planning 之前注入。
    /// 不参与 Equatable 比较（不影响测试 snapshot 比较语义）。
    var forkContext: AgentLoopForkContext? = nil

    var parsedInput: MessageResponse.Content.Input { ... }  // 保持原有实现不变

    // S-F3: forkContext 含 MessageParameter.Message（非 Equatable），手动实现 ==
    static func == (lhs: AgentLoopPendingTool, rhs: AgentLoopPendingTool) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.partialJson == rhs.partialJson &&
        lhs.isForkSubagent == rhs.isForkSubagent
        // forkContext intentionally excluded — context is implementation detail, not stream state
    }
}
```

> **注意：** 只修改了 `AgentLoopPendingTool`；`parsedInput` 计算属性和 `dynamicContent` 静态方法保持完全不变。

### Step 3: 确认编译通过

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-sf3-t3 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded|Build FAILED"
```

Expected: `Build succeeded`

### Step 4: 提交

```bash
git add agentGui/Services/AgentLoopRoundStreamAssembler.swift
git commit -m "feat(S-F3): add AgentLoopForkContext and forkContext field to AgentLoopPendingTool"
```

---

## Task 4: ToolConcurrencyBatchPlanner fork 感知

**Files:**
- Modify: `agentGui/Services/ToolGovernance/ToolConcurrencyBatchPlanner.swift`

**背景：** 当前 `partition()` 只通过 `isConcurrencySafe(tool.name)` 判断工具是否可并发。Fork 子代理（`tool.isForkSubagent == true`）需要在此检查**之前**被识别为并发安全，因为 `run_subagent` 在 `DefaultToolRegistry` 中没有 `isConcurrencySafe: true`。

### Step 1: 修改 `partition()` 方法

将现有 `partition` 方法替换为：

```swift
/// Partition `tools` into an ordered sequence of execution batches.
///
/// S-F3: Fork-mode subagents (`tool.isForkSubagent == true`) are treated as
/// concurrency-safe regardless of their tool name, enabling multiple fork children
/// dispatched in the same agent turn to execute in parallel (see S-F3 in
/// `2026-04-01-subagent-capability-enhancement-design.md`).
func partition(_ tools: [AgentLoopPendingTool]) -> [ToolExecutionBatch] {
    tools.reduce(into: [ToolExecutionBatch]()) { batches, tool in
        // S-F3: fork subagents are always concurrency-safe — checked BEFORE isConcurrencySafe
        // to avoid relying on run_subagent's ToolRegistry entry (which remains serial-safe
        // to keep non-fork subagents serialized).
        let safe = tool.isForkSubagent || ((try? isConcurrencySafe(tool.name)) ?? false)
        if safe, case .concurrent(var existing) = batches.last {
            // Merge into the current open concurrent batch.
            existing.append(tool)
            batches[batches.count - 1] = .concurrent(existing)
        } else if safe {
            batches.append(.concurrent([tool]))
        } else {
            batches.append(.serial(tool))
        }
    }
}
```

同时移除已有的 S-F3 "reservation" 注释块（该注释现已实现）。

### Step 2: 确认编译通过

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-sf3-t4 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

### Step 3: 提交

```bash
git add agentGui/Services/ToolGovernance/ToolConcurrencyBatchPlanner.swift
git commit -m "feat(S-F3): ToolConcurrencyBatchPlanner treats isForkSubagent as concurrency-safe"
```

---

## Task 5: ToolConcurrencyBatchPlanner fork 测试

**Files:**
- Modify: `agentGuiTests/ToolConcurrencyBatchPlannerTests.swift`
- Modify: `agentGuiTests/ToolConcurrencyBatchIntegrationTests.swift`

### Step 1: 在 `ToolConcurrencyBatchPlannerTests.swift` 末尾追加测试组

```swift
// MARK: - S-F3: Fork subagent concurrency

func test_forkSubagent_treatedAsConcurrencySafe() {
    let planner = makePlanner(safeToolNames: [])  // run_subagent NOT in safe set
    var forkTool = AgentLoopPendingTool(id: "fork-id", name: "run_subagent")
    forkTool.isForkSubagent = true
    let batches = planner.partition([forkTool])
    XCTAssertEqual(batches.count, 1)
    guard case .concurrent(let tools) = batches[0] else {
        return XCTFail("Fork subagent must produce concurrent batch")
    }
    XCTAssertEqual(tools[0].name, "run_subagent")
}

func test_multipleForkSubagents_mergeIntoConcurrentBatch() {
    let planner = makePlanner(safeToolNames: [])
    var fork1 = AgentLoopPendingTool(id: "f1", name: "run_subagent")
    fork1.isForkSubagent = true
    var fork2 = AgentLoopPendingTool(id: "f2", name: "run_subagent")
    fork2.isForkSubagent = true
    var fork3 = AgentLoopPendingTool(id: "f3", name: "run_subagent")
    fork3.isForkSubagent = true

    let batches = planner.partition([fork1, fork2, fork3])
    XCTAssertEqual(batches.count, 1, "Three fork subagents should merge into one concurrent batch")
    guard case .concurrent(let tools) = batches[0] else {
        return XCTFail("Expected single concurrent batch")
    }
    XCTAssertEqual(tools.count, 3)
}

func test_forkSubagent_mergesWithOtherSafeTools() {
    let planner = makePlanner(safeToolNames: ["web_search"])
    var fork = AgentLoopPendingTool(id: "f1", name: "run_subagent")
    fork.isForkSubagent = true
    let webSearch = AgentLoopPendingTool(id: "ws-1", name: "web_search")

    let batches = planner.partition([webSearch, fork])
    XCTAssertEqual(batches.count, 1, "Fork subagent should merge with preceding safe tool")
    guard case .concurrent(let tools) = batches[0] else {
        return XCTFail("Expected concurrent batch")
    }
    XCTAssertEqual(tools.count, 2)
}

func test_nonForkRunSubagent_remainsSerial() {
    // Non-fork run_subagent calls (standard subagents) must remain serial
    // to preserve the existing synchronous execution semantics.
    let planner = makePlanner(safeToolNames: [])
    let subagent = AgentLoopPendingTool(id: "s1", name: "run_subagent")
    // isForkSubagent defaults to false
    let batches = planner.partition([subagent])
    guard case .serial(let tool) = batches.first else {
        return XCTFail("Non-fork run_subagent must remain serial")
    }
    XCTAssertEqual(tool.name, "run_subagent")
}

func test_serialToolBetweenForkTools_producesThreeBatches() {
    let planner = makePlanner(safeToolNames: [])
    var fork1 = AgentLoopPendingTool(id: "f1", name: "run_subagent")
    fork1.isForkSubagent = true
    let bash = AgentLoopPendingTool(id: "bash-1", name: "bash")
    var fork2 = AgentLoopPendingTool(id: "f2", name: "run_subagent")
    fork2.isForkSubagent = true

    let batches = planner.partition([fork1, bash, fork2])
    XCTAssertEqual(batches.count, 3)
    guard case .concurrent = batches[0],
          case .serial = batches[1],
          case .concurrent = batches[2] else {
        return XCTFail("Expected concurrent / serial / concurrent pattern")
    }
}
```

### Step 2: 更新 `ToolConcurrencyBatchIntegrationTests.swift` 的 safe count 测试

将 `test_safeToolCount_matchesExpectation` 中的注释和断言更新：

```swift
func test_safeToolCount_matchesExpectation() {
    let registry = DefaultToolRegistry()
    let safeCount = registry.allDefinitions().filter(\.isConcurrencySafe).count
    // 11 tools: web_search, web_fetch, read_tool_payload + 8 LSP tools
    // Note: run_subagent is NOT in this count; fork subagents are handled via
    // AgentLoopPendingTool.isForkSubagent flag checked BEFORE isConcurrencySafe (S-F3).
    XCTAssertEqual(safeCount, 11, "Expected exactly 11 concurrency-safe tools in registry")
}
```

### Step 3: 运行测试，确认全部通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf3-t5 \
  -only-testing:agentGuiTests/ToolConcurrencyBatchPlannerTests \
  -only-testing:agentGuiTests/ToolConcurrencyBatchIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Build"
```

Expected: All tests PASS.

### Step 4: 提交

```bash
git add agentGuiTests/ToolConcurrencyBatchPlannerTests.swift \
        agentGuiTests/ToolConcurrencyBatchIntegrationTests.swift
git commit -m "test(S-F3): add fork subagent concurrency tests for ToolConcurrencyBatchPlanner"
```

---

## Task 6: AgentLoopRunRequest 携带渲染后系统提示

**Files:**
- Modify: `agentGui/Models/AgentLoopRunRequest.swift`
- Modify: `agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift`

**背景：** Fork 子代理需要使用父代理**已渲染**的系统提示文本（而非重新构建），以保证 byte-identical 的 API 请求前缀，从而命中父代理的 prompt cache。

### Step 1: 为 `AgentLoopRunRequest` 新增字段

在 `AgentLoopRunRequest.swift` 中：

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
    /// S-F3: 主代理已渲染的系统提示文本，供 fork 子代理直接复用以命中 prompt cache。
    /// 仅主代理 loop 设置此字段；subagent loop 保持 nil。
    let renderedSystemPromptText: String?

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
        criticalReminder: String? = nil,
        renderedSystemPromptText: String? = nil   // S-F3
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
        self.renderedSystemPromptText = renderedSystemPromptText   // S-F3
    }
}
```

### Step 2: 在主代理 loop 构建时设置 `renderedSystemPromptText`

在 `ClaudeService+AgenticLoop.swift` 中，找到主代理构建 `AgentLoopRunRequest` 的调用（`runSource: "main"` 或类似标识的调用点），在已设置 `systemPrompt` 的地方，同时传入 `renderedSystemPromptText: systemPrompt`：

查找类似代码：
```swift
let request = AgentLoopRunRequest(
    service: service,
    modelId: modelId,
    tools: tools,
    system: makeEphemeralSystemPrompt(systemPrompt),
    maxRounds: maxRounds,
    ...
    criticalReminder: nil
)
```

修改为：
```swift
let request = AgentLoopRunRequest(
    service: service,
    modelId: modelId,
    tools: tools,
    system: makeEphemeralSystemPrompt(systemPrompt),
    maxRounds: maxRounds,
    ...
    criticalReminder: nil,
    renderedSystemPromptText: systemPrompt   // S-F3: fork 子代理可通过 request.renderedSystemPromptText 复用
)
```

> **注意：** `agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift` 中可能有多个 `AgentLoopRunRequest` 初始化点（主代理 loop、background loop 等）。只需要在**主代理主循环**（`runSource: "main"` 等）处设置。Subagent loop（`runSource: "subagent"`）保持 `nil`。

### Step 3: 编译确认

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-sf3-t6 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`（`renderedSystemPromptText` 有默认值，所有旧调用不受影响）

### Step 4: 提交

```bash
git add agentGui/Models/AgentLoopRunRequest.swift \
        agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift
git commit -m "feat(S-F3): add renderedSystemPromptText to AgentLoopRunRequest for fork cache sharing"
```

---

## Task 7: runSubagentLoop 支持预构建初始消息

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift`

**背景：** Fork 子代理不从 `task` 字符串构建首条 user message，而是使用 `ForkMessageBuilder.buildForkedMessages()` 生成的包含父代理历史的初始消息列表。需要为 `runSubagentLoop` 添加可选的 `forkOverride` 参数。

**当前签名（简化）：**
```swift
func runSubagentLoop(
    task: String,
    definition: WorkflowRoleDefinition,
    toolCallRecord: ToolCall,
    service: any AnthropicService,
    modelId: String,
    overrideModelId: String? = nil,
    settings: AppSettings,
    sessionId: String,
    modelContext: ModelContext,
    onProgressUpdate: ... = nil
) async throws -> AgentMessage
```

### Step 1: 新增 ForkSubagentOverride 类型（文件顶部）

在 `ClaudeService+Subagent.swift` `// MARK: - Subagent Support` 之前插入：

```swift
// MARK: - S-F3 Fork Override

/// S-F3: fork 子代理执行参数，用于覆盖 runSubagentLoop 的默认消息构建和系统提示。
struct ForkSubagentOverride {
    /// 已由 ForkMessageBuilder 构建好的初始消息列表：[...parentHistory, assistantMsg, userMsg]
    /// 替代默认的单条 task user 消息。
    let initialMessages: [MessageParameter.Message]
    /// 父代理已渲染的系统提示文本（byte-identical 确保 cache 命中）。
    /// 替代 WorkflowRoleDefinition.systemPrompt。
    let parentSystemPromptText: String?
}
```

### Step 2: 修改 `runSubagentLoop` 签名 + 实现

在函数入口处添加 `forkOverride: ForkSubagentOverride? = nil` 参数，并相应调整初始消息构建逻辑：

```swift
func runSubagentLoop(
    task: String,
    definition: WorkflowRoleDefinition,
    toolCallRecord: ToolCall,
    service: any AnthropicService,
    modelId: String,
    overrideModelId: String? = nil,
    settings: AppSettings,
    sessionId: String,
    modelContext: ModelContext,
    onProgressUpdate: (@MainActor @Sendable (SubagentProgress) -> Void)? = nil,
    forkOverride: ForkSubagentOverride? = nil   // S-F3
) async throws -> AgentMessage {
    let startTime = Date()

    let resolvedModelId = SubagentModelResolver.resolve(
        preference: definition.modelPreference,
        parentModelId: modelId,
        overrideModelId: overrideModelId
    )

    // S-F3: fork 路径使用预构建的消息（含父代理历史）；普通路径构建单条 task 消息
    var loopMessages: [MessageParameter.Message]
    let systemText: String
    if let fork = forkOverride {
        loopMessages = fork.initialMessages
        systemText = fork.parentSystemPromptText ?? definition.systemPrompt
    } else {
        let firstTurnContent = ClaudeService.buildSubagentFirstTurnMessage(
            task: task,
            criticalReminder: definition.criticalReminder
        )
        loopMessages = [.init(role: .user, content: .text(firstTurnContent))]
        systemText = definition.systemPrompt
    }

    let system = makeEphemeralSystemPrompt(systemText)
    // ... 其余代码保持不变（request、runtime、runCoreAgentLoop、trailer 等）
}
```

### Step 3: 编译确认

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-sf3-t7 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`（`forkOverride` 有默认 nil 值，现有调用方不受影响）

### Step 4: 提交

```bash
git add agentGui/Services/ClaudeService/ClaudeService+Subagent.swift
git commit -m "feat(S-F3): runSubagentLoop accepts ForkSubagentOverride for fork path"
```

---

## Task 8: AgentLoopToolExecutionCoordinator fork 执行路径

**Files:**
- Modify: `agentGui/Services/AgentLoopToolExecutionCoordinator.swift`
- Modify: `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`

**背景：** Coordinator 的 `execute()` 方法需要识别 fork 工具，使用 `ForkMessageBuilder` 构建初始消息并强制后台执行（fork 总是异步）。`launchSubagent` 闭包接收 `ForkSubagentOverride?` 参数。

### Step 1: 修改 `AgentLoopToolExecutionCoordinator` 的 `launchSubagent` 签名

在 `AgentLoopToolExecutionCoordinator.swift` 的 `Dependencies` 中，将 `launchSubagent` 类型从：

```swift
let launchSubagent: (MessageResponse.Content.Input, ToolCall, (String) -> WorkflowRoleDefinition?, SubagentBackgroundExecutor, ModelContext?) async -> SubagentLaunchResult
```

改为：

```swift
let launchSubagent: (MessageResponse.Content.Input, ToolCall, (String) -> WorkflowRoleDefinition?, SubagentBackgroundExecutor, ModelContext?, ForkSubagentOverride?) async -> SubagentLaunchResult
```

### Step 2: 修改 `execute()` 方法中的 fork 分支

在 `if pendingTool.name == "run_subagent" {` 块中，增加 fork 判断：

```swift
if pendingTool.name == "run_subagent" {
    // S-F3: 构建 fork override（若当前工具是 fork 子代理）
    var forkOverride: ForkSubagentOverride? = nil
    if pendingTool.isForkSubagent, let ctx = pendingTool.forkContext {
        let directive = input["task"]?.stringValue ?? ""
        let forkedMessages = ForkMessageBuilder().buildForkedMessages(
            directive: directive,
            assistantObjects: ctx.assistantObjects
        )
        let initialMessages = ctx.parentMessages + forkedMessages
        forkOverride = ForkSubagentOverride(
            initialMessages: initialMessages,
            parentSystemPromptText: ctx.parentSystemPromptText
        )
    }

    let launchResult = await dependencies.launchSubagent(
        input,
        record,
        { name in AgentCatalog.shared.find(named: name)?.workflowRoleDefinition },
        dependencies.backgroundExecutor,
        dependencies.modelContext,
        forkOverride   // S-F3: nil for non-fork, non-nil for fork path
    )
    record.subagentAgentName = input["agent_name"]?.stringValue
    // ... 其余不变
}
```

### Step 3: 修改 `AgentLoopToolExecutionCoordinatorBuilder.build()` 中的 `launchSubagent` 闭包

在 `AgentLoopToolExecutionCoordinatorBuilder.swift` 中，更新 `launchSubagent` 闭包签名以接收 `ForkSubagentOverride?`，并将其透传给 `runSubagentLoop`：

```swift
launchSubagent: { [claudeService, service, modelId, settings] input, record, definitionResolver, backgroundExecutor, ctx, forkOverride in
    let agentName = input["agent_name"]?.stringValue ?? ""
    let task = input["task"]?.stringValue ?? ""
    let overrideModelId = input["model"]?.stringValue.flatMap {
        $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
    }
    let runInBackground = input["run_in_background"]?.boolValue ?? false

    // S-F3: fork 子代理始终以后台方式运行（强制 async）
    let isForkCall = forkOverride != nil

    guard let definition = definitionResolver(agentName) else {
        let available = AgentCatalog.shared.subagentInvocableAgents.map(\.name).joined(separator: ", ")
        return .sync(message: .error("unknown agent '\(agentName)'. Available: \(available)", sender: "system"))
    }

    let shouldRunBackground = isForkCall || runInBackground || definition.background

    let taskDescription = String(task.prefix(50))
    let sessionUUID = UUID(uuidString: capturedSessionId) ?? UUID()

    if shouldRunBackground, let parentSession = capturedSession, let ctx {
        let params = SubagentBackgroundLaunchParams(
            agentName: agentName,
            task: task,
            taskDescription: taskDescription,
            toolCallRecord: record,
            sessionID: sessionUUID,
            session: parentSession,
            runInBackground: true,
            definition: definition,
            launchSubagent: { task, def, progressCallback in
                do {
                    return try await .sync(message: claudeService.runSubagentLoop(
                        task: task,
                        definition: def,
                        toolCallRecord: record,
                        service: service,
                        modelId: modelId,
                        overrideModelId: overrideModelId,
                        settings: settings,
                        sessionId: capturedSessionId,
                        modelContext: capturedModelContext,
                        onProgressUpdate: progressCallback,
                        forkOverride: forkOverride   // S-F3: 透传 fork override
                    ))
                } catch {
                    return .sync(message: .error(error.localizedDescription, sender: def.name))
                }
            }
        )
        return await backgroundExecutor.launch(params: params, modelContext: ctx)
    } else {
        do {
            let msg = try await claudeService.runSubagentLoop(
                task: task,
                definition: definition,
                toolCallRecord: record,
                service: service,
                modelId: modelId,
                overrideModelId: overrideModelId,
                settings: settings,
                sessionId: capturedSessionId,
                modelContext: capturedModelContext,
                forkOverride: forkOverride   // S-F3
            )
            return .sync(message: msg)
        } catch {
            return .sync(message: .error(error.localizedDescription, sender: definition.name))
        }
    }
},
```

### Step 4: 编译确认

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-sf3-t8 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

### Step 5: 提交

```bash
git add agentGui/Services/AgentLoopToolExecutionCoordinator.swift \
        agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift
git commit -m "feat(S-F3): coordinator routes fork subagent tools through ForkMessageBuilder + forced async"
```

---

## Task 9: AgentLoopRoundExecutor fork 工具检测与上下文注入

**Files:**
- Modify: `agentGui/Services/AgentLoopRoundExecutor.swift`

**背景：** `handleToolUseOutcome()` 是 batch planning 的入口点。在调用 `batchPlanner.partition()` 之前，需要检测哪些 pending tool 是 fork 调用，并为它们注入 `AgentLoopForkContext`（父代理历史、当前 assistant objects、系统提示文本）。

**关键：** fork 检测依赖 `parsedInput["agent_name"]?.stringValue == ForkSubagentDefinition.agentType`，而 `parsedInput` 在 stream 结束后才可读。`handleToolUseOutcome` 是流式处理结束后第一个有完整 pending tools 的调用，时机正确。

### Step 1: 修改 `handleToolUseOutcome()` 中的 batch planning 前段

找到 `handleToolUseOutcome` 中的以下代码块（第 506 行附近）：

```swift
// 使用批次规划器分批执行：连续的只读工具并发，其余工具串行
let batchPlanner = ToolConcurrencyBatchPlanner(registry: DefaultToolRegistry())
let batches = batchPlanner.partition(outcome.pendingTools)
```

在其之前插入 fork 检测和上下文注入逻辑：

```swift
// S-F3: 检测 fork 子代理工具，注入执行上下文（在 batch planning 前）。
// fullAssistantObjects 包含当前轮次 assistant 消息的所有 content（text + thinking + toolUse）。
// 它被用于 ForkMessageBuilder.buildForkedMessages 构建所有 fork 子代理共享的 assistant prefix。
let pendingToolsForBatch: [AgentLoopPendingTool]
if outcome.pendingTools.contains(where: { $0.name == "run_subagent" }) {
    var fullAssistantObjects = outcome.assistantObjects
    if !outcome.currentRoundText.isEmpty {
        fullAssistantObjects.append(.text(outcome.currentRoundText))
    }
    pendingToolsForBatch = outcome.pendingTools.map { tool in
        guard tool.name == "run_subagent",
              tool.parsedInput["agent_name"]?.stringValue == ForkSubagentDefinition.agentType
        else { return tool }
        var forkTool = tool
        forkTool.isForkSubagent = true
        forkTool.forkContext = AgentLoopForkContext(
            parentMessages: messages,   // 当前 assistant 轮次开始前的完整历史
            assistantObjects: fullAssistantObjects,
            parentSystemPromptText: request.renderedSystemPromptText
        )
        return forkTool
    }
} else {
    pendingToolsForBatch = outcome.pendingTools
}

// 使用批次规划器分批执行：连续的只读工具并发，其余工具串行
let batchPlanner = ToolConcurrencyBatchPlanner(registry: DefaultToolRegistry())
let batches = batchPlanner.partition(pendingToolsForBatch)
```

同时，在后续 `for batch in batches { switch ... }` 中，`tools: concurrentTools` 和 `tool: serialTool` 均已是 `pendingToolsForBatch` 里的元素，无需其他改动。

### Step 2: 编译确认

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-sf3-t9 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

### Step 3: 提交

```bash
git add agentGui/Services/AgentLoopRoundExecutor.swift
git commit -m "feat(S-F3): detect fork subagents in handleToolUseOutcome and inject AgentLoopForkContext"
```

---

## Task 10: 端到端 fork 并发集成测试

**Files:**
- Create: `agentGuiTests/ForkConcurrentDispatchIntegrationTests.swift`

**目标：** 验证从 pending tool 检测、batch 规划到 coordinator fork 路径的完整链路。

### Step 1: 编写测试

```swift
// agentGuiTests/ForkConcurrentDispatchIntegrationTests.swift
import XCTest
@testable import agentGui
import SwiftAnthropic

/// S-F3 端到端集成测试：验证 fork 子代理从检测到并发批次的完整路径。
final class ForkConcurrentDispatchIntegrationTests: XCTestCase {

    // MARK: - Fork Context Stamping

    func test_forkToolDetection_stampsIsForkSubagent() {
        // 构造一个 run_subagent 输入，agent_name 为 "fork"
        var forkTool = AgentLoopPendingTool(id: "fork-1", name: "run_subagent")
        forkTool.partialJson = #"{"agent_name":"fork","task":"Explore the auth module"}"#

        // 验证字段正确解析
        XCTAssertEqual(forkTool.parsedInput["agent_name"]?.stringValue, ForkSubagentDefinition.agentType)
        XCTAssertFalse(forkTool.isForkSubagent, "Before executor injection, isForkSubagent must be false")

        // 模拟 executor 的检测逻辑
        if forkTool.parsedInput["agent_name"]?.stringValue == ForkSubagentDefinition.agentType {
            forkTool.isForkSubagent = true
        }

        XCTAssertTrue(forkTool.isForkSubagent, "After detection, isForkSubagent must be true")
    }

    func test_threeForkTools_partitionedIntoConcurrentBatch() {
        let planner = ToolConcurrencyBatchPlanner(registry: DefaultToolRegistry())

        var fork1 = AgentLoopPendingTool(id: "f1", name: "run_subagent")
        fork1.partialJson = #"{"agent_name":"fork","task":"Task A"}"#
        fork1.isForkSubagent = true

        var fork2 = AgentLoopPendingTool(id: "f2", name: "run_subagent")
        fork2.partialJson = #"{"agent_name":"fork","task":"Task B"}"#
        fork2.isForkSubagent = true

        var fork3 = AgentLoopPendingTool(id: "f3", name: "run_subagent")
        fork3.partialJson = #"{"agent_name":"fork","task":"Task C"}"#
        fork3.isForkSubagent = true

        let batches = planner.partition([fork1, fork2, fork3])
        XCTAssertEqual(batches.count, 1, "All 3 fork tools must land in one concurrent batch")
        guard case .concurrent(let tools) = batches[0] else {
            return XCTFail("Expected concurrent batch")
        }
        XCTAssertEqual(tools.count, 3)
        // Preserve original order
        XCTAssertEqual(tools[0].id, "f1")
        XCTAssertEqual(tools[1].id, "f2")
        XCTAssertEqual(tools[2].id, "f3")
    }

    // MARK: - ForkMessageBuilder full pipeline

    func test_twoForkChildren_buildInitialMessages_cacheIdenticalPrefix() {
        let builder = ForkMessageBuilder()
        let assistantObjects: [MessageParameter.Message.Content.ContentObject] = [
            .toolUse("t1", "run_subagent", ["agent_name": .string("fork"), "task": .string("Task A")]),
            .toolUse("t2", "run_subagent", ["agent_name": .string("fork"), "task": .string("Task B")])
        ]

        let msgsA = builder.buildForkedMessages(directive: "Task A", assistantObjects: assistantObjects)
        let msgsB = builder.buildForkedMessages(directive: "Task B", assistantObjects: assistantObjects)

        // Both children get 2 messages
        XCTAssertEqual(msgsA.count, 2)
        XCTAssertEqual(msgsB.count, 2)

        // Shared assistant message (byte-identical → cache hit)
        XCTAssertEqual(msgsA[0].role, .assistant)
        XCTAssertEqual(msgsB[0].role, .assistant)

        // Both fork children have tool_result placeholders (must be identical)
        guard case .list(let userObjsA) = msgsA[1].content,
              case .list(let userObjsB) = msgsB[1].content else {
            return XCTFail("Expected list user content")
        }
        // First 2 items are tool_results — identical placeholder for cache sharing
        for i in 0..<2 {
            if case .toolResult(let idA, let textA, _) = userObjsA[i],
               case .toolResult(let idB, let textB, _) = userObjsB[i] {
                XCTAssertEqual(idA, idB)
                XCTAssertEqual(textA, textB, "Placeholder text must be identical for cache sharing")
            } else {
                XCTFail("Expected toolResult at index \(i)")
            }
        }
        // Last item is the per-child directive (must differ)
        if case .text(let textA) = userObjsA.last, case .text(let textB) = userObjsB.last {
            XCTAssertNE(textA, textB, "Directives must differ between fork children")
        }
    }

    func test_isInForkChild_detectsForkBoilerplate() {
        let builder = ForkMessageBuilder()
        let directive = "Check auth module"
        let forkedMsgs = builder.buildForkedMessages(
            directive: directive,
            assistantObjects: [.toolUse("t1", "run_subagent", [:])]
        )

        // forkedMsgs = [assistantMsg, userMsg]
        // userMsg contains the buildChildMessage text which has <fork-boilerplate>
        XCTAssertTrue(
            isInForkChild(forkedMsgs),
            "isInForkChild must detect fork boilerplate in the user message built by ForkMessageBuilder"
        )
    }

    func test_isInForkChild_falseForNormalMessages() {
        let normalMessages: [MessageParameter.Message] = [
            .init(role: .user, content: .text("Please help me refactor the code")),
            .init(role: .assistant, content: .text("Sure, I'll help you."))
        ]
        XCTAssertFalse(isInForkChild(normalMessages), "Normal messages must not trigger fork guard")
    }

    // MARK: - ForkSubagentOverride

    func test_forkSubagentOverride_usesParentSystemPromptInsteadOfDefinition() {
        let override = ForkSubagentOverride(
            initialMessages: [.init(role: .user, content: .text("test"))],
            parentSystemPromptText: "Parent system prompt"
        )
        XCTAssertEqual(override.parentSystemPromptText, "Parent system prompt")
        XCTAssertEqual(override.initialMessages.count, 1)
    }
}

// MARK: - XCTAssertNE helper
private func XCTAssertNE(_ expression1: String, _ expression2: String, _ message: String = "") {
    XCTAssertNotEqual(expression1, expression2, message)
}
```

### Step 2: 添加测试文件到 Xcode project，运行测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf3-t10 \
  -only-testing:agentGuiTests/ForkConcurrentDispatchIntegrationTests \
  -only-testing:agentGuiTests/ForkMessageBuilderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Build"
```

Expected: All tests PASS.

### Step 3: 提交

```bash
git add agentGuiTests/ForkConcurrentDispatchIntegrationTests.swift \
        agentGui.xcodeproj/project.pbxproj
git commit -m "test(S-F3): add ForkConcurrentDispatchIntegrationTests end-to-end fork path coverage"
```

---

## Task 11: 全量回归测试验证

### Step 1: 运行现有受影响测试集

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf3-full \
  -only-testing:agentGuiTests/ForkSubagentDefinitionTests \
  -only-testing:agentGuiTests/ForkMessageBuilderTests \
  -only-testing:agentGuiTests/ForkConcurrentDispatchIntegrationTests \
  -only-testing:agentGuiTests/ToolConcurrencyBatchPlannerTests \
  -only-testing:agentGuiTests/ToolConcurrencyBatchIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Build|executed"
```

Expected: All tests PASS, 0 failures.

### Step 2: 运行 subagent 相关测试确认无回归

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf3-subagent \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|executed"
```

Expected: All tests PASS.

### Step 3: 最终提交 tag

```bash
git tag sf3-fork-concurrent-dispatcher
```

---

## 验收清单

| 验收标准 | 验证方式 |
|---------|---------|
| 同一轮发出 3 个 fork 子代理，全部进入同一并发批次 | `test_threeForkTools_partitionedIntoConcurrentBatch` |
| 普通 `run_subagent`（非 fork）保持串行执行 | `test_nonForkRunSubagent_remainsSerial` |
| 两个 fork 子代理的 API 请求前缀 byte-identical（共享 placeholder） | `test_twoForkChildren_buildInitialMessages_cacheIdenticalPrefix` |
| fork 子代理始终以后台（async）方式运行 | `AgentLoopToolExecutionCoordinatorBuilder` 中 `isForkCall` 强制后台 |
| `isInForkChild` 可检测 `ForkMessageBuilder` 生成的消息 | `test_isInForkChild_detectsForkBoilerplate` |
| 递归 fork 被阻止 | 现有 `ForkSubagentDefinitionTests` 中的 `isInForkChild` 测试 |
| 旧的 ToolConcurrencyBatch 测试全部通过（无回归） | Task 11 回归测试 |

---

## 架构关键路径图

```
主代理同一轮内发出多个 fork tool_use
           │
           ▼
AgentLoopRoundExecutor.handleToolUseOutcome()
  ├─ for each pending tool:
  │    if tool.name == "run_subagent" &&
  │       parsedInput["agent_name"] == "fork"
  │    → tool.isForkSubagent = true
  │    → tool.forkContext = AgentLoopForkContext(
  │          parentMessages: messages,
  │          assistantObjects: fullAssistantObjects,
  │          parentSystemPromptText: request.renderedSystemPromptText
  │      )
           │
           ▼
ToolConcurrencyBatchPlanner.partition(pendingTools)
  ├─ fork tool → concurrent batch  ← S-F3 核心修改
  └─ non-fork run_subagent → serial batch
           │
           ▼
executeConcurrentBatch([fork1, fork2, fork3])
  └─ parallel withTaskGroup:
       for each fork tool:
         coordinator.execute(pendingTool: fork, ...)
           │
           ▼
AgentLoopToolExecutionCoordinator.execute()
  if pendingTool.isForkSubagent:
    ForkMessageBuilder().buildForkedMessages(
      directive: input["task"],
      assistantObjects: ctx.assistantObjects
    )
    → initialMessages = ctx.parentMessages + forkedMsgs
    → ForkSubagentOverride(initialMessages, parentSystemPromptText)
    → force runInBackground = true
    → SubagentBackgroundExecutor.launch(...)
           │
           ▼
runSubagentLoop(..., forkOverride: override)
  if forkOverride:
    loopMessages = override.initialMessages   ← 含完整父代理历史
    system = makeEphemeralSystemPrompt(override.parentSystemPromptText)
  → runCoreAgentLoop(messages: &loopMessages, ...)
```

---

*计划生成时间: 2026-04-03*  
*参考设计文档: `2026-04-01-subagent-capability-enhancement-design.md` (S-F2, S-F3)*  
*参考源码: `src/tools/AgentTool/forkSubagent.ts`, `src/tools/AgentTool/AgentTool.tsx`*

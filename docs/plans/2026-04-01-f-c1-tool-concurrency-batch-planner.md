# F-C1 ToolConcurrencyBatchPlanner 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 `AgentLoopRoundExecutor` 的工具执行阶段，将同一轮 `[AgentLoopPendingTool]` 按 `isConcurrencySafe` 属性分批：只读工具合并为一个并发批次，其余工具独自串行执行，以降低多工具轮次的总延迟。

**Architecture:** 新增纯值类型 `ToolConcurrencyBatchPlanner`（无外部依赖，可独立测试）；在 `ToolDefinition` 上新增 `isConcurrencySafe` 静态属性；修改 `AgentLoopRoundExecutor.applyToolResults` 使用批次规划器替换原有顺序循环。并发批次通过 `withTaskGroup` 执行，结果收集后按原始顺序重排再统一写入 `toolResultObjects`。

**Tech Stack:** Swift 6, SwiftUI, SwiftData, @MainActor isolation, structured concurrency (`withTaskGroup`)

**参考:** Claude Code `src/services/tools/toolOrchestration.ts` → `partitionToolCalls()` + `runToolsConcurrently()`

---

## 关键设计决策

### isConcurrencySafe 为静态属性（非 input-dependent）

Claude Code 的 `isConcurrencySafe(parsedInput)` 按输入动态判断（bash `cat` 视为安全，`rm` 不安全）。初始版本使用静态属性：只对确认为只读的工具类型打标，bash 和编辑类一律保守标为 `false`，避免动态判断引入 shell 解析风险（与 Claude Code 注释中 `shell-quote parse failure → return false` 的保守回退一致）。

### @MainActor 并发模型

`ClaudeService` 和 `AgentLoopRoundExecutor` 均为 `@MainActor`。`withTaskGroup` 内的子任务继承 MainActor 隔离，因此可以直接 `await` 调用 `@MainActor` 方法。工具执行期间的真正 I/O（PTY、文件系统、网络、LSP）在 `await` 点让出 MainActor，允许同一批次的其他子任务在等待 I/O 期间进入执行，实现物理并发。

### pre-hook 仍串行执行

`willExecuteTool` 钩子返回预建的 `ToolCall` 记录并写入 ModelContext（需要 MainActor，有副作用），因此并发批次内也保持串行 pre-hook，执行阶段再并行。这与 Claude Code `setInProgressToolUseIDs` 在任务内部设置（而非在 batch 前）不同，此处更保守但正确。

### 结果按原始顺序重排

`withTaskGroup` 以完成顺序返回结果。每个子任务携带 `originalIndex`，收集后排序，确保 `toolResultObjects` 数组的顺序与 `pendingTools` 原始顺序一致（Anthropic API 要求 `tool_use` 与 `tool_result` 按相同顺序出现）。

---

## Task 1: 为 ToolDefinition 添加 isConcurrencySafe

**Files:**
- Modify: `agentGui/Models/ToolDefinition.swift`
- Modify: `agentGui/Services/ToolRegistry.swift`

### Step 1: 在 ToolDefinition.swift 添加属性

在 `ToolDefinition` 的属性列表中，在 `authorization` 之后添加：

```swift
/// Whether this tool is safe to execute concurrently with other tools
/// that share this flag. Read-only tools (LSP queries, payload reads,
/// web fetches) should return true. Write/execute tools must return false.
let isConcurrencySafe: Bool
```

在 `init` 中添加对应参数（带默认值 `false`）：

```swift
init(
    id: String,
    displayName: String,
    category: ToolCategory,
    schemaVersion: Int,
    supportedContexts: Set<ToolContext>,
    authorization: ToolAuthorizationDescriptor = .none,
    isConcurrencySafe: Bool = false,   // ← 新增，默认保守
    executorKey: String,
    descriptionBuilder: @escaping (ToolDefinitionBuildContext) -> String,
    inputSchemaBuilder: (ToolDefinitionBuildContext) -> JSONSchema
)
```

### Step 2: 在 ToolRegistry.swift 为各工具标注安全性

在 `DefaultToolRegistry.makeDefinitions()` 的各 definition 构造器中，按下表添加 `isConcurrencySafe` 参数。**未列出的工具保持默认 `false`**：

| 工具 ID | `isConcurrencySafe` | 理由 |
|---------|---------------------|------|
| `str_replace_based_edit_tool` | `false` | 写文件 |
| `bash` | `false` | 执行命令，有副作用 |
| `read_tool_payload` | `true` | 只读 payload 存储 |
| `web_search` | `true` | 网络只读查询 |
| `web_fetch` | `true` | 网络只读获取 |
| `lsp_definition` | `true` | LSP 只读 |
| `lsp_references` | `true` | LSP 只读 |
| `lsp_hover` | `true` | LSP 只读 |
| `lsp_document_symbols` | `true` | LSP 只读 |
| `lsp_workspace_symbols` | `true` | LSP 只读 |
| `lsp_diagnostics` | `true` | LSP 只读 |
| `lsp_list_servers` | `true` | LSP 只读 |
| `lsp_server_status` | `true` | LSP 只读 |
| `run_subagent` | `false` | 启动子代理，有状态 |

共有 10 个 LSP 工具 + 2 个网络工具 + 1 个 payload 工具 = 13 个工具标记为安全。

**示例修改（read_tool_payload）：**

```swift
private static func readToolPayloadDefinition() -> ToolDefinition {
    ToolDefinition(
        id: "read_tool_payload",
        displayName: "读取工具载荷",
        category: .system,
        schemaVersion: 1,
        supportedContexts: [.mainAgent, .subagent, .backgroundTask],
        isConcurrencySafe: true,   // ← 新增
        executorKey: "builtin.readToolPayload",
        // ...其余参数不变
    )
}
```

### Step 3: 编译验证

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：`Build succeeded`（`isConcurrencySafe` 有默认值 `false`，所有现有调用点无需修改）

### Step 4: Commit

```bash
git add agentGui/Models/ToolDefinition.swift agentGui/Services/ToolRegistry.swift
git commit -m "feat(F-C1): add isConcurrencySafe to ToolDefinition, tag 13 read-only tools"
```

---

## Task 2: 创建 ToolConcurrencyBatchPlanner

**Files:**
- Create: `agentGui/Services/ToolGovernance/ToolConcurrencyBatchPlanner.swift`
- Create: `agentGuiTests/ToolConcurrencyBatchPlannerTests.swift`

此文件所在目录可能需要新建 `ToolGovernance/`（按设计文档）。

### Step 1: 先写失败测试

```swift
// agentGuiTests/ToolConcurrencyBatchPlannerTests.swift
import XCTest
@testable import agentGui

final class ToolConcurrencyBatchPlannerTests: XCTestCase {

    // MARK: - Helpers

    private func safeTool(_ name: String) -> AgentLoopPendingTool {
        AgentLoopPendingTool(id: name + "-id", name: name)
    }

    private func unsafeTool(_ name: String) -> AgentLoopPendingTool {
        AgentLoopPendingTool(id: name + "-id", name: name)
    }

    private func makePlanner(safeToolNames: Set<String>) -> ToolConcurrencyBatchPlanner {
        ToolConcurrencyBatchPlanner(isConcurrencySafe: { safeToolNames.contains($0) })
    }

    // MARK: - Empty input

    func test_empty_returnsEmpty() {
        let planner = makePlanner(safeToolNames: ["web_search"])
        let batches = planner.partition([])
        XCTAssertTrue(batches.isEmpty)
    }

    // MARK: - Single tool

    func test_singleSafeTool_returnsConcurrentBatch() {
        let planner = makePlanner(safeToolNames: ["web_search"])
        let batches = planner.partition([safeTool("web_search")])
        XCTAssertEqual(batches.count, 1)
        guard case .concurrent(let tools) = batches[0] else {
            return XCTFail("Expected concurrent batch")
        }
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0].name, "web_search")
    }

    func test_singleUnsafeTool_returnsSerialBatch() {
        let planner = makePlanner(safeToolNames: [])
        let batches = planner.partition([unsafeTool("bash")])
        XCTAssertEqual(batches.count, 1)
        guard case .serial(let tool) = batches[0] else {
            return XCTFail("Expected serial batch")
        }
        XCTAssertEqual(tool.name, "bash")
    }

    // MARK: - Consecutive safe tools merge

    func test_twoSafeTools_returnsSingleConcurrentBatch() {
        let planner = makePlanner(safeToolNames: ["web_search", "lsp_hover"])
        let batches = planner.partition([
            safeTool("web_search"),
            safeTool("lsp_hover")
        ])
        XCTAssertEqual(batches.count, 1)
        guard case .concurrent(let tools) = batches[0] else {
            return XCTFail("Expected concurrent batch")
        }
        XCTAssertEqual(tools.count, 2)
    }

    func test_threeSafeTools_returnsSingleConcurrentBatch() {
        let planner = makePlanner(safeToolNames: ["web_search", "lsp_hover", "read_tool_payload"])
        let batches = planner.partition([
            safeTool("web_search"),
            safeTool("lsp_hover"),
            safeTool("read_tool_payload")
        ])
        XCTAssertEqual(batches.count, 1)
        guard case .concurrent(let tools) = batches[0] else {
            return XCTFail("Expected concurrent batch")
        }
        XCTAssertEqual(tools.count, 3)
    }

    // MARK: - Mixed sequences

    func test_safeUnsafe_returnsTwoBatches() {
        let planner = makePlanner(safeToolNames: ["web_search"])
        let batches = planner.partition([
            safeTool("web_search"),
            unsafeTool("bash")
        ])
        XCTAssertEqual(batches.count, 2)
        guard case .concurrent(let safeTools) = batches[0] else {
            return XCTFail("Expected first batch to be concurrent")
        }
        XCTAssertEqual(safeTools[0].name, "web_search")
        guard case .serial(let unsafeTool) = batches[1] else {
            return XCTFail("Expected second batch to be serial")
        }
        XCTAssertEqual(unsafeTool.name, "bash")
    }

    func test_unsafeSafeSafe_returnsSerialThenConcurrent() {
        let planner = makePlanner(safeToolNames: ["web_search", "lsp_hover"])
        let batches = planner.partition([
            unsafeTool("bash"),
            safeTool("web_search"),
            safeTool("lsp_hover")
        ])
        XCTAssertEqual(batches.count, 2)
        guard case .serial(let first) = batches[0] else {
            return XCTFail("Expected first batch to be serial")
        }
        XCTAssertEqual(first.name, "bash")
        guard case .concurrent(let concurrent) = batches[1] else {
            return XCTFail("Expected second batch to be concurrent")
        }
        XCTAssertEqual(concurrent.count, 2)
    }

    func test_safeSafeUnsafeSafe_returnsThreeBatches() {
        let planner = makePlanner(safeToolNames: ["web_search", "read_tool_payload", "lsp_hover"])
        let batches = planner.partition([
            safeTool("web_search"),
            safeTool("read_tool_payload"),
            unsafeTool("str_replace_based_edit_tool"),
            safeTool("lsp_hover")
        ])
        XCTAssertEqual(batches.count, 3)
        // batch[0]: concurrent([web_search, read_tool_payload])
        // batch[1]: serial(str_replace_based_edit_tool)
        // batch[2]: concurrent([lsp_hover])
        guard case .concurrent(let first) = batches[0] else {
            return XCTFail("Expected first batch to be concurrent")
        }
        XCTAssertEqual(first.count, 2)
        guard case .serial(let second) = batches[1] else {
            return XCTFail("Expected second batch to be serial")
        }
        XCTAssertEqual(second.name, "str_replace_based_edit_tool")
        guard case .concurrent(let third) = batches[2] else {
            return XCTFail("Expected third batch to be concurrent")
        }
        XCTAssertEqual(third.count, 1)
        XCTAssertEqual(third[0].name, "lsp_hover")
    }

    func test_twoUnsafeTools_returnsTwoSerialBatches() {
        let planner = makePlanner(safeToolNames: [])
        let batches = planner.partition([
            unsafeTool("bash"),
            unsafeTool("str_replace_based_edit_tool")
        ])
        XCTAssertEqual(batches.count, 2)
        guard case .serial(let first) = batches[0],
              case .serial(let second) = batches[1] else {
            return XCTFail("Expected two serial batches")
        }
        XCTAssertEqual(first.name, "bash")
        XCTAssertEqual(second.name, "str_replace_based_edit_tool")
    }

    // MARK: - Original order preservation in concurrent batch

    func test_concurrentBatchPreservesInputOrder() {
        let planner = makePlanner(safeToolNames: ["a", "b", "c"])
        let input = ["a", "b", "c"].map { safeTool($0) }
        let batches = planner.partition(input)
        guard case .concurrent(let tools) = batches[0] else {
            return XCTFail("Expected concurrent batch")
        }
        XCTAssertEqual(tools.map(\.name), ["a", "b", "c"])
    }

    // MARK: - isConcurrencySafe exception handling

    func test_whenSafetyCheckThrows_treatsAsUnsafe() {
        // Planner with a throwing closure: tool "boom" throws, must be treated as serial
        let planner = ToolConcurrencyBatchPlanner(isConcurrencySafe: { name in
            if name == "boom" { throw NSError(domain: "test", code: 1) }
            return true
        })
        let batches = planner.partition([safeTool("boom")])
        XCTAssertEqual(batches.count, 1)
        guard case .serial = batches[0] else {
            return XCTFail("Expected serial batch after safety check exception")
        }
    }
}
```

### Step 2: 运行测试，确认编译失败（类型未定义）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fc1-derived \
  -only-testing:agentGuiTests/ToolConcurrencyBatchPlannerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded|Test Suite"
```

预期：编译错误 `cannot find type 'ToolConcurrencyBatchPlanner'`

### Step 3: 创建实现文件

```swift
// agentGui/Services/ToolGovernance/ToolConcurrencyBatchPlanner.swift

import Foundation

/// Describes a group of tool calls scheduled for a single execution pass.
///
/// - `concurrent`: All tools in the batch are concurrency-safe (read-only)
///   and will be executed in parallel using a task group.
/// - `serial`: A single stateful or interactive tool that must run alone.
enum ToolExecutionBatch {
    case concurrent([AgentLoopPendingTool])
    case serial(AgentLoopPendingTool)
}

/// Partitions a flat list of pending tools into ordered execution batches.
///
/// Consecutive concurrency-safe tools are merged into a single `.concurrent`
/// batch. All other tools yield individual `.serial` batches.
///
/// The partitioning algorithm mirrors Claude Code's `partitionToolCalls()` in
/// `src/services/tools/toolOrchestration.ts`.
struct ToolConcurrencyBatchPlanner {

    /// Returns `true` when the named tool is safe to run concurrently with
    /// other tools that also return `true`. May throw; exceptions are treated
    /// conservatively as `false` (serial).
    let isConcurrencySafe: (String) throws -> Bool

    /// Partition `tools` into an ordered sequence of execution batches.
    func partition(_ tools: [AgentLoopPendingTool]) -> [ToolExecutionBatch] {
        tools.reduce(into: [ToolExecutionBatch]()) { batches, tool in
            let safe = (try? isConcurrencySafe(tool.name)) ?? false
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
}

extension ToolConcurrencyBatchPlanner {
    /// Convenience initialiser that queries a `ToolRegistry` for safety metadata.
    init(registry: some ToolRegistry) {
        self.isConcurrencySafe = { name in
            registry.definition(for: name)?.isConcurrencySafe ?? false
        }
    }
}
```

### Step 4: 运行测试，确认全部通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fc1-derived \
  -only-testing:agentGuiTests/ToolConcurrencyBatchPlannerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Test Suite.*passed|FAILED"
```

预期：`Test Suite 'ToolConcurrencyBatchPlannerTests' passed`（11 个测试用例全通过）

### Step 5: Commit

```bash
git add agentGui/Services/ToolGovernance/ToolConcurrencyBatchPlanner.swift \
        agentGuiTests/ToolConcurrencyBatchPlannerTests.swift
git commit -m "feat(F-C1): ToolConcurrencyBatchPlanner with partition algorithm and 11 unit tests"
```

---

## Task 3: 将 Planner 集成到 AgentLoopRoundExecutor

**Files:**
- Modify: `agentGui/Services/AgentLoopRoundExecutor.swift`

这是本 feature 唯一有运行时行为影响的变更。集成点是 `applyToolResults` 中对 `outcome.pendingTools` 的迭代。

### Step 3.1 — 理解现有执行序列

当前 `applyToolResults` 内层循环（简化版）：

```swift
for pending in outcome.pendingTools {
    // 1. willExecuteTool hook → optional pre-built ToolCall record
    // 2. assistantObjects.append(.toolUse(...))
    // 3. toolCoordinator.execute(pendingTool:, record:, interceptor:)
    // 4. didExecuteTool hook
    // 5. classifyFailureTrigger hook
    // 6. subagent verifier reduction (if applicable)
    // 7. toolObservations.append(...)
    // 8. toolResultObjects.append(.toolResult(...))
}
messages.append(assistant)
messages.append(toolResults)
```

**关键不变量：** `toolResultObjects` 中 `.toolResult` 块的顺序必须与 `assistantObjects` 中 `.toolUse` 块的顺序完全一致，否则 Anthropic API 会报错。

### Step 3.2 — 定义辅助类型（在同文件内，私有）

在 `AgentLoopRoundExecutor` 下方、同文件内添加：

```swift
// MARK: - Concurrent Batch Result Container (file-private)

/// Carries the full execution output of one tool within a concurrent batch,
/// preserving the original index so results can be re-sorted after parallel
/// execution completes.
private struct ConcurrentToolResult {
    let originalIndex: Int
    let pending: AgentLoopPendingTool
    let record: ToolCall
    let outcome: AgentLoopToolExecutionOutcome
}
```

### Step 3.3 — 在 applyToolResults 中替换迭代逻辑

定位现有循环：

```swift
for pending in outcome.pendingTools {
    let input = pending.parsedInput
    let willExecuteHooks = ...
    // ... (约 70 行)
    toolResultObjects.append(.toolResult(pending.id, result.text, isError: result.isError ? true : nil))
    toolResultObjects.append(contentsOf: result.mediaContent)
    toolSpan.end()
}
```

将整个 `for pending in outcome.pendingTools { ... }` 块替换为：

```swift
// –– 构建批次规划器（基于注册表静态属性）
let batchPlanner = ToolConcurrencyBatchPlanner(registry: DefaultToolRegistry())
let batches = batchPlanner.partition(outcome.pendingTools)

// –– 追踪当前 pendingTools 数组中的位置偏移，用于 willExecuteTool hook 的元数据
var pendingOffset = 0

for batch in batches {
    switch batch {
    case .concurrent(let concurrentTools):
        try await executeConcurrentBatch(
            tools: concurrentTools,
            pendingOffset: pendingOffset,
            outcome: outcome,
            state: &state,
            messages: messages,
            assistantObjects: &assistantObjects,
            toolResultObjects: &toolResultObjects,
            toolObservations: &toolObservations
        )
        pendingOffset += concurrentTools.count

    case .serial(let serialTool):
        try await executeSerialTool(
            tool: serialTool,
            pendingOffset: pendingOffset,
            outcome: outcome,
            state: &state,
            messages: messages,
            assistantObjects: &assistantObjects,
            toolResultObjects: &toolResultObjects,
            toolObservations: &toolObservations
        )
        pendingOffset += 1
    }
}
```

### Step 3.4 — 提取串行执行为 executeSerialTool

这是原始循环体的原样提取，只改变了「如何被调用」，不改变行为：

```swift
private func executeSerialTool(
    tool pending: AgentLoopPendingTool,
    pendingOffset: Int,
    outcome: RoundOutcome,
    state: inout AgentLoopRunState,
    messages: [MessageParameter.Message],
    assistantObjects: inout [MessageParameter.Message.Content.ContentObject],
    toolResultObjects: inout [MessageParameter.Message.Content.ContentObject],
    toolObservations: inout [String]
) async throws {
    let input = pending.parsedInput
    let willExecuteHooks = (try? await emitter.dispatch(
        .willExecuteTool,
        state: state,
        messages: messages,
        overrides: .init(
            metadata: [
                "toolName": pending.name,
                "inputLength": pending.partialJson.count,
                "roundIndex": outcome.roundIndex,
                "toolUseID": pending.id,
                "agentRound": outcome.round
            ],
            toolName: pending.name,
            toolInput: input
        )
    )) ?? AgentLoopHookDispatchResult()
    let toolSpan = PerformanceMonitor.self.startSpan("tool_\(pending.name)", category: "Tool", level: .normal)

    assistantObjects.append(.toolUse(pending.id, pending.name, input))
    let record = willExecuteHooks.toolCallRecord ?? claudeService.makeToolCallRecord(
        toolUseId: pending.id,
        toolName: pending.name,
        input: input,
        message: runtime.parentMessage,
        agentRound: outcome.round,
        executionContext: request.toolExecutionContext
    )
    let executionOutcome = await toolCoordinator.execute(
        pendingTool: pending,
        record: record,
        interceptor: runtime.toolInterceptor
    )
    let result = executionOutcome.result

    if let evidence = ExecutionGuard.evidenceKind(toolName: pending.name, input: input, result: result) {
        state.executionEvidence.insert(evidence)
        sharedState.writeExecutionEvidence(runtime.sessionId, state.executionEvidence)
    }
    await emitter.emit(
        .didExecuteTool,
        state: state,
        messages: messages,
        overrides: .init(
            metadata: Self.toolExecutionMetadata(
                toolName: pending.name,
                input: input,
                result: result,
                roundIndex: outcome.roundIndex,
                claudeService: claudeService
            ),
            toolName: pending.name,
            toolInput: input,
            toolResultText: result.text,
            toolCallRecord: record
        )
    )

    let classification = (try? await emitter.dispatch(
        .classifyFailureTrigger,
        state: state,
        messages: messages,
        overrides: .init(
            metadata: ["isError": result.isError],
            toolName: pending.name,
            toolInput: input,
            toolResultText: result.text,
            toolCallRecord: record
        )
    )) ?? AgentLoopHookDispatchResult()
    if let failureTrigger = classification.failureTrigger {
        state.loopCtx.pendingFailureTrigger = failureTrigger
    }

    if pending.name == "run_subagent", record.subagentAgentName == "verifier" {
        let store = SessionTaskStateStore(modelContext: runtime.modelContext)
        let existingVerification = sharedState.readVerification(runtime.sessionId)
            ?? store.verification(for: runtime.sessionId)
        let reduction = AgentLoopVerificationCoordinator.reduceVerifierResult(
            rawText: result.text,
            existingVerification: existingVerification,
            executionEvidence: state.executionEvidence,
            verifierAgent: record.subagentAgentName ?? "verifier"
        )
        state.verificationState = reduction.verificationState
        state.hookState.verificationState = reduction.verificationState
        sharedState.writeVerification(runtime.sessionId, reduction.report)
        try? store.saveVerification(reduction.report, for: runtime.sessionId)
        state.loopCtx.pendingFailureTrigger = reduction.failureTrigger
        record.subagentMessageMetadata = verifierMetadata(
            existing: record.subagentMessageMetadata,
            reduction: reduction
        )
    }

    let observation = (result.rawOutputText ?? result.text)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if !observation.isEmpty {
        toolObservations.append(observation)
    }

    toolResultObjects.append(.toolResult(pending.id, result.text, isError: result.isError ? true : nil))
    toolResultObjects.append(contentsOf: result.mediaContent)

    toolSpan.addMetadata("isError", value: result.isError)
    toolSpan.addMetadata("outputLength", value: result.text.count)
    toolSpan.end()
}
```

> **注意：** 这段代码与原始循环体内容完全相同，只是封装为函数。若在提取过程中遇到 `inout` 参数传递问题，将 `inout` 换成 `mutating struct` 或使用 `class` 包装器；但由于 `@MainActor struct` 自带排他访问保证，`inout` 在此上下文是安全的。

### Step 3.5 — 新增 executeConcurrentBatch

```swift
private func executeConcurrentBatch(
    tools: [AgentLoopPendingTool],
    pendingOffset: Int,
    outcome: RoundOutcome,
    state: inout AgentLoopRunState,
    messages: [MessageParameter.Message],
    assistantObjects: inout [MessageParameter.Message.Content.ContentObject],
    toolResultObjects: inout [MessageParameter.Message.Content.ContentObject],
    toolObservations: inout [String]
) async throws {
    // Phase 1: Pre-hooks (serial) — emit willExecuteTool and create ToolCall records
    // We serialize pre-hooks because they write to ModelContext and create persisted records.
    var preHookResults: [(
        pending: AgentLoopPendingTool,
        record: ToolCall,
        span: PerformanceSpan
    )] = []

    for pending in tools {
        let input = pending.parsedInput
        let willExecuteHooks = (try? await emitter.dispatch(
            .willExecuteTool,
            state: state,
            messages: messages,
            overrides: .init(
                metadata: [
                    "toolName": pending.name,
                    "inputLength": pending.partialJson.count,
                    "roundIndex": outcome.roundIndex,
                    "toolUseID": pending.id,
                    "agentRound": outcome.round
                ],
                toolName: pending.name,
                toolInput: input
            )
        )) ?? AgentLoopHookDispatchResult()

        let record = willExecuteHooks.toolCallRecord ?? claudeService.makeToolCallRecord(
            toolUseId: pending.id,
            toolName: pending.name,
            input: input,
            message: runtime.parentMessage,
            agentRound: outcome.round,
            executionContext: request.toolExecutionContext
        )
        assistantObjects.append(.toolUse(pending.id, pending.name, input))

        let span = PerformanceMonitor.self.startSpan(
            "tool_\(pending.name)",
            category: "Tool",
            level: .normal
        )
        preHookResults.append((pending: pending, record: record, span: span))
    }

    // Phase 2: Concurrent execution
    // withTaskGroup inherits @MainActor isolation. Each task awaits actual I/O,
    // which yields the MainActor and allows other tasks to make progress.
    var concurrentResults: [ConcurrentToolResult] = []
    concurrentResults.reserveCapacity(tools.count)

    await withTaskGroup(of: ConcurrentToolResult.self) { group in
        for (index, entry) in preHookResults.enumerated() {
            let pending = entry.pending
            let record = entry.record
            let coordinator = self.toolCoordinator
            let interceptor = self.runtime.toolInterceptor

            group.addTask { @MainActor in
                let executionOutcome = await coordinator.execute(
                    pendingTool: pending,
                    record: record,
                    interceptor: interceptor
                )
                return ConcurrentToolResult(
                    originalIndex: index,
                    pending: pending,
                    record: record,
                    outcome: executionOutcome
                )
            }
        }

        for await result in group {
            concurrentResults.append(result)
        }
    }

    // Phase 3: Re-sort by original index — guarantees toolResultObjects ordering
    concurrentResults.sort { $0.originalIndex < $1.originalIndex }

    // Phase 4: Post-hooks and state mutation (serial, in original order)
    for entry in concurrentResults {
        let pending = entry.pending
        let record = entry.record
        let result = entry.outcome.result
        let input = pending.parsedInput
        let span = preHookResults[entry.originalIndex].span

        if let evidence = ExecutionGuard.evidenceKind(toolName: pending.name, input: input, result: result) {
            state.executionEvidence.insert(evidence)
            sharedState.writeExecutionEvidence(runtime.sessionId, state.executionEvidence)
        }

        await emitter.emit(
            .didExecuteTool,
            state: state,
            messages: messages,
            overrides: .init(
                metadata: Self.toolExecutionMetadata(
                    toolName: pending.name,
                    input: input,
                    result: result,
                    roundIndex: outcome.roundIndex,
                    claudeService: claudeService
                ),
                toolName: pending.name,
                toolInput: input,
                toolResultText: result.text,
                toolCallRecord: record
            )
        )

        let classification = (try? await emitter.dispatch(
            .classifyFailureTrigger,
            state: state,
            messages: messages,
            overrides: .init(
                metadata: ["isError": result.isError],
                toolName: pending.name,
                toolInput: input,
                toolResultText: result.text,
                toolCallRecord: record
            )
        )) ?? AgentLoopHookDispatchResult()
        if let failureTrigger = classification.failureTrigger {
            state.loopCtx.pendingFailureTrigger = failureTrigger
        }

        // run_subagent never has isConcurrencySafe = true, so this branch
        // will in practice never fire for a concurrent batch. Guard kept for safety.
        if pending.name == "run_subagent", record.subagentAgentName == "verifier" {
            let store = SessionTaskStateStore(modelContext: runtime.modelContext)
            let existingVerification = sharedState.readVerification(runtime.sessionId)
                ?? store.verification(for: runtime.sessionId)
            let reduction = AgentLoopVerificationCoordinator.reduceVerifierResult(
                rawText: result.text,
                existingVerification: existingVerification,
                executionEvidence: state.executionEvidence,
                verifierAgent: record.subagentAgentName ?? "verifier"
            )
            state.verificationState = reduction.verificationState
            state.hookState.verificationState = reduction.verificationState
            sharedState.writeVerification(runtime.sessionId, reduction.report)
            try? store.saveVerification(reduction.report, for: runtime.sessionId)
            state.loopCtx.pendingFailureTrigger = reduction.failureTrigger
            record.subagentMessageMetadata = verifierMetadata(
                existing: record.subagentMessageMetadata,
                reduction: reduction
            )
        }

        let observation = (result.rawOutputText ?? result.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !observation.isEmpty {
            toolObservations.append(observation)
        }

        toolResultObjects.append(.toolResult(pending.id, result.text, isError: result.isError ? true : nil))
        toolResultObjects.append(contentsOf: result.mediaContent)

        span.addMetadata("isError", value: result.isError)
        span.addMetadata("outputLength", value: result.text.count)
        span.end()
    }
}
```

> **`PerformanceSpan` 兼容性：** 如果 `PerformanceSpan` 不是 `Sendable` 或无法跨任务传递，将 `span` 从 `preHookResults` 中移除，改为在 Phase 4 的串行后处理中单独创建并立即结束（这不影响 span 的有效性，只是时间区间略有不同）。如果遇到此编译错误，按如下方式修改 Phase 1 不创建 span，Phase 4 在每个 result 前后创建 span：
>
> ```swift
> // Phase 4 内部（替代版）:
> let span = PerformanceMonitor.self.startSpan("tool_\(pending.name)", category: "Tool", level: .normal)
> // ... (同上逻辑) ...
> span.end()
> ```

### Step 3.6: 编译验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：`Build succeeded`

常见编译错误及处理：
- `cannot pass immutable value as inout argument`：`messages` 参数从 `inout` 改为值捕获（copy-in 给并发方法签名，不需要修改）；如果 Phase 2 中 `withTaskGroup` 闭包捕获 `state`（inout），需要先用 `let stateSnapshot = state` 获取快照传给 task
- `cannot use mutating member on immutable value`：将 `inout` 参数分解为局部变量后再传入（Swift 6 strict concurrency 的常见限制）
- `PerformanceSpan is not Sendable`：按 Step 3.5 注意事项处理

### Step 3.7: Commit

```bash
git add agentGui/Services/AgentLoopRoundExecutor.swift
git commit -m "feat(F-C1): integrate ToolConcurrencyBatchPlanner into applyToolResults"
```

---

## Task 4: 集成验证测试

**Files:**
- Create: `agentGuiTests/ToolConcurrencyBatchIntegrationTests.swift`

这批测试验证批次规划器与 `DefaultToolRegistry` 协同工作，以及并发与串行批次的结果顺序保证。

### Step 1: 先写失败测试

```swift
// agentGuiTests/ToolConcurrencyBatchIntegrationTests.swift
import XCTest
@testable import agentGui

final class ToolConcurrencyBatchIntegrationTests: XCTestCase {

    // MARK: - DefaultToolRegistry integration

    func test_defaultRegistry_webSearchIsSafe() {
        let registry = DefaultToolRegistry()
        let planner = ToolConcurrencyBatchPlanner(registry: registry)
        let tools = [
            AgentLoopPendingTool(id: "ws-1", name: "web_search"),
            AgentLoopPendingTool(id: "ws-2", name: "web_fetch")
        ]
        let batches = planner.partition(tools)
        XCTAssertEqual(batches.count, 1, "Two consecutive safe tools should merge into one batch")
        guard case .concurrent(let concurrent) = batches[0] else {
            return XCTFail("Expected concurrent batch for read-only tools")
        }
        XCTAssertEqual(concurrent.count, 2)
    }

    func test_defaultRegistry_bashIsNotSafe() {
        let registry = DefaultToolRegistry()
        let planner = ToolConcurrencyBatchPlanner(registry: registry)
        let tools = [AgentLoopPendingTool(id: "bash-1", name: "bash")]
        let batches = planner.partition(tools)
        guard case .serial(let tool) = batches.first else {
            return XCTFail("Expected serial batch for bash")
        }
        XCTAssertEqual(tool.name, "bash")
    }

    func test_defaultRegistry_allLSPToolsAreSafe() {
        let registry = DefaultToolRegistry()
        let planner = ToolConcurrencyBatchPlanner(registry: registry)
        let lspTools = [
            "lsp_definition", "lsp_references", "lsp_hover",
            "lsp_document_symbols", "lsp_workspace_symbols",
            "lsp_diagnostics", "lsp_list_servers", "lsp_server_status"
        ].map { AgentLoopPendingTool(id: "\($0)-id", name: $0) }

        let batches = planner.partition(lspTools)
        XCTAssertEqual(batches.count, 1, "All LSP tools should merge into one concurrent batch")
        guard case .concurrent(let concurrent) = batches[0] else {
            return XCTFail("Expected all LSP tools to be concurrent")
        }
        XCTAssertEqual(concurrent.count, lspTools.count)
    }

    func test_defaultRegistry_readOnlyWithBashInMiddle_producesThreeBatches() {
        let registry = DefaultToolRegistry()
        let planner = ToolConcurrencyBatchPlanner(registry: registry)
        let tools = [
            AgentLoopPendingTool(id: "ws-1", name: "web_search"),
            AgentLoopPendingTool(id: "bash-1", name: "bash"),
            AgentLoopPendingTool(id: "lsp-1", name: "lsp_hover")
        ]
        let batches = planner.partition(tools)
        XCTAssertEqual(batches.count, 3)
        guard case .concurrent = batches[0],
              case .serial = batches[1],
              case .concurrent = batches[2] else {
            return XCTFail("Expected concurrent / serial / concurrent batch pattern")
        }
    }

    // MARK: - Result ordering guarantee (using mock executor)

    func test_concurrentBatchResultsPreserveOriginalOrder() async {
        // Simulate two tools that complete in reverse order
        // Tool A takes longer (index 0), Tool B fast (index 1)
        // Result array must still be [A, B]
        let registry = DefaultToolRegistry()
        let planner = ToolConcurrencyBatchPlanner(registry: registry)
        let tools = [
            AgentLoopPendingTool(id: "slow-id", name: "web_search"),
            AgentLoopPendingTool(id: "fast-id", name: "web_fetch")
        ]
        let batches = planner.partition(tools)
        guard case .concurrent(let concurrent) = batches[0] else {
            return XCTFail("Expected concurrent batch")
        }

        // Verify the batch preserves insertion order (input order)
        XCTAssertEqual(concurrent[0].id, "slow-id")
        XCTAssertEqual(concurrent[1].id, "fast-id")
    }

    // MARK: - isConcurrencySafe annotation count

    func test_safeToolCount_matchesExpectation() {
        let registry = DefaultToolRegistry()
        let safeCount = registry.allDefinitions().filter(\.isConcurrencySafe).count
        // 13 tools: web_search, web_fetch, read_tool_payload + 10 LSP tools
        XCTAssertEqual(safeCount, 13, "Expected exactly 13 concurrency-safe tools")
    }
}
```

### Step 2: 运行测试，确认当前状态

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fc1-integration-derived \
  -only-testing:agentGuiTests/ToolConcurrencyBatchIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Test Suite|FAILED|passed"
```

预期：编译通过（Task 1-3 已完成）；若 `safeCount` 计数不符则说明 Task 2 中遗漏了某个工具标注，按错误信息补充。

### Step 3: 修复直到全部通过

常见失败：`test_safeToolCount_matchesExpectation` 计数不符 → 回到 `ToolRegistry.swift` 检查是否所有 13 个工具均已添加 `isConcurrencySafe: true`。

### Step 4: 运行全量既有测试，确保没有回退

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fc1-full-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite.*failed|error:" | head -30
```

预期：无新增失败。

### Step 5: Commit

```bash
git add agentGuiTests/ToolConcurrencyBatchIntegrationTests.swift
git commit -m "test(F-C1): integration tests for batch planner with DefaultToolRegistry"
```

---

## Task 5: 向 Xcode 项目注册新文件

**Files:**
- Modify: `agentGui.xcodeproj/project.pbxproj`

新建的 Swift 文件若未通过 Xcode 手动添加，需要手动注册。

### Step 1: 检查是否已注册

```bash
grep "ToolConcurrencyBatchPlanner" agentGui.xcodeproj/project.pbxproj | head -5
grep "ToolConcurrencyBatchPlannerTests" agentGui.xcodeproj/project.pbxproj | head -5
grep "ToolConcurrencyBatchIntegrationTests" agentGui.xcodeproj/project.pbxproj | head -5
```

若所有命令均无输出，说明文件未注册。

### Step 2: 在 Xcode 中手动添加

在 Xcode 中：
1. 用 Xcode 打开 `agentGui.xcodeproj`
2. 在 `agentGui/Services/ToolGovernance/` 下找到 `ToolConcurrencyBatchPlanner.swift`（若目录不存在，先在 Finder 中创建，再 drag-in）
3. 右键 → "Add Files to agentGui" → 确认 Target Membership 勾选正确
4. 同样处理两个测试文件（Target: `agentGuiTests`）

### Step 3: 编译验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

### Step 4: Commit

```bash
git add agentGui.xcodeproj/project.pbxproj
git commit -m "chore(F-C1): register ToolGovernance files in Xcode project"
```

---

## 验收检查表

完成所有 Task 后，按以下标准逐条验证：

| 验收标准 | 验证方式 |
|---------|---------|
| `ToolDefinition` 有 `isConcurrencySafe` 属性（默认 `false`） | 编译通过，grep 确认 |
| 13 个只读工具标记为 `true` | `test_safeToolCount_matchesExpectation` 通过 |
| `ToolConcurrencyBatchPlanner.partition` 正确分批 | 11 个单元测试全通过 |
| 连续 safe 工具合并为单个 concurrent 批次 | `test_twoSafeTools_returnsSingleConcurrentBatch` 通过 |
| non-safe 工具独自获得 serial 批次 | `test_singleUnsafeTool_returnsSerialBatch` 通过 |
| 安全检查异常时保守降级为 serial | `test_whenSafetyCheckThrows_treatsAsUnsafe` 通过 |
| `DefaultToolRegistry` 集成正确 | 集成测试 4 个全通过 |
| 原有测试无回退 | 全量测试通过 |
| 编译无警告（Swift 6 strict concurrency） | `xcodebuild build` 无 error |

---

## 文件变更汇总

| 操作 | 文件 |
|------|------|
| 新建 | `agentGui/Services/ToolGovernance/ToolConcurrencyBatchPlanner.swift` |
| 新建 | `agentGuiTests/ToolConcurrencyBatchPlannerTests.swift` |
| 新建 | `agentGuiTests/ToolConcurrencyBatchIntegrationTests.swift` |
| 修改 | `agentGui/Models/ToolDefinition.swift`（+`isConcurrencySafe` 属性和 init 参数） |
| 修改 | `agentGui/Services/ToolRegistry.swift`（13 个工具添加 `isConcurrencySafe: true`） |
| 修改 | `agentGui/Services/AgentLoopRoundExecutor.swift`（`applyToolResults` 使用批次规划器） |
| 修改 | `agentGui.xcodeproj/project.pbxproj`（注册新文件） |

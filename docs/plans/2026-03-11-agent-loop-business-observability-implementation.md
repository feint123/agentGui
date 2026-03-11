# Agent Loop Business Observability Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add unified business observability for the agent loop, using the same engineering style as the existing performance monitor, and remove direct `print`/`printf` logging from the current loop path.

**Architecture:** Keep `PerformanceMonitor` focused on latency and throughput, and introduce a parallel structured business-log layer for runtime state changes. The agent loop, reflection path, workflow activation path, and loop-adjacent compression/memory steps should emit typed events through a single monitor API backed by `OSLog`, with per-run correlation metadata and testable formatting/level rules.

**Tech Stack:** Swift 6, Foundation, OSLog, SwiftData, Swift Testing, `xcodebuild` on macOS.

---

## Implementation Notes

- 本次只处理“Agent Loop 主执行链路”的业务监控，不顺手清理所有服务中的历史调试日志。
- “统一业务监控”不是把 `print` 包一层，而是要有明确的事件类型、日志级别、字段规范和相关 ID。
- `PerformanceMonitor` 保留性能计时职责；业务事件不要继续塞进性能 span 名称里，避免语义混杂。
- 所有新业务日志都必须走统一 API，禁止在 `ClaudeService+AgenticLoop.swift`、`WorkflowRuntime.swift`、`WorkflowAgentRunner.swift`、`ClaudeService+Reflection.swift`、`ClaudeService+ContextCompression.swift` 中继续直接 `print`。
- 第一阶段只要求日志可在 Console.app / unified logging 中检索，不要求先做 UI 面板。
- 日志字段要默认做裁剪和脱敏，避免直接打出完整 prompt、完整消息数组、完整工具输入 JSON。
- 按 TDD 执行：先锁定事件模型与输出契约，再接入主循环，最后做迁移清理和回归验证。

## Proposed File Layout

**Create core observability types:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/BusinessMonitor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentBusinessEvent.swift`

**Modify loop and workflow runtime:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopPhase.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowRuntime.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowDefinition.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Reflection.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ContextCompression.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/PerformanceMonitor.swift`

**Create or expand tests:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BusinessMonitorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopBusinessObservabilityTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkflowBusinessObservabilityTests.swift`

### Task 1: Define A Unified Business Monitor Contract

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/BusinessMonitor.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentBusinessEvent.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BusinessMonitorTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/PerformanceMonitor.swift`

**Step 1: Write the failing test**

新增测试，锁定业务日志的事件枚举、等级映射、字段裁剪和 run correlation 行为。

```swift
import Foundation
import Testing
@testable import agentGui

struct BusinessMonitorTests {
    @Test func eventProducesStableCategoryLevelAndSanitizedMetadata() {
        let context = BusinessLogContext(
            runID: "run-1",
            sessionID: "session-1",
            workflowID: "wf-1",
            roundIndex: 3,
            toolName: "bash"
        )

        let entry = BusinessMonitor.makeEntry(
            .toolExecutionStarted,
            context: context,
            metadata: [
                "command": String(repeating: "x", count: 500),
                "messageCount": 28
            ]
        )

        #expect(entry.category == "AgentBusiness")
        #expect(entry.level == .info)
        #expect(entry.metadata["runID"] == "run-1")
        #expect((entry.metadata["command"] as? String)?.count == 160)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/BusinessMonitorTests
```

Expected: FAIL because `BusinessMonitor`, `BusinessLogContext`, and `AgentBusinessEvent` do not exist.

**Step 3: Write minimal implementation**

实现统一业务日志基础层：

- `AgentBusinessEvent` 定义主循环业务事件，如 `loopStarted`、`memoryBootstrapLoaded`、`roundStarted`、`toolExecutionStarted`、`toolExecutionFinished`、`reflectionStarted`、`loopFinished`、`loopFailed`
- `BusinessLogContext` 提供 `runID / sessionID / workflowID / roundIndex / toolName / phase`
- `BusinessMonitor` 提供 `emit(...)`、`scoped(...)` 或 `event(...)` 风格 API，接口形态与 `PerformanceMonitor` 接近，但不做耗时计算
- 日志后端使用 `Logger(subsystem: "com.agentgui", category: "AgentBusiness")`
- metadata 做白名单和长度裁剪，禁止无上限输出完整 messages 或 JSON

```swift
enum AgentBusinessEvent: String, Sendable {
    case loopStarted
    case memoryBootstrapLoaded
    case roundStarted
    case stopReasonReceived
    case toolExecutionStarted
    case toolExecutionFinished
    case reflectionStarted
    case reflectionCompleted
    case continuationInjected
    case loopFinished
    case loopFailed
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Utilities/BusinessMonitor.swift agentGui/Models/AgentBusinessEvent.swift agentGuiTests/BusinessMonitorTests.swift
git commit -m "feat: add unified business monitor"
```

### Task 2: Instrument The Main Agent Loop With Structured Business Events

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopPhase.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopBusinessObservabilityTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopExecutionGuardTests.swift`

**Step 1: Write the failing test**

新增测试，要求主 loop 在关键状态变化时发出结构化事件，并且不再依赖原始 `print` 文本。

```swift
@Test func runCoreAgentLoopEmitsLifecycleEventsInOrder() async throws {
    let sink = InMemoryBusinessLogSink()
    let service = ClaudeService.makeForTests(businessSink: sink)
    var messages: [MessageParameter.Message] = [.init(role: .user, content: .text("fix the build"))]

    _ = try await service.runCoreAgentLoop(
        messages: &messages,
        service: MockAnthropicService.endTurn(text: "done"),
        modelId: "claude-test",
        tools: [],
        system: nil,
        settings: .testDefaults,
        sessionId: "session-1",
        modelContext: TestModelContextFactory.make(),
        maxRounds: 2,
        makeRound: { AgentRound(roundIndex: $0) },
        parentMessage: nil,
        onTextAccumulated: { _ in }
    )

    #expect(sink.events.map(\.event) == [.loopStarted, .roundStarted, .stopReasonReceived, .loopFinished])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopBusinessObservabilityTests
```

Expected: FAIL because `runCoreAgentLoop` does not emit business events and has no injectable sink.

**Step 3: Write minimal implementation**

在主循环中接入统一业务日志，至少覆盖这些节点：

- loop 启动，包含 `runID`、`sessionID`、`modelId`、`maxRounds`
- memory bootstrap 命中，包含来源 `unified/task/story`
- 每轮开始，包含 `phase`、`roundIndex`、`messageCount`
- token 统计结果，包含 `inputTokens` 和 context ratio
- stream 开始/结束，包含 `roundIndex`、`deltaCount`、`textBytes`
- stop reason 落地，包含 `stopReason` 与 phase transition
- tool 执行开始/结束，包含 `toolName`、`status`、`durationMs`、`isIntercepted`
- reflection 开始/结束，包含 trigger、confidence、retry 决策
- finalizing / failed / maxRounds 终止

同时删除或替换本文件中的直接 `print` 调用，包括但不限于：

- unified/task/story memory 加载日志
- initial messages dump
- reflection 日志
- round start / model / token / stream / stop reason 日志
- tool execution 日志
- max_tokens / pause_turn / failed / maxRounds 日志

实现建议：

- 在 `runAgenticLoop` 或 `runCoreAgentLoop` 开始处生成 `runID`
- 在 `AgentLoopContext` 增加可直接序列化的 `phaseLabel`
- 对 `messages`、`pending.partialJson`、`result.text` 仅记录摘要，不记录完整内容

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Models/AgentLoopPhase.swift agentGuiTests/AgentLoopBusinessObservabilityTests.swift
git commit -m "feat: add structured business logs to agent loop"
```

### Task 3: Extend The Same Logging Contract To Workflow And Subagent Paths

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowRuntime.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowDefinition.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkflowBusinessObservabilityTests.swift`

**Step 1: Write the failing test**

新增测试，锁定 workflow activation 和 contract violation 会使用统一业务日志，并带上 workflow correlation 字段。

```swift
@Test func workflowRunnerEmitsActivationAndContractViolationEvents() async throws {
    let sink = InMemoryBusinessLogSink()
    let runner = WorkflowAgentRunner.makeForTests(businessSink: sink)

    _ = try await runner.run(
        role: .reviewerFixture,
        context: .fixture(),
        inboxMessages: [],
        activationRecord: .fixture()
    )

    #expect(sink.events.contains { $0.event == .workflowActivationStarted })
    #expect(sink.events.allSatisfy { $0.metadata["workflowID"] != nil })
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/WorkflowBusinessObservabilityTests
```

Expected: FAIL because workflow runtime still uses raw `print`.

**Step 3: Write minimal implementation**

把 workflow 路径统一接到 `BusinessMonitor`：

- `WorkflowRuntime.log(_:)` 删除，改成 typed events
- `WorkflowAgentRunner` 的 activation start / finish / rejection / contract violation 改成事件发射
- `WorkflowDefinition` 中 `Contract[subscribesTo]` 违约改成结构化告警事件
- workflow 事件带上 `workflowID`、`roleName`、`activationID`、`turnsUsed`

推荐补充事件：

- `workflowStarted`
- `workflowActivationStarted`
- `workflowActivationFinished`
- `workflowContractViolation`
- `workflowFinished`

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/WorkflowRuntime.swift agentGui/Services/WorkflowAgentRunner.swift agentGui/Services/WorkflowDefinition.swift agentGuiTests/WorkflowBusinessObservabilityTests.swift
git commit -m "feat: unify workflow business logs"
```

### Task 4: Migrate Loop-Adjacent Reflection And Compression Logs, Then Remove Console Fallbacks

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Reflection.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ContextCompression.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/PerformanceMonitor.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BusinessMonitorTests.swift`

**Step 1: Write the failing test**

补测试，要求性能监控不再通过 `print` 直接写控制台，反射与压缩路径也只走统一业务/性能监控接口。

```swift
@Test func performanceMonitorDoesNotFallbackToDirectPrint() {
    #expect(PerformanceMonitor.consoleFallbackEnabled == false)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/BusinessMonitorTests
```

Expected: FAIL because `PerformanceMonitor` still prints to stdout and adjacent services still call `print`.

**Step 3: Write minimal implementation**

完成最后一轮迁移：

- `ClaudeService+Reflection.swift` 中“API failed / JSON parse failed / no text block”改用业务事件
- `ClaudeService+ContextCompression.swift` 中“compression triggered / extraction failed / persist error / parse failed”改用业务事件或性能事件
- `PerformanceMonitor` 去掉直接 `print` 的 console fallback，保留 `OSLog` 输出；若仍需要开发期开关，则通过可注入 sink，而不是直写 stdout

验收标准：

- `agentGui/Services` 的主 loop 相关文件不再存在新的 `print(`
- 业务日志和性能日志都能通过统一 sink 测试
- 发生错误时日志仍保留足够上下文，但不会输出完整 prompt 或海量 JSON

**Step 4: Run targeted regression checks**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/BusinessMonitorTests -only-testing:agentGuiTests/AgentLoopBusinessObservabilityTests -only-testing:agentGuiTests/WorkflowBusinessObservabilityTests
```

Then run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopExecutionGuardTests -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests
```

Expected: PASS. Existing loop control and memory injection behavior should remain unchanged.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+Reflection.swift agentGui/Services/ClaudeService+ContextCompression.swift agentGui/Utilities/PerformanceMonitor.swift agentGuiTests/BusinessMonitorTests.swift
git commit -m "refactor: remove direct console logging from loop path"
```

## Rollout Checklist

1. 先合入 `BusinessMonitor` 和事件模型，不改行为，只建立基础设施。
2. 再改 `ClaudeService+AgenticLoop.swift`，确保主 loop 有完整事件覆盖。
3. 然后迁移 workflow 和 subagent 路径，统一 correlation ID。
4. 最后删掉 loop 主链路中的直接 `print`，并关闭 `PerformanceMonitor` 的 stdout fallback。
5. 在 Console.app 中按 subsystem `com.agentgui` 和 category `AgentBusiness` / `Performance` 校验可读性与检索性。

## Risks And Guardrails

- 风险：日志字段过多导致噪音上升。
  约束：首期只记录状态迁移、工具执行、反射、压缩、终止原因，不记录全文内容。
- 风险：为了日志而污染主 loop 逻辑。
  约束：通过 `BusinessLogContext` 和 helper 方法集中组装 metadata，业务代码只发事件，不手拼字符串。
- 风险：测试难以断言 `OSLog` 输出。
  约束：为 `BusinessMonitor` 提供 in-memory sink，单测只验证结构化 entry，不直接抓系统日志。
- 风险：删除 `print` 后调试体验下降。
  约束：保留 debug 级别的 `OSLog` 和可注入 sink，不回退到 stdout。

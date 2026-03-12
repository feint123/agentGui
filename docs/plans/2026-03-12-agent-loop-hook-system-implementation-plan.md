# Agent Loop Hook System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Refactor the current agent loop into a clean loop engine driven by a typed hook system, so all existing loop trigger points flow through hooks instead of being emitted or handled inline.

**Architecture:** Introduce a typed hook layer made of `AgentLoopHook`, `AgentLoopHookDispatcher`, and stage-specific context/result models, then migrate the current direct trigger points in `runCoreAgentLoop(...)` into focused built-in hooks. Keep the loop engine responsible only for state progression, stream consumption, tool execution flow, and hook dispatch boundaries; move observability, stream projection, memory bootstrap, tool audit, failure classification, reflection handling, and finalization guard into hook implementations.

**Tech Stack:** Swift 6, Swift Testing, SwiftAnthropic, SwiftData, existing `ClaudeService`, `AgentLoopContext`, workflow runtime, business observability, and current tool-call persistence models.

---

## 1. 实施原则

- 先建 hook contract 和 dispatcher，再迁移现有副作用，避免一边拆一边继续往 `runCoreAgentLoop(...)` 里塞逻辑。
- 先锁测试，后搬代码。每次迁移一类触发点，只做最小改动让测试重新通过。
- 优先迁移最通用的触发点：observability 与 stream projection；它们能先验证 hook 骨架是否稳定。
- 不保留兼容层。项目是新项目，旧 callback 和直接 `BusinessMonitor.emit(...)` 都应被替换，而不是长期并存。
- 所有 hook 都必须是 typed contract；禁止引入字符串事件总线作为“临时方案”。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopHookModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHookDispatcher.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHooks/BusinessObservabilityHook.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHooks/StreamProjectionHook.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHooks/MemoryBootstrapHook.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHooks/ToolAuditHook.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHooks/FailureClassificationHook.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHooks/ReflectionHandlingHook.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHooks/FinalizationGuardHook.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopHookDispatcherTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopStreamProjectionHookTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopMemoryBootstrapHookTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopToolAuditHookTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopFailureClassificationHookTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopReflectionHookTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopFinalizationHookTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopPhase.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentBusinessEvent.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/BusinessMonitor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopBusinessObservabilityTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopExecutionGuardTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemorySubagentContractTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkflowBusinessObservabilityTests.swift`

## 3. 关键设计决策

### 3.1 Hook contract 不是事件总线

V1 必须定义强类型 hook contract，而不是把现有 `AgentBusinessEvent` 扩展成一个万能消息枚举。hook contract 至少需要显式表达：

- 执行阶段
- hook 类型：observer / mutator / decisionMaker
- 顺序
- 失败策略
- 当前允许修改的上下文字段

`AgentBusinessEvent` 在新结构中只应承担“可观测性映射目标”的职责，不应反向定义 hook 系统本身。

### 3.2 Loop engine 只保留最小控制流

V1 完成后，`runCoreAgentLoop(...)` 中允许保留的逻辑只有：

- `AgentLoopContext` 状态推进
- 组装模型请求并消费流式响应
- 组装工具执行输入输出
- 调用 dispatcher 进入对应 hook stage
- 根据 hook 返回值决定 phase 如何前进

以下逻辑必须迁出 loop 主体：

- `BusinessMonitor.emit(...)`
- `onTextAccumulated(...)`
- 统一记忆 bootstrap 构建与消息注入
- `ToolCall` 记录细节与 terminal 事件投影
- reviewer / executor 失败分类
- reflection 副作用与 correction prompt 注入
- continuation / pause-turn 文案生成
- finalization guard 决策

### 3.3 Hook context 必须显式分层

不要尝试做一个超大的可变 `HookContext` 让所有 hook 随意写。V1 至少拆成：

- run 级上下文
- round 级上下文
- tool 级上下文
- reflection / finalization 决策上下文

其中 observer hook 应只拿快照；mutator hook 只能返回 patch；decision hook 只能返回强类型 decision。

### 3.4 Hook dispatcher 只调度，不承载业务

`AgentLoopHookDispatcher` 不得变成新的 God Object。它只负责：

- 收集适用 hook
- 按顺序执行
- 合并结果
- 隔离错误

任何业务语义都必须留在具体 hook 中。

## 4. 任务拆解

### Task 1: 建立 Hook 基础模型与 Dispatcher

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopHookModels.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHookDispatcher.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopHookDispatcherTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`

**Step 1: Write the failing test**

新增 `AgentLoopHookDispatcherTests.swift`，锁定以下基础行为：

- 同一 stage 的 hook 按 `order` 升序执行
- observer hook 抛错时，dispatcher 记录失败并继续执行后续 hook
- required mutator hook 失败时，dispatcher 返回 abort 结果
- decision hook 返回的结果能被 dispatcher 汇总给调用方

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

struct AgentLoopHookDispatcherTests {

    @Test func dispatcherExecutesHooksInStableOrder() async throws {
        let recorder = HookCallRecorder()
        let dispatcher = AgentLoopHookDispatcher(hooks: [
            TestObserverHook(id: "late", order: 20, recorder: recorder),
            TestObserverHook(id: "early", order: 10, recorder: recorder)
        ])

        _ = try await dispatcher.dispatch(
            .didStartRun,
            context: .testRunContext()
        )

        #expect(recorder.ids == ["early", "late"])
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopHookDispatcherTests
```

Expected: FAIL，因为 hook model 和 dispatcher 还不存在。

**Step 3: Write minimal implementation**

在 `AgentLoopHookModels.swift` 中定义最小契约：

```swift
enum AgentLoopHookStage: Sendable {
    case prepareRun
    case didStartRun
    case willStartRound
    case didReceiveTextDelta
    case didResolveStopReason
    case willExecuteTool
    case didExecuteTool
    case classifyFailureTrigger
    case willStartReflection
    case didCompleteReflection
    case prepareContinuation
    case prepareResumeAfterPause
    case decideFinalization
    case didFinishRun
    case didFailRun
}

enum AgentLoopHookKind: Sendable {
    case observer
    case mutator
    case decisionMaker
}

protocol AgentLoopHook: Sendable {
    var id: String { get }
    var order: Int { get }
    var kind: AgentLoopHookKind { get }
    var isRequired: Bool { get }
    func supports(_ stage: AgentLoopHookStage) -> Bool
    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult
}
```

在 `AgentLoopHookDispatcher.swift` 中实现串行调度、错误分类、结果聚合。先不接入真实业务 hook，只保证基础调度正确。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/AgentLoopHookModels.swift agentGui/Services/AgentLoopHookDispatcher.swift agentGuiTests/AgentLoopHookDispatcherTests.swift
git commit -m "feat: add agent loop hook dispatcher"
```

### Task 2: 迁移 Business Observability 到内建 Hook

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHooks/BusinessObservabilityHook.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/BusinessMonitor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopBusinessObservabilityTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkflowBusinessObservabilityTests.swift`

**Step 1: Write the failing test**

扩展 `AgentLoopBusinessObservabilityTests.swift`，要求 loop 生命周期事件仍按原顺序出现，但 `runCoreAgentLoop(...)` 不再直接持有 `emitBusinessEvent(...)` 私有函数。

测试示例：

```swift
@Test func runCoreAgentLoopEmitsLifecycleEventsViaHook() async throws {
    let sink = InMemoryBusinessLogSink()
    let claudeService = ClaudeService()
    claudeService.businessLogSink = sink

    var messages: [MessageParameter.Message] = [
        .init(role: .user, content: .text("fix the build"))
    ]

    let result = try await claudeService.runCoreAgentLoop(
        messages: &messages,
        service: FakeAnthropicService.endTurn(text: "done"),
        modelId: "claude-test",
        tools: [],
        system: nil,
        settings: AppSettings(),
        sessionId: "",
        modelContext: try makeModelContext(),
        maxRounds: 2,
        makeRound: { AgentRound(roundIndex: $0) },
        parentMessage: nil,
        onTextAccumulated: { _ in }
    )

    #expect(result.completedSuccessfully)
    #expect(sink.events.map(\.event) == [.loopStarted, .roundStarted, .stopReasonReceived, .loopFinished])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopBusinessObservabilityTests -only-testing:agentGuiTests/WorkflowBusinessObservabilityTests
```

Expected: FAIL，在移除内联 emit 后，没有 hook 驱动事件。

**Step 3: Write minimal implementation**

实现 `BusinessObservabilityHook`：

- 订阅 `didStartRun`、`willStartRound`、`didResolveStopReason`、`willExecuteTool`、`didExecuteTool`、`willStartReflection`、`didCompleteReflection`、`prepareContinuation`、`didFinishRun`、`didFailRun`
- 将 typed hook stage 映射到现有 `AgentBusinessEvent`
- 统一通过 `BusinessMonitor.emit(...)` 输出

在 `ClaudeService+AgenticLoop.swift` 中删除私有 `emitBusinessEvent(...)` helper，改为在对应边界调用 dispatcher。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopHooks/BusinessObservabilityHook.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Utilities/BusinessMonitor.swift agentGuiTests/AgentLoopBusinessObservabilityTests.swift agentGuiTests/WorkflowBusinessObservabilityTests.swift
git commit -m "refactor: move agent loop observability into hook"
```

### Task 3: 迁移 Stream Projection，替换 `onTextAccumulated`

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHooks/StreamProjectionHook.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopStreamProjectionHookTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`

**Step 1: Write the failing test**

新增 `AgentLoopStreamProjectionHookTests.swift`，锁定以下行为：

- 文本 delta 累积达到阈值时，stream projection hook 会更新主消息文本
- subagent 运行时不会触发主消息 UI 投影
- workflow worker 可以继续通过 action snippet 获取文本摘要，但不再依赖 `onTextAccumulated` 直传

测试示例：

```swift
@Test func streamProjectionHookUpdatesAssistantMessageForMainAgent() async throws {
    let message = Message(role: "assistant", textContent: "")
    let hook = StreamProjectionHook()
    var context = AgentLoopHookContext.testRoundContext(parentMessage: message)

    context.currentRoundText = "hello"
    context.accumulatedText = "hello"

    _ = try await hook.perform(stage: .didReceiveTextDelta, context: context)

    #expect(message.textContent == "hello")
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopStreamProjectionHookTests
```

Expected: FAIL，因为 stream projection hook 和新的 context 还没接上。

**Step 3: Write minimal implementation**

实现 `StreamProjectionHook`，负责：

- 处理 `didReceiveTextDelta` 与 `didReceiveThinkingDelta`
- 根据执行上下文决定是否投影到 `parentMessage`
- 提供统一的 snippet 输出能力供 workflow action 使用

同时修改 `runCoreAgentLoop(...)` 签名，移除长期暴露的 `onTextAccumulated` 参数，改为由 hook context 携带必要投影对象。

同步修改 `ClaudeService+Subagent.swift` 与 `WorkflowAgentRunner.swift` 的调用代码，接入新的 hook 配置。

**Step 4: Run test to verify it passes**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopStreamProjectionHookTests -only-testing:agentGuiTests/AgentLoopBusinessObservabilityTests
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopHooks/StreamProjectionHook.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Services/ClaudeService+Subagent.swift agentGui/Services/WorkflowAgentRunner.swift agentGuiTests/AgentLoopStreamProjectionHookTests.swift
git commit -m "refactor: replace loop text callback with stream projection hook"
```

### Task 4: 迁移 Memory Bootstrap 到 Run Hook

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHooks/MemoryBootstrapHook.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopMemoryBootstrapHookTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemorySubagentContractTests.swift`

**Step 1: Write the failing test**

新增 `AgentLoopMemoryBootstrapHookTests.swift`，覆盖以下行为：

- `prepareRun` 阶段能注入 unified memory bootstrap 消息
- unified memory 不可用时，仍能降级到 task memory / story memory 分支
- hook 返回的是消息 patch 与观测 metadata，而不是直接改写 loop 局部变量

测试示例：

```swift
@Test func memoryBootstrapHookReturnsMessageInsertions() async throws {
    let hook = MemoryBootstrapHook()
    let context = AgentLoopHookContext.testRunContext(sessionId: "session-1")

    let result = try await hook.perform(stage: .prepareRun, context: context)
    let patch = try #require(result.messagePatch)

    #expect(!patch.insertions.isEmpty)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopMemoryBootstrapHookTests
```

Expected: FAIL，因为 memory bootstrap 还在 loop 内联逻辑里。

**Step 3: Write minimal implementation**

把当前 `buildUnifiedMemoryBootstrap(...)`、task memory fallback、story memory fallback 的调度入口搬到 `MemoryBootstrapHook` 中。

要求：

- loop 只在 `prepareRun` 阶段应用 hook 返回的 message insertions
- hook 自己负责决定使用 unified / task / story 哪条路径
- 观测事件交给 `BusinessObservabilityHook` 消费 hook metadata 发出，不允许 `MemoryBootstrapHook` 直接 emit business event

**Step 4: Run test to verify it passes**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopMemoryBootstrapHookTests -only-testing:agentGuiTests/StoryMemorySubagentContractTests
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopHooks/MemoryBootstrapHook.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGuiTests/AgentLoopMemoryBootstrapHookTests.swift agentGuiTests/StoryMemorySubagentContractTests.swift
git commit -m "refactor: move memory bootstrap into run hook"
```

### Task 5: 迁移 Tool Audit 与 Failure Classification

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHooks/ToolAuditHook.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHooks/FailureClassificationHook.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopToolAuditHookTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopFailureClassificationHookTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`

**Step 1: Write the failing tests**

新增两组测试：

- `AgentLoopToolAuditHookTests.swift`
- `AgentLoopFailureClassificationHookTests.swift`

覆盖以下行为：

- `willExecuteTool` 能创建 `ToolCall` 记录并带上 memory runtime metadata
- `didExecuteTool` 能更新状态、结束时间、terminal 输出和 evidence
- `classifyFailureTrigger` 能把 tool error 映射为 `.toolFailure`
- `classifyFailureTrigger` 能把 reviewer `needs_revision` 与 executor failed JSON 映射为相应 `FailureTrigger`

测试示例：

```swift
@Test func failureClassificationHookRecognizesReviewerRejection() async throws {
    let hook = FailureClassificationHook()
    var context = AgentLoopHookContext.testToolContext(toolName: "run_subagent")
    context.toolInput = ["agent_name": .string("reviewer")]
    context.toolResultText = "{\"status\":\"needs_revision\"}"

    let result = try await hook.perform(stage: .classifyFailureTrigger, context: context)

    #expect(result.failureTrigger == .reviewerRejection(feedback: context.toolResultText))
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopToolAuditHookTests -only-testing:agentGuiTests/AgentLoopFailureClassificationHookTests
```

Expected: FAIL，因为 tool 审计和失败分类还散落在 loop 主体里。

**Step 3: Write minimal implementation**

实现 `ToolAuditHook`：

- 负责 `ToolCall` 的创建与完成更新
- 负责 bash terminal registry 相关投影入口
- 负责 evidence 收集 patch

实现 `FailureClassificationHook`：

- 负责 tool error 检测
- 负责 reviewer / executor 子代理特殊语义识别

在 loop 中把现有内联 `ToolCall` 审计细节和 `pendingFailureTrigger` 分类迁移为 hook 调用。

**Step 4: Run tests to verify they pass**

Run the same `xcodebuild` command.

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopHooks/ToolAuditHook.swift agentGui/Services/AgentLoopHooks/FailureClassificationHook.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGuiTests/AgentLoopToolAuditHookTests.swift agentGuiTests/AgentLoopFailureClassificationHookTests.swift
git commit -m "refactor: move tool audit and failure classification into hooks"
```

### Task 6: 迁移 Reflection Handling 与 Finalization Guard

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHooks/ReflectionHandlingHook.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHooks/FinalizationGuardHook.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopReflectionHookTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopFinalizationHookTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopExecutionGuardTests.swift`

**Step 1: Write the failing tests**

新增两组测试，覆盖以下行为：

- `willStartReflection` / `didCompleteReflection` 能执行 reflection、写回 round 字段、写入 task memory、返回 correction prompt patch
- `decideFinalization` 能返回 allow / retry / fail，并替代 loop 中直接调用 `ExecutionGuard.resolveFinalization(...)`
- `prepareContinuation` 与 `prepareResumeAfterPause` 能分别返回 continuation prompt patch

测试示例：

```swift
@Test func finalizationGuardHookRequestsRetryWhenExecutionEvidenceIsMissing() async throws {
    let hook = FinalizationGuardHook()
    var context = AgentLoopHookContext.testFinalizationContext()
    context.executionRequirement = .mustRunTests
    context.executionEvidenceKinds = []

    let result = try await hook.perform(stage: .decideFinalization, context: context)

    #expect(result.finalizationDecision == .retry)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopReflectionHookTests -only-testing:agentGuiTests/AgentLoopFinalizationHookTests -only-testing:agentGuiTests/AgentLoopExecutionGuardTests
```

Expected: FAIL，因为 reflection 和 execution guard 仍在 loop 内联逻辑里。

**Step 3: Write minimal implementation**

实现 `ReflectionHandlingHook`：

- 封装 `reflectOnRound(...)`
- 统一负责 reflection 数据落盘与 correction prompt patch 生成
- 把 task memory 失败写入也视作 hook 内部处理

实现 `FinalizationGuardHook`：

- 用 `ExecutionGuard` 作为内部策略实现
- 返回强类型 `FinalizationDecision`
- 提供 `prepareContinuation` 与 `prepareResumeAfterPause` 的 prompt patch 生成

在 loop 中把 reflection 分支和 finalization 分支改成“请求 hook 决策 + 应用 patch”的结构。

**Step 4: Run tests to verify they pass**

Run the same `xcodebuild` command.

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopHooks/ReflectionHandlingHook.swift agentGui/Services/AgentLoopHooks/FinalizationGuardHook.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGuiTests/AgentLoopReflectionHookTests.swift agentGuiTests/AgentLoopFinalizationHookTests.swift agentGuiTests/AgentLoopExecutionGuardTests.swift
git commit -m "refactor: move reflection and finalization policies into hooks"
```

### Task 7: 统一 Main Agent / Subagent / Workflow Worker 的 Hook 配置入口

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopPhase.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopBusinessObservabilityTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkflowBusinessObservabilityTests.swift`

**Step 1: Write the failing test**

新增或扩展现有测试，要求三条执行路径共享同一 hook contract：

- main agent 使用默认内建 hooks
- subagent 使用同一 dispatcher，但根据 scope 过滤掉主消息投影 hook
- workflow worker 使用同一 dispatcher，并保留 workflow 专属 action snippet / artifact 场景

测试示例：

```swift
@Test func subagentAndWorkflowUseSharedHookContract() async throws {
    let mainHooks = AgentLoopHookFactory.makeDefaultHooks(for: .mainAgent)
    let subagentHooks = AgentLoopHookFactory.makeDefaultHooks(for: .subagent)
    let workflowHooks = AgentLoopHookFactory.makeDefaultHooks(for: .workflowWorker)

    #expect(mainHooks.map(\.id).contains("business-observability"))
    #expect(subagentHooks.map(\.id).contains("business-observability"))
    #expect(workflowHooks.map(\.id).contains("business-observability"))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopBusinessObservabilityTests -only-testing:agentGuiTests/WorkflowBusinessObservabilityTests
```

Expected: FAIL，因为 hook 配置入口尚未统一。

**Step 3: Write minimal implementation**

新增统一的 hook factory 或等价配置入口，根据 `ToolContext` 或执行上下文生成 hooks：

- `.mainAgent`
- `.subagent`
- `.workflowWorker`

把 `ClaudeService+Subagent.swift` 和 `WorkflowAgentRunner.swift` 接到同一套 factory，移除局部专用 callback 扩展点。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Services/ClaudeService+Subagent.swift agentGui/Services/WorkflowAgentRunner.swift agentGui/Models/AgentLoopPhase.swift agentGuiTests/AgentLoopBusinessObservabilityTests.swift agentGuiTests/WorkflowBusinessObservabilityTests.swift
git commit -m "refactor: unify hook configuration across agent loop contexts"
```

### Task 8: 端到端回归与文档收尾

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-12-agent-loop-hook-system-requirements.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-10-agent-architecture.md`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopBusinessObservabilityTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopExecutionGuardTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemorySubagentContractTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkflowBusinessObservabilityTests.swift`

**Step 1: Run focused regression suite**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopHookDispatcherTests \
  -only-testing:agentGuiTests/AgentLoopBusinessObservabilityTests \
  -only-testing:agentGuiTests/AgentLoopStreamProjectionHookTests \
  -only-testing:agentGuiTests/AgentLoopMemoryBootstrapHookTests \
  -only-testing:agentGuiTests/AgentLoopToolAuditHookTests \
  -only-testing:agentGuiTests/AgentLoopFailureClassificationHookTests \
  -only-testing:agentGuiTests/AgentLoopReflectionHookTests \
  -only-testing:agentGuiTests/AgentLoopFinalizationHookTests \
  -only-testing:agentGuiTests/WorkflowBusinessObservabilityTests \
  -only-testing:agentGuiTests/StoryMemorySubagentContractTests
```

Expected: PASS。

**Step 2: Run broader smoke suite**

Run the existing workspace task:

```bash
./scripts/run_quality_smoke.sh
```

Expected: PASS。如果失败，先确认是否为本次 hook 改动引入的回归，再最小修复。

**Step 3: Update docs to match shipped architecture**

更新需求文档与技术架构文档，确保其中不再把 `onTextAccumulated`、内联 business event emit、内联 reflection / execution guard 描述为现状目标结构。

**Step 4: Commit**

```bash
git add docs/spec/2026-03-12-agent-loop-hook-system-requirements.md docs/technical-spec/2026-03-10-agent-architecture.md
git commit -m "docs: finalize agent loop hook architecture docs"
```

## 5. 风险与控制点

### 风险 1：Hook context 过大，重新形成新的 God Object

控制方式：

- 先按 run / round / tool / decision 四类上下文拆分
- 所有 mutator hook 通过 patch 返回改动，避免共享任意可写状态

### 风险 2：Stream hook 引入后影响高频路径性能

控制方式：

- 保留现有节流阈值
- 在 `StreamProjectionHook` 内做批量更新，不在每个 delta 上做重持久化

### 风险 3：Reflection 与 finalization 迁移后状态机语义变乱

控制方式：

- 保留 `AgentLoopContext` 作为唯一 phase 真源
- hook 只能返回明确的 decision / patch，不能直接跳过状态机写 phase

### 风险 4：Subagent / workflow 复用时 hook 组合不一致

控制方式：

- 使用统一 factory 生成 hooks
- 用测试明确 main / subagent / workflow 各自启用哪些 hook

## 6. 完成标准

满足以下条件时，本计划可视为完成：

1. `runCoreAgentLoop(...)` 中所有现有直接触发事件都已经改为通过 hook dispatcher 驱动。
2. `BusinessMonitor` 只通过 `BusinessObservabilityHook` 接入，不再由 loop 主体直接调用。
3. `onTextAccumulated` 已被移除或降级为内部兼容细节，不再是 loop 的长期扩展接口。
4. memory bootstrap、tool audit、failure classification、reflection、continuation、execution guard 都已拥有明确 hook 实现。
5. main agent、subagent、workflow worker 共享同一套 hook contract 和配置入口。
6. 新增 focused tests 全部通过，现有 agent loop 相关测试无回归。

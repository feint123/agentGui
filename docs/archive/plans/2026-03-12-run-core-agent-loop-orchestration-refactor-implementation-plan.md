# Run Core Agent Loop Orchestration Refactor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在不改变当前 agent loop 行为的前提下，完成 `runCoreAgentLoop(...)` 的最后一轮结构性收口，把剩余的输入建模、运行时状态、Hook 上下文装配、Hook 依赖构建和主循环编排从 `ClaudeService+AgenticLoop.swift` 中提取出来。

**Architecture:** 保留现有 `AgentLoopRoundStreamAssembler`、`AgentLoopToolExecutionCoordinator`、`AgentLoopPhaseOutcomeApplier`、`AgentLoopVerificationCoordinator` 和 `AgentLoopBuiltInHookFactory` 作为底层协作者。新增 `request/runtime/state` 值对象、`AgentLoopHookEmitter`、`AgentLoopHookDependencyFactory` 与 `AgentLoopRunner`，让 `runCoreAgentLoop(...)` 退化为一个薄入口，只负责构建运行依赖并启动 runner。整个重构必须优先锁定现有 hook 语义、phase 转移、tool audit 写入时机与 verification side effect，不引入产品行为变化。

**Tech Stack:** Swift 6, SwiftData, Swift Testing, SwiftAnthropic, 现有 `ClaudeService` agent loop 基础设施。

---

## 1. 当前状态与约束

- 该仓库已经完成第一轮拆分，以下组件已存在且应复用，而不是重复重写：
  - `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopRoundStreamAssembler.swift`
  - `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinator.swift`
  - `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopPhaseOutcomeApplier.swift`
  - `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopMemoryBootstrapComposer.swift`
  - `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopBuiltInHookFactory.swift`
  - `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopVerificationCoordinator.swift`
- 当前 `runCoreAgentLoop(...)` 仍然保留大量局部状态、嵌套函数和 Hook context 手工装配逻辑，是这次计划的主要收口对象。
- 该任务是纯重构：
  - 不新增 hook stage
  - 不改变 stop reason 到 phase 的语义
  - 不改变 tool result 注入策略
  - 不改变 verification gate 与 reflection gate 的触发条件
- 所有新类型应尽量使用小而明确的初始化参数，避免重新引入一个巨大的 dependency bag。

## 2. 目标文件清单

### 新文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopRunRequest.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopRuntime.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopRunState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopSharedStateAccess.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHookEmitter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHookDependencyFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopRunner.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopHookEmitterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopHookDependencyFactoryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopRunnerTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopBuiltInHookFactoryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopBusinessObservabilityTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopExecutionGuardTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui.xcodeproj/project.pbxproj`

## 3. 设计落点

### 3.1 输入与运行时边界

- `AgentLoopRunRequest`
  - 只承载纯输入：`service`、`modelId`、`tools`、`system`、`maxRounds`、`executionRequirement`、`toolExecutionContext`
- `AgentLoopRuntime`
  - 只承载当前执行环境绑定：`settings`、`session`、`sessionId`、`modelContext`、`makeRound`、`parentMessage`、`streamProjectionTarget`、`toolInterceptor`

### 3.2 单次运行状态与共享状态访问

- `AgentLoopRunState`
  - 聚合当前 `runCoreAgentLoop(...)` 中散落的局部变量：
    - `runID`
    - `accumulatedText`
    - `loopCtx`
    - `loopMemory`
    - `executionEvidence`
    - `executionGuardRetryCount`
    - `hookState`
- `AgentLoopSharedStateAccess`
  - 通过闭包暴露 `ClaudeService` 上仍需保留的共享状态写口：
    - `sessionVerifications`
    - `sessionExecutionEvidence`
    - `currentModelId`
    - `currentInputTokens`

### 3.3 Hook 发射与依赖构建

- `AgentLoopHookEmitter`
  - 替代当前 `dispatchHooks(...)`、`emitHook(...)`、`emitBusinessEvent(...)`、`currentRoundTextForHook(...)`
  - 统一构建 `AgentLoopHookContext`
  - 把 “observer 型 emit” 与 “required decision 型 dispatch” 明确区分
- `AgentLoopHookDependencyFactory`
  - 替代当前 `AgentLoopBuiltInHookFactory.Dependencies(...)` 的大块内联闭包
  - 将 memory bootstrap、tool record create/update、reflection resolve 变成命名方法

### 3.4 主循环编排

- `AgentLoopRunner`
  - 拥有 `request`、`runtime`、`sharedState`、`emitter`、`hookDispatcher` 和现有协作者
  - 负责：bootstrap、phase 分发、round streaming、tool result 注入、verification/reflection 驱动、最终结果组装
  - `runCoreAgentLoop(...)` 只做：
    - 组装 request/runtime/sharedState
    - 创建 dependency factory / hook dispatcher / emitter / runner
    - 调用 `runner.run(messages: &messages)`

## 4. Task breakdown

### Task 1: 锁定当前 orchestration seam 的行为

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopHookEmitterTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopRunnerTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopExecutionGuardTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopBusinessObservabilityTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`

**Step 1: Write the failing tests**

补齐下列 characterization coverage，先锁住行为再拆代码：

- `currentRoundText` 默认解析顺序必须是：显式 `currentRoundText` > `projectedText` > `accumulatedText`
- `didStartRun` 和 `didApplyBootstrap` 的 metadata 语义保持不变
- reflection phase 消费 `pendingFailureTrigger` 后不会遗留脏状态
- verification failure 进入 reflection 时，`executionEvidence` 与 verification report 的写入时机不变
- max-round termination 与正常 finish termination 仍然互斥

建议测试骨架：

```swift
@Test func hookEmitterUsesProjectedTextAsDefaultCurrentRoundText() async throws {
    let dispatcher = RecordingHookDispatcher()
    let emitter = AgentLoopHookEmitter(
        dispatcher: dispatcher,
        request: .testValue(),
        runtime: .testValue(),
        businessLogSink: nil
    )
    var state = AgentLoopRunState()
    state.accumulatedText = "older"

    _ = try await emitter.dispatch(
        .didReceiveTextDelta,
        state: state,
        messages: [],
        overrides: .init(projectedText: "newer")
    )

    #expect(dispatcher.lastContext?.currentRoundText == "newer")
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopHookEmitterTests \
  -only-testing:agentGuiTests/AgentLoopRunnerTests \
  -only-testing:agentGuiTests/AgentLoopExecutionGuardTests \
  -only-testing:agentGuiTests/AgentLoopBusinessObservabilityTests \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests
```

Expected: FAIL，因为新 emitter / runner 及相应 test helpers 尚不存在。

**Step 3: Add minimal test helpers**

- 为 `AgentLoopRunRequest`、`AgentLoopRuntime` 预留 `testValue()` helper
- 添加 recording dispatcher / fake business sink，避免直接依赖真实 `ClaudeService`

**Step 4: Run tests again**

Expected: 仍然 FAIL，但失败点应收敛到缺失的实现类型。

**Step 5: Commit**

```bash
git add agentGuiTests/AgentLoopHookEmitterTests.swift agentGuiTests/AgentLoopRunnerTests.swift agentGuiTests/AgentLoopExecutionGuardTests.swift agentGuiTests/AgentLoopBusinessObservabilityTests.swift agentGuiTests/AgentLoopIntegrationTests.swift
git commit -m "test: characterize agent loop orchestration seams"
```

### Task 2: 引入 request/runtime/state/shared-state 四个基础类型

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopRunRequest.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopRuntime.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopRunState.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopSharedStateAccess.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`

**Step 1: Write the failing implementation skeleton**

先创建最小类型定义和构造函数，不改行为：

```swift
struct AgentLoopRunRequest {
    let service: any AnthropicService
    let modelId: String
    let tools: [MessageParameter.Tool]
    let system: MessageParameter.System?
    let maxRounds: Int
    let executionRequirement: ExecutionRequirement
    let toolExecutionContext: ToolContext
}

struct AgentLoopRuntime {
    let settings: AppSettings
    let session: Session?
    let sessionId: String
    let modelContext: ModelContext
    let makeRound: (Int) -> AgentRound
    let parentMessage: Message?
    let streamProjectionTarget: AgentLoopStreamProjectionTarget
    let toolInterceptor: ((String, MessageResponse.Content.Input) async -> ToolExecutionResult?)?
}
```

**Step 2: Run targeted tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests
```

Expected: FAIL，因为调用点和 `runCoreAgentLoop(...)` 签名尚未迁移。

**Step 3: Migrate call sites with no behavior change**

- `runAgenticLoop(...)` 构建 `request` 与 `runtime`
- `runSubagent(...)` 的复用入口改为同一签名
- `WorkflowAgentRunner` 改为传递 request/runtime，而不是继续传 16 个参数
- `ClaudeService+AgenticLoop.swift` 仅先改签名与局部变量装配，不做更大结构调整

**Step 4: Run tests to verify they pass**

Run the same command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/AgentLoopRunRequest.swift agentGui/Models/AgentLoopRuntime.swift agentGui/Models/AgentLoopRunState.swift agentGui/Models/AgentLoopSharedStateAccess.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Services/ClaudeService+Subagent.swift agentGui/Services/WorkflowAgentRunner.swift
git commit -m "refactor: add explicit agent loop request and runtime models"
```

### Task 3: 提取 AgentLoopHookEmitter，移除 Hook context 手工拼装

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHookEmitter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopHookEmitterTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopBusinessObservabilityTests.swift`

**Step 1: Write the failing implementation skeleton**

创建统一 emitter 和 overrides：

```swift
struct HookContextOverrides {
    var metadata: [String: Any] = [:]
    var toolName: String? = nil
    var projectedText: String? = nil
    var currentRoundText: String? = nil
    var currentRoundThinking: String? = nil
    var toolInput: MessageResponse.Content.Input? = nil
    var toolResultText: String? = nil
    var toolCallRecord: ToolCall? = nil
}

struct AgentLoopHookEmitter {
    func makeContext(
        state: AgentLoopRunState,
        messages: [MessageParameter.Message],
        overrides: HookContextOverrides = .init()
    ) -> AgentLoopHookContext { ... }

    func emit(...) async { ... }
    func dispatch(...) async throws -> AgentLoopHookDispatchResult { ... }
    func emitBusinessEvent(...) { ... }
}
```

**Step 2: Run targeted tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopHookEmitterTests \
  -only-testing:agentGuiTests/AgentLoopBusinessObservabilityTests
```

Expected: FAIL，因为 `ClaudeService+AgenticLoop.swift` 仍在使用本地嵌套函数。

**Step 3: Replace nested helpers in runCoreAgentLoop(...)**

- 删除 `dispatchHooks(...)`
- 删除 `emitHook(...)`
- 删除 `emitBusinessEvent(...)`
- 删除 `currentRoundTextForHook(...)`
- 将原调用点逐一替换为：
  - `try await emitter.dispatch(...)` 用于 required decision 场景
  - `await emitter.emit(...)` 用于 observer 场景
- `prepareRun` 不再单独手工构造 `AgentLoopHookContext`

**Step 4: Run tests to verify they pass**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopHookEmitter.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGuiTests/AgentLoopHookEmitterTests.swift agentGuiTests/AgentLoopBusinessObservabilityTests.swift
git commit -m "refactor: extract agent loop hook emitter"
```

### Task 4: 提取 AgentLoopHookDependencyFactory，消灭大块内联闭包

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHookDependencyFactory.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopHookDependencyFactoryTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopBuiltInHookFactoryTests.swift`

**Step 1: Write the failing tests**

覆盖下列语义：

- memory bootstrap composition 会把 runtime profiles / layers / warnings / snapshot id 写回 hook state
- tool call record 创建时仍会复制 memory runtime metadata
- tool call record 更新时仍会写入 preview、summary、payload ref、status 和 end time
- reflection resolver 仍会把 reflection 结果写回 `lastRound`，并在存在 concerns / fixes 时写入 failure audit

**Step 2: Run targeted tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopHookDependencyFactoryTests \
  -only-testing:agentGuiTests/AgentLoopBuiltInHookFactoryTests
```

Expected: FAIL，因为 factory 尚不存在。

**Step 3: Implement the factory and migrate dependency assembly**

建议结构：

```swift
struct AgentLoopHookDependencyFactory {
    let claudeService: ClaudeService
    let request: AgentLoopRunRequest
    let runtime: AgentLoopRuntime
    let bootstrapMessagesSnapshot: [MessageParameter.Message]

    func build(state: AgentLoopBuiltInHookFactory.State) -> AgentLoopBuiltInHookFactory.Dependencies { ... }
}
```

迁移规则：

- 每个原内联闭包体单独成为命名方法
- 只把 `ClaudeService` 必需能力透传进去，不把整个 loop 状态重新捕获回来
- 工厂不得承担 dispatch 责任，只构建 dependencies

**Step 4: Run tests to verify they pass**

Run the same command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopHookDependencyFactory.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGuiTests/AgentLoopHookDependencyFactoryTests.swift agentGuiTests/AgentLoopBuiltInHookFactoryTests.swift
git commit -m "refactor: extract agent loop hook dependency factory"
```

### Task 5: 提取 AgentLoopRunner，收口 bootstrap + phase loop + finalization

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopRunner.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopRunnerTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`

**Step 1: Write the failing implementation skeleton**

建议入口：

```swift
struct AgentLoopRunner {
    let request: AgentLoopRunRequest
    let runtime: AgentLoopRuntime
    let sharedState: AgentLoopSharedStateAccess
    let hookDispatcher: AgentLoopHookDispatcher
    let emitter: AgentLoopHookEmitter
    let toolExecutionCoordinator: AgentLoopToolExecutionCoordinator

    func run(messages: inout [MessageParameter.Message]) async throws -> AgentLoopRunResult { ... }
}
```

拆分的最小私有方法：

- `applyBootstrap(...)`
- `handleReflectionPhase(...)`
- `handleVerificationPhase(...)`
- `executeStreamingRound(...)`
- `handleToolResultsIfNeeded(...)`
- `finish(...)`

**Step 2: Run targeted tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopRunnerTests \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests
```

Expected: FAIL，因为 runner 尚未接管主循环。

**Step 3: Migrate the loop into AgentLoopRunner**

迁移要求：

- `runCoreAgentLoop(...)` 只做装配，不保留主 while 循环
- 保持现有协作者边界：
  - streaming 继续使用 `AgentLoopRoundStreamAssembler`
  - tool execution 继续使用 `AgentLoopToolExecutionCoordinator`
  - verification 继续使用 `AgentLoopVerificationCoordinator`
  - phase outcome 继续使用 `AgentLoopPhaseOutcomeApplier`
- `sessionVerifications`、`sessionExecutionEvidence`、`currentModelId`、`currentInputTokens` 通过 `AgentLoopSharedStateAccess` 访问
- `runCoreAgentLoop(...)` 方法体目标控制在 120 行以内；如果能稳定做到 80 行以内更好，但不要为了行数打碎语义

**Step 4: Run tests to verify they pass**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopRunner.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGuiTests/AgentLoopRunnerTests.swift agentGuiTests/AgentLoopIntegrationTests.swift
git commit -m "refactor: move core agent loop orchestration into runner"
```

### Task 6: 清理调用面、工程引用和全量验证

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui.xcodeproj/project.pbxproj`

**Step 1: Remove dead local code paths**

- 删除已不再使用的局部变量、嵌套函数和过渡封装
- 保留最小兼容包装，前提是确有外部引用无法同步迁移

**Step 2: Run the focused agent loop suites**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopHookEmitterTests \
  -only-testing:agentGuiTests/AgentLoopHookDependencyFactoryTests \
  -only-testing:agentGuiTests/AgentLoopRunnerTests \
  -only-testing:agentGuiTests/AgentLoopBuiltInHookFactoryTests \
  -only-testing:agentGuiTests/AgentLoopExecutionGuardTests \
  -only-testing:agentGuiTests/AgentLoopBusinessObservabilityTests \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests
```

Expected: PASS.

**Step 3: Run full regression for the already-extracted collaborators**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopRoundStreamAssemblerTests \
  -only-testing:agentGuiTests/AgentLoopToolExecutionCoordinatorTests \
  -only-testing:agentGuiTests/AgentLoopPhaseOutcomeApplierTests \
  -only-testing:agentGuiTests/AgentLoopMemoryBootstrapComposerTests \
  -only-testing:agentGuiTests/AgentLoopVerificationCoordinatorTests
```

Expected: PASS.

**Step 4: Run repository smoke checks**

Run:

```bash
./scripts/run_quality_smoke.sh
```

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Services/ClaudeService+Subagent.swift agentGui/Services/WorkflowAgentRunner.swift agentGui.xcodeproj/project.pbxproj
git commit -m "refactor: finalize agent loop orchestration extraction"
```

## 5. 验收标准

- [ ] `runCoreAgentLoop(...)` 不再持有本地 `dispatchHooks(...)` / `emitHook(...)` / `emitBusinessEvent(...)` / `currentRoundTextForHook(...)`
- [ ] Hook context 的默认填充语义有测试覆盖
- [ ] built-in hook dependencies 不再通过大块匿名闭包直接写在 `runCoreAgentLoop(...)` 内
- [ ] `runCoreAgentLoop(...)` 仅负责装配 request/runtime/sharedState/emitter/runner
- [ ] `ClaudeService+Subagent.swift` 和 `WorkflowAgentRunner.swift` 已迁移到新签名
- [ ] `sessionVerifications`、`sessionExecutionEvidence`、`currentModelId`、`currentInputTokens` 的写入时机与重构前一致
- [ ] reflection、verification、tool execution、finalization 的行为在现有测试语义下无回归
- [ ] `./scripts/run_quality_smoke.sh` 通过
- [ ] 无新增编译 warning

## 6. 实施顺序建议

- 严格按任务顺序执行，不要跳到 Task 5 先做 runner。
- Task 3 和 Task 4 是最高风险点，因为它们最容易把“结构重构”意外变成“hook 语义重写”。
- 每个任务结束后立即运行对应测试，不要把多个提取动作堆到一次验证里。

Plan complete and saved to `docs/plans/2026-03-12-run-core-agent-loop-orchestration-refactor-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
# `runCoreAgentLoop` 重构技术设计文档

> 状态: 草案  
> 日期: 2026-03-12

---

## 1. 现状分析

### 1.1 问题度量

| 指标 | 当前值 | 目标值 |
|------|--------|--------|
| 方法行数 | ~780 行 (L68 – L870) | ≤ 300 行 |
| 嵌套闭包层级 | 最深 4 层 | ≤ 1 层 |
| 参数数量 | 16 个 | ≤ 8 个 (通过参数对象) |
| 内联嵌套函数 | 5 个 (`dispatchHooks`, `emitHook`, `emitBusinessEvent`, `currentRoundTextForHook`, `pendingToolID`) | 0 个 |
| 方法内局部状态变量 | 8 个 | 封装到上下文对象 |

### 1.2 核心问题

1. **God Method**: `runCoreAgentLoop` 承担了至少 6 种职责 —— Hook 依赖装配、StreamAssembler 驱动、状态机转换、工具执行编排、Reflection 调度、最终结果组装。
2. **闭包地狱**: `hookDependencies` 的构造是一个巨大的闭包字面量嵌套（`memoryBootstrapLoader` 内嵌 `composer.compose`，`createToolCallRecord` 捕获 `pendingToolID`/`roundForToolContext` 等局部函数）。闭包体内自由捕获 `self`、`service`、`settings`、`modelContext` 等变量，形成一个难以阅读、不可测试的黑盒。
3. **Hook 上下文手动装配**: 每次调用 `dispatchHooks`/`emitHook`，都需要手动从局部变量拼装一个 `AgentLoopHookContext`（12+ 个字段），复制粘贴式的 metadata 字典遍布全方法。
4. **状态散落**: `accumulatedText`、`loopCtx`、`loopMemory`、`executionEvidence`、`executionGuardRetryCount`、`hookState` 等可变状态以局部变量形式散布在方法开头，与方法体中的使用相隔数百行。
5. **参数爆炸**: 16 个参数，其中多个是 "forwarded" 到子组件的配置值（`service`、`modelId`、`settings`、`sessionId` 等），方法签名无法自描述。

---

## 2. 设计目标

1. **方法体 ≤ 300 行**: 核心循环只包含状态机骨架 + 按阶段分发。
2. **单一职责**: 每个提取出的类型/方法只做一件事。
3. **Hook 上下文自动化**: 消除手动拼装 `AgentLoopHookContext` 的重复代码。
4. **可测试性**: 新提取的组件可被单元测试独立验证。
5. **零行为变更**: 纯结构重构，所有现有测试必须无修改通过。
6. **错误传播显式化**: required hook 失败、bootstrap 中止、finalization 决策失败必须有明确定义的控制流结果，不能继续依赖 `try?` 静默吞掉异常。
7. **状态边界清晰**: 区分「单次 run 的局部状态」与 `ClaudeService` 持有的跨 run / 跨 session 共享状态，避免通过新的参数对象继续隐式耦合。
8. **语义兼容优先于行数指标**: `currentRoundText`、`projectedText`、verification gate、tool audit record 更新时机等行为契约优先锁定，再做结构拆分。

---

## 3. 架构设计

### 3.1 整体分层

```
┌───────────────────────────────────────────────────┐
│  ClaudeService.runCoreAgentLoop()  (≤80 行)       │  ← 入口：构建 Runner，启动循环
├───────────────────────────────────────────────────┤
│  AgentLoopRunner (新类型)  (≤200 行)              │  ← 状态机循环骨架
│    ├─ AgentLoopRunRequest          (纯输入)        │
│    ├─ AgentLoopRuntime             (运行时绑定)    │
│    ├─ AgentLoopRunState            (可变状态)      │
│    ├─ AgentLoopSharedStateAccess   (共享状态写口)  │
│    ├─ AgentLoopHookEmitter         (Hook 发射器)   │
│    ├─ AgentLoopHookDependencyFactory (依赖工厂)   │
│    └─ AgentLoopRoundExecutor       (单轮执行)      │
├───────────────────────────────────────────────────┤
│  现有组件 (不变)                                   │
│    AgentLoopHookDispatcher                        │
│    AgentLoopToolExecutionCoordinator              │
│    AgentLoopPhaseOutcomeApplier                   │
│    AgentLoopRoundStreamAssembler                  │
│    AgentLoopVerificationCoordinator               │
│    AgentLoopBuiltInHookFactory                    │
└───────────────────────────────────────────────────┘
```

### 3.2 新类型详解

---

#### 3.2.1 `AgentLoopRunRequest` + `AgentLoopRuntime` — 输入与运行时绑定分离

**动机**: 当前 16 个参数里混杂了三类信息：纯输入、持久化依赖、回调/投影。若简单压成一个 `AgentLoopRunConfig`，只会把参数爆炸转化为一个巨大的 dependency bag。更合理的拆法是分离 request 与 runtime。

```swift
/// 一次 loop 调用的纯输入，适合在调用栈中传递。
struct AgentLoopRunRequest {
    let service: any AnthropicService
    let modelId: String
    let tools: [MessageParameter.Tool]
    let system: MessageParameter.System?
    let maxRounds: Int
    let executionRequirement: ExecutionRequirement
    let toolExecutionContext: ToolContext
}

/// 与当前运行环境耦合的对象引用与回调。
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

**好处**:
- `runCoreAgentLoop` 可简化为 `(messages: inout [...], request: AgentLoopRunRequest, runtime: AgentLoopRuntime)`，但不强迫所有子组件都依赖完整对象。
- `RoundExecutor` 主要依赖 `request`；持久化、UI 投影、tool interception 等依赖由 `runtime` 提供。
- 降低「所有 helper 都能顺手拿到所有依赖」的耦合风险。

---

#### 3.2.2 `AgentLoopRunState` — 可变状态聚合

**动机**: 将单次 loop 执行期间的局部状态聚合，同时明确哪些状态不属于它。

```swift
/// 单次 agentic loop 执行期间的全部可变状态。
struct AgentLoopRunState {
    let runID: String
    var accumulatedText: String = ""
    var loopCtx: AgentLoopContext
    var loopMemory: ContextMemory = ContextMemory()
    var executionEvidence: Set<ExecutionEvidenceKind> = []
    var executionGuardRetryCount: Int = 0
    let hookState: AgentLoopBuiltInHookFactory.State

    init() {
        self.runID = UUID().uuidString
        self.loopCtx = AgentLoopContext(phase: .executing)
        self.hookState = AgentLoopBuiltInHookFactory.State()
    }
}

/// ClaudeService 持有的共享副作用写口。
/// 避免 RoundExecutor 直接回写 service 全局属性，掩盖状态边界。
struct AgentLoopSharedStateAccess {
    let readVerification: (String) -> CompletionVerification?
    let writeVerification: (String, CompletionVerification) -> Void
    let readExecutionEvidence: (String) -> Set<ExecutionEvidenceKind>
    let writeExecutionEvidence: (String, Set<ExecutionEvidenceKind>) -> Void
    let setCurrentModelId: (String) -> Void
    let setCurrentInputTokens: (Int) -> Void
}
```

**边界说明**:
- `AgentLoopRunState` 只承载本次 run 的局部状态，不直接拥有 `sessionVerifications`、`sessionExecutionEvidence`、`currentModelId`、`currentInputTokens`。
- 这些共享状态继续由 `ClaudeService` 持有，但通过显式访问接口读写，避免新提取类型继续偷偷捕获 `self`。

---

#### 3.2.3 `AgentLoopHookEmitter` — Hook 上下文工厂 + 发射器

**动机**: 消除 `dispatchHooks`/`emitHook`/`emitBusinessEvent` 三个嵌套函数以及每次调用时的 12 字段手动拼装。

```swift
/// 负责将运行时状态自动注入到 HookContext，并向 HookDispatcher 分发事件。
/// 替代三个嵌套闭包函数 + 12 字段手动装配。
struct AgentLoopHookEmitter {
    let dispatcher: AgentLoopHookDispatcher
    let request: AgentLoopRunRequest
    let runtime: AgentLoopRuntime
    let businessLogSink: BusinessLogSink?

    /// 从当前运行状态自动构建 HookContext，用户只需提供差异字段。
    func makeContext(
        state: AgentLoopRunState,
        messages: [MessageParameter.Message],
        overrides: HookContextOverrides = .init()
    ) -> AgentLoopHookContext {
        var ctx = AgentLoopHookContext(
            runID: state.runID,
            sessionID: runtime.sessionId,
            workflowID: nil,
            executionContext: request.toolExecutionContext,
            modelId: request.modelId,
            roundIndex: state.loopCtx.roundIndex,
            phase: state.loopCtx.phase.label
        )
        ctx.stopReason = state.loopCtx.lastStopReason
        ctx.failureTrigger = state.loopCtx.pendingFailureTrigger
        ctx.accumulatedText = overrides.projectedText ?? state.accumulatedText
        ctx.currentRoundText = overrides.currentRoundText
            ?? overrides.projectedText
            ?? state.accumulatedText
        ctx.currentRoundThinking = overrides.currentRoundThinking ?? ""
        ctx.messagesSnapshot = messages
        ctx.metadata = overrides.metadata
        ctx.streamProjectionTarget = runtime.streamProjectionTarget
        ctx.pendingToolName = overrides.toolName
        ctx.toolInput = overrides.toolInput ?? [:]
        ctx.toolResultText = overrides.toolResultText ?? ""
        ctx.toolCallRecord = overrides.toolCallRecord
        return ctx
    }

    /// Fire-and-forget hook（不关心返回值）。
    func emit(
        _ stage: AgentLoopHookStage,
        state: AgentLoopRunState,
        messages: [MessageParameter.Message],
        overrides: HookContextOverrides = .init()
    ) async {
        let ctx = makeContext(state: state, messages: messages, overrides: overrides)
        _ = try? await dispatcher.dispatch(stage, context: ctx)
    }

    /// 需要读取 hook 返回值的 dispatch。
    func dispatch(
        _ stage: AgentLoopHookStage,
        state: AgentLoopRunState,
        messages: [MessageParameter.Message],
        overrides: HookContextOverrides = .init()
    ) async throws -> AgentLoopHookDispatchResult {
        let ctx = makeContext(state: state, messages: messages, overrides: overrides)
        return try await dispatcher.dispatch(stage, context: ctx)
    }

    /// 发射业务事件。
    func emitBusinessEvent(
        _ event: AgentBusinessEvent,
        state: AgentLoopRunState,
        metadata: [String: Any] = [:]
    ) {
        let context = BusinessLogContext(
            runID: state.runID,
            sessionID: runtime.sessionId.isEmpty ? nil : runtime.sessionId,
            roundIndex: state.loopCtx.roundIndex,
            phase: state.loopCtx.phase.label
        )
        BusinessMonitor.emit(event, context: context, metadata: metadata, sink: businessLogSink)
    }
}

/// 差异覆盖参数，避免为每种 hook 调用定义独立方法。
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
```

**语义约束**:

- `currentRoundText` 的默认值必须与现有实现保持一致：先取显式覆盖，再取 `projectedText`，最后回退到 `accumulatedText`。
- `emit(...)` 仅用于 observer 型、fire-and-forget 场景；凡是需要消费 `abortReason` / `failures` / `decisions` 的阶段必须使用 `dispatch(...)` 并显式处理结果。
- `prepareRun` 不能绕过 emitter 单独构造 context，否则又会回到双轨逻辑。

#### 3.2.3.1 Hook 失败与中止语义

重构必须把 HookDispatcher 暴露出来的控制流信号接入主状态机，而不是继续在调用点用 `try?` 忽略。

```swift
enum AgentLoopHookControl {
    case `continue`(AgentLoopHookDispatchResult)
    case abort(reason: AgentLoopHookAbortReason, failures: [AgentLoopHookFailure])
}
```

**规则**:

- `prepareRun` 若返回 `.abort`，本次 run 直接失败并发射 `didFailRun`。
- `processReflection` / `decideFinalization` 若 required hook 失败，也必须进入失败终态，而不是默认回退到 `.continue`。
- observer hook 失败可保留现有容错语义，但 failures 需要进入 telemetry / test 断言面。

**与现状对比**:

| 现状 | 重构后 |
|------|--------|
| 每次调用写 12 行字段赋值 | `emitter.makeContext(...)` 统一构造，且语义有测试锁定 |
| `dispatchHooks` 内联 30 行 | `emitter.dispatch(...)`，失败不再被静默吞掉 |
| `emitBusinessEvent` 内联 5 行 | `emitter.emitBusinessEvent(...)` 一行 |

---

#### 3.2.4 `AgentLoopHookDependencyFactory` — 从闭包地狱中提取 Hook 依赖构建

**动机**: `hookDependencies` 的 5 个闭包体合计 ~120 行，捕获了大量外部变量。将其提取为一个独立工厂类型。

```swift
/// 将 AgentLoopBuiltInHookFactory.Dependencies 的构建从 runCoreAgentLoop 中提取出来。
/// 每个闭包体变成一个命名方法，便于阅读和测试。
struct AgentLoopHookDependencyFactory {
    let claudeService: ClaudeService
    let request: AgentLoopRunRequest
    let runtime: AgentLoopRuntime
    let bootstrapMessagesSnapshot: [MessageParameter.Message]

    func build(hookState: AgentLoopBuiltInHookFactory.State) -> AgentLoopBuiltInHookFactory.Dependencies {
        AgentLoopBuiltInHookFactory.Dependencies(
            businessLogSink: claudeService.businessLogSink,
            memoryBootstrapLoader: { state in
                try await self.loadMemoryBootstrap(state: state)
            },
            createToolCallRecord: { context, state in
                self.createToolCallRecord(context: context, state: state)
            },
            updateToolCallRecord: { context, _ in
                self.updateToolCallRecord(context: context)
            },
            reflectionResolver: { context, state in
                try await self.resolveReflection(context: context, state: state)
            }
        )
    }

    // MARK: - 命名方法 (各 ≤ 30 行)

    private func loadMemoryBootstrap(
        state: AgentLoopBuiltInHookFactory.State
    ) async throws -> AgentLoopMessagePatch? {
        // 原 memoryBootstrapLoader 闭包体, 保持相同逻辑
        ...
    }

    private func createToolCallRecord(
        context: AgentLoopHookContext,
        state: AgentLoopBuiltInHookFactory.State
    ) -> ToolCall {
        // 原 createToolCallRecord 闭包体
        ...
    }

    private func updateToolCallRecord(context: AgentLoopHookContext) {
        // 原 updateToolCallRecord 闭包体
        ...
    }

    private func resolveReflection(
        context: AgentLoopHookContext,
        state: AgentLoopBuiltInHookFactory.State
    ) async -> AgentLoopReflectionResolution {
        // 原 reflectionResolver 闭包体
        ...
    }
}
```

---

#### 3.2.5 `AgentLoopRoundExecutor` — 单轮执行逻辑提取

**动机**: `while` 循环体内约 480 行。按阶段拆分为独立方法，但仍以「状态机控制流」而不是「机械切函数」为核心。

```swift
/// 执行 agentic loop 的单个 round。
/// 拥有对 request、runtime、sharedState、emitter、toolCoordinator 的引用，但不拥有状态。
struct AgentLoopRoundExecutor {
    let request: AgentLoopRunRequest
    let runtime: AgentLoopRuntime
    let sharedState: AgentLoopSharedStateAccess
    let emitter: AgentLoopHookEmitter
    let toolCoordinator: AgentLoopToolExecutionCoordinator

    /// 处理 reflecting 阶段。
    func executeReflection(
        state: inout AgentLoopRunState,
        messages: inout [MessageParameter.Message]
    ) async { ... }

    /// 处理 verifying 阶段。
    func executeVerification(
        state: inout AgentLoopRunState,
        messages: [MessageParameter.Message],
        accumulatedText: String
    ) async throws { ... }

    /// 执行一轮 API 流式调用 + 结果消费。
    /// 返回 RoundOutcome 描述本轮产出。
    func executeStreamingRound(
        state: inout AgentLoopRunState,
        messages: inout [MessageParameter.Message]
    ) async throws -> RoundOutcome { ... }

    /// 根据收到的 stop_reason 分发到对应阶段处理。
    func applyPhaseOutcome(
        outcome: RoundOutcome,
        state: inout AgentLoopRunState,
        messages: inout [MessageParameter.Message]
    ) async throws { ... }
}

/// 单轮执行产出的简洁描述。
struct RoundOutcome {
    let roundIndex: Int
    let round: AgentRound
    let currentRoundText: String
    let currentRoundThinking: String
    let pendingTools: [AgentLoopPendingTool]
    let stopReason: String?
    let assistantObjects: [MessageParameter.Message.Content.ContentObject]
    let accumulatedTextBeforeRound: String
}
```

---

### 3.3 重构后的 `runCoreAgentLoop` 骨架

```swift
@discardableResult
func runCoreAgentLoop(
    messages: inout [MessageParameter.Message],
    request: AgentLoopRunRequest,
    runtime: AgentLoopRuntime
) async throws -> AgentLoopRunResult {

    // 1. 初始化运行状态
    var state = AgentLoopRunState()
    let bootstrapSnapshot = messages

    // 2. 构建 Hook 管线
    let depFactory = AgentLoopHookDependencyFactory(
        claudeService: self,
        request: request,
        runtime: runtime,
        bootstrapMessagesSnapshot: bootstrapSnapshot
    )
    let hookDeps = depFactory.build(hookState: state.hookState)
    let dispatcher = AgentLoopHookDispatcher(
        hooks: AgentLoopBuiltInHookFactory().makeHooks(dependencies: hookDeps, state: state.hookState)
    )
    let emitter = AgentLoopHookEmitter(
        dispatcher: dispatcher,
        request: request,
        runtime: runtime,
        businessLogSink: businessLogSink
    )

    // 3. 构建单轮执行器
    let toolCoord = AgentLoopToolExecutionCoordinatorBuilder(
        claudeService: self,
        service: request.service,
        modelId: request.modelId,
        settings: runtime.settings,
        sessionId: runtime.sessionId,
        modelContext: runtime.modelContext
    ).build()
    let sharedState = AgentLoopSharedStateAccess(
        readVerification: { self.sessionVerifications[$0] },
        writeVerification: { self.sessionVerifications[$0] = $1 },
        readExecutionEvidence: { self.sessionExecutionEvidence[$0] ?? [] },
        writeExecutionEvidence: { self.sessionExecutionEvidence[$0] = $1 },
        setCurrentModelId: { self.currentModelId = $0 },
        setCurrentInputTokens: { self.currentInputTokens = $0 }
    )
    let roundExec = AgentLoopRoundExecutor(
        request: request,
        runtime: runtime,
        sharedState: sharedState,
        emitter: emitter,
        toolCoordinator: toolCoord
    )

    // 4. Bootstrap
    await emitter.emit(.didStartRun, state: state, messages: messages, overrides: .init(
        metadata: ["modelId": request.modelId, "maxRounds": request.maxRounds, "messageCount": messages.count]
    ))
    try await roundExec.applyBootstrap(state: &state, messages: &messages, dispatcher: dispatcher, emitter: emitter)

    // 5. 状态机主循环 — 纯骨架，每个 case ≤ 5 行
    while state.loopCtx.shouldContinue && state.loopCtx.roundIndex < request.maxRounds {
        try Task.checkCancellation()

        switch state.loopCtx.phase {
        case .reflecting:
            await roundExec.executeReflection(state: &state, messages: &messages)
            continue

        case .verifying:
            try await roundExec.executeVerification(state: &state, messages: &messages)
            continue

        default:
            let outcome = try await roundExec.executeStreamingRound(state: &state, messages: &messages)
            try await roundExec.applyPhaseOutcome(outcome: outcome, state: &state, messages: &messages)
        }
    }

    // 6. 终结
    return roundExec.buildResult(state: state, messages: messages)
}
```

**行数估算**: ~60 行。

**补充约束**:

- `executeStreamingRound` 只负责「发请求 + 消费 stream + 生成 RoundOutcome」，不直接决定失败终态。
- `applyPhaseOutcome` 负责唯一的状态转换出口，包括 hook abort、tool_use 无 block、verification gate、reflection retry。
- `buildResult` 负责统一结束路径，补发 `willFinishRun` / `didFinishRun` / `didFailRun`，避免尾部逻辑散落。

---

## 4. 分步实施计划

全部步骤均为行为不变的结构重构。每一步完成后，全部现有测试必须通过。

### Phase 1: 提取 `AgentLoopRunRequest` / `AgentLoopRuntime`

| 步骤 | 操作 | 文件 |
|------|------|------|
| 1.1 | 创建 `AgentLoopRunRequest.swift` 与 `AgentLoopRuntime.swift` | `Models/` |
| 1.2 | 修改 `runCoreAgentLoop` 签名：输入与运行时绑定分离，避免单一大对象 | `ClaudeService+AgenticLoop.swift` |
| 1.3 | 修改 `runAgenticLoop` 外层调用点：分别构建 `request` / `runtime` | 同上 |
| 1.4 | 修改所有其他 `runCoreAgentLoop` 调用点 | Sub-agent 入口、测试 |
| 1.5 | 运行全部测试 | — |

### Phase 2: 提取局部状态与共享状态访问接口

| 步骤 | 操作 | 文件 |
|------|------|------|
| 2.1 | 创建 `AgentLoopRunState.swift` 与 `AgentLoopSharedStateAccess.swift` | `Models/` |
| 2.2 | 将局部 run 状态迁入 `AgentLoopRunState`；保留 service 级共享状态在 `ClaudeService` 中 | `ClaudeService+AgenticLoop.swift` |
| 2.3 | 用显式 shared-state access 替换对 `sessionVerifications` / `currentInputTokens` 等直接写入 | 同上 |
| 2.4 | 运行全部测试 | — |

### Phase 3: 提取 Hook 发射器 `AgentLoopHookEmitter`

| 步骤 | 操作 | 文件 |
|------|------|------|
| 3.1 | 创建 `AgentLoopHookEmitter.swift` + `HookContextOverrides.swift` | `Services/` |
| 3.2 | 删除 `dispatchHooks`/`emitHook`/`emitBusinessEvent`/`currentRoundTextForHook` 嵌套函数 | `ClaudeService+AgenticLoop.swift` |
| 3.3 | 所有调用点改为 `emitter.emit(...)` / `emitter.dispatch(...)`，并显式处理 `abortReason` | 同上 |
| 3.4 | 补 Characterization Tests：`currentRoundText` 默认语义、`prepareRun` 中止、observer failure 容错 | `agentGuiTests/` |
| 3.5 | 运行全部测试 | — |

### Phase 4: 提取 Hook 依赖工厂 `AgentLoopHookDependencyFactory`

| 步骤 | 操作 | 文件 |
|------|------|------|
| 4.1 | 创建 `AgentLoopHookDependencyFactory.swift` | `Services/` |
| 4.2 | 将 `hookDependencies` 块的 5 个闭包体迁移为命名方法，但优先保持对现有副作用时机的精确复刻 | 同上 |
| 4.3 | 删除原闭包代码 + `pendingToolID`/`roundForToolContext` 嵌套函数 | `ClaudeService+AgenticLoop.swift` |
| 4.4 | 补测试：tool record 创建/更新时机、reflection 写回 round 字段与 failure audit | `agentGuiTests/` |
| 4.5 | 运行全部测试 | — |

### Phase 5: 提取单轮执行器 `AgentLoopRoundExecutor`

| 步骤 | 操作 | 文件 |
|------|------|------|
| 5.1 | 创建 `AgentLoopRoundExecutor.swift` + `RoundOutcome.swift` | `Services/` |
| 5.2 | 提取 `executeReflection` | 原 while 循环 reflecting 分支 |
| 5.3 | 提取 `executeVerification` | 原 while 循环 verifying 分支 |
| 5.4 | 提取 `executeStreamingRound` | 原 while 循环 streaming + delta 消费 |
| 5.5 | 提取 `applyPhaseOutcome` | 原 switch loopCtx.phase 各 case |
| 5.6 | 提取 `buildResult` + `applyBootstrap` | 原 while 后的终结逻辑 + bootstrap |
| 5.7 | 补测试：phase 转移顺序、verification gate、tool_use 无 block 时失败路径 | `agentGuiTests/` |
| 5.8 | 运行全部测试 | — |

### Phase 6: 最终清理

| 步骤 | 操作 |
|------|------|
| 6.1 | 添加旧签名的 deprecated 包装（如有外部调用点暂未迁移） |
| 6.2 | 更新 Xcode project.pbxproj 引用新文件 |
| 6.3 | 运行全部测试 + Quality Smoke |
| 6.4 | 验证 `runCoreAgentLoop` 行数 ≤ 80 行 |

---

## 5. 设计模式映射

| 模式 | 应用位置 | 解决的问题 |
|------|----------|------------|
| **Parameter Object** | `AgentLoopRunRequest` | 纯输入参数收敛 |
| **Runtime Context** | `AgentLoopRuntime` | 运行时绑定与回调集中管理 |
| **State Object** | `AgentLoopRunState` | 散落的局部可变状态 |
| **Gateway** | `AgentLoopSharedStateAccess` | 显式访问 service 级共享状态 |
| **Facade / Gateway** | `AgentLoopHookEmitter` | 12 字段手动装配 → 自动化 |
| **Factory Method** | `AgentLoopHookDependencyFactory` | 120 行闭包嵌套 → 命名方法 |
| **Strategy + Decomposition** | `AgentLoopRoundExecutor` 的阶段方法 | 480 行循环体 → 4 个独立方法 |
| **Value Object** | `RoundOutcome`, `HookContextOverrides` | 减少散落的中间变量 |

---

## 6. 风险与缓解

| 风险 | 缓解 |
|------|------|
| `inout messages` 跨类型传递的生命周期 | `messages` 始终由调用者持有，`RoundExecutor` 方法通过 `inout` 参数操作，语义不变 |
| `@MainActor` 隔离问题 | 新类型不添加 actor 标注；`ClaudeService` 已是 `@MainActor`，提取方法保持在同一 actor 上下文 |
| Hook 行为回归 | 每个 Phase 完成后跑全量测试；Phase 3 是最高风险点，需额外对比 hook 调用顺序、abort 行为、metadata 语义 |
| 参数对象继续掩盖真实依赖 | 使用 `request` / `runtime` 拆分；新增类型的方法签名仅注入所需字段 |
| Hook context 语义漂移 | 为 `currentRoundText` / `projectedText` / `messagesSnapshot` 写 characterization tests，先锁定旧行为再重构 |
| `prepareRun` 与其他阶段走双轨逻辑 | bootstrap 也必须经统一 emitter / control adapter 处理，禁止保留旁路调用 |
| 共享 service 状态被新组件隐式修改 | 通过 `AgentLoopSharedStateAccess` 显式读写；在测试中断言 side effect 时机 |
| 性能影响 | 新增的结构体是值类型，构造成本可忽略；无额外堆分配 |

---

## 7. 新增文件清单

| 文件路径 | 类型 | 大致行数 |
|----------|------|----------|
| `agentGui/Models/AgentLoopRunRequest.swift` | struct | ~30 |
| `agentGui/Models/AgentLoopRuntime.swift` | struct | ~25 |
| `agentGui/Models/AgentLoopRunState.swift` | struct | ~25 |
| `agentGui/Models/AgentLoopSharedStateAccess.swift` | struct | ~20 |
| `agentGui/Services/AgentLoopHookEmitter.swift` | struct | ~100 |
| `agentGui/Services/AgentLoopHookDependencyFactory.swift` | struct | ~130 |
| `agentGui/Services/AgentLoopRoundExecutor.swift` | struct | ~250 |

---

## 8. 验收标准

- [ ] `runCoreAgentLoop` 方法体 ≤ 80 行
- [ ] 循环体内无嵌套函数声明
- [ ] `hookDependencies` 构建无内联闭包体超过 3 行
- [ ] 所有现有 `AgentLoop*Tests` 无修改通过
- [ ] `prepareRun` required hook 失败时，run 明确失败而不是继续执行
- [ ] `processReflection` / `decideFinalization` 的 `abortReason` 有测试覆盖
- [ ] `currentRoundText` 默认解析顺序与重构前一致
- [ ] `sessionVerifications` / `sessionExecutionEvidence` / `currentInputTokens` 的写入时机与重构前一致
- [ ] `willFinishRun` / `didFinishRun` / `didFailRun` 终结路径统一且互斥
- [ ] Hook stage 定义与真实发射点完成一次覆盖审计，未使用 stage 要么补实现要么删定义
- [ ] Quality Smoke 脚本通过
- [ ] 无新增编译器 warning

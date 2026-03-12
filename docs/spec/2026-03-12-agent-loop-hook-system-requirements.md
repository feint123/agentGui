# Agent Loop Hook System 需求说明

日期：2026-03-12

关联对象：`ClaudeService+AgenticLoop`、`ClaudeService+Subagent`、`WorkflowAgentRunner`、`AgentLoopPhase`、`AgentLoopContext`、`AgentBusinessEvent`、`BusinessMonitor`、`ToolCall`、`AgentRound`、`ExecutionGuard`、统一记忆运行时

## 1. 背景

当前项目的 Agent Loop 已经具备较完整的运行能力，主循环集中处理以下职责：

- loop 生命周期控制
- stop reason 状态转换
- 统一记忆 bootstrap 注入
- streaming 文本与 thinking 累积
- UI 文本回推
- `ToolCall` / `AgentRound` 持久化
- 工具执行前后审计
- 子代理与 workflow 特殊拦截
- failure trigger 识别
- reflection 执行与纠错 prompt 注入
- continuation / pause 恢复 prompt 注入
- execution guard 决策
- business observability 事件上报

这说明 Agent Loop 已经不是一个纯粹的“执行引擎”，而是承担了越来越多旁路副作用与策略判断。当前 `ClaudeService+AgenticLoop` 中既有核心控制流，也有大量直接触发的事件与副作用，典型现象包括：

- 直接调用 `emitBusinessEvent(...)`
- 直接调用 `onTextAccumulated(...)`
- 直接写入 `ToolCall`、`AgentRound`、统一记忆快照
- 直接拼接 continuation / reflection 的补偿消息
- 直接在 loop 内识别 reviewer / executor 失败语义

这类实现短期可行，但会带来三个持续性问题：

- 主循环可读性下降，状态机逻辑与扩展逻辑混杂
- 新增一个事件或副作用时，必须继续改动 loop 主体
- 观测、UI、审计、策略判断无法以统一扩展点复用

项目目前仍属于新项目阶段，不需要兼容旧接口，也不需要设计迁移过渡层。因此可以直接以“干净 loop 内核 + typed hook 管线”的方式重构。

## 2. 目标

本需求的目标如下：

- 为 Agent Loop 建立一套统一、强类型、可测试的 Hook System
- 将当前 loop 上所有直接触发的事件统一改为通过 hook 分发
- 让 loop 主体只保留执行状态机与最小控制流，不再直接承担观测、UI 投影、审计、补偿策略等扩展职责
- 让主 Agent、子代理、workflow worker 共享同一套 hook contract，而不是各自发明事件回调
- 让 business observability 成为 hook 的一个内建消费者，而不是 loop 的内联逻辑
- 为未来增加新的审计、调试、治理、UI 派生能力提供稳定扩展面

## 3. 不在本次范围

- 不要求兼容现有直接事件调用方式
- 不要求保留旧的 callback 形态作为兼容层
- 不要求在本期引入通用插件市场或动态加载脚本 hook
- 不要求把所有工具执行逻辑从 `ClaudeService` 拆成独立模块
- 不要求重写 workflow 调度模型本身
- 不要求把 Business Monitor 替换成远程遥测系统

## 4. 现状问题定义

### 4.1 loop 内部同时承担状态机和扩展点职责

当前 `runCoreAgentLoop(...)` 一边维护 `AgentLoopContext` 状态机，一边直接触发 UI、日志、持久化和策略逻辑。这会导致 loop 的“真正控制流”被埋在大量细节中。

### 4.2 事件是散点触发，不是统一 contract

当前已经存在一组业务事件：

- `loopStarted`
- `memoryBootstrapLoaded`
- `roundStarted`
- `stopReasonReceived`
- `toolExecutionStarted`
- `toolExecutionFinished`
- `reflectionStarted`
- `reflectionCompleted`
- `continuationInjected`
- `loopFinished`
- `loopFailed`

但这些事件只是“在 loop 里手动 emit 的日志点”，还不是通用 hook contract，因此无法稳定承载 UI、审计、策略和测试隔离。

### 4.3 非日志类触发点也散落在 loop 内

除了 `BusinessMonitor` 事件，当前还有多类真实扩展点没有统一抽象：

- `onTextAccumulated` 的 UI 投影
- 统一记忆 bootstrap 的构建与消息注入
- `ToolCall` 记录与终端任务状态追踪
- failure trigger 的分类
- reflection 后的 task memory 写入
- continuation / pause-turn 的补偿 prompt 注入
- finalization 前的 execution guard 决策

这些都是“事件触发后带来额外行为”的典型 hook 场景，但目前仍由 loop 直接串起来。

### 4.4 主 Agent / 子代理 / workflow 已经共享 loop，但没有共享 hook 面

当前主 Agent、`run_subagent`、workflow worker 都会进入 `runCoreAgentLoop(...)`，这说明 loop 内核已经共享成功；但共享的只是“执行函数”，不是“扩展机制”。继续沿用零散闭包和内联 if/else，会让共享内核越来越重。

## 5. 总体方案

### 5.1 核心原则

- loop 内核只负责状态推进，不直接感知具体扩展实现
- hook 必须是强类型 contract，不接受无约束的字符串事件总线
- hook 分为观察型、变更型、决策型三类，权限边界必须清晰
- hook 执行顺序必须稳定、可测试、可解释
- hook 失败处理必须分级，旁路失败不能拖垮主循环
- 同一套 hook contract 必须适用于 main agent、subagent、workflow worker

### 5.2 目标形态

系统需要形成三层结构：

1. `AgentLoopEngine`
只包含最小状态机与 round 驱动逻辑。

2. `AgentLoopHookDispatcher`
负责按阶段分发 hook、维护顺序、收集结果、隔离错误。

3. `AgentLoopHook`
定义所有 hook 的 typed contract。内建实现包括 observability、UI projection、memory bootstrap、tool audit、reflection persistence、execution guard 等。

目标状态下，loop 主体保留的职责应收敛为：

- 初始化 run context
- 调用 hook 完成 run 级预处理
- 发起模型请求与读取 stream
- 更新 `AgentLoopContext` 状态机
- 调度工具执行与 stop reason 分支
- 汇总结束结果

除上述最小职责外，其余可扩展行为必须通过 hook 完成。

## 6. Hook 模型要求

### 功能点 1：建立统一 Hook 协议

系统必须定义统一的 hook 协议，例如 `AgentLoopHook`，每个 hook 至少具备以下元数据：

- `id`
- `scope`
- `order`
- `kind`
- `isRequired`

其中：

- `scope` 用于声明 hook 适用范围，例如 `mainAgent`、`subagent`、`workflowWorker`、`all`
- `order` 用于保证稳定执行顺序
- `kind` 至少区分 `observer`、`mutator`、`decisionMaker`
- `isRequired` 用于定义失败是否中断 loop

系统不得使用仅靠字符串匹配的松散事件总线来代替 typed hook 协议。

### 功能点 2：建立统一 Hook 上下文对象

系统必须为 hook 提供统一上下文，例如 `AgentLoopHookContext`，至少包含以下信息：

- `runID`
- `sessionID`
- `workflowID`
- `executionContext`
- `modelId`
- `roundIndex`
- `phase`
- `messagesSnapshot`
- `settingsSnapshot`
- `pendingToolName`
- `stopReason`
- `failureTrigger`
- `accumulatedText`
- `currentRoundText`
- `currentRoundThinking`

要求：

- hook 获取到的上下文必须是结构化数据，不允许依赖 `[String: Any]` 传输核心状态
- 对于只读 hook，上下文应以不可变快照方式提供
- 对于可变 hook，只允许修改被当前阶段明确开放的字段

### 功能点 3：区分观察型、变更型、决策型 Hook

系统必须将 hook 分为三类：

1. 观察型 Hook
用途：日志、埋点、调试面板、时间线投影。
限制：不得改变 loop 控制流。

2. 变更型 Hook
用途：注入 bootstrap 消息、生成 continuation prompt、追加反思纠错消息、回写 UI 投影。
限制：只能修改当前阶段允许改写的数据。

3. 决策型 Hook
用途：failure classification、execution guard、finalization policy。
限制：必须返回强类型决策对象，不得直接写死在 loop 主体中。

## 7. Hook 阶段划分

### 功能点 4：定义 run 级 hook 阶段

系统必须至少提供以下 run 级阶段：

- `prepareRun`
- `didStartRun`
- `willFinishRun`
- `didFinishRun`
- `didFailRun`

其中：

- `prepareRun` 允许变更型 hook 生成 run 级初始注入，例如统一记忆 bootstrap
- `didStartRun` 用于 observability、run timeline 等旁路通知
- `willFinishRun` 用于结果归并与终止前补偿
- `didFinishRun` 与 `didFailRun` 用于收尾通知与审计

### 功能点 5：定义 round 级 hook 阶段

系统必须至少提供以下 round 级阶段：

- `willStartRound`
- `willRequestModel`
- `didReceiveTextDelta`
- `didReceiveThinkingDelta`
- `didResolveStopReason`
- `didCompleteRoundPersistence`

要求：

- `didReceiveTextDelta` 必须成为 `onTextAccumulated` 的正式替代入口
- `didResolveStopReason` 必须成为当前 `stopReasonReceived` 的正式 hook 阶段
- round 级 hook 需要能够访问当前 round 的快照与累计文本状态

### 功能点 6：定义 tool 级 hook 阶段

系统必须至少提供以下 tool 级阶段：

- `didDiscoverToolCall`
- `willExecuteTool`
- `didExecuteTool`
- `didClassifyToolFailure`
- `didAppendToolResults`

要求：

- 当前 `toolExecutionStarted`、`toolExecutionFinished` 必须由这些 hook 阶段承载
- `ToolCall` 记录创建、终端任务事件投影、evidence 收集必须从 loop 主体迁移到 tool 相关 hook 中
- tool hook 需要支持子代理与 workflow 工具拦截场景

### 功能点 7：定义 reflection / continuation / finalization hook 阶段

系统必须至少提供以下策略型阶段：

- `classifyFailureTrigger`
- `willStartReflection`
- `didCompleteReflection`
- `prepareContinuation`
- `prepareResumeAfterPause`
- `decideFinalization`

要求：

- 当前 reviewer rejection、executor validation failure、tool failure 的识别必须改为 `classifyFailureTrigger` 决策 hook
- 当前 reflection 前后事件必须分别落到 `willStartReflection`、`didCompleteReflection`
- 当前 continuation 与 pause_turn 的补偿消息必须通过对应 hook 生成，不得在 loop 中直接拼接文案
- 当前 execution guard 必须抽象为 `decideFinalization` 决策 hook，不再由 loop 主体直接依赖 `ExecutionGuard.resolveFinalization(...)`

## 8. 现有触发点到 Hook 的映射要求

下列现有触发点必须全部改为通过 hook 触发：

| 当前触发点 | 现状 | 目标 Hook 阶段 |
|------|------|------|
| `loopStarted` | loop 内直接 emit | `didStartRun` |
| `memoryBootstrapLoaded` | bootstrap 完成后直接 emit | `prepareRun` / `didApplyBootstrap` |
| `roundStarted` | round 前直接 emit | `willStartRound` |
| `stopReasonReceived` | stop reason 后直接 emit | `didResolveStopReason` |
| `toolExecutionStarted` | 工具前直接 emit | `willExecuteTool` |
| `toolExecutionFinished` | 工具后直接 emit | `didExecuteTool` |
| `reflectionStarted` | reflection 前直接 emit | `willStartReflection` |
| `reflectionCompleted` | reflection 后直接 emit | `didCompleteReflection` |
| `continuationInjected` | continuation / resume 时直接 emit | `prepareContinuation` / `prepareResumeAfterPause` |
| `loopFinished` | loop 返回前直接 emit | `didFinishRun` |
| `loopFailed` | loop 失败时直接 emit | `didFailRun` |
| `onTextAccumulated` | loop 内直接闭包回调 | `didReceiveTextDelta` / `didAccumulateOutput` |
| memory bootstrap 注入 | loop 内直接构造消息 | `prepareRun` |
| failure trigger 分类 | loop 内直接 if/else 判定 | `classifyFailureTrigger` |
| reflection task memory 写入 | loop 内直接调用 | `didCompleteReflection` |
| continuation prompt 生成 | loop 内直接拼接字符串 | `prepareContinuation` |
| pause resume prompt 生成 | loop 内直接拼接字符串 | `prepareResumeAfterPause` |
| execution guard 决策 | loop 内直接调用 | `decideFinalization` |

要求：

- loop 主体不得再直接调用 `BusinessMonitor.emit(...)`
- loop 主体不得再直接持有 `onTextAccumulated` 这种专用 callback 作为长期扩展方式
- Business Monitor 必须退化为一个内建 `ObserverHook`

## 9. 内建 Hook 组成要求

系统落地时，至少需要内建以下 hook：

### Hook 1：`BusinessObservabilityHook`

职责：

- 订阅 run / round / tool / reflection / finalization 事件
- 将 typed hook 事件映射到现有 `AgentBusinessEvent`
- 统一输出到 `BusinessMonitor`

要求：

- 这是 observability 适配层，不得反向控制 loop 流程

### Hook 2：`MemoryBootstrapHook`

职责：

- 在 `prepareRun` 阶段构建统一记忆、task memory、story memory 注入
- 返回需要插入到消息列表的 bootstrap 结果

要求：

- loop 内核只消费 hook 返回的 bootstrap patch，不直接构建记忆注入文案

### Hook 3：`StreamProjectionHook`

职责：

- 在 `didReceiveTextDelta`、`didReceiveThinkingDelta` 阶段执行 UI 投影
- 控制节流、合并策略与消息投影

要求：

- 这将取代当前 `onTextAccumulated` 特殊闭包

### Hook 4：`ToolAuditHook`

职责：

- 创建 `ToolCall` 记录
- 维护 terminal task 状态投影
- 记录 evidence、输出摘要和审计字段

要求：

- loop 内核只负责请求工具执行，不负责工具审计细节

### Hook 5：`FailureClassificationHook`

职责：

- 根据 tool 结果、子代理结果、workflow 约定产出 `FailureTrigger`

要求：

- reviewer / executor 的特殊语义不得继续散落在 loop 主体中

### Hook 6：`ReflectionHandlingHook`

职责：

- 执行 reflection
- 负责 reflection 持久化、副作用写入与 correction prompt 生成

要求：

- loop 主体只负责在 phase=`reflecting` 时调用 hook dispatcher，不直接理解 reflection 副作用细节

### Hook 7：`FinalizationGuardHook`

职责：

- 在 `decideFinalization` 阶段返回 allow / retry / fail 三类决策

要求：

- 当前 `ExecutionGuard` 应作为该 hook 的实现之一存在

## 10. 执行顺序与错误处理要求

### 功能点 8：保证 Hook 执行顺序稳定

要求：

- 同一阶段的 hook 必须按 `order` 升序串行执行
- 默认不允许并行执行会改写上下文的 hook
- 只有显式声明为只读 observer 的 hook 才允许未来扩展为并行模式

### 功能点 9：定义 Hook 失败隔离策略

要求：

- `observer` hook 失败时，默认记录错误并继续 loop
- `mutator` hook 失败时，若 `isRequired = false`，记录错误并跳过该 hook；若 `isRequired = true`，允许结束本次 loop
- `decisionMaker` hook 失败时，必须返回明确降级策略，不允许把 loop 置于未定义状态

系统至少需要定义以下失败结果：

- `ignored`
- `degraded`
- `abortRun`
- `retryWithFallback`

### 功能点 10：保证 Hook 可测试与可回放

要求：

- hook dispatcher 必须支持注入测试 hook
- 每个 hook 阶段必须可以通过单元测试验证调用顺序、输入快照与返回结果
- loop 测试必须能够在不依赖真实 `BusinessMonitor`、UI 或持久化层的情况下运行

## 11. 结构约束要求

### 功能点 11：Loop 内核必须收敛为最小主体

重构完成后，`runCoreAgentLoop(...)` 或等价内核中的直接职责必须限制为：

- 维护 `AgentLoopContext`
- 发起模型请求
- 读取流式事件
- 聚合本轮原始输出
- 执行工具调用主流程
- 将阶段性交给 hook dispatcher
- 根据 hook 返回结果推进状态机

以下行为不得继续以内联形式长期保留在 loop 主体中：

- business event emit
- UI 文本回推
- memory bootstrap 生成
- continuation / pause prompt 文案拼装
- reviewer / executor 失败语义识别
- reflection 持久化副作用
- `ToolCall` 详情审计与 terminal 事件投影

### 功能点 12：Hook 系统不得退化为新的“万能 God Object”

要求：

- `AgentLoopHookDispatcher` 只负责调度，不负责任何业务判断
- 各 hook 必须按职责单一拆分，不允许重新把所有旁路逻辑塞进一个超大 hook
- hook 之间的数据流必须通过 typed result 或 context patch 传递，不得共享隐式全局状态

## 12. 非功能要求

### 12.1 性能

- hook 引入后，主 loop 额外调度开销必须可控
- 高频阶段如 text delta 处理必须支持节流或批处理，避免每个 delta 都触发重量级持久化
- observer hook 不得阻塞模型流读取

### 12.2 可观测性

- 系统必须能解释某个阶段到底执行了哪些 hook、顺序如何、是否失败
- 调试视图至少要能查看 run 级 hook 执行轨迹

### 12.3 可维护性

- 新增一个 hook 时，不应要求修改 loop 内核的控制流分支
- 新增一个 observability 或 UI 投影需求时，只应新增或替换 hook 实现

## 13. 验收标准

满足以下条件时，本需求视为完成：

1. Agent Loop 中现有所有直接业务触发点都已迁移到 hook 分发机制。
2. `BusinessMonitor` 不再由 loop 主体直接调用，而是由内建 hook 驱动。
3. `onTextAccumulated` 被正式替换为 stream 相关 hook，不再作为 loop 参数长期存在。
4. 统一记忆 bootstrap、failure classification、reflection、副作用持久化、continuation 生成、execution guard 都有明确 hook 归属。
5. 主 Agent、子代理、workflow worker 共享同一套 hook contract。
6. loop 主体的代码审阅结果能够清晰看到“状态机逻辑”和“hook 分发点”两层结构。
7. 至少具备以下测试：
   - hook 调用顺序测试
   - required / optional hook 失败隔离测试
   - main agent 生命周期 hook 触发测试
   - subagent / workflow 复用同一 hook contract 的测试
   - text delta 与 tool 生命周期 hook 的行为测试

## 14. 建议的后续实施顺序

建议按以下顺序实施：

1. 先抽出 `AgentLoopHook`、`AgentLoopHookDispatcher`、typed context / result。
2. 首先迁移 `BusinessMonitor` 与 `onTextAccumulated`，验证 hook 基础骨架可用。
3. 再迁移 memory bootstrap、tool audit、failure classification。
4. 最后迁移 reflection、continuation、execution guard 等决策型逻辑。

这样可以先把“事件统一入口”建立起来，再逐步把复杂副作用移出 loop 内核，避免一次性重写整条执行链。
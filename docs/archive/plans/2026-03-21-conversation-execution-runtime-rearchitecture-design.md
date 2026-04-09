# 2026-03-21 对话执行运行时重构设计方案

日期：2026-03-21

目标：彻底替换当前以 ClaudeService 全局单任务状态为中心的对话执行链路，建立一个模块化、可扩展、支持多会话同时运行、支持同会话消息排队的执行运行时。

关联对象：

1. `ClaudeService`
2. `ConversationExecutionProviderRegistry`
3. `ConversationExecutionRuntimeCoordinator`
4. `GitHubCopilotCLIExecutionProvider`
5. `OpenCodeCLIExecutionProvider`
6. `ChatView`
7. `Session`
8. `Message`
9. SwiftData 持久化链路

关联文档：

1. `docs/workflow-orchestration-design-2026-03-08.md`
2. `docs/plans/2026-03-12-agenticloop-swiftdata-modelactor-implementation-plan.md`
3. `docs/current-capability-baseline-2026-03-14.md`

---

## 1. 结论先行

当前问题不是某个停止按钮、某个 provider、某个 `isStreaming` 判断写得不够严谨，而是整个对话执行架构仍然建立在“当前只有一个活跃执行”的假设上。

这个假设至少体现在四个位置：

1. `ClaudeService` 只暴露一个全局 `isStreaming`。
2. `ChatView` 直接把输入区禁用状态绑定到这个全局布尔值上。
3. provider 接口是一次 `send -> await 完成 -> 返回` 的请求响应模型，不是作业模型。
4. ACP provider 内部把运行时、active turn、取消、消息落盘都混在一个对象里，天然更像“一次执行器调用”，而不是“可调度的会话运行时”。

因此，不建议继续在现有链路上修补，例如：

1. 再加几个局部状态位。
2. 再补一个 `cancel` 特判。
3. 把 `isStreaming` 拆成每个 session 一个字典，但仍然保留原来的直接调用式 provider。

这些都只能缓解眼前问题，不能满足未来要求：

1. 多会话同时运行。
2. 同一会话运行中仍可编辑并发送消息。
3. 消息进入队列，按顺序执行。
4. provider、runtime、UI、持久化彼此解耦。

推荐方案是引入一套新的执行运行时分层：

1. `ConversationExecutionOrchestrator`，负责系统级调度。
2. `SessionExecutionMailbox`，负责每会话串行队列。
3. `ExecutionScheduler`，负责公平挑选可执行作业并分配运行时槽位。
4. `ExecutionRuntimePool`，负责 provider runtime 生命周期和复用。
5. `ConversationExecutionDriver`，负责把具体 provider 适配为统一的作业执行接口。
6. `ExecutionProjectionStore`，负责 UI 可观察状态投影。

本质上，这是把“直接调 provider”改为“向执行系统提交作业”。

## 2. 现状诊断

### 2.1 当前链路的真实形态

当前发送链路大致是：

`ChatView.sendMessage()`

-> `ClaudeService.sendMessage(...)`

-> `ConversationExecutionProviderRegistry.provider(...)`

-> 某个 provider 的 `send(...)`

-> provider 内部自己维护 active turn、runtime、消息、取消和最终状态。

这个形态的核心特点是：

1. 上层把“发送一次消息”当作一次同步的业务动作。
2. provider 把“执行状态”封装在自己内部，而不是上浮成独立运行时状态机。
3. UI 只知道“当前是否在 streaming”，不知道“当前 session 是否在运行”“队列里还有几个作业”“哪条消息是排队中”。

### 2.2 已有的可复用基础

现有代码并非完全没有演进基础，至少已有三块可以复用：

1. provider 抽象已经存在，且开始引入 `runtimeScope`。
2. `ConversationExecutionRuntimeCoordinator` 已经在处理“切换 provider 时释放冲突运行时”的问题。
3. SwiftData、`Session`、`Message`、`ToolCall`、`AgentRound` 这些持久化模型已能承载历史记录和执行投影。

说明仓库已经意识到“运行时协调”与“provider 选择”是两个不同层次，但当前只走到了 runtime conflict coordination，没有走到 queue-based orchestration。

### 2.3 当前架构的根本限制

根本限制不是功能点缺失，而是边界错位：

1. `ClaudeService` 同时承担 API facade、执行控制、UI 状态源和部分持久化控制。
2. provider 同时承担 runtime host、turn state、消息写入、事件归并和取消逻辑。
3. UI 直接消费服务内部布尔状态，而不是消费独立的会话执行投影。

这会导致三个结构性后果：

1. 无法自然支持多会话并发，因为“系统正在执行”与“这个 session 正在执行”被混为一谈。
2. 无法自然支持同会话排队，因为 provider 接口不是作业队列接口。
3. 无法自然支持恢复、重试、替换、编辑 queued 消息，因为没有独立的 job 概念。

## 3. 外部方案调研结论

本次调研重点参考了三类高可信资料：

1. Swift 官方并发文档，关注 actor 隔离、任务取消、`@Sendable`、结构化并发。
2. Apple `swift-async-algorithms`，关注 `AsyncChannel`、merge、buffer、背压语义。
3. Apple SwiftData 文档，关注 `ModelContext`、`transaction`、`ModelActor`、持久化通知和后台写入边界。

### 3.1 对本项目最有用的结论

#### A. actor 适合做执行状态边界，不适合直接承载 UI 模型

Swift actor 非常适合封装以下可变状态：

1. 每会话执行队列。
2. 全局调度器。
3. provider runtime 池。
4. 尝试取消、超时、重试计数。

但 actor 不适合直接作为 SwiftUI 的状态源。UI 仍应消费 `@MainActor` 下的投影模型。

这意味着推荐使用“双层状态”模式：

1. actor 持有真实可变运行时状态。
2. `@Observable` store 持有 UI 投影快照。

#### B. AsyncChannel 很适合做 mailbox 和事件总线

`AsyncChannel` 的价值不是“能做异步序列”，而是它天然具备：

1. producer-consumer 语义。
2. 背压。
3. 可组合进 merge/buffer 管线。

这非常适合用在：

1. `SessionExecutionMailbox` 的作业入口。
2. driver 到 orchestrator 的事件流。
3. orchestrator 到 projection store 的事件总线。

#### C. SwiftData 必须通过独立写边界进入执行系统

SwiftData 文档和仓库已有 ModelActor 迁移计划都指向同一个结论：

1. 后台/异步执行链路不应直接携带 UI 上的 `ModelContext` 到处传。
2. 更不应让多个并发执行路径直接共享 live `@Model` 实例。

因此，新的执行系统不应以 live `Message` 或 live `Session` 为运行时主键，而应使用稳定标识：

1. `sessionId`
2. `messageId`
3. `jobId`
4. `attemptId`

所有 durable state 变更通过持久化写服务完成。

### 3.2 调研后排除的路线

#### 路线 A：继续扩展现有 provider 接口

做法是保留当前 `send/regenerate/editAndResend/cancel` 形式，只在外围加更多状态字典。

不推荐，原因：

1. 作业概念仍不存在。
2. 队列只能在 facade 层伪造。
3. provider 内部 active turn 状态仍然不可被统一调度器接管。

#### 路线 B：完整事件溯源系统

做法是所有运行时状态只保留 event log，再重建投影。

不推荐作为第一阶段，原因：

1. 复杂度过高。
2. 对当前仓库是过度设计。
3. 迁移成本远高于收益。

#### 路线 C：推荐路线，actor 调度 + 持久化作业模型 + UI 投影

这是建议采用的路线：

1. 运行时状态由 actor 隔离。
2. durable queue 由 SwiftData 承载。
3. UI 通过单独的 projection store 消费状态。
4. provider 被下沉为 driver，不再拥有系统级调度职责。

## 4. 设计目标

### 4.1 必须达成的目标

1. 支持多会话同时运行。
2. 同一会话运行中允许继续编辑输入框并发送消息。
3. 新消息进入队列，等待前序作业完成后执行。
4. 停止当前运行不会污染后续 queued 消息。
5. provider、runtime、队列、持久化、UI 投影分层清晰。
6. 后续接入更多执行器时，不需要复制一套 active turn 逻辑。
7. 支持恢复、重试、替换 queued job、取消 queued job。

### 4.2 明确非目标

1. 第一阶段不追求任意 session 内并行执行多条消息。
2. 第一阶段不做完整 event sourcing。
3. 第一阶段不重写消息渲染 UI，只重构其状态来源。
4. 第一阶段不把 workflow runtime 和 conversation runtime 直接合并成一个大引擎。

这里的关键原则是：

多会话并发，单会话保序。

这既满足产品需求，也能避免对话上下文乱序。

## 5. 核心设计原则

### 5.1 每会话串行，不等于全局串行

每个 session 必须有自己的 mailbox。该 mailbox 内的作业默认串行执行，保证消息顺序和上下文一致性。

但系统层面不能再是单活执行。调度器应能同时驱动多个不同 session 的 mailbox，只受运行时槽位和 provider 资源约束限制。

### 5.2 作业是第一公民，消息只是业务载体

当前系统把消息当作执行动作本身，这会让“排队”“编辑 queued 消息”“重试某次尝试”都很别扭。

新系统应把执行对象定义为 `ExecutionJob`，而不是 `Message`。

消息仍然存在，但它只承担：

1. 聊天历史展示。
2. 用户输入内容快照。
3. agent 输出内容承载。

真正的调度、取消、重试、超时、队列顺序，都属于 `ExecutionJob`。

### 5.3 provider 只做执行，不做编排

provider 不再拥有：

1. 系统级队列。
2. 全局 active turn 表。
3. 会话是否允许执行的判断。
4. UI 是否可编辑的直接控制。

provider 只负责把一个 job attempt 执行为事件流。

## 6. 推荐架构

### 6.1 总体分层

建议采用六层结构：

1. `ChatView` / `ChatViewModel` / projection consumer
2. `ExecutionProjectionStore`，面向 UI 的状态投影
3. `ConversationExecutionOrchestrator`，系统级入口
4. `ExecutionScheduler` + `SessionExecutionMailbox`，负责排队与分发
5. `ExecutionRuntimePool` + `ConversationExecutionDriver`
6. `ExecutionPersistenceStore`，负责作业与尝试的 durable state

数据流应变为：

`用户点击发送`

-> 创建或更新 `ExecutionJob`

-> job 进入 `SessionExecutionMailbox`

-> `ExecutionScheduler` 选择可运行 job

-> 从 `ExecutionRuntimePool` 申请 runtime lease

-> 交给具体 `ConversationExecutionDriver`

-> driver 产生事件流

-> orchestrator 消费事件并更新持久化状态

-> `ExecutionProjectionStore` 刷新 UI

### 6.2 模块清单

建议新增或重构为以下模块：

#### A. `ConversationExecutionOrchestrator`

职责：

1. 作为新的统一入口，替代 `ClaudeService.sendMessage(...)` 直接调 provider 的路径。
2. 接收 enqueue、cancel、replace、retry、resume 请求。
3. 连接 scheduler、runtime pool、persistence、projection。

建议接口：

```swift
@MainActor
protocol ConversationExecutionService {
    func enqueue(_ command: EnqueueExecutionCommand) async throws -> ExecutionJobHandle
    func cancelRunning(in sessionID: String) async
    func cancelQueued(jobID: UUID) async
    func replaceQueued(jobID: UUID, with payload: ExecutionPayloadDraft) async throws
    func retry(jobID: UUID) async throws -> ExecutionJobHandle
}
```

#### B. `SessionExecutionMailbox`

职责：

1. 每个 session 一个 mailbox。
2. 只保证本会话内保序。
3. 持有 head job、queued jobs、running attempt 引用。

推荐实现：actor + `AsyncChannel<MailboxCommand>`。

#### C. `ExecutionScheduler`

职责：

1. 在多个 session mailbox 的 head job 中选择可运行作业。
2. 处理公平性和资源上限。
3. 处理 provider runtime scope 的并发限制。

推荐策略：

1. 每 session 仅允许一个 running job。
2. 全局按 round-robin 或 aging fairness 调度。
3. 按 `runtimeScope` 和 `providerID` 施加并发上限。

#### D. `ExecutionRuntimePool`

职责：

1. 管理 built-in 与外部 ACP 运行时实例。
2. 负责 runtime 申请、复用、释放、重置。
3. 处理 session binding 和 provider runtime compatibility。

它替代当前 scattered 在 provider 里的：

1. `runtimeClients`
2. `activeTurns`
3. 跨 provider runtime 释放策略

#### E. `ConversationExecutionDriver`

职责：

1. 统一 provider 执行接口。
2. 对 orchestrator 暴露事件流，而不是 blocking response。

建议接口：

```swift
protocol ConversationExecutionDriver: Sendable {
    var providerID: ConversationExecutionProviderID { get }
    var runtimeScope: ConversationExecutionRuntimeScope? { get }

    func execute(
        job: ExecutionJobSnapshot,
        lease: RuntimeLease
    ) -> AsyncThrowingStream<ExecutionEvent, Error>

    func cancel(attemptID: UUID) async
    func resetSession(sessionID: String) async
}
```

#### F. `ExecutionProjectionStore`

职责：

1. 为 UI 提供每 session 投影。
2. 提供 `isRunning`、`queuedCount`、`activeJobID`、`canEditComposer` 等派生状态。
3. 只做 projection，不做调度。

### 6.3 为什么这套分层适合当前仓库

因为它能直接对接现有三类资产：

1. SwiftUI 需要 `@Observable` 状态源。
2. SwiftData 已经承载消息和会话持久化。
3. provider 已经有 built-in、Copilot ACP、OpenCode ACP 三种路径。

它不是推倒重来，而是把职责重新摆正。

## 7. 新的数据模型

### 7.1 新增 `ExecutionJob`

建议不要把队列状态塞回 `MessageStatus`。应新增独立模型：

```swift
@Model
final class ExecutionJob {
    var id: UUID
    var sessionID: String
    var providerIDRaw: String
    var stateRaw: String
    var payloadJSON: String
    var sourceUserMessageID: UUID?
    var targetAgentMessageID: UUID?
    var enqueuedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var queuePositionHint: Int?
    var replaceableUntilDispatch: Bool
}
```

推荐状态：

1. `queued`
2. `admitted`
3. `running`
4. `completed`
5. `failed`
6. `cancelled`
7. `superseded`

### 7.2 新增 `ExecutionAttempt`

一个 job 可以有多次 attempt，用于：

1. retry
2. provider crash restart
3. runtime handoff

```swift
@Model
final class ExecutionAttempt {
    var id: UUID
    var jobID: UUID
    var stateRaw: String
    var startedAt: Date
    var endedAt: Date?
    var runtimeScopeRaw: String?
    var runtimeInstanceKey: String?
    var stopReason: String?
    var errorMessage: String?
}
```

### 7.3 `Message` 继续保留，但不再承载队列主状态

用户点击发送时，仍然立即创建 user message，这符合聊天产品直觉。

但是否进入执行、是否排队、是否被替换，不再用 `Message.status` 表达，而改为由 `ExecutionJob` 表达。

这样有三个好处：

1. 不污染现有消息渲染和历史逻辑。
2. queued user message 仍可显示为“已提交，等待执行”。
3. agent message 可以在真正 dispatch 时再创建，或者提前创建 placeholder 并由 job 绑定。

### 7.4 新增 `SessionExecutionProjection`

这不是持久化模型，而是 UI 投影：

```swift
struct SessionExecutionProjection: Equatable, Sendable {
    let sessionID: String
    let runningJobID: UUID?
    let queuedJobIDs: [UUID]
    let queuedCount: Int
    let isRunning: Bool
    let canEditComposer: Bool
    let canSubmitNewJob: Bool
    let activeProviderID: ConversationExecutionProviderID?
}
```

`ChatView` 未来只消费它，而不是直接看 `claudeService.isStreaming`。

## 8. 会话并发与队列语义

### 8.1 并发模型

推荐默认并发模型：

1. 单 session 内严格串行。
2. 多 session 间允许并行。
3. provider 或 runtime scope 可配置上限。

示例：

1. built-in provider 允许最多 `N` 个 session 并行。
2. 外部 ACP provider 可以按 provider 或 runtime scope 设独立上限。
3. 同一个 session 无论何种 provider，始终只允许一个 running job。

### 8.2 排队语义

当 session 已有 running job 时：

1. 用户仍可编辑输入框。
2. 点击发送创建新的 `ExecutionJob(state: queued)`。
3. UI 立刻显示 queued 徽标和队列位置。
4. 前序 job 结束后，scheduler 自动 dispatch 队头 job。

### 8.3 编辑 queued 消息的语义

必须明确区分两类编辑：

#### A. 编辑运行中 job

第一阶段不支持就地修改运行中 job 的 payload。

允许的操作是：

1. 取消运行中 job。
2. 新建替代 job。

#### B. 编辑 queued job

支持。

推荐规则：

1. 只要 job 还未 dispatch，就允许更新 payload。
2. 更新时保留同一个 `jobID`，不改变队列顺序。
3. 如果用户希望把 queued job 变成新的末尾作业，则显式执行“移到队尾”或“取消并重发”。

### 8.4 停止语义

停止必须分为两层：

1. `cancelRunning(sessionID)` 只影响当前 attempt。
2. `cancelQueued(jobID)` 只影响队列中的未来作业。

这样“停止当前”不会误伤后续 queued 消息。

## 9. Provider 适配策略

### 9.1 当前 provider 接口为什么要废弃为 facade-only

当前接口：

1. `send`
2. `regenerate`
3. `editAndResend`
4. `cancel`

它的问题是：

1. 所有行为都假设由 UI 直接触发。
2. 没有 job/attempt 标识。
3. 没有 event stream。
4. runtime 生命周期和消息持久化混在一起。

因此建议保留旧接口仅作为过渡 facade，内部立即转成 orchestrator command。

### 9.2 新 driver 责任边界

driver 只负责：

1. 将 job payload 转换成 provider 请求。
2. 将 provider 原始回调、工具事件、token 流、stop reason 标准化为 `ExecutionEvent`。
3. 响应 cancel。

driver 不再负责：

1. 决定是否能执行。
2. 写 UI 状态。
3. 维护全局或系统级 active turn。
4. 维护队列顺序。

### 9.3 ACP provider 的特殊处理

Copilot ACP 和 OpenCode ACP 目前都有自己的：

1. `runtimeClients`
2. `activeTurns`
3. session binding
4. cancel 逻辑

这些都应拆分：

1. runtime client 生命周期交给 `ExecutionRuntimePool`。
2. active turn 生命周期交给 orchestrator attempt state。
3. binding 作为 runtime pool 的一部分管理。
4. provider 仅保留协议适配和事件标准化。

## 10. UI 重构方向

### 10.1 输入框禁用策略重写

输入框不应再绑定“系统是否正在 streaming”。

新的禁用策略应是：

1. 只在 composer 自己不可交互时禁用，例如 provider 不可用、当前 draft 正在本地保存、用户主动锁定输入等。
2. session 有 running job 时，允许继续输入和发送。
3. 发送动作变成 enqueue，不再强依赖当前空闲。

### 10.2 stop/send 按钮策略

推荐改为：

1. 当输入框有内容时，主按钮始终是“发送到队列”。
2. 运行中状态在输入区附近显示单独的 stop 控件和 queued count。
3. session 头部或消息列表顶部显示当前运行状态与排队数。

### 10.3 消息列表状态来源

消息列表当前很多“是否 streaming”的判断，也应切到 projection：

1. message row 是否显示 live indicator。
2. 是否自动滚动到底。
3. 是否允许编辑历史消息。

这些都应基于 `SessionExecutionProjection` 和 `ExecutionJobProjection` 计算，而不是基于单个全局布尔值。

## 11. 持久化与恢复策略

### 11.1 持久化原则

所有 durable queue state 都应先写作业模型，再进入调度。

也就是说，enqueue 的原子性应是：

1. 创建 user message。
2. 创建 `ExecutionJob(state: queued)`。
3. 保存成功后再向 mailbox 投递 in-memory command。

如果第 3 步失败，系统仍可从 durable queue 恢复。

### 11.2 恢复原则

应用重启时，应进行两类恢复：

1. `queued/admitted` job 重新入队。
2. `running` job 标记为 `interrupted` 或进入可恢复判定。

对于 ACP provider，如果 runtime session 可恢复，可通过 runtime pool 继续 attach；否则转为 interrupted 并允许用户 retry。

### 11.3 SwiftData 边界

执行系统不要把 live `ModelContext` 在 actor 间传递。

推荐增加专门的持久化服务，例如：

1. `ExecutionPersistenceStoreActor`
2. `ExecutionJobRepository`
3. `ExecutionProjectionRepository`

执行系统通过 DTO 与 repository 通信。

## 12. 方案备选与取舍

### 12.1 方案 A：轻量演进，保留现有 provider 形态

做法：

1. 把 `isStreaming` 改为 `[sessionId: Bool]`。
2. 在 `ClaudeService` 上加一个简单队列数组。
3. provider 逻辑基本不动。

优点：

1. 改动小。
2. 可以较快把“同会话排队”勉强做出来。

缺点：

1. provider 仍然拥有过多状态。
2. 多会话并发和 runtime 资源协调会迅速失控。
3. 后续恢复、重试、优先级、替换 queued job 都会继续堆补丁。

结论：不推荐。

### 12.2 方案 B：推荐方案，作业驱动的会话邮箱 + 调度器

做法：

1. 引入 `ExecutionJob` 与 `ExecutionAttempt`。
2. 引入 orchestrator、scheduler、runtime pool、projection store。
3. provider 下沉为 driver。

优点：

1. 模块边界清晰。
2. 满足多会话并发与同会话排队。
3. 对未来增加优先级、恢复、批量取消、后台执行都友好。

缺点：

1. 改造面较大。
2. 需要阶段性兼容旧路径。

结论：推荐。

### 12.3 方案 C：统一到 workflow runtime

做法：

直接把 conversation execution 视作 workflow runtime 的一个特例。

优点：

1. 长期统一调度模型。
2. conversation 和 workflow 共用 mailbox/event bus。

缺点：

1. 现阶段复杂度太高。
2. conversation 和 workflow 的产品语义还不完全一致。
3. 迁移风险显著高于方案 B。

结论：作为长期收敛方向可以预留接口，但不应作为本轮落地方案。

## 13. 推荐迁移路径

### 阶段 1：建立新模型，不改产品行为

目标：先把基础设施铺出来。

内容：

1. 新增 `ExecutionJob`、`ExecutionAttempt`、projection 模型。
2. 新增 `ExecutionPersistenceStore`。
3. 新增 orchestrator 空壳和 scheduler 空壳。
4. `ClaudeService` 先改为 facade，内部可继续走旧路径。

收益：

1. 先统一 durable state。
2. 不立刻冲击 UI。

### 阶段 2：旧 provider 包装成 driver

目标：把 provider 从“编排者”降级为“执行器”。

内容：

1. 为 built-in、Copilot ACP、OpenCode ACP 提供 driver adapter。
2. 将 provider 内 active turn 管理逐步上移到 orchestrator。
3. 将 runtime 管理下移到 runtime pool。

### 阶段 3：切换发送入口为 enqueue

目标：从直接执行切到作业提交。

内容：

1. `ChatView.sendMessage()` 改为 enqueue。
2. 输入框不再因 running job 而禁用。
3. UI 开始显示 queued count。

此阶段可以先保守配置：

1. 先以 runtime scope 约束为前提放开多 session 并发。
2. 同会话仍保持严格串行。

当前仓库的实际收口比原方案仍保守一些，但已不再停留在 gate 阶段：

1. `ExecutionJob`、projection、mailbox、scheduler、orchestrator 骨架已经存在。
2. 聊天输入区的 queue-aware 表现也已经具备，并有纯状态单测覆盖。
3. orchestrator 已经接通真实 dispatch / completion / cancel 闭环：enqueue 会创建 durable job、dispatch compatibility driver、在完成或取消后收敛 attempt/job 状态并自动续跑队列头。
4. 发送入口不再依赖显式 feature gate，`ClaudeService.sendMessage(...)`、`regenerate(...)`、`editAndResend(...)` 都已统一走 job runtime。
5. 当前生产配置已放开到最多 2 个并发 job，但 scheduler 仍按 runtime scope 串行化高风险执行器：`builtIn` 和 `externalACP` 各自同 scope 仍只允许单活，避免共享运行时状态互相踩踏。
6. orchestrator 在实例恢复时会从持久化层重建 queued/running jobs：历史 `running` attempt 会先收敛为 `interrupted`，随后对应 job 重新回到 mailbox 继续调度，避免留下永久 pending 的 placeholder 消息和僵尸 job。
7. projection UI 只在当前 session 确实存在 `running` 或 `queued` 投影时启用，避免 idle 场景再次出现全局 `isStreaming` 与 projection 双状态源分裂。

### 阶段 4：开启多会话并发

目标：从“支持排队”升级到“支持真正并发”。

内容：

1. scheduler 启用多 session dispatch。
2. runtime pool 按 provider/scope 施加并发限制。
3. projection UI 显示每 session 执行状态。

### 阶段 5：支持 queued job 编辑与替换

目标：完成用户明确提出的能力。

内容：

1. queued job 可编辑。
2. queued job 可取消。
3. running job 支持 cancel + replace。

## 14. 风险与控制

### 14.1 最大风险

最大的风险不是代码量，而是迁移过程中同时存在两套执行状态源。

必须避免出现：

1. 一部分 UI 看 `claudeService.isStreaming`。
2. 另一部分 UI 看 `SessionExecutionProjection`。

否则会继续产生状态分裂。

### 14.2 风险控制原则

1. 一旦某个 UI 区域接入 projection，就彻底移除对旧全局状态的依赖。
2. provider 迁移时，禁止新增新的本地 active turn 逻辑。
3. 所有取消、重试、替换语义都必须先落到 job/attempt，再触发 runtime 操作。
4. dispatch / cancel / completion 一旦接通，必须彻底移除发送 gate，避免 runtime 与 legacy path 再次长期并存。

## 15. 2026-03-21 收尾状态

本轮实现完成后，当前设计落地状态应理解为“发送闭环与恢复入口都已接通，剩余尾项主要集中在更高阶能力”：

1. 已完成 durable job / attempt 模型、persistence store、mailbox、scheduler、projection store、compatibility driver 和 queue-aware UI 基础形态。
2. 已补上关键回归保护：取消当前运行中的 job 不会清掉同 session 的 queued job，且取消后会自动推进队列中的下一条 job。
3. 已把 `ClaudeService.isStreaming` 标记为 deprecated，明确其仅为 legacy fallback。
4. orchestrator 与 compatibility driver 已接成真实 dispatch、completion 和 cancel 闭环，显式 feature gate 已移除。
5. `sendMessage`、`regenerate`、`editAndResend` 已统一收口到 job runtime，并复用同一套 enqueue / dispatch / cancel / projection 生命周期。
6. scheduler 已允许多 session 并发，但仍按 `builtIn` 与 `externalACP` runtime scope 保持同 scope 单活；这是当前验证后可接受的安全边界。
7. orchestrator 已具备 durable job 恢复能力，应用或 service 重建后会把 persisted queued/running jobs 重挂回 mailbox，并把旧 running attempt 收敛为 `interrupted`。
8. 剩余尾项主要是更细粒度的 queued job 编辑/替换能力。
9. 如果后续还要继续放宽并发，必须先把 built-in 从 `ClaudeService` 的全局状态彻底改造成 per-session 隔离执行状态；在这件事完成前，不应继续提升 built-in 相关并发能力。

## 16. 建议落地文件边界

建议新增或重构的文件边界如下：

1. `agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
2. `agentGui/Services/Execution/ExecutionScheduler.swift`
3. `agentGui/Services/Execution/SessionExecutionMailbox.swift`
4. `agentGui/Services/Execution/ExecutionRuntimePool.swift`
5. `agentGui/Services/Execution/ConversationExecutionDriver.swift`
6. `agentGui/Services/Execution/ExecutionProjectionStore.swift`
7. `agentGui/Services/Execution/ExecutionPersistenceStore.swift`
8. `agentGui/Models/ExecutionJob.swift`
9. `agentGui/Models/ExecutionAttempt.swift`
10. `agentGui/ViewModels/SessionExecutionProjection.swift`

现有以下文件应逐步退化为 facade 或适配层：

1. `agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
2. `agentGui/Services/ConversationExecutionRuntimeCoordinator.swift`
3. `agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
4. `agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`

## 17. 最终建议

本轮技术改造不应以“修掉停止后输入框状态不回落”为目标收束。

那个问题只是当前架构的一次症状暴露。真正应该做的是把对话执行从：

1. 单全局状态
2. 直接调用 provider
3. provider 内部自管 active turn

重构为：

1. 每会话 mailbox
2. 系统级 scheduler
3. 独立 runtime pool
4. job/attempt 持久化模型
5. UI projection

推荐采用方案 B，也就是“作业驱动的会话邮箱 + 调度器”方案。

原因很直接：

1. 它是当前仓库复杂度下最稳的长期方案。
2. 它可以先支持同会话排队，再自然扩展到多会话并发。
3. 它不要求一开始就统一到 workflow runtime，但为长期统一预留了边界。

如果下一步继续推进实现，建议先写一份严格按阶段拆解的 implementation plan，并以阶段 1 到阶段 3 为第一个交付批次。
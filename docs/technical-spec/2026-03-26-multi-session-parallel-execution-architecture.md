# agentGui 多会话并行执行架构设计

日期：2026-03-26

## 1. 文档目标

本文档回答的问题是：

> 在 agentGui 当前同时支持 built-in agent 与 ACP / Copilot 类外部执行器的前提下，如何把“单活会话执行”升级为“多会话并行执行”，使用户从会话 A 切换到会话 B 时，会话 A 仍可继续运行、持续落盘、可回放、可取消、可恢复。

本文档覆盖：

1. 当前实现中限制并行执行的关键原因。
2. 为什么问题的根源不只是 UI 切换，而是前台状态、调度器和 provider runtime 生命周期被错误耦合。
3. 一个面向 v1 的多会话并行执行架构，优先解决“多会话并行”，并为未来多 agent 并发 / agent team 预留扩展位。
4. 推荐的数据模型、服务拆分、迁移顺序、风险和验证策略。

非目标：

1. 本文档不直接提交运行时代码实现。
2. 本文档不把“一会话内多 agent 并发执行”作为 v1 必达目标。
3. 本文档不讨论远程 channel、Feishu、workflow graph 等更大范围的统一编排替换。
4. 本文档不要求一次性重写现有 execution job / projection / ACP binding 基础设施。

## 2. 结论先行

推荐结论如下：

1. v1 应明确引入“**选中的会话**”与“**正在运行的会话**”分离的架构，不再让 `WorkspaceState.selectedSession` 参与 runtime 所有权决策。
2. built-in 与 ACP 执行面都应改为**会话级 execution context**，而不是依赖全局 `currentSession` 或“同一 runtime scope 只能有一个活跃会话”的假设。
3. `ConversationExecutionRuntimeCoordinator` 不应在会话切换时关闭同 scope 的其它 runtime；它应转为非破坏性的 runtime warmup / activation coordinator。
4. `ExecutionScheduler` 不应再以 `runtimeScope` 作为天然互斥锁；应改为 provider-capacity / session-capacity 驱动的调度策略。
5. ACP 侧实际上已经有较好的 per-session 基础设施：`ACPSessionRuntimeRegistry`、`ACPSessionRuntimeActor`、binding/state store 都是按 session 组织的；当前阻碍并行的主要问题，是 `ACPExternalExecutionProviderBase.prepareForActivation()` 与 `closeInactiveSessionRuntimes()` 主动关闭其它会话。
6. built-in 侧的最大阻碍，是 `ClaudeService.currentSession` 与依赖它的审批/交互路径。这部分必须拆成 session-scoped execution context registry。
7. 现有 `ExecutionJob`、`ExecutionPersistenceStore`、`ExecutionProjectionStore`、`SessionExecutionMailbox` 已经提供了不错的作业队列基础，应尽量复用，而不是重做。

一句话概括：

> 这次不是“给会话列表加个后台 badge”，而是把“前台选择态”和“执行控制态”彻底解耦，把运行时所有权从 UI 选中状态迁移到会话级 execution controller 上。

## 3. 现状调研摘要

### 3.1 当前 built-in 执行路径

当前 built-in agent 的主链路如下：

1. `ChatView+Actions.sendMessage()` 触发发送。
2. `ClaudeService.sendMessage(...)` 走 `ConversationExecutionOrchestrator.enqueue(...)`。
3. `ConversationExecutionOrchestrator.dispatch(...)` 选择 provider、准备 runtime、创建 driver。
4. `BuiltInConversationExecutionProvider.send(...)` 调用 `ClaudeService.sendMessageBuiltIn(...)`。
5. `ClaudeService.resumeSendBuiltIn(...)` 设置 `currentSession = session`，再进入 `runAgenticLoop(...)`。
6. `runAgenticLoop(...) -> runCoreAgentLoop(...) -> AgentLoopRunner / AgentLoopRoundExecutor` 执行多轮工具调用循环。

关键文件：

1. `agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
2. `agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift`
3. `agentGui/Services/AgentLoopRunner.swift`
4. `agentGui/Services/AgentLoopRoundExecutor.swift`
5. `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`

### 3.2 当前 ACP 执行路径

当前 ACP / Copilot 类 provider 的主链路如下：

1. `ConversationExecutionOrchestrator.dispatch(...)` 选择 external ACP provider。
2. `ACPExternalExecutionProviderBase.send(...)` 负责配置解析、可用性探测、远端会话准备、prompt 派发、更新投影和 assistant message 收敛。
3. runtime 生命周期由 `ACPProviderRuntimeSupervisor -> ACPSessionRuntimeRegistry -> ACPSessionRuntimeActor` 管理。
4. `ACPSessionRuntimeActor` 负责一条 local session 对应的 transport client、remote session 恢复与重建。
5. `ACPExternalAgentRuntimeClient.ensureSession(...)` 约束单个 runtime client 同时只能附着一个 remote session。

关键文件：

1. `agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
2. `agentGui/Services/ACP/ACPProviderRuntimeSupervisor.swift`
3. `agentGui/Services/ACP/ACPSessionRuntimeRegistry.swift`
4. `agentGui/Services/ACP/ACPSessionRuntimeActor.swift`
5. `agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`

#### 3.2.1 ACP runtime / runtime client / transport 当前分层

结合当前实现，ACP 链路实际上已经分成四层，而且层次边界相对清晰：

1. **provider/session runtime 管理层**
   `ACPProviderRuntimeSupervisor -> ACPSessionRuntimeRegistry` 按 `(providerID, localSessionID)` 找到或创建 `ACPSessionRuntimeActor`。
2. **session runtime actor 层**
   `ACPSessionRuntimeActor` 持有当前 local session 的 `runtimeClient`、`runtimeWorkingDirectory`、`activationID`、`lastHandshake`，负责 restore / rebuild / cancel / close。
3. **runtime client 层**
   `ACPExternalAgentRuntimeClient` 封装 `ACPManagedClientRuntime`，内部有 `attachedSessionHandshake`，因此**单个 runtime client 天然只服务一个 remote session**。
4. **transport / protocol 层**
   `ACPManagedClientRuntime` 负责拉起外部进程，并把 `ACPTransport + ACPConnection(actor) + ACPMessageRouter + ACPLocalClientHandler(actor)` 组装为一个完整的 ACP 会话通道。

这四层的意义要在设计上明确写死：

1. `ACPSessionRuntimeActor` 是**local session 级别**的控制平面。
2. `ACPExternalAgentRuntimeClient` 是**单 session / 单 remote session 级别**的协议客户端，不应该跨 session 复用。
3. `ACPConnection`、底层 `transport`、`ACPMessageRouter`、`ACPLocalClientHandler` 也应视为**随 runtime client 一起创建和销毁**的隔离资源。
4. 真正允许共享的，只应是 provider 静态配置、binding store、projection store、permission center 这类上层协作组件，而不是 protocol transport 本身。

换句话说，多会话并行下正确的模型不是“一个 provider 挂多个 session”，而是：

> 一个 provider manager 管多个 session runtime；每个 session runtime 拥有自己独立的 runtime client、connection、transport、router 和 local handler。

### 3.3 当前“单活会话”约束来自哪里

现状中，限制并行执行的关键点不是一个，而是三层叠加：

#### A. 前台 UI 绑定被误当成运行时所有权

`WorkspaceState.selectedSession` 当前既承担“当前展示哪个会话”的角色，也在大量路径里被间接视为“当前 active session”。

相关文件：

1. `agentGui/Utilities/WorkspaceState.swift`
2. `agentGui/Views/Workbench/WorkbenchConversationPane.swift`
3. `agentGui/Views/ChatView.swift`

这会让“切换会话”天然带出“切换 active runtime”的心智和实现路径。

#### B. built-in 运行时依赖全局 currentSession

`ClaudeService` 中存在全局：

1. `currentSession`
2. `isStreaming`

其中 `AgentLoopToolExecutionCoordinatorBuilder.requestApprovalIfNeeded(...)` 直接用：

```swift
guard claudeService.currentSession?.sessionId == sessionId else {
    return nil
}
```

这意味着：一旦 `currentSession` 被新会话覆盖，旧会话上的审批/交互路径就可能失效或退化。

相关文件：

1. `agentGui/Services/ClaudeService/ClaudeService.swift`
2. `agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
3. `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`

#### C. 调度和 ACP 激活逻辑显式地关闭其它会话

当前代码里有两条强约束：

1. `ExecutionScheduler` 用 `runtimeScope` 做互斥，同一 scope 只 admit 一个 job。
2. ACP provider 在激活时会主动关闭其它 session runtime。

证据如下：

1. `ExecutionScheduler.admitReadyJobs(...)` 中使用 `reservedRuntimeScopes`，导致 `.builtIn` 与 `.externalACP` 各自天然串行。
2. `ConversationExecutionRuntimeCoordinator.prepareForActivation(...)` 会遍历同 scope provider，并对非 active provider 调用 `prepareForActivation(isActiveProvider: false)`。
3. `ACPExternalExecutionProviderBase.prepareForActivation(...)` 中：
   - `isActiveProvider == true` 时调用 `closeInactiveSessionRuntimes(keeping:)`
   - `isActiveProvider == false` 时调用 `deactivateAllSessionRuntimes()`
4. `ACPExternalExecutionProviderBase.send(...)` 一开始也会调用 `closeInactiveSessionRuntimes(keeping:)`

相关文件：

1. `agentGui/Services/Execution/ExecutionScheduler.swift`
2. `agentGui/Services/ConversationExecutionRuntimeCoordinator.swift`
3. `agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`

### 3.4 当前已经存在、值得复用的基础设施

现有仓库并不是完全没有并发基础，相反，以下能力已经相当接近目标架构：

1. `ExecutionJob` / `ExecutionAttempt`
   已提供 job 队列与 attempt 持久化。
2. `ExecutionPersistenceStore`
   已支持 enqueue、recoverableJobs、start、finish。
3. `SessionExecutionMailbox`
   已按 session 隔离待执行 job。
4. `ExecutionProjectionStore`
   已按 session 维护 UI 可消费的执行投影。
5. `ACPSessionRuntimeRegistry`
   已按 `(providerID, localSessionID)` 维护 runtime actor，而不是单例。
6. `ACPSessionRuntimeActor`
   已具备单 session runtime 重建、恢复、取消能力。
7. `ACPExternalSessionBindingStore` / `ACPExternalProviderSessionStateStore`
   已具备 local session 到 remote session 的持久化与暂态映射。

结论：当前代码库真正缺少的不是“每会话独立数据结构”，而是“允许这些 per-session 结构同时活着的调度与生命周期策略”。

## 4. 问题定义

从产品视角看，用户诉求是：

1. 会话 A 开始执行后，即使用户切到会话 B，会话 A 也继续工作。
2. 会话 A 的进度、工具调用、审批阻塞、完成结果仍然持续更新。
3. 用户可以从会话列表、时间线、提醒入口看见会话 A 是否仍在运行、是否需要关注。
4. 用户可以在不切回 A 的情况下取消 A，或在需要时一键回到 A 处理阻塞。

从系统视角看，这要求运行时满足：

1. **会话级隔离**：执行状态、审批状态、流式输出状态不能是全局单例。
2. **非破坏性切换**：切换选中会话不能隐式 cancel / deactivate 其它会话。
3. **可恢复**：应用重启后能恢复 job / projection / remote binding。
4. **可观测**：后台运行中的会话必须有持续投影。
5. **可扩展**：未来扩展到多 agent 并发时，不需要再次拆掉“单 session 独占 runtime”的假设。

## 5. 设计目标

### 5.1 必达目标

1. 支持 built-in session 与 ACP session 在不同会话中并行执行。
2. 会话切换不再影响已经运行的其它会话。
3. 保持 `ExecutionJob` / `ExecutionProjectionStore` / ACP binding 现有资产可复用。
4. 保持取消、恢复、错误落盘、时间线展示语义清晰。
5. 设计应模块化，可为后续 agent team 提供执行平面基础。

### 5.2 非目标

1. 不保证所有 provider 无限并发。
2. 不在 v1 引入 workflow graph、mailbox routing、agent-to-agent 消息总线。
3. 不要求一会话内多个 agent 真并行执行。
4. 不在 v1 做跨进程分布式调度。

## 6. 设计原则

### 6.1 选中态不等于执行态

`selectedSession` 只表示当前前台显示对象，不再表示唯一 active runtime owner。

### 6.2 会话是执行控制的最小单位

调度、审批、取消、恢复、流式状态都按 session 切分。

### 6.3 provider 并发能力由策略声明，而不是隐式写死

“同一 runtime scope 天然串行”过于粗糙。真正应表达的是：

1. 单 session 是否允许并发多个 job。
2. 单 provider 最多允许多少活跃 session。
3. 某 provider 的 runtime 是否必须独占底层资源。

### 6.4 UI 只消费投影，不直接驱动运行时拆除

切换 ChatView 只能改变展示，不应触发 runtime teardown。

### 6.5 优先演进，不大爆炸重写

尽量在现有 `ConversationExecutionOrchestrator`、`ExecutionProjectionStore`、ACP runtime actor 基础上增量演进。

### 6.6 MainActor 只承载 UI 状态发布与用户决议

多会话并行不是单纯放开调度，还要求明确线程职责边界，避免把耗时链路继续堆在 `MainActor` 上。

主线程应只负责：

1. SwiftUI 可观察状态更新。
2. `ExecutionProjectionStore` / `SessionExecutionRegistry` 一类面向展示的状态发布。
3. 权限审批、`ask_user_question`、跳转会话等用户交互决议。

主线程不应承担：

1. 外部进程启动与关闭。
2. ACP `initialize` / `loadSession` / `prompt` / `cancel` 的协议往返等待。
3. stdio transport 读写、流式事件接收、终端输出轮询。
4. session 恢复、binding 读取、runtime 回收与超时控制。
5. 文件系统 / 终端等潜在慢 IO。

如果 API 入口短期仍在 `@MainActor` 上，推荐模式也应是“快速组装参数后立即切到 actor / detached task 执行，完成后再 hop 回主线程发布投影”，而不是把整个 runtime 握手和 IO 链路都挂在主线程上。

## 7. 推荐架构

### 7.1 总体架构

推荐把执行面明确拆成四层：

1. `WorkspaceSelectionState`
   只负责当前前台会话选择。
2. `SessionExecutionController`
   每个 session 一个，负责该 session 的 execution state、审批、attention、取消、恢复。
3. `ProviderRuntimeManager`
   每个 provider 一个，负责创建 / 回收 session 级 runtime 实例。
4. `ExecutionScheduler`
   只做容量约束与公平调度，不做“切视图时关闭别人 runtime”这类行为。

示意关系：

`UI selection -> SessionExecutionProjection <- SessionExecutionController -> ProviderRuntimeManager -> runtime(session scoped)`

这里最关键的变化是：

> “会话是否在运行”由 `SessionExecutionController` 决定，而不是由当前前台选中了哪个 `ChatView` 决定。

### 7.2 会话执行状态模型

建议把当前 `SessionExecutionProjection` 从偏队列视角，升级为“队列 + 活动 + 注意力”三段式投影。

推荐新增或扩展字段：

```swift
struct SessionExecutionProjection: Equatable, Sendable {
    let sessionID: String

    let runningJobID: UUID?
    let queuedJobIDs: [UUID]
    let queuedCount: Int

    let activityState: SessionExecutionActivityState
    let presentationState: SessionExecutionPresentationState
    let needsAttention: Bool
    let attentionReason: SessionExecutionAttentionReason?

    let activeProviderID: ConversationExecutionProviderID?
    let currentPhase: AgentLoopPhase?
    let lastProgressAt: Date?
}
```

其中：

1. `activityState` 负责表达 `idle / queued / running / blocked / finishing`。
2. `presentationState` 负责表达 `foreground / background`。
3. `needsAttention` 负责表达“该会话虽不在前台，但需要用户处理审批 / prompt / 错误”。

这样 UI 才能自然表达：

1. 前台运行
2. 后台运行
3. 后台等待用户审批
4. 后台已完成但未读

### 7.3 选择态与执行态解耦

推荐保留 `WorkspaceState.selectedSession` 作为纯 UI 状态，但增加独立的执行注册中心：

```swift
@MainActor
final class SessionExecutionRegistry {
    func controller(for sessionID: String) -> SessionExecutionController
    func projection(for sessionID: String) -> SessionExecutionProjection
    func runningSessionIDs() -> [String]
}
```

`ChatView`、`SessionListView`、Timeline、toolbar badge 都只从 registry / projection store 读取状态，不直接依赖 `ClaudeService.currentSession` 这类全局变量。

### 7.4 built-in 运行时：从全局 currentSession 改为 session context registry

这是 built-in 并行化的核心改造。

当前问题：

1. `ClaudeService.currentSession` 是单值。
2. 审批逻辑通过 `currentSession?.sessionId == sessionId` 判断是否可继续。
3. `isStreaming` 也是全局。

推荐改为：

```swift
@MainActor
final class BuiltInSessionExecutionRegistry {
    func context(for sessionID: String) -> BuiltInSessionExecutionContext
}

struct BuiltInSessionExecutionContext {
    let sessionID: String
    var isRunning: Bool
    var currentInputTokens: Int
    var currentModelID: String
    var pendingApproval: PendingToolApproval?
    var pendingUserQuestion: AskUserQuestionRequest?
}
```

关键变化：

1. `ClaudeService` 不再持有单个 `currentSession`，改为按 session 查 context。
2. `AgentLoopToolExecutionCoordinatorBuilder` 的审批路径改为基于 `sessionId` 直接路由，而不是看当前前台 session。
3. `pendingUserQuestion` 也要变成 session-scoped，否则后台会话一旦触发问题弹窗，会覆盖前台状态。

这一拆分完成后，built-in loop 就天然具备“多个 session 同时推进”的前提。

### 7.5 ACP 运行时：从“切换激活即关闭他人”改为“session-scoped runtime retention”

ACP 侧现状其实已经接近目标：

1. `ACPSessionRuntimeRegistry` 是按 session 保存 activation。
2. `ACPSessionRuntimeActor` 是 per-session。
3. `ACPExternalAgentRuntimeClient` 单 client 只能附着一个 remote session，但这不是问题，因为本来就应是“一会话一个 client/runtime 实例”。

真正要改的是生命周期策略：

#### 当前错误策略

1. `prepareForActivation(isActiveProvider: true)` 会 `closeInactiveSessionRuntimes(keeping:)`
2. `prepareForActivation(isActiveProvider: false)` 会 `deactivateAllSessionRuntimes()`
3. `send(...)` 一开始也会清理其它 runtime

#### 推荐策略

1. `prepareForActivation(...)` 重命名语义为 `prepareSessionRuntime(...)`，变成**非破坏性 warmup**。
2. 切换到会话 B 时，只 warm B，不关闭 A。
3. 只有在以下情况下才允许回收某 session runtime：
   - 用户显式 reset / cancel and teardown
   - provider 达到并发容量上限，需要按策略驱逐最旧 idle runtime
   - 应用关闭或 provider 全局重置

也就是说，ACP 并发的关键不是“让一个 runtime client 挂多个 session”，而是“允许多个 session runtime actor 同时存在”。

#### 7.5.1 隔离边界要落实到 runtime client 与 transport

这里需要特别强调运行时内部的实例关系，否则实现时很容易又退回到“provider 级单例 runtime”：

1. 一个 `ACPSessionRuntimeActor` 对应一个 local session 的执行上下文。
2. 一个 `ACPSessionRuntimeActor` 在任一时刻最多持有一个 `ACPExternalAgentRuntimeClient`。
3. 一个 `ACPExternalAgentRuntimeClient` 对应一个 `ACPManagedClientRuntime`。
4. 一个 `ACPManagedClientRuntime` 对应一条独立的 `ACPConnection`、一条独立的 `ACPTransport`、一个独立的 `ACPMessageRouter` 和一个独立的 `ACPLocalClientHandler`。

因此，多会话并行时的隔离要求应明确为：

1. **transport 隔离**
   不同 session 不能共享同一条 stdio / pipe transport，避免请求 ID、流事件、错误传播和 close 语义互相污染。
2. **runtime client 隔离**
   `attachedSessionHandshake` 的单会话约束保留，不要试图把一个 runtime client 改造成多 remote session 复用器。
3. **handler 隔离**
   `ACPLocalClientHandler` 内部维护 `terminalStates`，它应随 session runtime 一起隔离，避免 terminal ID 和 sessionID 路由串线。
4. **terminal runtime 隔离**
   `terminalRuntimeProvider(request.sessionID)` 已经在向 session 级终端运行时靠拢；设计上应保持“终端任务命名空间按 session 切分”。
5. **activation 隔离**
   `RuntimeActivationID` 的职责应继续保留，用来丢弃旧 runtime 残留更新，避免 rebuild 后的旧事件写回新会话状态。

这也是为什么“单 client 单 remote session”不是瓶颈，而是并发安全的边界：真正的并行来自多个 session runtime 并存，而不是在一个 client 里复用多个 remote session。

#### 7.5.2 ACP 外层对象与后台执行边界

当前代码中 `ACPExternalExecutionProviderBase`、`ACPProviderRuntimeSupervisor`、`ACPExternalProviderRuntimeTransportClient` 等外层接口带有 `@MainActor`，这在单活模型下问题不明显，但在多会话并行下需要额外约束：

1. `@MainActor` provider facade 可以保留，用于承接 UI 触发、写入 projection 和协调用户交互。
2. 真正的 runtime 工作必须下沉到 `ACPSessionRuntimeActor`、`ACPConnection`、`ACPLocalClientHandler` 这类后台隔离单元。
3. `initializeIfNeeded()`、`loadSessionIfPossible()`、`createSession()`、`prompt()`、`cancel()` 的等待过程不应长期占据主线程。
4. provider 层如果暂时还保留 `@MainActor` 协议，应把耗时步骤封装到非主线程 actor / task 中执行，再把结果回推到主线程状态层。

设计上可以接受“主线程拥有 facade”，但不能接受“主线程拥有 transport 生命周期”。

### 7.6 调度器：从 runtime scope 互斥，升级为容量策略

当前 `ExecutionScheduler` 的问题，是把 `.builtIn` / `.externalACP` 当成天然全局锁。

推荐改为：

```swift
struct ProviderExecutionCapacityPolicy: Sendable {
    let providerID: ConversationExecutionProviderID
    let maxConcurrentSessions: Int
    let maxConcurrentJobsPerSession: Int
    let allowsBackgroundExecution: Bool
}
```

调度规则建议如下：

1. 同一 session 仍默认 `maxConcurrentJobsPerSession = 1`，避免同一对话同时跑两条 job。
2. built-in provider 默认允许多个 session 并发。
3. ACP provider 默认也允许多个 session 并发，但容量可配置，例如 2 或 3。
4. capacity 不足时，新的 job 进入队列，不因为用户切换会话而抢占旧 job。

这样一来，调度器表达的是“资源容量”，而不是“视图焦点”。

### 7.7 RuntimeCoordinator：从 destructive activation 改为 capability-aware warmup

当前 `ConversationExecutionRuntimeCoordinator.prepareForActivation(...)` 会遍历同 scope provider，并触发对其它 provider 的反向 prepare。这在单活模型下成立，但在并发模型下是破坏性的。

推荐改为：

```swift
@MainActor
struct ConversationExecutionRuntimeCoordinator {
    func warmRuntimeIfNeeded(
        session: Session,
        provider: any ConversationExecutionProvider,
        modelContext: ModelContext,
        reason: RuntimeWarmupReason
    ) async
}
```

原则：

1. warmup 只针对目标 `(provider, session)`。
2. 不再通知同 scope 其它 provider 做 teardown。
3. 真正的资源回收由 provider runtime manager 根据 capacity policy 独立决定。

### 7.8 后台执行中的阻塞与用户交互

多会话并行后，一个现实问题是：后台会话可能在执行中遇到审批、终端 prompt、`ask_user_question`。

v1 推荐策略：

1. 会话继续后台运行，直到遇到需要人工输入的阻塞点。
2. 一旦阻塞，session projection 变为 `needsAttention = true`。
3. UI 在会话列表、侧边栏 badge、通知中心统一暴露“会话 X 等待处理”。
4. 用户可以：
   - 直接在全局弹层处理
   - 或跳转回该会话处理
5. 未处理前，该会话保持 `blocked`，而不是被隐式 cancel。

这样既能满足后台并行，又不会把敏感审批自动化。

### 7.9 持久化与恢复

现有 `ExecutionPersistenceStore` 已经具备 job 恢复能力，ACP binding 也能恢复 remote session。v1 只需要把会话级 execution context 的恢复补齐：

1. 启动时恢复 pending / running job 到 mailbox。
2. 恢复每个 session 的 projection。
3. built-in session context 恢复到“可继续展示”的状态，但不强求恢复流式 token 细节。
4. ACP session 若 provider 支持 `session/load`，继续按现有 binding 恢复 remote session。

重点是：

> 恢复的入口应是 execution registry / orchestrator，而不是“只有当前选中的会话才 bootstrap”。

### 7.10 UI 线程保护策略

为了避免多会话后台运行拖慢前台交互，建议把线程边界作为架构约束写入实现标准：

1. `SessionExecutionController` / registry 的公开状态更新可以在 `MainActor`。
2. `ExecutionProjectionStore` 的最终 publish 可以在 `MainActor`，但事件归并、归一化和去抖不应依赖主线程长时间串行执行。
3. `ACPConnection` 的消息接收、`transport.send`、`ACPSessionRuntimeActor.prepareRuntimeSession(...)`、`ACPManagedClientRuntime.launch(...)` 应视为后台执行路径。
4. built-in agent loop 中的工具执行、bash 观察、LSP / 文件系统 IO 同样不应以 `ClaudeService @MainActor` 为天然运行上下文。
5. 所有跨线程回主的操作都应尽量聚焦在：
   - 更新可观察状态
   - 写入或刷新 message / tool call projection
   - 发布 attention / approval / ask-user-question 事件

尤其要避免以下反模式：

1. 在 `MainActor` 上等待 `initialize` / `loadSession` 超时。
2. 在 `MainActor` 上串行 drain 多个后台 session 的 update task。
3. 在 `MainActor` 上做高频终端输出轮询和大文本拼接。
4. 把“为保证线程安全”误写成“所有运行时调用都放到主线程”。

如果后续实现需要在协议层调整隔离，优先方向应是：

1. 保持 UI-facing store / interaction center 在 `MainActor`。
2. 将 ACP transport client 协议和 runtime client 的耗时方法迁移到普通 actor 或 `Sendable` 后台对象。
3. 通过显式事件投递，而不是主线程共享可变状态，连接后台 runtime 与前台 UI。

## 8. 推荐模块拆分

### 8.1 新增或重构的核心模块

#### A. `SessionExecutionRegistry`

职责：

1. 管理 session -> controller 映射。
2. 提供 projection 查询。
3. 汇总 running / blocked / attention 状态。

#### B. `SessionExecutionController`

职责：

1. 管理单 session 的生命周期。
2. 接收 job started / finished / blocked / progress 事件。
3. 更新 `ExecutionProjectionStore`。
4. 路由 cancel / attention resolve / foreground attach。

#### C. `BuiltInSessionExecutionRegistry`

职责：

1. 存储 built-in per-session 执行上下文。
2. 替代 `ClaudeService.currentSession`、全局 `pendingUserQuestion`。
3. 为审批、prompt、token 统计提供 session-scoped 状态。

#### D. `ProviderExecutionCapacityPolicy`

职责：

1. 声明 provider 并发能力。
2. 供 `ExecutionScheduler` 和 provider runtime manager 共同使用。

### 8.2 尽量保留的模块

以下模块建议保留并演进，而不是推倒重来：

1. `ConversationExecutionOrchestrator`
2. `ExecutionPersistenceStore`
3. `ExecutionProjectionStore`
4. `SessionExecutionMailbox`
5. `ACPSessionRuntimeRegistry`
6. `ACPSessionRuntimeActor`
7. `ACPExternalSessionBindingStore`

## 9. 关键接口建议

### 9.1 Provider 并发能力声明

建议在 provider 或 registry 层增加：

```swift
protocol ConversationExecutionProvider: AnyObject {
    var id: ConversationExecutionProviderID { get }
    var runtimeScope: ConversationExecutionRuntimeScope? { get }
    var capacityPolicy: ProviderExecutionCapacityPolicy { get }
}
```

如果短期不想改 protocol，也可以由 registry 外挂一份 policy map。

### 9.2 ACP provider 生命周期接口

建议把今天的：

```swift
func prepareForActivation(
    session: Session,
    isActiveProvider: Bool,
    modelContext: ModelContext,
    trigger: ConversationExecutionActivationTrigger
) async
```

重构为更符合语义的接口：

```swift
func warmSessionRuntimeIfNeeded(
    session: Session,
    modelContext: ModelContext,
    reason: RuntimeWarmupReason
) async
```

这能避免“是否 active provider”这种单活时代概念继续污染并发模型。

### 9.3 built-in 审批与问题路由

建议新增统一的 session-scoped 交互中心：

```swift
@MainActor
final class SessionInteractionCenter {
    func publishToolApproval(_ request: ToolApprovalRequest, for sessionID: String)
    func publishUserQuestion(_ request: AskUserQuestionRequest, for sessionID: String)
    func resolve(sessionID: String, response: SessionInteractionResponse)
}
```

这会比把审批、prompt、ask-user-question 散落在 `ClaudeService` 全局变量里更可扩展，也更适合未来 agent team 共享。

## 10. 迁移计划

推荐分四步落地。

### Phase 1：先解耦展示态与执行态

目标：

1. `WorkspaceState.selectedSession` 只保留 UI 语义。
2. `SessionListView`、toolbar、ChatView 改为从 `ExecutionProjectionStore` 读状态。
3. 明确区分前台运行 / 后台运行 / 后台阻塞。

收益：

1. 不改 provider runtime 就能先把状态模型理顺。
2. 降低后续 runtime 改造的 UI 风险。

### Phase 2：built-in 改成 per-session execution context

目标：

1. 移除 `ClaudeService.currentSession` 对审批路径的控制作用。
2. 把 `pendingUserQuestion`、streaming/token 等状态 session 化。
3. 让多个 built-in session 可以同时存在活跃 loop。

这是 v1 成败的核心步骤。

### Phase 3：ACP 去掉跨 session destructive teardown

目标：

1. 删除 `closeInactiveSessionRuntimes(keeping:)` 的默认调用路径。
2. 删除 `deactivateAllSessionRuntimes()` 在 selection activation 中的使用。
3. 保留 per-session runtime actor 与 binding 恢复。
4. 引入 capacity-aware runtime 回收策略。

### Phase 4：调度器升级为容量策略

目标：

1. 移除 `ExecutionScheduler` 对 `runtimeScope` 的互斥保守限制。
2. 改为 session / provider 双层容量控制。
3. 验证多会话 built-in + ACP 并行 job 的公平性和取消语义。

## 11. 对未来多 agent 并发 / agent team 的意义

虽然本文档聚焦多会话并行，但它直接为后续 agent team 提供三个前置条件：

1. **execution ownership 不再绑定前台 UI**
   agent worker 可以在后台持续工作。
2. **session-scoped interaction center**
   后续多个 agent 的审批 / 阻塞事件可以统一汇聚。
3. **capacity-aware scheduler**
   后续可以自然扩展为 worker / role / session 多维容量控制，而不是继续使用粗粒度 scope 锁。

换句话说，这次如果仍沿用“切会话 = 切 runtime”的模型，后续 agent team 基本还得再推翻一次；现在先把多会话并行打通，是必要的地基工程。

## 12. 风险与权衡

### 12.1 风险：并发后 UI 交互复杂度上升

后台会话可能同时请求审批、用户问题、终端输入。

应对：

1. 统一 attention 模型。
2. 所有阻塞事件都带 `sessionID`。
3. 提供“跳转到对应会话”入口。

### 12.2 风险：ACP provider 并发占用更多进程资源

如果每个 session 都有独立 ACP transport client / process，资源占用会上升。

应对：

1. provider-capacity policy 默认保守。
2. runtime 空闲回收按 idle TTL 处理。
3. 不以切换会话作为回收时机。

### 12.3 风险：built-in 全局状态拆分会波及较广

`ClaudeService` 当前承载大量状态与工具执行路径，拆分不当容易引入回归。

应对：

1. 先引入 registry，再逐步迁移字段。
2. 保持旧字段只读兼容一段时间。
3. 用 focused tests 覆盖多 session 并行发送、审批阻塞、切换恢复。

### 12.4 风险：MainActor 成为多会话并行下的隐性串行瓶颈

即使调度器放开并发，如果 ACP / built-in 的实际耗时调用仍停留在 `MainActor`，最终效果仍可能表现为：

1. 前台输入卡顿。
2. 会话切换延迟。
3. 后台会话越多，主线程越忙，投影刷新越不稳定。

应对：

1. 明确主线程只做状态发布和交互决议。
2. 对 runtime 握手、restore、prompt 往返、终端轮询建立后台 actor 边界。
3. 针对 `@MainActor` provider facade 增加 profiling / signpost，验证没有把慢路径留在主线程。

## 13. 验证策略

设计落地后，至少应覆盖以下验证场景：

1. 会话 A built-in 执行中，切到会话 B 并发发送，A 继续推进。
2. 会话 A ACP 执行中，切到会话 B，A 不被取消，projection 持续更新。
3. 后台会话触发审批，请求能被看见并正确归属到对应 session。
4. 同一 session 仍保持 job 串行，不产生双 prompt 重叠。
5. 应用重启后，recoverable jobs 与 ACP remote binding 可恢复。
6. 取消后台运行会话时，不影响其它会话。
7. 两个 ACP session 并发运行时，各自 `runtime client / connection / transport / local handler` 不共享实例，关闭 A 不影响 B。
8. ACP `loadSession` / `initialize` 超时或恢复失败时，只重建目标 session runtime，不误伤同 provider 下其它 session。
9. 在后台同时存在多个活跃 session 时，前台滚动、输入、切换不会因为主线程被 runtime IO 占用而明显卡顿。

建议测试层次：

1. `ExecutionScheduler` 单元测试：容量策略与公平调度。
2. `ConversationExecutionOrchestrator` 集成测试：多 session enqueue / dispatch / finish。
3. ACP runtime 生命周期测试：多 activation 并存、回收、恢复。
4. ACP transport 隔离测试：request/response、stream event、terminal state、close/cancel 只落到所属 session。
5. UI 冒烟：会话列表 badge、切换会话、后台 attention 提示，以及多后台 session 时前台交互流畅性。

## 14. 最终建议

推荐按以下原则推进实现：

1. **先改模型，再改 provider**：先把 execution projection 和 session interaction 做对。
2. **先解耦，再放并发**：先去掉 selection 与 runtime 的耦合，再逐步放开 capacity。
3. **优先 built-in 与 ACP 两条主链都可并行**：不要只把 built-in 做成并发，而让 ACP 仍保留单活 teardown。
4. **所有并发能力都以 session 为第一层抽象**：这是未来扩展到 agent team 最稳的边界。
5. **不要把 `MainActor` 当作线程安全兜底**：UI 安全与 runtime 并行是两套职责边界，必须显式拆开。

最终推荐方案不是“多开几个线程”，而是：

> 用 session-scoped execution controller + provider-capacity scheduler + non-destructive runtime warmup，替换当前以 selected session 和 runtime scope singleton 为核心的单活模型。

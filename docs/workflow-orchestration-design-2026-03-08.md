# 多代理 Workflow Orchestration 设计方案

日期：2026-03-08

## 背景

当前 agent loop 已经具备以下能力：

- 主代理通过 `runCoreAgentLoop` 执行多轮工具调用。
- 通过 `run_subagent` 可临时启动一个子代理 loop。
- 子代理返回 `AgentMessage`，已经有基础的结构化消息抽象。
- 会话级已有 `ExecutionPlan`、`TodoItem` 等状态，可用于展示执行进度。

但现有实现的核心限制也很明确：

- `run_subagent` 本质上是一次同步工具调用，子代理没有持续身份，也没有持久上下文。
- 子代理只能把结果回传给主代理，不能显式地给其他子代理发消息。
- workflow 主要依赖 system prompt 中的“先 planner、再 explorer、再 coder”这类软约束，不是运行时的显式编排模型。
- 没有统一的中间产物模型，planner 输出、review 结论、coder 修改建议、executor 验证结果都只是文本。
- 无法自然表达回路与条件分支，例如“review 不通过则回 coder”，“coder 信息不足则请求 explorer 补充上下文”。

结论：可以实现你描述的设计，但不建议做成写死的线性 `Workflow.execute()`。更合适的方向是：

1. 用显式的 workflow graph 替代 prompt 中的隐式流程。
2. 用共享任务上下文 + agent mailbox 替代一次性 `run_subagent` 返回值。
3. 用事件驱动调度器替代“主代理串行调用所有子代理”的模式。

这会让 planner、explorer、coder、reviewer、executor 既可以按模板协作，也可以在运行时动态回跳、请求补充信息、或者触发新的分支。

## 目标

新架构需要满足以下目标：

- 支持预定义 workflow 模板，但不把执行路径写死成一条链。
- 支持多代理之间显式通信，而不只是“子代理 -> 主代理 -> 子代理”的人工中转。
- 支持条件分支、循环、重试、人工介入、超时与终止。
- 支持结构化中间产物，避免所有节点只交换自由文本。
- 与现有 `ClaudeService`、`AgentRound`、`ToolCall`、`ExecutionPlan`、UI 时间线兼容。
- 允许逐步迁移，先兼容现有 `run_subagent`，再切到真正的 workflow runtime。

非目标：

- 不追求通用 DAG 引擎到可以编排任意业务系统。
- 不做任意子代理无限递归生成子代理。
- 不把所有协作都交给模型自由决定，运行时仍然必须有边界、预算和安全策略。

## 核心思路

建议把现在的“主 loop + 临时 subagent loop”升级为三层模型：

1. `WorkflowDefinition`
   负责定义一类任务的角色、阶段、共享工件、默认路由规则和终止条件。

2. `WorkflowRuntime`
   负责真正执行 workflow：调度 agent、管理 mailbox、保存共享上下文、处理分支与回路。

3. `AgentWorker`
   负责执行一次 agent turn。它不再被看成“一次工具调用”，而是 workflow 内的一个可反复唤醒的 worker。

本质上，这是一个“受约束的多代理事件系统”：

- workflow 中有多个具名 worker，例如 `planner`、`explorer`、`coder`、`reviewer`。
- 每个 worker 都有自己的 inbox、memory slice、可用工具和可写工件范围。
- worker 每次被调度时，从 inbox 和共享上下文读取信息，输出结构化消息、工件变更、或新的任务请求。
- runtime 根据消息类型和 routing rule 决定下一步唤醒谁，而不是由主代理在 prompt 里手工串起来。

这样可以同时满足“可复用模式”和“非线性协作”。

## 推荐架构：Graph + Mailbox + Shared Artifacts

### 1. WorkflowDefinition 不是固定脚本，而是约束图

建议不要定义成：

```swift
protocol Workflow {
    var name: String { get }
    func execute(context: WorkflowContext) async throws -> WorkflowResult
}
```

而是改成：

```swift
protocol WorkflowDefinition {
    var id: String { get }
    var displayName: String { get }
    var roles: [WorkflowRoleDefinition] { get }
    var entrypoints: [WorkflowTrigger] { get }
    var routingRules: [WorkflowRoutingRule] { get }
    var completionPolicy: WorkflowCompletionPolicy { get }
    func bootstrap(context: inout WorkflowContext) throws
}
```

这里的关键变化是：

- workflow 定义的是角色、路由规则、完成条件，而不是一段固定执行代码。
- 真正的推进由 runtime 根据事件动态决定。

### 2. WorkflowContext 是共享黑板，不是只读参数

`WorkflowContext` 应该包含：

```swift
struct WorkflowContext: Codable, Sendable {
    var workflowId: UUID
    var sessionId: String
    var userTask: String

    var status: WorkflowStatus
    var artifacts: [WorkflowArtifact]
    var mailboxes: [String: AgentMailbox]
    var agentStates: [String: AgentWorkerState]
    var sharedFacts: [WorkflowFact]
    var checkpoints: [WorkflowCheckpoint]

    var budget: WorkflowBudget
    var policies: WorkflowPolicies
}
```

重点不在字段名，而在语义：

- `artifacts`：plan、exploration、patch summary、review report、test result 等结构化工件。
- `mailboxes`：每个 agent 都有 inbox/outbox。
- `agentStates`：记录当前 agent 在等待什么、最近产出什么、是否阻塞。
- `sharedFacts`：跨 agent 共识，例如“目标文件是 X”“测试命令是 Y”。
- `checkpoints`：支持恢复和 UI 回放。

### 3. Agent 间通信通过消息总线，不直接共享 prompt

建议新增统一消息模型：

```swift
struct WorkflowMessage: Codable, Identifiable, Sendable {
    var id: UUID
    var workflowId: UUID
    var sender: String
    var recipients: [String]
    var kind: WorkflowMessageKind
    var subject: String
    var body: String
    var artifactRefs: [String]
    var replyTo: UUID?
    var createdAt: Date
}

enum WorkflowMessageKind: String, Codable {
    case task
    case infoRequest
    case infoResponse
    case handoff
    case reviewFeedback
    case approval
    case rejection
    case statusUpdate
    case completion
    case escalation
}
```

这样 reviewer 不需要“告诉主代理再转 coder”，而是可以直接发：

- `sender = reviewer`
- `recipients = ["coder"]`
- `kind = .reviewFeedback`
- `artifactRefs = [reviewReportId, patchSetId]`

runtime 负责投递、持久化和调度，不需要把通信逻辑塞进 prompt。

## 角色模型

建议把现在的 `SubagentDefinition` 升级为 `WorkflowRoleDefinition`，在保留系统提示与工具控制的基础上，再增加输入输出契约与路由能力。

```swift
struct WorkflowRoleDefinition: Codable, Sendable {
    let name: String
    let displayName: String
    let systemPrompt: String
    let tools: [WorkflowToolCapability]

    let readableArtifacts: Set<WorkflowArtifactKind>
    let writableArtifacts: Set<WorkflowArtifactKind>
    let subscribesTo: Set<WorkflowMessageKind>
    let defaultOutputs: [WorkflowMessageKind]

    let maxTurnsPerActivation: Int
    let maxActivations: Int
}
```

这带来两个重要好处：

1. 明确 agent 边界
   例如 `reviewer` 可以读 patch、plan、tests result，但不能直接修改文件；`coder` 可以修改代码，但不能改 review report。

2. 明确 agent 通信协议
   例如 `explorer` 主要消费 `task/infoRequest`，输出 `infoResponse/statusUpdate`；`reviewer` 主要输出 `approval/rejection/reviewFeedback`。

## 运行时模型

### 1. WorkflowRuntime 是真正的 orchestrator

建议新增一个独立服务，例如：

```swift
@MainActor
final class WorkflowRuntime {
    func startWorkflow(
        definition: any WorkflowDefinition,
        session: Session,
        initialTask: String
    ) async throws -> WorkflowHandle

    func resumeWorkflow(_ workflowId: UUID) async throws
    func cancelWorkflow(_ workflowId: UUID)
    func deliver(_ message: WorkflowMessage) async
}
```

它负责：

- 创建 workflow 实例和初始上下文。
- 决定哪个 agent 可运行。
- 把 agent 输出转换成状态更新、消息、工件、或新的调度任务。
- 处理超时、重试、取消、人工介入。

### 2. 调度不是“按顺序调用”，而是“选下一个 runnable agent”

建议 runtime 内部维护一个调度循环：

```swift
while workflow.isActive {
    let runnableAgents = scheduler.runnableAgents(in: context)
    let nextAgent = scheduler.pickNext(from: runnableAgents, context: context)
    let result = try await workerRunner.run(agent: nextAgent, context: &context)
    try reducer.apply(result, to: &context)
}
```

这里的关键点：

- `runnableAgents` 来自 mailbox、依赖条件和预算，而不是固定顺序。
- `pickNext` 可以按优先级、公平性、阻塞解除、或模板建议来选择。
- `reducer` 把 agent 输出统一归约到 workflow 状态，便于持久化和重放。

### 3. Agent 一次 activation 只做一个有限 turn

不要让某个 agent 一口气占满整个任务。建议模型是：

- workflow 调度到 `coder`
- `coder` 被激活一次
- 它在自己有限的 turn budget 内完成一轮局部工作
- 然后产出结果并让出控制权

这样 reviewer 才能插入，explorer 才能补充信息，planner 才能做 replan。

## 非线性协作如何实现

你举的编码例子可以建模成下面这个状态图：

```text
planner -> explorer -> coder -> reviewer -> done
                      ^         |
                      |         v
                  executor <- fix_requested
```

但在 runtime 里不要硬编码成“只能这样走”。更好的表达方式是路由规则：

### CodeChangeWorkflow 的默认规则

1. workflow 启动时，把用户任务投递给 `planner`。
2. 如果 planner 生成的计划包含未知代码位置或依赖不明确，则向 `explorer` 发 `task`。
3. 当 exploration artifact 达到最小充分信息阈值时，runtime 允许 `coder` 进入 runnable。
4. coder 完成代码变更后，自动向 `reviewer` 和 `executor` 广播结果。
5. reviewer 如果输出 `approval`，且 executor 验证通过，则 workflow 完成。
6. reviewer 如果输出 `rejection` 或 `reviewFeedback`，则给 `coder` 投递修复任务。
7. coder 如果判断上下文不足，可以向 `explorer` 发送 `infoRequest`。
8. explorer 回复 `infoResponse` 后，scheduler 再次激活 coder。
9. 多次 review 失败后，触发 `planner` 重新规划或升级到人工确认。

所以 workflow 的“模式”是存在的，但 runtime 实际执行路径是动态生成的。

## 中间产物设计

现有 `AgentMessage` 已经比纯字符串更进一步，但还不够。建议再引入 artifact 层，把长期有效的信息从消息里剥离出来。

```swift
struct WorkflowArtifact: Codable, Identifiable, Sendable {
    var id: String
    var kind: WorkflowArtifactKind
    var title: String
    var producer: String
    var version: Int
    var content: WorkflowArtifactContent
    var status: ArtifactStatus
    var createdAt: Date
    var updatedAt: Date
}

enum WorkflowArtifactKind: String, Codable {
    case plan
    case explorationReport
    case codePatchSummary
    case reviewReport
    case testReport
    case decisionLog
    case finalAnswer
}
```

建议每类 artifact 都有尽量稳定的 schema。比如：

- `plan`：目标、步骤、依赖、风险、退出条件。
- `explorationReport`：相关文件、关键符号、发现、未解问题。
- `reviewReport`：severity、finding、blocking、suggestedFix。
- `testReport`：命令、结果、失败摘要、重现性。

消息负责“推动流程”，artifact 负责“沉淀事实”。

这能显著降低多代理协作时的上下文噪音。

## 对现有代码的具体改造建议

### 第一层：保守演进

先保留现有 `runCoreAgentLoop`，但把子代理从“临时工具调用”升级为“workflow worker 的一次 activation”。

最小改造路径：

1. 保留 `SubagentDefinition`，新增 `WorkflowRoleDefinition`。
2. 保留 `AgentMessage`，新增 `WorkflowMessage` 和 `WorkflowArtifact`。
3. 在 `ClaudeService+Subagent.swift` 旁边新增 `WorkflowRuntime.swift`。
4. 新增 `WorkflowInstance` SwiftData 模型，用于持久化 workflow 状态。
5. `run_subagent` 工具先不删除，而是内部改为调用 runtime 的 `activateRole()`。

这样现有主代理还能工作，但底层已经具备 workflow runtime。

### 第二层：把 prompt 里的强制流程规则迁移到 runtime

当前 `ACPClientService` 的 system prompt 中写了很多强制编排规则，例如：

- 研究任务必须先 explorer。
- 复杂任务先 create_execution_plan。
- 实施中按步骤推进。

这些规则短期有效，但长期会和 runtime 冲突，因为：

- prompt 规则是软约束，模型可能偏离。
- runtime 规则才是可观察、可恢复、可测试的真实编排层。

建议把 prompt 改成：

- 主代理主要负责理解用户意图、选择 workflow 模板、做最终对用户输出。
- workflow 内部调度不再靠 prompt 文本描述，而靠 runtime 的 role、route、policy。

也就是说，system prompt 从“告诉模型怎么 orchestrate”改成“告诉模型什么时候选择 workflow，以及如何在自己的角色边界内工作”。

### 第三层：把 UI 从“轮次视图”扩展为“workflow 视图”

现在 UI 已有 `AgentRound`、`ToolCall` 和 todo 列表。后续建议增加：

- workflow 时间线：显示 agent activation、消息流、artifact 版本。
- mailbox 视图：谁给谁发了什么任务/反馈。
- artifact 面板：plan、review、test report、decision log。
- 阻塞状态：等待用户、等待 explorer、等待测试、等待 reviewer。

这比只看主代理文本更适合长任务。

## 数据模型建议

建议新增以下 SwiftData 模型：

### 1. WorkflowInstance

```swift
@Model
final class WorkflowInstance {
    var id: UUID
    var sessionId: String
    var definitionId: String
    var statusRaw: String
    var userTask: String
    var startedAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade) var messages: [WorkflowMessageRecord] = []
    @Relationship(deleteRule: .cascade) var artifacts: [WorkflowArtifactRecord] = []
    @Relationship(deleteRule: .cascade) var activations: [WorkflowActivationRecord] = []
}
```

### 2. WorkflowActivationRecord

记录一次 agent 被唤醒执行：

- 哪个 role
- 由什么事件触发
- 激活前后状态
- 消耗轮次、耗时、结果

### 3. WorkflowMessageRecord

持久化 agent 间消息，供调试和 UI 可视化。

### 4. WorkflowArtifactRecord

持久化结构化工件，并支持版本号，避免 reviewer 永远在看旧 patch。

## 调度策略建议

runtime 不应该完全自由，也不应该完全写死。建议采用“模板 + 策略”的双层控制。

### 模板层

例如 `CodeChangeWorkflow` 指定：

- 默认入口角色是 planner。
- 关键 artifact 包括 plan、exploration、patch、review、test。
- 关键完成条件包括 review pass 和 test pass。

### 策略层

由通用 scheduler 决定：

- 谁先运行。
- 是否允许并行，例如 reviewer 与 executor 可并行消费 coder 的 patch。
- 某 agent 连续失败 N 次后是否熔断。
- 是否触发 replanning。

建议默认策略如下：

- 优先唤醒正在阻塞关键路径的 agent。
- 同一 agent 连续激活次数受限，避免 coder 占满整个任务。
- `reviewFeedback` 和 `infoResponse` 的优先级高于普通 `statusUpdate`。
- 如果 workflow 在固定时间内没有产生新的 artifact 或状态变更，标记为 stalled。

## 与现有 AgentMessage 的关系

现有 `AgentMessage` 不需要废弃，但建议角色变成“模型返回结果的 transport 对象”，而不是 workflow 内部唯一通信模型。

推荐分层：

- `AgentMessage`
  单次 agent activation 的输出，贴近 LLM 调用结果。

- `WorkflowMessage`
  runtime 内部的正式通信对象，用于投递、调度和持久化。

- `WorkflowArtifact`
  持久事实对象，用于共享上下文和版本演进。

转换关系：

```text
AgentMessage -> RuntimeReducer -> WorkflowMessage / WorkflowArtifact / StateMutation
```

这样能把“模型说了什么”和“系统状态变成了什么”分开。

## 一个更合适的 API 形态

你最初给出的 API 偏向同步线性流程。建议替换为下面这种风格：

```swift
protocol WorkflowDefinition {
    var id: String { get }
    func makeInitialState(task: String) -> WorkflowContext
    func makeScheduler() -> any WorkflowScheduler
    func makeReducer() -> any WorkflowReducer
}

protocol WorkflowScheduler {
    func runnableRoles(in context: WorkflowContext) -> [String]
    func chooseNextRole(in context: WorkflowContext) -> String?
}

protocol WorkflowReducer {
    mutating func apply(
        activationResult: AgentActivationResult,
        to context: inout WorkflowContext
    ) throws
}

protocol WorkflowAgentRunner {
    func runRole(
        _ role: WorkflowRoleDefinition,
        in context: WorkflowContext
    ) async throws -> AgentActivationResult
}
```

这里把工作拆成：

- definition：定义 workflow 类型。
- scheduler：决定谁运行。
- runner：真正执行 agent。
- reducer：把执行结果落到状态。

这比一个大而全的 `execute(context:)` 更容易扩展，也更适合测试。

## 编码任务的推荐模板

以下是 `CodeChangeWorkflow` 的建议行为，而不是固定脚本：

### 入口阶段

- `planner` 读取用户任务，产出 `plan` artifact。
- 如果任务已经足够明确，也可以跳过 planner，直接由 runtime 写一个最小 plan。

### 探索阶段

- `explorer` 根据 plan 的未决项补充代码上下文。
- 产出 `explorationReport` artifact，至少包含相关文件、关键符号、风险点。

### 实施阶段

- `coder` 基于 plan + exploration 执行变更。
- 输出 `codePatchSummary` artifact，并附带需要验证的命令建议。

### 审查/验证阶段

- `reviewer` 读取 patch summary 和相关文件，产出 `reviewReport`。
- `executor` 运行测试/构建，产出 `testReport`。

### 回路阶段

- 如果 `reviewReport.blockingFindings > 0`，则生成发往 coder 的 `reviewFeedback`。
- 如果 `testReport.status == failed`，则生成发往 coder 的 `rejection`。
- 如果 coder 标记 `needsMoreContext`，则生成发往 explorer 的 `infoRequest`。
- 如果 explorer 返回的新信息影响范围较大，则可触发 planner replan。

### 完成阶段

仅当以下条件满足才结束：

- patch 已产出。
- reviewer 通过或无 blocking finding。
- executor 验证通过，或明确记录未验证原因。
- workflow 生成 `finalAnswer` artifact。

## 失败与安全策略

多代理协作如果没有护栏，会比单代理更容易失控。建议一开始就把以下策略做进 runtime：

### 预算控制

- 每个 workflow 有总轮次预算、token 预算、时间预算。
- 每个 role 有激活次数上限和单次 turn 上限。

### 权限控制

- role 级工具白名单。
- artifact 读写权限。
- 某些消息类型只允许部分角色发送，例如只有 reviewer 能发 blocking review。

### 熔断控制

- 相同 review finding 重复 2-3 次未消除，触发 replan 或人工介入。
- coder/explorer 循环请求超过阈值，标记为 stalled。
- executor 连续失败且错误类型不变时，不应无限重试。

### 可恢复性

- 每次 activation 后写 checkpoint。
- app 重启后可恢复 workflow 上下文、mailbox、artifact 版本和挂起状态。

## 迁移路径

建议按四步迁移，而不是一次性推翻：

### Phase 1

新增 workflow 数据模型和 runtime，但主入口仍沿用现有 agent loop。

### Phase 2

把 `run_subagent` 改造成 `activate_role` 的兼容壳。

### Phase 3

新增首个模板 `CodeChangeWorkflow`，让主代理在复杂编码任务时选择 workflow 模式。

### Phase 4

逐步把 `ACPClientService` 中的 prompt 编排规则下沉到 runtime policy，减少 prompt orchestration 文本。

这样做的优点是：

- 不会破坏当前已可工作的简单 subagent 模式。
- 可以先做数据层和运行时，再做 UI。
- 可以逐步观测真实任务中的通信模式，再决定是否继续泛化。

## 最小可行版本建议

如果你想控制改造规模，建议先做一个 MVP：

1. 新增 `WorkflowInstance`、`WorkflowMessageRecord`、`WorkflowArtifactRecord`。
2. 新增 `WorkflowRuntime`，但先只支持单 workflow 模板：`code_change`。
3. 子代理之间先不支持任意广播，只支持：
   - `coder -> explorer` 请求补充信息
   - `reviewer -> coder` 提交修复意见
   - `executor -> coder` 返回失败结果
4. 先把 mailbox 做成持久化队列，不做复杂并行。
5. UI 先展示 workflow timeline + artifact list，不做完整通信图。

这个版本已经能覆盖你提到的核心回路：

- Planner 分析
- Explorer 探索
- Coder 实施
- Reviewer 审查并退回
- Coder 请求更多上下文
- Explorer 继续补充

也就是说，业务价值已经够了，但实现复杂度仍然可控。

## 推荐结论

可以实现，而且建议实现。

但推荐的实现方式不是把当前 `run_subagent` 简单包装成一个线性 `Workflow.execute(context:)`，而是引入：

- workflow definition
- workflow runtime
- mailbox/message bus
- artifact/shared context
- scheduler + reducer

这样 workflow 才真正具备：

- 非线性执行
- agent 间通信
- 回路与重规划
- 可观察、可恢复、可测试

一句话总结：

把“多代理协作”从 prompt 技巧升级为应用层 runtime 能力。

## 建议的下一步

如果继续落地，建议下一步直接做下面三件事：

1. 定义 `WorkflowInstance / WorkflowMessage / WorkflowArtifact` 数据模型。
2. 实现一个最小 `WorkflowRuntime`，先支持 `CodeChangeWorkflow`。
3. 把现有 `run_subagent` 接到 runtime 上，作为兼容层，而不是直接删除。
日期：2026-03-16

# agentGui 后台 Agent 调度设计（NSBackgroundActivityScheduler）

## 1. 目标与范围

本文档定义 agentGui 接入 `NSBackgroundActivityScheduler` 的后台 Agent 定时执行方案。当前阶段聚焦一个明确范围：允许用户手动创建定时任务，并由 agent 按用户编写的提示词在后台定时执行。

本设计默认采用“任务级调度，绑定会话输出”的方向：

- 底层调度对象是可复用的后台任务模板，而不是某个临时 UI 状态。
- 每个任务由用户显式创建，核心输入是标题、执行周期、工作区和提示词模板。
- 任务执行时默认唤醒一个受控的 Agent loop，并把结果回写到指定 `Session`。
- `NSBackgroundActivityScheduler` 只负责“系统允许时触发”，不直接承载业务状态机。

这符合 Apple 对 `NSBackgroundActivityScheduler` 的定位：适合 10 分钟以上粒度、可延迟、可让系统按能耗与热状态自由安排的后台维护任务，不适合严格准点或强实时任务。

## 2. 设计原则

### 2.1 主流实现遵循

采用业界主流的三层结构：

- `Trigger Layer`：系统调度器，只关心什么时候可能被唤醒。
- `Queue / Policy Layer`：决定本次是否值得执行、执行哪类任务、失败后何时重试。
- `Execution Layer`：真正唤醒 agent 并执行用户提示词。

这也是 `NSBackgroundActivityScheduler` 最稳妥的接法。直接把业务逻辑塞进 scheduler block 会导致测试困难、恢复困难、策略无法演进。

### 2.2 不直接复刻现有定时器产品

本方案禁止做成通用 cron 克隆，也不照搬“纯定时器 + 黑盒提示词执行器”的自动助手。创新点必须建立在 agentGui 现有优势上：会话沉淀、受控工具权限、后台执行治理、结果回写和业务事件观测。

### 2.3 后台能力先服务于“低干扰、高价值”任务

第一阶段只支持 deferrable 工作：

- 周期性仓库巡检
- 自动摘要 / 汇总
- 指定工作区的例行检查
- 用户自定义提示词驱动的后台任务
- 低频、可延迟的上下文整理任务

明确不支持：

- 秒级定时
- 严格 SLA 触发
- 依赖持续前台 UI 交互的任务
- 需要用户即时输入才能继续的任务

## 3. Apple 官方约束与设计含义

根据 `NSBackgroundActivityScheduler` 官方语义，设计上必须接受以下事实：

- `identifier` 必须稳定，且跨启动保持不变，系统会据此学习调度启发式。
- `interval` 是建议值，不是准点承诺。
- `tolerance` 会影响系统合并执行窗口，默认可很宽。
- block 运行在后台串行队列上，适合低优先级工作。
- 必须调用 completion handler；否则重复任务不会被正确重调度。
- 执行中应根据 `shouldDefer` 尽快收尾并返回 `.deferred`。
- `invalidate()` 只能阻止后续调度，不能终止已开始的执行。

因此，本方案不会把“任务的真实计划时间”与“系统唤醒时间”等同起来，而是引入单独的业务层 `eligibility` 判断：系统即使唤醒了进程，本次也可能只做轻量预检查，然后决定跳过或延后真正的 Agent 执行。

## 4. 现有架构对接点

仓库当前已有以下可复用资产：

- `ClaudeService` 与 `AgentLoop`：适合承接后台单代理任务。
- `Session` / `Message`：适合承接任务结果回写与历史留痕。
- `AppSettings`：适合承载全局后台能力开关与默认策略。
- `SwiftData`：适合持久化任务定义、运行记录、调度状态和恢复快照。
- `RuntimeRecoveryService`：可复用其中断恢复理念。
- `MemoryBackgroundJob`：说明仓库已经接受“后台作业 + 结果回写”的建模方式。

因此不建议新增一个完全独立的后台执行引擎，而应让后台调度成为 `AgentLoop` 的一个新触发入口，并统一回写到现有会话数据结构。

## 5. 总体方案

### 5.1 分层架构

```text
NSBackgroundActivityScheduler
        │
        ▼
BackgroundActivityCoordinator
        │
        ├── BackgroundTaskRegistry
        ├── BackgroundTaskPolicyEngine
        ├── BackgroundTaskEligibilityEvaluator
        ├── BackgroundTaskExecutionCoordinator
        └── BackgroundTaskObservationStore
                    │
        ├── AgentLoop adapter
        └── Session message writer
```

各层职责：

- `BackgroundActivityCoordinator`
  负责创建/持有系统 scheduler，处理 app 启动、设置变更、任务增删时的重新注册。

- `BackgroundTaskRegistry`
  从 SwiftData 读取已启用任务，生成稳定 identifier，并维护 in-memory scheduler map。

- `BackgroundTaskPolicyEngine`
  把用户侧“每天早上、每 6 小时、工作日白天”等意图转成系统层 `interval / tolerance / qos / repeats`。

- `BackgroundTaskEligibilityEvaluator`
  在真正唤醒 agent 前做二次判定，例如工作区是否存在、网络策略是否允许、是否仍在冷却期、是否正在运行相同任务。

- `BackgroundTaskExecutionCoordinator`
  将后台任务路由到受控 `AgentLoop` 执行器，并负责结果回写。

- `BackgroundTaskObservationStore`
  持久化每次触发、跳过、完成、失败、deferred 的证据与摘要，为 UI 和策略反馈提供数据。

### 5.2 为什么这样分层

这个结构的关键收益是把“系统唤醒”与“用户提示词执行”解耦。以后如果需要引入手动触发、登录触发、文件系统事件触发，仍然可以复用同一套任务定义、策略引擎与执行协调器，而不把 `NSBackgroundActivityScheduler` 绑定成唯一入口。

### 5.3 当前阶段的明确边界

当前阶段不纳入 `WorkflowRuntime` / `WorkflowDefinition` 相关能力，避免把后台定时任务做成第二套 workflow 平台。

这一期只支持：

- 用户手动创建任务
- 用户手动编写提示词
- 任务按时间策略触发
- 通过受控 `AgentLoop` 执行
- 输出回写到绑定的 `Session`

这一期不支持：

- workflow 调度
- 多代理编排
- 自动 replanning
- 基于 artifact 的阶段恢复

## 6. 数据模型设计

建议新增以下 SwiftData 模型。

### 6.1 `BackgroundAgentTask`

表示一个后台任务模板。

建议字段：

- `id: UUID`
- `taskKey: String`，稳定业务键，用于生成 scheduler identifier
- `title: String`
- `isEnabled: Bool`
- `sessionId: String`
- `taskPrompt: String`
- `systemPromptOverride: String?`
- `promptTemplate: String`
- `workspacePath: String?`
- `workingDirectoryPath: String?`
- `modelIDOverride: String?`
- `toolGrantPolicyJSON: String`
- `schedulePolicyJSON: String`
- `executionPolicyJSON: String`
- `lastScheduledAt: Date?`
- `lastTriggeredAt: Date?`
- `lastCompletedAt: Date?`
- `lastResultSummary: String?`
- `consecutiveFailureCount: Int`
- `cooldownUntil: Date?`
- `createdAt: Date`
- `updatedAt: Date`

其中：

- `schedulePolicy` 负责表达用户意图，比如“每 6 小时运行”“工作日 9-18 点内允许执行”。
- `executionPolicy` 负责表达预算、失败是否自动重试、结果写回方式等。
- `toolGrantPolicy` 负责表达后台任务可用工具范围，避免直接继承前台会话的全部权限。

其中字段建议做如下收敛：

- `taskPrompt` 是用户实际编写的提示词正文，应成为任务的核心字段。
- `promptTemplate` 可作为增强字段，用于后续支持变量插值；如果当前阶段追求简单，可以只保留 `taskPrompt`，把 `promptTemplate` 改名为 `taskPrompt`。
- `sessionId` 在这一期建议设为必填，确保后台输出有稳定归宿。

### 6.2 `BackgroundAgentTaskRun`

表示一次实际运行或被跳过的记录。

建议字段：

- `id: UUID`
- `taskId: UUID`
- `schedulerIdentifier: String`
- `triggerSource: BackgroundTriggerSource`
- `scheduledWindowStart: Date?`
- `scheduledWindowEnd: Date?`
- `actualStartAt: Date?`
- `finishedAt: Date?`
- `status: BackgroundTaskRunStatus`
- `decision: BackgroundExecutionDecision`
- `deferReason: String?`
- `skipReason: String?`
- `resultSummary: String?`
- `messageId: PersistentIdentifier?`
- `agentSummaryJSON: String?`
- `businessEventDigestJSON: String?`

这里有意把“skip”和“run”都建模成 run record。因为对后台系统来说，没有执行也是一个重要结果，后续自适应策略要依赖这些观测样本。

### 6.3 `BackgroundTaskTriggerPolicy`

建议作为 Codable 值类型序列化到 JSON，不单独建表。字段可包含：

- `baseIntervalSeconds`
- `toleranceSeconds`
- `repeats`
- `qualityOfService`
- `allowedWeekdays`
- `allowedHourRange`
- `minimumBatteryPolicy`
- `requiresNetwork`
- `jitterStrategy`
- `quietHours`

### 6.4 `BackgroundTaskExecutionPolicy`

同样建议 JSON 序列化。字段可包含：

- `maxTurns`
- `maxExecutionSeconds`
- `maxConsecutiveFailures`
- `failureBackoffPolicy`
- `allowDirectAgentLoop`
- `allowFileWrite`
- `allowBash`
- `allowMemoryMutation`
- `resultDeliveryMode`
- `appendUserVisibleMessage`

## 7. 服务接口设计

### 7.1 协议层

```swift
protocol BackgroundTaskSchedulable: Sendable {
    var taskKey: String { get }
    func makeSystemSchedule(now: Date) -> BackgroundSystemSchedule
    func evaluateEligibility(now: Date, environment: BackgroundExecutionEnvironment) -> BackgroundEligibility
}

protocol BackgroundTaskExecutable: Sendable {
    func execute(
        task: BackgroundAgentTask,
        run: BackgroundAgentTaskRun,
        modelContext: ModelContext
    ) async throws -> BackgroundExecutionOutcome
}

protocol BackgroundExecutionAdapter: Sendable {
    func supports(task: BackgroundAgentTask) -> Bool
    func execute(task: BackgroundAgentTask, modelContext: ModelContext) async throws -> BackgroundExecutionOutcome
}
```

### 7.2 核心服务

建议新增：

- `BackgroundActivityCoordinator`
- `BackgroundTaskRegistry`
- `BackgroundTaskPolicyEngine`
- `BackgroundTaskEligibilityEvaluator`
- `BackgroundTaskExecutionCoordinator`
- `BackgroundAgentLoopAdapter`
- `BackgroundPromptComposer`
- `BackgroundSessionResultWriter`
- `BackgroundTaskObservationService`

建议目录：

```text
agentGui/
  Services/
    Background/
      BackgroundActivityCoordinator.swift
      BackgroundTaskRegistry.swift
      BackgroundTaskPolicyEngine.swift
      BackgroundTaskEligibilityEvaluator.swift
      BackgroundTaskExecutionCoordinator.swift
      BackgroundPromptComposer.swift
      BackgroundSessionResultWriter.swift
      BackgroundTaskObservationService.swift
      Adapters/
        BackgroundAgentLoopAdapter.swift
```

    ### 7.3 手动创建任务的产品约束

    这一期后台任务不是系统自动发现出来的，而是用户主动创建：

    - 用户选择一个 `Session` 作为结果落点
    - 用户输入任务标题
    - 用户输入提示词正文
    - 用户选择执行周期和时间偏好
    - 用户选择工具权限等级

    这意味着服务层必须把“可编辑任务定义”视为一等对象，而不是把调度参数塞进 `AppSettings`。

## 8. 调度与执行流程

### 8.1 App 启动时

1. `agentGuiApp` 初始化 `ModelContainer` 和现有服务。
2. 读取 `AppSettings` 的后台总开关。
3. `BackgroundActivityCoordinator.bootstrap(modelContext:)` 扫描所有已启用 `BackgroundAgentTask`。
4. 为每个任务生成稳定 identifier，例如：
   `com.agentgui.background.task.<taskKey>`
5. coordinator 为每个任务创建或刷新 `NSBackgroundActivityScheduler`。

### 8.2 系统触发时

1. 系统调用 scheduler block。
2. coordinator 创建一条 `BackgroundAgentTaskRun(status: .triggered)`。
3. 先执行 `EligibilityEvaluator`：
   - 任务是否启用
   - 是否在 quiet hours
   - 是否命中 cooldown
   - 工作区是否仍存在
   - 是否已有同 taskKey 运行中实例
   - 当前系统是否建议 defer
4. 若不满足：
   - 写入 skip / deferred 原因
   - 调用 completion handler 返回 `.deferred` 或 `.finished`
5. 若满足：
   - 进入 `ExecutionCoordinator`
  - 用 `BackgroundPromptComposer` 组装本轮实际提示词
  - 路由到 `BackgroundAgentLoopAdapter`
  - 生成结果摘要并回写 `Session`
   - 按 outcome 更新任务状态与下一轮策略

### 8.3 执行完成后

1. 持久化 `BackgroundAgentTaskRun`
2. 回写 `BackgroundAgentTask.lastCompletedAt` / `consecutiveFailureCount` / `cooldownUntil`
3. 若需调整策略，更新 `schedulePolicyJSON`
4. 必须调用 completion handler
5. 若任务停用或已删除，则 `invalidate()` 并从 registry 清理

## 9. 与现有执行体系的映射

### 9.1 AgentLoop 路径

适合短小、单目标、预算清晰的自动化任务。

例子：

- 定时执行用户编写的巡检提示词
- 定时生成会话摘要
- 定时整理待办事项
- 定时刷新某个 session 的上下文压缩结果

映射方式：

- `BackgroundAgentLoopAdapter` 创建受限的 `AgentLoopRunRequest`
- 强制更低预算、更窄工具权限
- 禁止需要人工澄清的 prompt 继续扩张
- 结果产出为新的 `Message`、摘要记录或轻量结构化状态

### 9.2 Session 回写路径

后台任务不应只留下日志，还应留下用户可见结果。

建议默认回写策略：

- 在目标 `Session` 中追加一条系统说明消息，标注该任务由后台定时触发
- 追加一条 agent 结果消息，承载最终文本输出
- 若执行失败，则追加一条精简失败摘要，而不是把内部异常堆栈直接暴露给用户

这能保证后台任务不是“静默黑盒”，而是用户可以在原会话里追溯结果。

## 10. 创新点

本方案的创新点不在“定时器本身”，而在后台 agent 的决策与反馈闭环。

### 10.1 双阶段唤醒：Trigger 不等于 Full Run

主流做法通常是系统一唤醒就直接执行任务。本方案加入“轻量判定阶段”：

- 第一阶段只做 eligibility 与价值评估。
- 第二阶段才决定是否真的拉起 agent loop。

这让系统调度和业务价值解耦，能显著降低无效唤醒成本。

### 10.2 Outcome-aware Cadence

不是固定每 N 小时跑一次，而是根据结果动态调整节奏：

- 连续无变化：延长 interval
- 发现高价值变更：缩短 interval
- 连续失败：指数退避并进入 cooldown
- 多次 skip：调整 quiet hours 或改为只读预检

这比普通 cron 更适合 agent 工作，因为 agent 任务的价值密度是波动的。

### 10.3 Prompt Capsule

不是把用户提示词原样裸跑，而是为后台任务引入一个“提示词胶囊”层：

- 用户编写原始提示词
- 系统在执行前注入任务元信息，例如任务名、触发时间、工作区路径
- 系统注入后台执行约束，例如禁止等待人工输入、预算上限、失败时直接收敛输出

这样既保留用户自定义提示词的自由度，又避免后台执行退化成不可控的 prompt sandbox。

### 10.4 Session-native Delivery

相比只在调度中心显示一个状态，本方案强调“结果直接回到用户原会话”：

- 用户不需要切换到独立日志页才能知道 agent 做了什么
- 同一个会话能形成长期执行历史
- 后续用户可以沿着这条后台产出的消息继续追问或手动接管

这比常见定时任务器只提供 run log 更贴近 agent 产品形态。

### 10.5 背景信任分级

后台任务默认不是“全权限 Agent”。设计中引入 trust tier：

- `observe-only`：只读上下文与只读工具
- `maintain`：允许摘要、压缩、归档、memory 整理
- `act-limited`：允许有限写入，例如更新 todo、写入结构化状态

这样可以让后台自动化先从保守模式起步，而不是一上来复用前台全部工具能力。

## 11. 策略细节

### 11.1 系统调度映射建议

| 用户语义 | interval | tolerance | qos | 备注 |
|----------|----------|-----------|-----|------|
| 每 2 小时巡检 | 7200s | 1800s | `.background` | 强调节能 |
| 每天摘要 | 86400s | 7200s | `.utility` | 允许较大窗口 |
| 每 6 小时执行用户自定义提示词 | 21600s | 3600s | `.utility` | 兼顾结果时效 |
| memory 维护 | 43200s | 10800s | `.background` | 低优先级 |

默认不推荐：

- 10 分钟以下频率
- `userInitiated` 级别 QoS
- tolerance 过小

### 11.2 defer 规则

满足任一条件时建议返回 `.deferred`：

- `scheduler.shouldDefer == true`
- 同任务已有运行中实例
- 网络或工作区依赖暂不可用
- 任务已进入 cooldown
- 前一次执行尚未形成稳定收尾状态

### 11.3 skip 与 defer 区分

- `skip`：业务上主动不执行，但本轮已处理完成，例如任务被禁用。
- `defer`：系统条件或环境条件不适合，需要稍后重试。

这个区分很重要，因为二者对后续 cadence 调整的意义不同。

## 12. 设置与 UI 建议

### 12.1 `AppSettings` 增量字段

建议增加：

- `backgroundAgentEnabled: Bool`
- `backgroundAgentDefaultQoS: String`
- `backgroundAgentRequiresExternalPower: Bool`
- `backgroundAgentMaximumConcurrentRuns: Int`
- `backgroundAgentObservationRetentionDays: Int`

### 12.2 设置页

建议新增“后台自动化”分组：

- 总开关
- 能耗优先模式
- 默认静默时段
- 默认工作区限制
- 后台任务列表入口

### 12.3 手动创建任务表单

用户创建任务时建议至少填写以下字段：

- 任务名称
- 绑定会话
- 提示词正文
- 运行频率
- 可选工作目录
- 工具权限等级

提示词编辑体验建议：

- 支持多行输入
- 支持预览系统注入变量
- 支持“立即测试运行一次”
- 在保存前提示该任务是否允许写文件或执行 bash

### 12.4 后台任务管理页

建议后续提供独立 panel，而不是塞进当前聊天页。

展示维度：

- 任务名称
- 下次建议运行窗口
- 最近一次实际运行时间
- 最近结果摘要
- 当前信任级别
- 连续失败次数
- 绑定会话
- 提示词摘要

## 13. 可观测性与审计

后台 agent 的关键不是“能跑”，而是“跑完以后可解释”。建议最少记录以下事件：

- scheduler 注册成功 / 失效
- 系统触发
- eligibility 判定结果
- 真正开始执行
- agent loop 完成
- 返回 `.finished` 或 `.deferred`
- 策略被自动调整

建议复用已有 `BusinessMonitor` 风格，新增事件类别：

- `backgroundTaskRegistered`
- `backgroundTaskTriggered`
- `backgroundTaskSkipped`
- `backgroundTaskDeferred`
- `backgroundTaskStarted`
- `backgroundTaskCompleted`
- `backgroundTaskFailed`
- `backgroundTaskPolicyAdjusted`

## 14. 失败恢复设计

### 14.1 运行中断

如果 app 在后台任务执行中被终止：

- `BackgroundAgentTaskRun` 保持 `.running` 或 `.interrupted`
- 下次启动时 `BackgroundActivityCoordinator` 扫描异常运行记录
- 可借鉴 `RuntimeRecoveryService` 的恢复思路，但本期只恢复后台任务自身的运行状态，不恢复 workflow 上下文

### 14.2 重复失败

建议策略：

- 第 1 次失败：正常记录
- 第 2 次连续失败：增加 backoff
- 第 3 次连续失败：进入 cooldown，并降级为 observe-only
- 达到阈值：暂停任务，要求用户手动恢复

### 14.3 模型或权限不可用

如果 API key、模型配置、工作区路径已失效：

- 不应不断后台重试
- 应记录持久错误状态
- UI 提示需要人工修复，而不是默默消耗触发机会

## 15. 测试方案

### 15.1 单元测试

- `BackgroundTaskPolicyEngineTests`
- `BackgroundTaskEligibilityEvaluatorTests`
- `BackgroundTaskRegistryTests`
- `BackgroundTaskExecutionCoordinatorTests`
- `BackgroundAgentLoopAdapterTests`
- `BackgroundPromptComposerTests`
- `BackgroundSessionResultWriterTests`

重点覆盖：

- identifier 稳定性
- schedule policy 到系统参数的映射
- defer / skip / run 的分类准确性
- cooldown 与 backoff
- 同任务并发保护

### 15.2 集成测试

用可注入的 scheduler factory 替代真实 `NSBackgroundActivityScheduler`，验证：

- app 启动后任务注册
- 设置变更后重新注册
- 触发后能正确落库 run record
- agent loop adapter 能把结果写回 session

### 15.3 UI 测试

后续为后台任务管理页增加：

- 启停任务
- 查看最近运行结果
- 失败状态可见性
- cooldown 状态可见性

## 16. 分阶段落地建议

### Phase 1：基础接入

- 新增 `BackgroundAgentTask` / `BackgroundAgentTaskRun`
- 新增 `BackgroundActivityCoordinator`
- 支持 app 启动时注册 scheduler
- 支持用户手工创建定时提示词任务
- 支持结果回写到 session

### Phase 2：执行适配器

- 接入 `AgentLoop`
- 增加 `BackgroundPromptComposer`
- 增加 eligibility evaluator 与 observation store
- 增加设置页后台总开关

### Phase 3：策略进化

- outcome-aware cadence
- cooldown / backoff
- trust tier
- Prompt Capsule

### Phase 4：产品化

- 后台任务管理 UI
- 历史运行面板
- 失败恢复入口
- 用户可配置 quiet hours / workspace scope
- 立即试跑与提示词预览

## 17. 推荐结论

推荐采用“系统 scheduler 只做触发，业务层再做价值判定与受控执行”的方案。这是接入 `NSBackgroundActivityScheduler` 最稳妥的主流实现，也是和当前 agentGui 架构最兼容的方向。

具体建议如下：

- 用 `NSBackgroundActivityScheduler` 做稳定、低频、可延迟的后台唤醒。
- 用新的 `BackgroundActivityCoordinator` 统一管理注册与触发。
- 用新的 `BackgroundTaskExecutionCoordinator` 驱动受控 `AgentLoop`。
- 把“用户手动创建任务并填写提示词”作为本期核心产品能力。
- 把结果稳定回写到 `Session` / `Message`，而不是只保留内部日志。
- 用 `BackgroundAgentTaskRun` 把 skip / defer / complete 全量观测下来。
- 用 outcome-aware cadence、Prompt Capsule、trust tier 作为差异化创新点。

这样做不会复刻一个普通定时器产品，而是把 agentGui 的会话连续性、受控工具执行和后台治理能力延伸到“用户自定义提示词定时执行”场景。
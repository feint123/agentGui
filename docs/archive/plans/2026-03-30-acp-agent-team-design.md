# ACP Agent Team Design

**Goal:** 为 agentGui 设计一套基于 ACP provider 的 agent team 模式，让多个异构 provider 能够围绕同一任务协作、沟通、并行推进创意与执行型工作，同时提供一套独立于当前 message UI 的 team workbench。

**Architecture:** 在现有 ACP provider 和 execution runtime 之上新增一层轻量 team runtime。该 runtime 使用 Brief-Claim-Commit 协议组织 provider 协作，用 task cards 和 typed artifacts 作为共享黑板，用 merge gate 与 review gate 控制收敛，并以独立 Team Workbench 承载交互，而不是把 team 执行过程投影回普通消息列表。除了 mission 和 artifact 之外，team runtime 还必须显式建模 provider participation plan、dispatch policy 与 accepted-claim-driven execution，避免实现退化成普通 session default provider 的隐式继承。

**Tech Stack:** Swift 6, SwiftUI, SwiftData, 现有 ACP provider registry, existing execution projection store, session runtime infrastructure, artifact-oriented UI projection.

---

## 1. 结论先行

推荐把这项需求定义为：

“在 ACP 执行面上增加一个 team control plane 和一个 team-specific workbench，而不是把多个 provider 塞进一条聊天消息流。”

核心推荐如下：

1. team 的基本对象不是 message，而是 mission、task card、artifact、review。
2. provider 间通信不走自由文本群聊，而走结构化 memo 与 artifact 引用。
3. 并行由 claim 和 workstream 驱动，不由“谁先说话”驱动。
4. UI 采用工作台，不复用当前 message bubble。
5. 第一阶段只做有限 team 协作，不做无限递归代理网络。

## 2. 设计目标

### 2.1 必须达成

1. 用户可以在一次任务中启用多个 ACP provider 共同工作。
2. provider 可以围绕同一 mission 交换结构化信息并并行执行子任务。
3. 系统能够区分 creative parallelism 与 execution parallelism。
4. team 运行时有明确的收敛点、冲突处理和失败回退。
5. UI 独立于现有 message 流，能够清楚展示 team 状态与产物。
6. 设计不要求一次性替换现有单 agent 模式，两者应并存。

### 2.2 非目标

1. 本期不实现跨会话的 agent marketplace。
2. 本期不做无限层级的 agent 递归生成。
3. 本期不引入通用 DAG 平台来编排所有应用功能。
4. 本期不要求所有 provider 都支持 team mode，可以先基于支持 ACP 的 provider 子集。
5. 本期不把 provider 原始内部推理完整暴露给用户。

## 3. 第一性原理

本设计只建立在五条原则之上：

1. 协作的本质是共享外部状态，不是共享长上下文。
2. 并行的本质是子问题相互独立，不是同时生成文本。
3. 团队的本质是分工和收敛，不是投票数量。
4. 用户关心的是 ownership 和进度，不是内部 chatter。
5. 复杂度必须延后，先用最少原语跑通高价值协作。

## 4. 为什么不能复用当前 message UI

当前 message UI 的默认单位是“一个 user turn 对应一个 agent answer”。这和 team 模式天然不一致。

team 模式真正的主对象是：

1. 一项 mission；
2. 多张 task cards；
3. 多个 provider lane；
4. 多份进行中的 artifact；
5. 一次收敛动作。

如果继续复用 message UI，会出现四个问题：

1. 结构错位：任务板会退化成多层嵌套消息。
2. 并行不可见：用户只会看到不断增长的文本日志。
3. ownership 不清：难以知道谁负责哪个子任务。
4. 结果难收敛：artifact 和 review 会被埋在消息流里。

因此，team mode 必须是独立表面，不是 message UI 的一种样式变体。

## 5. 推荐交互模型：Team Workbench

推荐新增一套独立界面：Team Workbench。

布局建议：

```text
┌──────────────────────────────────────────────────────────────┐
│ Mission Header                                              │
│ objective | constraints | acceptance | budget | status      │
├───────────────┬───────────────────────────────┬─────────────┤
│ Team Roster   │ Workstream Board              │ Inspector   │
│ providers     │ task cards + lanes + gates    │ artifact    │
│ health        │ parallel progress             │ review      │
│ readiness     │ blockers                       │ trace       │
├───────────────┴───────────────────────────────┴─────────────┤
│ Commit Bar: merge | ask human | replan | stop | publish     │
└──────────────────────────────────────────────────────────────┘
```

其核心不是炫技，而是把 team 的三个层级拆开：

1. Mission Header：团队为什么而工作。
2. Workstream Board：团队现在怎么分工。
3. Inspector：每个工件、handoff、冲突的具体细节。

## 6. 核心运行模型

### 6.1 Mission

一条 team run 对应一个 mission。mission 不是 message，而是一份结构化任务章程。

建议模型：

```swift
struct AgentTeamMission: Identifiable, Codable, Sendable {
    let id: UUID
    let title: String
    let objective: String
    let constraints: [String]
    let acceptanceCriteria: [String]
    let preferredMode: AgentTeamMode
    let budget: AgentTeamBudget
}
```

### 6.2 Team Mode

team 至少支持三种模式：

```swift
enum AgentTeamMode: String, Codable, Sendable {
    case creativeExploration
    case executionDelivery
    case researchAndSynthesis
}
```

原因：

1. creativeExploration 追求多样性与对比；
2. executionDelivery 追求 ownership、验证与合并；
3. researchAndSynthesis 追求并行取证与最终综述。

这三种模式共享 runtime，但 claim 规则与 merge 规则不同。

### 6.3 Provider Participation Model

Team 设计不能只说“多个 provider 会参与”，还必须定义 provider 从哪里来、何时被选中、以及 team run 如何持久化这份选择结果。

建议新增：

```swift
struct AgentTeamProviderPlan: Codable, Equatable, Sendable {
    let eligibleProviders: [ExecutionProviderReference]
    let preferredConductor: ExecutionProviderReference
    let preferredReviewer: ExecutionProviderReference?
    let dispatchPolicy: AgentTeamDispatchPolicy
}

enum AgentTeamDispatchPolicy: String, Codable, Sendable {
    case manualSelection
    case sourceSessionSeeded
    case autoClaim
}
```

规则建议：

1. standalone team 创建时，用户应看到可参与 team 的 provider 列表，并明确确认 initial conductor 或 reviewer，而不是静默落到 built-in。
2. 从 source session 创建 team 时，可以把 source session 的 default provider 作为 seed，但它只能是初始候选，不能替代完整的 provider plan。
3. team provider 必须来自当前可用且已验证的 provider 集合。built-in provider 与 dynamic external ACP profile 都是一等参与者，设计不能依赖 legacy preset provider ID。
4. provider plan 应在 team 启动时快照化保存。这样即使设置页后续修改默认 provider 或 profile 配置，既有 team run 的 ownership 语义仍然稳定。
5. `budget.maxActiveProviders` 是运行时并发约束，不只是展示字段；它应直接限制 claim acceptance 与后续 dispatch admission。

这一层的目标是把 provider 选择前移到 team 启动面，而不是在真正 dispatch 时才临时读取 session 默认 provider。

### 6.4 Brief-Claim-Commit 协议

这是整个系统最关键的最小协作协议。

#### Brief

conductor 生成统一任务 brief，内容包括：

1. objective
2. constraints
3. acceptance criteria
4. known workspace context
5. initial task cards

#### Claim

每个 provider 先提交 claim，而不是直接执行。

```swift
struct AgentTeamClaim: Identifiable, Codable, Sendable {
    let id: UUID
    let providerReference: ExecutionProviderReference
    let taskCardID: UUID
    let confidence: Double
    let rationaleSummary: String
    let requiredCapabilities: [String]
    let expectedArtifacts: [AgentTeamArtifactKind]
    let estimatedCost: AgentTeamCostEstimate
}
```

Claim 的作用：

1. 防止盲目并行；
2. 让系统先判断 provider-task fit；
3. 让 UI 从一开始就可解释。

#### Commit

provider 不直接“回答用户”，而是提交 artifact、status memo 或 review result。

这会把 team 协作从 message-first 变成 artifact-first。

### 6.5 Provider Dispatch Lifecycle

Claim 只是 team 协议的一半。design 还必须定义 accepted claim 之后如何进入真实执行，否则系统只会得到一个静态 task board。

推荐调度链如下：

1. 用户确认 brief 与 provider plan 后，conductor 生成 initial task cards。
2. team runtime 向 `eligibleProviders` 广播可 claim 的 cards，而不是立即执行。
3. provider 返回 claim，内容至少包含 confidence、required capabilities、expected artifacts、estimated cost。
4. conductor 或 claim resolver 选择 accepted claim，并把 `taskCard.owner` 与 `acceptedClaimID` 持久化到黑板。
5. 只有 accepted owner 才能获得 `AgentTeamExecutionContext(taskCardID, claimID)`，并据此进入 execution orchestrator。
6. team 模式下的真实 dispatch provider 必须来自 accepted claim owner，而不是来自普通 session 的 default provider fallback。
7. 若当前没有 accepted claim，则 card 进入 `awaitingClaim` 或 `blocked`，不得静默回退到任意 provider 开始执行。
8. 多卡并行时，runtime 根据 `budget.maxActiveProviders` 控制同时 dispatch 的 owner 数量。

设计含义是：session default provider 只允许作为 team 启动阶段的 seed，不允许作为 team 运行阶段的最终调度依据。真正的执行权来自 accepted claim。

## 7. 角色分层

### 7.1 Conductor

conductor 不必是最强 provider，也不应承担所有实际执行。它只负责：

1. 生成 brief；
2. 创建 task cards；
3. 接收 claims；
4. 分配 ownership；
5. 触发 replan；
6. 控制 merge/publish。

这里最重要的原则是：conductor 是控制面，不是万能 worker。

### 7.2 Worker Provider

worker provider 是实际执行者。每个 worker 一次只应拥有有限数量的 active cards。

worker 输出三类内容：

1. artifact draft
2. status memo
3. escalation request

### 7.3 Reviewer Provider

reviewer 不一定常驻，但在 executionDelivery 模式中必须存在。其职责是：

1. 检查 artifact 是否满足任务卡要求；
2. 标记 conflict 或 insufficiency；
3. 触发 fix loop 或 approve。

### 7.4 Human

用户不是旁观者，而是最后的边界条件提供者。系统需要允许用户在三个时点介入：

1. mission 启动前调整约束；
2. merge gate 前审批；
3. blocker 出现时补充信息。

## 8. 共享黑板模型

推荐不要让 provider 直接读写彼此完整上下文，而是通过共享黑板传递结构化对象。

### 8.1 Task Card

```swift
struct AgentTeamTaskCard: Identifiable, Codable, Sendable {
    let id: UUID
    let title: String
    let goal: String
    let kind: AgentTeamTaskKind
    let dependencies: [UUID]
    let owner: ExecutionProviderReference?
    let reviewer: ExecutionProviderReference?
    let status: AgentTeamTaskStatus
    let artifactIDs: [UUID]
}
```

### 8.2 Artifact

```swift
struct AgentTeamArtifact: Identifiable, Codable, Sendable {
    let id: UUID
    let kind: AgentTeamArtifactKind
    let title: String
    let producer: ExecutionProviderReference
    let taskCardID: UUID
    let version: Int
    let summary: String
    let payload: AgentTeamArtifactPayload
    let status: AgentTeamArtifactStatus
}
```

第一阶段建议支持：

1. brief
2. ideaDraft
3. explorationReport
4. implementationPlan
5. patchProposal
6. validationReport
7. reviewReport
8. finalSynthesis

### 8.3 Memo

memo 是 provider 之间最轻量的沟通形式。它不是长消息，而是状态化便签。

```swift
struct AgentTeamMemo: Identifiable, Codable, Sendable {
    let id: UUID
    let from: ExecutionProviderReference
    let to: [ExecutionProviderReference]
    let kind: AgentTeamMemoKind
    let subject: String
    let body: String
    let artifactRefs: [UUID]
}
```

kind 第一阶段只需要：

1. requestInfo
2. provideInfo
3. handoff
4. block
5. review
6. approval

## 9. 并行策略

### 9.1 Creative Parallelism

creativeExploration 模式下的并行目标不是提速，而是提高解空间质量。

推荐策略：

1. conductor 为同一任务创建 2 到 3 个 creative cards。
2. 每个 card 由不同 provider 独立产出 ideaDraft。
3. providers 之间在发散阶段不互相读取草稿正文，只共享 brief。
4. 到 synthesis gate 再统一对比并收敛。

这可以防止所有 provider 过早互相污染，导致创意坍塌成一个平均答案。

### 9.2 Execution Parallelism

executionDelivery 模式下的并行目标是拆分独立工作面。

推荐策略：

1. 只并行无写冲突或低耦合子任务。
2. 每张 task card 只有一个 owner。
3. 共享输出统一进入 artifact board。
4. 任何跨卡依赖必须显式声明。
5. merge 前必须走 review gate。

### 9.3 Dynamic Replan

并行不是静态 DAG。运行过程中应该允许：

1. blocker 触发补充探索卡；
2. review 失败触发修复卡；
3. 用户补充约束后触发 mission brief 更新；
4. owner 放弃任务后重新 claim。

## 10. Capability Slicing

这是针对 tool-space interference 的直接设计。

team 模式下不应让 provider 默认暴露完整能力，而应基于当前 mission 只暴露切片后的 capability set。

```swift
struct AgentTeamCapabilitySlice: Codable, Sendable {
    let providerReference: ExecutionProviderReference
    let enabledTools: [String]
    let enabledCommandGroups: [String]
    let writableArtifactKinds: [AgentTeamArtifactKind]
    let readableArtifactKinds: [AgentTeamArtifactKind]
}
```

直接收益：

1. 减少工具冲突；
2. 降低 prompt 负担；
3. 增强 provider 角色边界；
4. 提高 claim 的可解释性。

## 11. Merge 与 Review 机制

### 11.1 Merge Gate

team 模式必须有显式 merge gate。任何 final publish 之前，都需要满足：

1. 必要 artifacts 已存在；
2. critical blockers 为零；
3. required reviews 已完成；
4. acceptance criteria 全部被映射到具体 evidence。

### 11.2 Review 不是附属功能

review 是 team 模式成立的前提。没有 review，多 provider 只会带来更多未校验输出。

executionDelivery 模式下，建议至少支持：

1. semantic review
2. validation review
3. publish approval

### 11.3 冲突处理

当两个 provider 的 artifacts 冲突时，不直接拼接，而是进入 explicit conflict state：

1. 标记冲突 artifact pair；
2. 要求 reviewer 给出 conflict summary；
3. conductor 选择 merge、discard、rerun 或 ask human。

## 12. UI 详细设计

### 12.1 Mission Header

显示：

1. 目标摘要
2. 当前模式
3. 团队状态
4. 成本和 token 预算
5. 是否等待用户

### 12.2 Team Roster

不是头像列表，而是 provider 状态面板：

1. provider 名称
2. provider 来源类型，例如 Built-In / External ACP / Dynamic Profile
3. 当前角色
4. 当前 card
5. readiness
6. last artifact
7. blocker badge

此外建议额外显示：

8. participation state，例如 eligible、warming、claiming、owner、reviewing、blocked、offline。

### 12.3 Workstream Board

这是主视图，不是消息时间线。

推荐以 task card 为中心，而不是 provider 为中心。可采用两层视图：

1. 默认视图：按阶段列出 cards，例如 Briefing、Claimed、Working、Reviewing、Done。
2. 切换视图：按 provider 显示 lane，看到谁正在负责什么。

### 12.4 Inspector

点击任何 card 或 artifact 后，右侧 inspector 展示：

1. artifact 内容摘要
2. 关联 memo
3. review 状态
4. trace 摘要
5. upstream/downstream 依赖

### 12.5 Commit Bar

这是用户最关键的控制面。建议只提供少量高价值动作：

1. Merge current output
2. Ask one provider to rework
3. Replan mission
4. Add constraint
5. Stop team
6. Publish to chat transcript

## 13. 与现有聊天系统的关系

Team Workbench 不替代普通对话，而是与之并存。

推荐关系如下：

1. 用户仍可以从 chat 输入问题。
2. 当用户选择 Team Mode 时，系统新建一条 team run。
3. team run 在独立 workbench 中执行。
4. 完成后只把 final synthesis 和核心 artifacts 发布回主聊天 transcript。
5. 详细 team 过程保留在 workbench，可回放，但不灌入 message list。

因此，主聊天记录保存的是“结论”，而 team workbench 保存的是“协作过程”。

## 14. 数据与持久化建议

建议新增以下一组 team scoped model：

1. AgentTeamRun
2. AgentTeamMission
3. AgentTeamProviderPlan
4. AgentTeamTaskCard
5. AgentTeamArtifact
6. AgentTeamMemo
7. AgentTeamReview
8. AgentTeamProjectionSnapshot

第一阶段不需要把所有原始 provider 输出都持久化。默认持久化：

1. typed artifacts
2. memos
3. card state transitions
4. review decisions
5. publish summary

raw trace 可按需保留在 audit store。

## 15. 风险与防护

### 15.1 最大风险：team 比单 agent 更慢更贵

防护：

1. 只在 team-worthy 任务上启用；
2. 严格限制 active providers 数量；
3. creative 模式最多 3 路发散；
4. 未 claim 成功的 provider 不进入执行。

### 15.2 最大失败模式：provider 互相污染

防护：

1. 发散阶段隔离草稿；
2. 共享黑板只交换摘要和 artifacts；
3. capability slicing；
4. merge 前 reviewer 把关。

### 15.3 最大 UI 风险：重新做成日志面板

防护：

1. 默认展示 cards，不展示原始对话；
2. trace 只在 inspector 内二级展开；
3. 永远把 ownership、status、artifact 放在视觉前面。

## 16. 验收标准

1. 用户能明确看到 team objective、分工与当前状态。
2. 两个以上 provider 能围绕一个 mission 并行推进不同 cards。
3. creativeExploration 模式能产出多个独立草案并在 synthesis gate 收敛。
4. executionDelivery 模式能在 review gate 之后再 publish 最终结果。
5. 主聊天流不再承载 team 的所有中间细节。
6. team 过程可回放、可审计、可定位 blocker。

## 17. Feature 拆分

### Feature 1：Team Session 壳层

目标：引入 team run 这一新实体，但暂不做复杂协作。

范围：

1. 新增 Team Mode 入口。
2. 新增 team run 生命周期模型。
3. 允许从 chat 启动独立 team workbench。

验收标准：

1. 用户可创建 team run。
2. 普通 chat 与 team run 能并存。
3. team run 不复用当前 message 主体结构。

### Feature 2：Mission Header 与 Team Workbench Shell

目标：建立独立 UI 外壳。

范围：

1. Mission Header。
2. Team Roster 区。
3. Workstream Board 占位区。
4. Inspector 占位区。

验收标准：

1. team 有独立工作台。
2. message bubble 不再是主承载面。

### Feature 3：Brief 模型

目标：把 team 启动输入收敛为 mission brief。

范围：

1. objective、constraints、acceptance criteria。
2. mode 与 budget。
3. 初始上下文摘要。
4. provider participation plan。
5. source session seeded provider 与 explicit provider selection 规则。

验收标准：

1. team 启动后存在统一 brief。
2. 所有 provider 都从同一 brief 出发。
3. standalone team 创建时不会静默退化为隐式 built-in provider。
4. team run 会持久化保存 provider plan snapshot，而不是仅依赖 session default provider。

### Feature 4：Claim 协议

目标：执行前先 claim，避免盲目并行。

范围：

1. provider 提交 confidence、expected output、required capabilities。
2. conductor 根据 claim 分配 owner。
3. accepted claim 生成 team execution context。
4. execution dispatch 从 accepted owner 派发，而不是从 session 默认 provider 派发。
5. `maxActiveProviders` 参与 dispatch admission。

验收标准：

1. provider 不会在未 claim 的情况下直接进入执行。
2. UI 能显示谁认领了什么。
3. 非 owner provider 无法绕过 claim gate 进入执行。
4. owner 被选中后，系统能自动把对应 card 派发给正确的 provider。

### Feature 5：Task Card Board

目标：把协作单位从 message 切换为 task card。

范围：

1. 任务卡模型。
2. 状态流转：briefed、claimed、working、reviewing、done、blocked。
3. card 依赖关系。

验收标准：

1. 用户能看到 team 当前有哪些 cards。
2. 并行工作通过 cards 可见。

### Feature 6：Typed Artifact Board

目标：把 provider 间共享从自由文本改成结构化工件。

范围：

1. artifact schema。
2. artifact list 与 inspector。
3. card 到 artifact 的引用关系。

验收标准：

1. provider 可以提交 artifact。
2. artifact 能被 reviewer 与 conductor 消费。

### Feature 7：Creative Parallelism

目标：支持创意型并行。

范围：

1. 多 provider 独立草案。
2. synthesis gate。
3. 差异对比视图。

验收标准：

1. 同一 creative card 可产生 2 到 3 份并行草案。
2. UI 能明确显示草案差异和最终收敛结果。

### Feature 8：Execution Parallelism

目标：支持执行型并行。

范围：

1. 独立 workstream cards。
2. owner 单写规则。
3. blocker 与 dependency 管理。

验收标准：

1. 两个以上 provider 能并行推进独立 cards。
2. card 间依赖与阻塞可见。

### Feature 9：Memo 与 Handoff

目标：在 provider 之间建立轻量通信。

范围：

1. requestInfo、provideInfo、handoff、block、review、approval。
2. memo feed 仅作为辅助层。

验收标准：

1. provider 可以围绕 card 交换结构化 memo。
2. UI 不会退化成聊天群。

### Feature 10：Review Gate 与 Merge Gate

目标：让收敛成为显式系统能力。

范围：

1. reviewer 角色。
2. review artifacts。
3. merge gate。
4. ask human path。

验收标准：

1. final publish 前必须经过 gate。
2. 冲突和失败有明确回路。

### Feature 11：Capability Slicing

目标：减少 team 模式下的工具干扰。

范围：

1. provider team role。
2. tool subset。
3. artifact read/write permissions。

验收标准：

1. team 模式下 provider 不再暴露完整工具空间。
2. 不同角色的 provider 有清晰边界。

### Feature 12：Audit 与 Failure Diagnostics

目标：让 team 系统可调试、可审计。

范围：

1. step timeline。
2. card transition log。
3. critical failure 定位。
4. publish summary。

验收标准：

1. 能定位 team 在哪张 card、哪个 handoff 上出错。
2. 用户与开发者都能回放关键链路。

### Feature 13：Conductor Dispatch Phase（Conductor 独立调度阶段）

目标：让 conductor 从"auto-claim 标签"升级为真正的控制面角色，拥有独立的 planning 阶段，能产出结构化 task breakdown 驱动后续 worker dispatch，Roster 面板各字段反映真实运行时状态。

背景：当前实现（Feature 3/4/5）中，conductor 只是 auto-claim 时使用的 provider 引用，`AgentTeamLaunchCoordinator.launch()` 仅把整个 brief 打平为一段 prompt 发给 conductor 执行，与直接让单个 provider 执行无本质区别。Roster 面板的 readiness/focus 字段为硬编码，不反映运行时状态。详见 `docs/bug/2026-03-31-agent-team-conductor-no-scheduling.md`。

范围：

1. **Conductor Planning 阶段**：在 worker card dispatch 开始前，增加独立的 conductor planning job，要求 conductor provider 根据 brief 产出结构化执行计划（JSON 格式 task breakdown：card 标题、kind、依赖、预期 artifact 类型）。
2. **Planning 结果解析与 Card 生成**：解析 conductor 回复，自动生成子 task cards 并写入 `claimBoardState`，替换 launch 阶段的静态单卡。
3. **Conductor 专用 Prompt**：`AgentTeamMissionPromptBuilder` 为 conductor planning 阶段生成专用 prompt，明确告知 conductor 其职责是输出结构化计划，而非直接执行任务。
4. **Roster 动态状态**：`AgentTeamWorkbenchPresentation` 的 Roster 各条目（conductor / worker / reviewer）的 `readiness`、`focus`、`blocker` 字段改为读取 `claimBoardState` 运行时状态，不再使用硬编码字符串。
5. **Planning Gate**：conductor planning 完成前，worker dispatch 入口保持 `awaitingClaim`，确保 planning 结果驱动后续分工，不允许静默跳过。

降级规则：

- 若 conductor planning 失败（解析错误或超时），系统降级为单卡模式并在 Roster 标记 conductor focus 为"PlanFailed"，不静默挂起执行。

验收标准：

1. 启动 team 后，UI 能看到独立的 conductor planning 阶段（Roster 中 conductor 的 focus 更新为"Planning"）。
2. conductor planning 完成后，board 上出现由 conductor 回复解析出的多张子 task cards。
3. Roster 面板各条目的 readiness/focus/blocker 字段反映实际运行时状态，不再显示硬编码字符串。
4. 若 conductor planning 失败，系统能正确降级并标记状态，不死锁。

### Feature 14：Smart Brief Composer — 单输入口与 AI 结构化提取

目标：将 Team Mission Brief 的创建入口收敛为单个自由文本输入框，通过内置 LLM 自动提取结构化字段（objective、constraints、acceptanceCriteria），移除对 ACP provider 意义不大的 Budget 字段。

背景：当前 `AgentTeamBriefComposerSheet` 要求用户手动填写 Objective、Constraints、Acceptance Criteria 等多个独立区域，并包含 tokenBudgetText / costBudgetText 等对 ACP 无实际意义的字段。该交互门槛高、与 LLM-first 应用风格不符，且 Budget 字段在 ACP 层面无任何调度效果。

#### 模型变更

**移除 Budget 自由文本字段**（`AgentTeamBudget` 与 `AgentTeamMissionBriefDraft` 变更）：

- 移除 `tokenBudgetText` 和 `costBudgetText`。
- `AgentTeamBudget` 仅保留 `maxActiveProviders: Int`，并改名为 `AgentTeamDispatchBudget` 以清晰表达语义。
- `maxActiveProviders` 保留在高级配置折叠区，不作为主界面必填项。

**新增 `rawInput` 到 `AgentTeamMissionBriefDraft`**：

```swift
struct AgentTeamMissionBriefDraft: Equatable, Sendable {
    var rawInput: String                   // 主输入框：任务自由描述
    var objective: String                  // AI 提取或手动填写
    var constraintsText: String            // AI 提取或手动填写
    var acceptanceCriteriaText: String     // AI 提取或手动填写
    var mode: AgentTeamMode
    var maxActiveProviders: Int
    var extractionState: BriefExtractionState
    // ...provider 字段
}

enum BriefExtractionState: Equatable, Sendable {
    case idle
    case extracting
    case done
    case failed(String)
}
```

**新增 `MissionBriefExtractionService`**：

```swift
struct MissionBriefExtractionResult: Sendable {
    let objective: String
    let constraints: [String]
    let acceptanceCriteria: [String]
    let suggestedMode: AgentTeamMode
}

protocol MissionBriefExtractionService: Sendable {
    func extract(from rawInput: String) async throws -> MissionBriefExtractionResult
}
```

实现以单轮 built-in LLM 请求完成提取，使用 JSON schema 约束输出格式，避免长流式响应。

#### 交互流程

1. 用户在大型 TextEditor 中输入任务描述（没有字数下限，哪怕一句话也可以）。
2. 用户点击"解析 Brief"按钮，或在停止输入 1.5s 后自动触发提取。
3. Sheet 显示 extracting 状态（shimmer 动画）。
4. 提取完成后，objective / constraints / acceptanceCriteria 以只读预览卡片展示，支持点击进入编辑。
5. 用户可以完全跳过提取，直接以 rawInput 作为 objective 提交（即快速路径：输入 → 直接创建 Team）。
6. 提取失败时显示内联错误提示，不阻断创建流程。

#### Budget 移除原则

- tokenBudgetText 和 costBudgetText 完全移除，不以其他形式保留在 UI 中。
- `maxActiveProviders` 保留，但移入可折叠的"高级选项"区，默认值为 2，不作为主界面可见字段。
- `AgentTeamMissionBriefResolver.fallbackBrief` 同步移除 Budget 文本字段的生成逻辑。

#### 向后兼容

已有的 `AgentTeamMissionBrief` model 中 `budget` 字段改为 `dispatchBudget: AgentTeamDispatchBudget`，只保留 `maxActiveProviders`，通过 `AgentTeamMissionBrief` 的 Codable 实现对旧数据做 migration（旧 `budget` key 映射到 `dispatchBudget.maxActiveProviders`，丢弃文本字段）。

范围：

1. 移除 `AgentTeamBudget` 文本字段，新增 `AgentTeamDispatchBudget`。
2. `AgentTeamMissionBriefDraft` 新增 `rawInput`、`extractionState`；移除 `tokenBudgetText`、`costBudgetText`。
3. 新增 `MissionBriefExtractionService` 协议与 `BuiltInMissionBriefExtractionService` 实现。
4. `AgentTeamBriefComposerSheet` 主输入改为单 TextEditor，加"解析 Brief"按钮与自动触发逻辑。
5. Brief 提取结果展示为可编辑预览区（折叠/展开）。
6. Fallback Resolver 同步移除 Budget 文本字段引用。

验收标准：

1. Sheet 打开时只有一个主要输入框，用户不需要打开任何折叠区域就能完成 Team 创建。
2. 输入文本后提取 Brief，能正确填充 objective、constraints、acceptanceCriteria。
3. Budget 相关文本字段在任何 UI 位置都不再可见。
4. 旧的持久化 brief 数据能正确 migration，`maxActiveProviders` 不丢失。
5. 提取失败时用户仍能直接创建 Team（降级为仅 rawInput 作为 objective）。

---

### Feature 15：Provider 角色多重分配与 Warm-up 模型选择

目标：让同一个 ACP provider 可以同时担任 conductor、worker、reviewer 中的一个或多个角色；在用户打开 Brief Composer 时自动 warm-up 所有可用 provider，并将 warm-up 结果（modes、model 选项）暴露给用户选择。

背景：当前 `AgentTeamProviderPlan` 通过独立的 `preferredConductor` / `preferredReviewer` 字段表达角色，Reviewer 选项强制排除与 Conductor 相同的 provider（见 `reviewerOptions` 计算属性），导致同一 provider 无法身兼两职。此外，provider 的 modes 和 models 只有在 session 已存在时才从 `ACPExternalSessionFeatureStore` 获取，Brief Composer 阶段无法展示这些选项。

#### 模型变更

**新增 `AgentTeamProviderRole`**：

```swift
enum AgentTeamProviderRole: String, CaseIterable, Codable, Equatable, Sendable {
    case conductor   // 主导者：生成 brief、分配 card、控制 merge
    case worker      // 执行者：处理 task card
    case reviewer    // 审核者：验证 artifact、触发修复或 approve
}
```

**新增 `AgentTeamProviderRoleAssignment`**：

```swift
struct AgentTeamProviderRoleAssignment: Codable, Equatable, Sendable {
    let providerReference: ExecutionProviderReference
    var roles: Set<AgentTeamProviderRole>
    var selectedModelID: String?
    var selectedModeID: String?
}
```

**更新 `AgentTeamProviderPlan`**：

```swift
struct AgentTeamProviderPlan: Codable, Equatable, Sendable {
    var roleAssignments: [AgentTeamProviderRoleAssignment]
    var dispatchPolicy: AgentTeamDispatchPolicy

    // 计算属性，派生自 roleAssignments
    var eligibleProviders: [ExecutionProviderReference] { ... }
    var preferredConductor: ExecutionProviderReference { ... }
    var preferredReviewer: ExecutionProviderReference? { ... }
}
```

向后兼容：`AgentTeamProviderPlan` 提供从旧格式（独立 conductor/reviewer 字段）迁移的 Codable init。

#### Provider Warm-up 机制

Brief Composer Sheet 出现时，立即对所有已启用的 ACP provider 触发后台 warm-up 探测：

```swift
@MainActor
final class BriefComposerProviderWarmupCoordinator: Observable {
    enum WarmupState: Sendable {
        case idle
        case warming
        case ready(modes: [ExecutionOptionItem], modelOptions: [ExecutionOptionItem])
        case failed
    }
    var states: [ExecutionProviderReference: WarmupState]

    func warmup(provider: ExecutionProviderReference,
                claudeService: ClaudeService,
                sourceSession: Session?,
                modelContext: ModelContext) async
}
```

Warm-up 策略：

1. 使用 source session（如有）作为探测上下文，调用 `claudeService.handleExecutionProviderSelectionChange(trigger: .sessionBootstrap)`。
2. 从 `ACPExternalSessionFeatureStore` 获取 `configurationSnapshot`，提取 modes 和 models。
3. 若无 source session，使用临时 `UUID` 作为 session ID 触发探测，探测完成后不持久化。
4. Fallback：若 warm-up 超时（> 8s）或失败，使用 `ACPCLIConfiguration.curatedModelOptions` 作为模型选项。

Warm-up 在 Sheet 出现时并发触发所有 provider（不阻塞用户输入），状态实时更新到 UI。

#### 角色分配规则

1. Conductor 必须有且仅有一个 provider 担任（不允许多个 conductor）。
2. Worker 和 Reviewer 可以有 0 到 N 个（0 时由 conductor 兼任）。
3. 同一 provider 可以同时担任：conductor + reviewer、conductor + worker、worker + reviewer。
4. 系统不自动强制拒绝任何合法组合，但 UI 提示单 provider 身兼所有角色时协作效果有限。

范围：

1. 新增 `AgentTeamProviderRole` 枚举与 `AgentTeamProviderRoleAssignment` 结构体。
2. `AgentTeamProviderPlan` 改用 `roleAssignments` 替代独立 conductor/reviewer 字段，保留计算属性向下兼容。
3. 新增 `BriefComposerProviderWarmupCoordinator`（`@Observable @MainActor`）。
4. Brief Composer Sheet 出现时自动并发触发所有可用 provider warm-up。
5. `AgentTeamMissionBriefDraft` 角色相关字段改用 `roleAssignments: [AgentTeamProviderRoleAssignment]`，移除 `eligibleProviderIDs`、`preferredConductorID`、`preferredReviewerID`。
6. `AgentTeamLaunchCoordinator` 更新为从 `roleAssignments` 读取 conductor/worker/reviewer。

验收标准：

1. 同一 provider 可以在 UI 中同时被勾选为 conductor 和 reviewer，创建的 Team 能正确持久化这一分配。
2. Brief Composer 打开后，ACP provider card 显示 warm-up 进度（loading → ready/failed）。
3. warm-up 成功的 provider card 展示可用的 modes 和 model 选项供用户选择。
4. warm-up 失败的 provider 仍可参与 team，但 model/mode 选项改为降级静态列表。
5. `AgentTeamLaunchCoordinator` 使用 roleAssignment 中的 conductor，而不是旧的 `preferredConductor` 字段。

---

### Feature 17：Per-Agent Virtual Session — 并行 Agent 独立运行时管理

目标：为 team mode 中每个并行运行的 agent（被接受的 claim owner）分配独立的虚拟 session，使 `ExecutionScheduler` 能同时 admit 多个来自不同 session ID 的 job，从而让 Feature 8（Execution Parallelism）真正做到多 provider 同时工作。

背景：

当前 `ExecutionScheduler.admitReadyJobs` 以 `sessionID` 作为互斥键：只要 `runningJobsBySessionID[candidate.sessionID] != nil`，同一 session 的下一个 job 就无法被 admit。因此，如果所有并行 task card 都通过父 team session 的 `sessionID` 提交，调度器会把它们串行化——同一时刻只有一张卡在执行。这与 Feature 8 要求的并发执行语义根本矛盾。

此外，`SessionExecutionMailbox` 也是按 sessionID 绑定的：每个 session 有独立队列，mailbox 的 `markRunning` 强制要求同 session 只有一个 running job。

解决方案：每个被接受的 claim 在进入 `.working` 阶段时，分配一个独立的**虚拟 session ID**（`virtualSessionID`，即一个 UUID 字符串），并以该 ID 提交到 scheduler 和 mailbox。这样，N 张并行 task card 就对应 N 个不同的 sessionID，调度器能同时 admit 全部，完全符合现有 `maxConcurrentJobs` 约束（只需提高限制）。

#### 虚拟 Session 的定义

虚拟 session 不是 SwiftData `Session` 实体，而是一个纯内存的轻量记录：

```swift
struct AgentTeamVirtualSession: Identifiable, Sendable {
    let id: String               // 作为 sessionID 使用的 UUID 字符串
    let parentTeamSessionID: String
    let taskCardID: UUID
    let claimID: UUID
    let providerReference: ExecutionProviderReference
    let allocatedAt: Date
}
```

关键原则：

1. **虚拟 session 的 ID 仅用于 scheduler 和 mailbox 分派层**，不作为持久化主键，不出现在 SwiftData 存储中。
2. **父 team session** 仍是所有 UI、SwiftData 存储和 workbench 投影的唯一锚点。
3. 所有来自虚拟 session 的 execution projection 事件，通过 registry 映射回 `(parentTeamSessionID, taskCardID)` 后再更新 workbench。

#### AgentTeamVirtualSessionRegistry

```swift
@MainActor
final class AgentTeamVirtualSessionRegistry: Observable {

    // virtualSessionID → virtual session record
    private(set) var sessions: [String: AgentTeamVirtualSession] = [:]

    /// 为一个被接受的 claim 分配虚拟 session。
    /// 每个 (claimID, taskCardID) 组合最多分配一个虚拟 session；重复调用幂等。
    @discardableResult
    func allocate(
        for claim: AgentTeamClaim,
        parentTeamSessionID: String
    ) -> AgentTeamVirtualSession {
        if let existing = sessions.values.first(where: { $0.claimID == claim.id }) {
            return existing
        }
        let vsid = UUID().uuidString
        let vs = AgentTeamVirtualSession(
            id: vsid,
            parentTeamSessionID: parentTeamSessionID,
            taskCardID: claim.taskCardID,
            claimID: claim.id,
            providerReference: claim.providerReference,
            allocatedAt: Date()
        )
        sessions[vsid] = vs
        return vs
    }

    /// card 完成/失败/放弃时释放对应虚拟 session。
    func release(for taskCardID: UUID) {
        sessions = sessions.filter { $0.value.taskCardID != taskCardID }
    }

    /// 通过 virtualSessionID 查找父 team session 和 card ID，用于 projection 路由。
    func resolve(virtualSessionID: String) -> (teamSessionID: String, taskCardID: UUID)? {
        guard let vs = sessions[virtualSessionID] else { return nil }
        return (vs.parentTeamSessionID, vs.taskCardID)
    }

    /// 父 team session 所有活跃虚拟 session 的 ID 集合，用于 runtime retention。
    func activeVirtualSessionIDs(for teamSessionID: String) -> Set<String> {
        Set(sessions.values
            .filter { $0.parentTeamSessionID == teamSessionID }
            .map { $0.id })
    }
}
```

Registry 生命周期与父 team session 绑定，建议挂载在 `AgentTeamSessionState` 或 `ClaudeService+TeamDispatch` 的 dispatch 上下文中。

#### 与 ClaimPhaseResult 的集成

`AgentTeamLaunchCoordinator.ClaimPhaseResult` 新增 `virtualSessionID` 字段：

```swift
struct ClaimPhaseResult: Equatable {
    let primaryCardID: UUID
    let executionTarget: AgentTeamExecutionTarget
    let missionPrompt: String
    let virtualSessionID: String   // 新增：分派层使用的 scheduler key
}
```

`claimPrimaryCard` 和 `claimBatch` 在返回前通过 registry 为每个结果分配 `virtualSessionID`。

#### 与 ClaudeService+TeamDispatch 的集成

`launchTeamMission` 当前使用 `session.sessionId` 作为 execution job 的 sessionID。并行 dispatch 路径改为：

```swift
// 单卡 dispatch（向后兼容，Feature 4 不需要虚拟 session）
// virtualSessionID == 父 team session ID，无变化

// 多卡并行 dispatch（Feature 8 路径）
for claimResult in batchResults {
    let dispatchSessionID = claimResult.virtualSessionID  // 使用虚拟 session ID
    await claudeService.dispatchTeamCardJob(
        sessionID: dispatchSessionID,
        providerReference: claimResult.executionTarget.providerReference,
        prompt: claimResult.missionPrompt,
        teamContext: claimResult.executionTarget.teamContext
    )
}
```

规则：单卡 conductor dispatch（Feature 4/13 路径）继续使用父 team session ID，保持与 `foregroundSessionID` 的对齐，不引入虚拟 session。虚拟 session 只在 `claimBatch` 路径（Feature 8）中启用。

#### Runtime Retention 策略

虚拟 session 的 ACP provider 进程保活机制：

| 保活来源 | 覆盖范围 | 说明 |
|---|---|---|
| `foregroundSessionID = team session` | 父 team session 的 provider | card 间空窗期保活，由 Feature 18.3 修复提供 |
| execution lease per virtualSessionID | 当前正在运行的卡 | 执行期间由现有 lease 机制保活 |
| `teamActiveVirtualSessionIDs` 集合（新增） | 所有活跃虚拟 session | team 运行期间批量保护 N 个 provider 进程 |

建议在 `ConversationExecutionRuntimeCoordinator.RetentionState` 增加：

```swift
var teamActiveVirtualSessionIDs: Set<String> = []
```

在 `reconcileRuntimeRetention` 中，把这个集合的所有 session ID 视为 retained（与 `foregroundSessionID` 和 execution lease 并列），防止 N-1 张卡完成后、下一张卡开始前，对应 provider 进程被 kill。

在 `AgentTeamSessionView` 的 `.task` 中，通过 registry 的 `activeVirtualSessionIDs(for:)` 结果实时更新该集合。

#### Provider maxConcurrentSessions 约束

`ProviderExecutionCapacityPolicy.default` 目前 `maxConcurrentSessions: .max`，不限制同一 provider 同时服务多少个 session。在 team 模式下，若同一 ACP provider 被分配到多张 task card 同时执行（round-robin 可能产生这种情况），需确认该 provider 的 CLI 实现是否支持多进程并发或多 session 复用。

建议在 provider plan validation 阶段增加检查：若同一 provider 被分配到多张并行 card，且 `providerMaxConcurrentSessions < 2`，则 dispatch 时自动将该 provider 的多张卡串行化（通过保持父 session ID）而不是使用虚拟 session。

#### Projection 路由（与 Workbench 的集成）

虚拟 session 的 execution projection 事件（streaming tokens、finish、error）会以 `virtualSessionID` 为键写入 `ExecutionProjectionStore`。Workbench 需要知道这些结果属于哪张 task card：

1. `AgentTeamWorkbenchPresentation` 在计算 card 状态时，通过 registry 查找当前 card 的 `virtualSessionID`，再从 projection store 读取对应条目的内容快照。
2. Workbench artifact inspector 可通过 `(parentTeamSessionID, taskCardID)` 而非 `virtualSessionID` 来展示结果，保持 UI 层与底层 dispatch 层解耦。

#### 生命周期摘要

```
claim accepted
    │
    ▼
allocate(virtualSession) ← registry.allocate(for: claim, parentTeamSessionID:)
    │
    ▼
dispatchTeamCardJob(sessionID: virtualSessionID)
    │  scheduler.admitReadyJobs → OK（独立 session ID）
    ▼
card status = .working
    │  provider 执行，streaming events 写入 projection[virtualSessionID]
    ▼
card status = .done / .failed
    │
    ▼
registry.release(for: taskCardID)
teamActiveVirtualSessionIDs 从 runtimeCoordinator 中移除此 virtualSessionID
```

范围：

1. 新增 `AgentTeamVirtualSession` 值类型。
2. 新增 `AgentTeamVirtualSessionRegistry`（`@MainActor @Observable`），挂载在 team dispatch 上下文。
3. `AgentTeamLaunchCoordinator.ClaimPhaseResult` 新增 `virtualSessionID: String`；`claimBatch` 在返回前调用 registry 分配。
4. `ClaudeService+TeamDispatch.launchTeamMission` 多卡路径使用 `claimResult.virtualSessionID` 而非 `session.sessionId`。
5. `ConversationExecutionRuntimeCoordinator.RetentionState` 新增 `teamActiveVirtualSessionIDs: Set<String>`；`reconcileRuntimeRetention` 将其作为额外 retained sessions。
6. `AgentTeamSessionView` `.task` 阶段，通过 registry 实时维护 `teamActiveVirtualSessionIDs`。
7. `AgentTeamWorkbenchPresentation` 从 registry 查找 card 对应的 `virtualSessionID`，用于 projection store 读取路由。

降级规则：

- 若 `claimBatch` 返回结果数 ≤ 1（单卡路径，Feature 4/13），不分配虚拟 session，直接使用父 team session ID，完全向后兼容。
- 若 registry 分配失败，log 错误并降级为父 session ID（使并行退化为串行，但不阻断执行）。

验收标准：

1. Feature 8 并行路径：两张 `.working` 状态的 task card 在 Workbench 同时显示"执行中"，不互相等待。
2. `ExecutionScheduler.runningJobsBySessionID` 在并行执行期间包含至少两个不同的虚拟 session ID。
3. 一张 card 完成后，其他 card 继续执行，对应 provider 进程未被 kill（`teamActiveVirtualSessionIDs` 保活）。
4. Card 完成后，对应虚拟 session 从 registry 和 `teamActiveVirtualSessionIDs` 中移除，不造成内存泄漏。
5. 单卡路径（Feature 4/13）行为无变化，不引入虚拟 session。

---

### Feature 16：Brief Composer 全面 UI 重设计

目标：将 `AgentTeamBriefComposerSheet` 的视觉风格、交互结构和动画升级至与应用整体一致的 Liquid Glass / macOS 26+ 水准，采用两步式布局、spring 动画、Provider Card 展开、warm-up 状态可视化及 Mode 卡片选择器。

背景：当前 Sheet 使用基础 `TextField` + `TextEditor` + `Toggle` 堆叠布局，无动画、无分步骤、无状态反馈，视觉质量与应用其他部分（Liquid Glass card、slide 动画、WorkbenchSidebarSectionCard 等）差距明显，且 Provider 选择交互仅依赖 Toggle + Picker，缺乏直观性。

#### 整体布局

Sheet 改为水平双栏 + 底部 Commit Bar：

```
┌─────────────────────────────────────────────────────────┐
│  创建 Team Mission                           [×]         │
├──────────────────────────┬──────────────────────────────┤
│  Left: 任务意图           │  Right: Team 配置            │
│                          │                              │
│  ┌──────────────────┐    │  [Built-in]  ● Conductor     │
│  │  TextEditor      │    │  [OpenCode]  ○ warm-up...    │
│  │  （主输入）       │    │  [Claude CLI] × 未安装       │
│  └──────────────────┘    │                              │
│  [解析 Brief]  shimmer    │  高级选项 ▾                  │
│                          │    并发上限: [–] 2 [+]       │
│  ── 提取结果预览 ──       │                              │
│  Objective: ...          │                              │
│  Constraints: chip chip  │                              │
│  Criteria: chip chip     │                              │
│                          │                              │
│  Mode:                   │                              │
│  [执行交付][创意探索]     │                              │
│  [研究综合]              │                              │
├──────────────────────────┴──────────────────────────────┤
│                              [取消]  [创建 Team  →]     │
└─────────────────────────────────────────────────────────┘
```

#### 关键 UI 组件

**MainInputArea（左栏）**：

- 主 TextEditor 占左栏主体，min-height 120pt，占位文本："描述你想完成的任务：目标、限制、期望结果都可以直接写..."
- 输入框使用 `workbenchSidebarHeaderFieldStyle()` 背景（glassEffect）。
- "解析 Brief" 按钮紧贴输入框底部右侧，提取中变为 shimmer 进度条（`ProgressView`）。
- 提取结果预览区：用 `WorkbenchSidebarSectionCard` 包裹，以 `withAnimation(.spring(duration: 0.35))` fade + slide in。
  - Objective 以 editable Text 展示。
  - Constraints / Criteria 以可删除 chip 展示（`TagChipView`，复用现有 chip 组件）。
- Mode 选择：3 个 `GlassEffectContainer` 卡片，横向排列，选中态有 `.glassEffect(.regular.interactive())` 高亮。

**ProviderSetupArea（右栏）**：

- 每个可用 provider 渲染为独立 `ProviderRoleCard`：
  - 顶部行：provider 名称 + 类型 badge（Built-in / ACP）+ warm-up 状态 indicator（`ProgressView` -> 绿点 / 红叉，spring 动画）。
  - Role chips 行：`[Conductor]` `[Worker]` `[Reviewer]` 三个 toggleable chip，选中态使用 `.glassEffect(.regular.interactive())`，多选支持（需遵守 conductor 唯一性规则）。
  - 展开区（warm-up 完成后可见）：Model Picker + Mode Picker，使用 `ExecutionOptionPicker`，以 `transition(.move(edge: .top).combined(with: .opacity))` + spring 动画展开。
  - 未安装 provider 显示灰色 badge，role chip 禁用。
- "高级选项" 折叠区：`maxActiveProviders` Stepper，默认折叠，用 `DisclosureGroup` 实现。

**Commit Bar（底部）**：

- HStack：Spacer + `Button("取消")` + `Button("创建 Team")` 带 SF Symbol `arrow.right`。
- 创建 Team 按钮：disabled 条件 = rawInput 空 || 无 conductor 角色分配。
- 按钮使用 `.keyboardShortcut(.defaultAction)` 和 `.keyboardShortcut(.cancelAction)`。

#### 动画规格

| 动画场景 | 规格 |
|---|---|
| Brief 提取结果展示 | `.spring(duration: 0.35, bounce: 0.2)` + `.opacity` + `.offset(y: 12 → 0)` |
| Provider warm-up 状态变化 | `.spring(duration: 0.3)` 驱动状态图标切换 |
| Provider Card 展开模型选项 | `.spring(duration: 0.4, bounce: 0.1)` + `transition(.move(edge: .top).combined(with: .opacity))` |
| Mode 卡片选中 | `.spring(duration: 0.25)` scaleEffect + glassEffect 高亮 |
| Sheet 出现 | 系统默认 Sheet 动画，内容以 `.task` 触发并发 warm-up |
| 提取中 shimmer | `withAnimation(.linear(duration: 1.2).repeatForever())` |

#### 可访问性

- 所有交互元素保留 `accessibilityIdentifier` 命名规范（agentTeam.brief.* 前缀）。
- Mode 选择卡片添加 `accessibilityAddTraits(.isButton)`。
- ProviderRoleCard 的 warm-up 状态添加 `accessibilityLabel`（"正在连接 OpenCode..."、"OpenCode 就绪"）。

范围：

1. `AgentTeamBriefComposerSheet` 完全重写为双栏布局，提取原有子视图为独立 View struct。
2. 新增 `BriefMainInputArea`、`BriefExtractionPreviewCard`、`BriefModeSelector`（左栏组件）。
3. 新增 `ProviderRoleCard`、`ProviderRoleChipRow`、`ProviderModelPicker`（右栏组件）。
4. 所有 glass 风格统一使用 `workbenchSidebarCardStyle()` / `glassEffect` 替代原有 `RoundedRectangle stroke` overlay。
5. `AgentTeamBriefComposerRequest` 更新以注入 `BriefComposerProviderWarmupCoordinator`（来自 Feature 15）。
6. 全面补充 spring 动画（移除旧代码中所有硬编码 frame 或无动画的状态切换）。

验收标准：

1. Sheet 视觉风格与 WorkbenchSidebarSectionCard / glassEffect 等已有组件一致，不出现与 app 风格割裂的硬边框或空白区域。
2. Provider warm-up 状态能以动画形式从"连接中"过渡到"就绪"，用户无需刷新。
3. Brief 提取结果出现时有 spring 动画，chips 可独立删除，objective 可内联编辑。
4. Mode 选择卡片的选中/取消选中有明确视觉反馈（glassEffect 高亮 + spring scale）。
5. 创建 Team 按钮的 enabled/disabled 状态正确响应 rawInput 和 conductor 分配状态。
6. Provider Card 展开/折叠有流畅动画，不出现位移跳变。

---

## 18. Team Runtime 执行管理：现状、约束与 Bug 分析

### 18.1 执行 Runtime 架构（共享层）

Team session 与普通 chat session 共用同一套执行 runtime：

```
ClaudeService
  └─ ConversationExecutionOrchestrator  (@MainActor)
       ├─ ExecutionScheduler(maxConcurrentJobs: 2)   ← 全局并发上限
       ├─ SessionExecutionMailbox  (per session)
       ├─ ExecutionRuntimePool  (per provider)
       └─ ConversationExecutionRuntimeCoordinator    ← 生命周期管理
```

关键约束：

1. **全局并发上限 `maxConcurrentJobs: 2`**：所有 session（team + chat）合计最多 2 个并发 job。MVP 单卡 team 只占 1 个 slot，暂不成瓶颈；但未来并行多卡执行（Feature 8）需提高这一限制。
2. **每 session 同一时刻至多 1 个 running job**：`ExecutionScheduler.admitReadyJobs` 按 session ID 过滤——`runningJobsBySessionID[candidate.sessionID] != nil` 时直接跳过同 session 的后续候选；`SessionExecutionMailbox.markRunning` 在 `runningJobID != nil` 时同样拒绝入队。这意味着**所有并行 task card 不能共享同一个 sessionID，否则会被静默串行化**。完全符合 team 模式当前的单卡串行执行需求，但 Feature 8（Execution Parallelism）要求每张并行 card 持有独立 sessionID，详见 Feature 17。
3. `ProviderExecutionCapacityPolicy.default` 的 `maxConcurrentSessions: .max` 不限制 provider 级并发，但受 `maxConcurrentJobs` 全局约束。

### 18.2 ACP Provider Runtime 生命周期与保活机制

`ConversationExecutionRuntimeCoordinator` 维护两类保活来源：

| 保活来源 | 设置时机 | 清除时机 |
|---|---|---|
| `foregroundSessionID` | `prepareForActivation(trigger: .selection 或 .sessionBootstrap)` | 切换到其他 session |
| `executionLeaseProviderReferencesBySessionID` | `prepareForActivation(trigger: .executionDispatch)` | 对应 job finish 后 `reconcileRuntimeRetention` 时 runtime snapshot `isRunning=false` |

只要 session 在其中任一来源中被引用，其 ACP provider 进程就不会被 `releasePreparedRuntime` 终止。反之，进程会被主动 kill。

### 18.3 已定位 Bug：Team Session 未设置 foregroundSession 导致 Runtime 被释放

**症状**：ACP provider 或 built-in 在 team session 中跑一轮后执行不下去，下次触发需要重新冷启动，甚至直接失败。

**根因**：

`AgentTeamSessionView` 原始实现缺少 `.task` 中的 `sessionBootstrap` 调用，导致：

1. `ConversationExecutionRuntimeCoordinator.foregroundSessionID` 从未被设置为 team session 的 ID。
2. 第一张卡执行完毕 → `finish()` → `projectionWriter.apply(.finished(...))` → runtime snapshot `isRunning=false` → `reconcileRuntimeRetention` → 既无 foreground 保护，也无 execution lease → ACP provider 进程被 `releasePreparedRuntime` 终止。
3. 第二张卡 launch 时，需要从零重启 ACP provider CLI 进程（OpenCode、Claude Code 等冷启动约 5-10 秒），且重启失败概率不低。

相比之下，`ChatView` 在 `warmExecutionRuntimeIfNeeded()` 中正确地调用了：

```swift
await claudeService.handleExecutionProviderSelectionChange(
    session: session,
    selectedProviderReference: resolvedExecutionProviderReference,
    modelContext: modelContext,
    trigger: .sessionBootstrap
)
```

这使 chat session 成为 `foregroundSession`，其 ACP 进程在卡间空窗期也能存活。

**修复**：在 `AgentTeamSessionView.body` 上添加：

```swift
.task(id: session.sessionId) {
    let settings = AppSettings.getOrCreate(in: modelContext)
    let providerReference = session.agentTeamState?.claimBoardState?.preferredExecutionTarget()?.providerReference
        ?? ConversationExecutionProviderRegistry.resolveProviderReference(for: session, settings: settings)
    await claudeService.handleExecutionProviderSelectionChange(
        session: session,
        selectedProviderReference: providerReference,
        modelContext: modelContext,
        trigger: .sessionBootstrap
    )
}
```

此修复保证：
- Team session 视图出现时立即设置 `foregroundSessionID`。
- ACP provider 进程在两卡之间的空窗期因为 foreground 保护而存活。
- 若 team 已 launch（有 accepted claim），则用 accepted claim 的 provider reference 进行预热，确保热路径对齐。

### 18.4 `finish()` 后 `reconcileRuntimeRetention` 时序说明

`ConversationExecutionOrchestrator.finish()` 的调用顺序：

```
persistenceStore.finish(...)
mailbox.finishRunning(...)
scheduler.markFinished(...)
projectionWriter.apply(.finished(...))   ← runtime snapshot isRunning → false
runtimeCoordinator.reconcileRuntimeRetention(...)
dispatchReadyJobs()
```

`reconcileRuntimeRetention` 时，runtime snapshot 已标记为 `isRunning=false`，所以 execution lease 只能保活"正在运行"的 job 对应的 provider。这是设计行为，不是 bug。

对 team 模式的含义：

1. **有 foreground 保护（修复后）**：team session 始终是 foreground session，ACP 进程存活，下一张卡可热启动。
2. **无 foreground 保护（修复前）**：每张卡执行完均触发 ACP 进程终止，下一张卡需冷启动。

### 18.5 `weak self` 异步流风险

```swift
Task { @MainActor [weak self] in
    guard let self else { return }
    for try await event in stream { ... }
}
```

`ConversationExecutionOrchestrator` 被 `ClaudeService` 以强引用存储（`executionOrchestrator: ConversationExecutionOrchestrator?`），而 `ClaudeService` 是 app 生命周期级的 `@Environment`，不会提前释放。

实际影响：当前架构下此风险属于理论性，不会触发。但若未来 orchestrator 生命周期变化（如按 workspace 分组独立创建），需改为 `strong` 捕获并在流结束后显式清理。

### 18.6 Feature 4/5 实际落地情况与 AgentTeamLaunchCoordinator

Feature 4（Claim 协议）和 Feature 5（Task Card Board）的核心调度链在以下文件中已实现：

| 组件 | 文件 | 职责 |
|---|---|---|
| `AgentTeamLaunchCoordinator` | `Services/Team/AgentTeamLaunchCoordinator.swift` | auto-claim、budget 控制、RunStatus 推进、card done 标记 |
| `AgentTeamMissionPromptBuilder` | `Services/Team/AgentTeamMissionPromptBuilder.swift` | brief → mission prompt 构建 |
| `ClaudeService+TeamDispatch` | `Services/ClaudeService/ClaudeService+TeamDispatch.swift` | `launchTeamMission` / `stopTeamMission` |
| `AgentTeamClaimExecutionGate` | `Services/Team/AgentTeamClaimExecutionGate.swift` | execution dispatch 前的 claim 合法性验证 |
| `AgentTeamCommitBarView` | `Views/Team/AgentTeamWorkbenchPanelViews.swift` | 用户 Launch / Stop 操作入口 |

**当前 auto-claim 策略**：`AgentTeamLaunchCoordinator.launch()` 自动为第一张 `.briefed` 状态卡创建并接受 claim，confidence=1.0，provider 来自 brief 确认的 conductor provider reference。不依赖 session default provider fallback。

**multi-provider broadcast（Feature 4 完整形态）** 尚未实现：当前只支持单 conductor provider 认领主卡，多 provider 同时 claim 并由 conductor 选择最优 owner 的广播逻辑放在 Feature 8（Execution Parallelism）后处理。

## 19. 推荐落地顺序

建议顺序：

1. Feature 1
2. Feature 2
3. Feature 3
4. **Feature 14**（Brief 单输入口与 AI 结构化提取）— 在 Feature 3 之后立即落地，因为 Brief 创建是整个 team 启动的入口
5. **Feature 15**（Provider 角色多重分配与 Warm-up 模型选择）— 依赖 Feature 14 的数据模型重构，需同步落地或紧随其后
6. **Feature 16**（Brief Composer 全面 UI 重设计）— 依赖 Feature 14 + 15 服务层完成后再做 UI 层
7. Feature 4
8. Feature 5
9. Feature 6
10. Feature 10
11. **Feature 17**（Per-Agent Virtual Session）— **Feature 8 的前置基础设施**，必须在并行调度之前完成；单卡路径可以在 Feature 5/6 期间同步构建 registry 骨架，但虚拟 session 分配路径需在 Feature 8 开始前验证
12. Feature 8
13. Feature 7
14. Feature 9
15. Feature 11
16. Feature 12
17. Feature 13

原因：

1. 先把独立表面和核心对象建立起来。
2. Feature 14/15/16 是 Brief 创建入口的重设计，应在 Feature 3（Brief 模型）之后、Feature 4（Claim 协议）之前完成，否则后续 claim/dispatch 逻辑将基于旧的数据模型积累技术债。
3. Feature 14 的 Budget 字段移除和 roleAssignment 模型变更是破坏性改动，越早落地迁移成本越低。
4. 再做协作协议和 artifact。
5. merge gate 必须早于大规模并行，不然系统会只增复杂度。
6. **Feature 17 必须先于 Feature 8**：Feature 8 的核心承诺（两个以上 provider 并行推进独立 cards）在技术上依赖每张 card 有独立的 `sessionID`；若不先做 Feature 17，Feature 8 的并发执行在 scheduler 层会被静默串行化，验收标准无法达成。
7. execution parallelism 比 creative parallelism 更容易验证，适合先落地。
8. capability slicing 和 diagnostics 放在有真实 team 行为之后再做，成本更低。
9. conductor 独立调度阶段（Feature 13）依赖 Feature 5（task card board）与 Feature 12（audit/diagnostics）稳定后再做，此时 conductor prompt 解析失败可通过 audit log 快速定位。

## 20. 最终建议

这项需求的关键不在于“让 ACP provider 彼此聊天”，而在于“让 ACP provider 围绕任务板形成有边界的团队”。

最值得落地的一句话设计是：

把 team mode 做成 Team Workbench，加上 Brief-Claim-Commit 协议，而不是给当前聊天页加更多消息气泡。
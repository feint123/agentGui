# ACP Agent Team Feature 4 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 agentGui 落地 Feature 4 的 Claim 协议：在 Team Mode 中把 provider 的实际执行前置为一轮显式 claim，要求 provider 先声明 confidence、expected output、required capabilities，再由 conductor 选择 owner，并让 Team Workbench 能稳定展示“谁认领了什么”和当前 claim 决策结果。

**Architecture:** 延续 Feature 1-3 已建立的 `Session(kind: .agentTeam)`、`AgentTeamSessionState`、mission brief resolver 和 workbench presentation，不提前实现完整 artifact / memo / review 黑板。Feature 4 采用“纯 Swift claim contract + `AgentTeamSessionState` JSON 持久化 + accepted-claim-driven dispatch”的增量方案：新增 claim board / claim / assignment 的 typed contract，由 `AgentTeamClaimCoordinator` 负责 bootstrap、claim 提交和 owner 选择，再把 claim 结果投影到 Team Workbench，并在 execution enqueue / dispatch 前统一从 accepted claim owner 派发，同时通过 gate 阻止未 claim 或错 owner 的 provider 进入执行。

**Tech Stack:** Swift 6、SwiftUI for macOS、SwiftData、Observation、现有 `Session` / `AgentTeamSessionState` / `AgentTeamSessionFactory` / `AgentTeamMissionBriefResolver` / `AgentTeamWorkbenchPresentation` / `ConversationExecutionOrchestrator` / `ExecutionPayloadDraft` / ACP provider registry、Swift Testing、XCTest UI tests。

**Depends On:** [docs/plans/2026-03-30-acp-agent-team-design.md](../plans/2026-03-30-acp-agent-team-design.md), [docs/plans/2026-03-30-acp-agent-team-feature1-implementation-plan.md](../plans/2026-03-30-acp-agent-team-feature1-implementation-plan.md), [docs/plans/2026-03-30-acp-agent-team-feature2-implementation-plan.md](../plans/2026-03-30-acp-agent-team-feature2-implementation-plan.md), [docs/plans/2026-03-31-acp-agent-team-feature3-implementation-plan.md](../plans/2026-03-31-acp-agent-team-feature3-implementation-plan.md)

---

## 0. 执行约束

- 我正在使用 writing-plans skill 来编写这份 implementation plan。
- 这份计划只覆盖 Feature 4，不提前实现 Feature 5 的完整 task card 状态机、Feature 6 的 typed artifact registry、Feature 7 的 creative parallelism、Feature 8 的真实并行执行分流、Feature 9 的 memo feed 或 Feature 10 的 review / merge gate。
- Claim 协议必须建立在 Feature 3 的 canonical mission brief 之上，所有 claim 都只能针对同一份 resolved brief 及其派生的 team card 提交，不能重新引入多份“伪 brief”。
- 为了保持与 Feature 3 一致的增量策略，Feature 4 先使用“纯 Swift contract + `AgentTeamSessionState` JSON slot”持久化 claim board 与 assignment，不把 team blackboard 一次性扩成多层 SwiftData 关系网。
- 本 feature 允许引入最小 claim card contract 作为“可认领工作单元”，但不在这里兑现 Feature 5 全量 board state machine；card 只承载 claim 所需的最小字段：title、goal、owner、claim summary、phase。
- Team Workbench 必须从当前的 placeholder roster / board 升级为真实 claim projection，至少能显示：card 标题、候选 provider claims、最终 owner、未认领/已认领状态。
- Feature 4 不能只停留在 UI；必须在 team-scoped execution path 上建立统一 gate，确保没有 accepted claim 的 provider 不能进入实际执行。由于当前 `ExecutionPayloadDraft` 还不带 team metadata，因此需要同步规划 execution payload / request 的最小扩展。
- 不要求本 feature 直接驱动真实 remote provider 自主产出 claim 文本；首版 claim 提交允许由 team runtime / conductor service 根据 provider roster 和显式输入构建 typed claim record，但最终存储契约必须和设计文档中的 `providerReference + taskCardID + confidence + requiredCapabilities + expectedArtifacts + estimatedCost` 对齐。
- `AgentTeamMode` 当前只落地了 `.executionDelivery`，Feature 4 不顺手扩成 creative / research 多模式矩阵；claim policy 先只为 executionDelivery 建立规则，其他 mode 以后在同一 contract 上增量扩展。
- 遵循 @swiftui-expert-skill：Team Workbench 的 claim projection 必须保持“presentation helper 生成展示数据，View 只负责渲染”；不要把 claim 排序、owner 选择或 fallback 文案散落在多个 view body 内。
- 严格按 @test-driven-development 执行：每个任务先写失败测试，再写最小实现，再回归验证。
- 完成全部任务后，用 @requesting-code-review 做一次 focused review，重点检查：claim 是否真的是执行前置 gate、UI 是否明确展示 owner / claim 状态、以及实现是否没有偷跑到完整 task/artifact 系统。

## 1. 当前状态摘要

- 当前 [agentGui/Models/AgentTeamSessionState.swift](../../agentGui/Models/AgentTeamSessionState.swift) 已经持久化 `claimBoardJSON`，并通过 `claimBoardState` / `updateClaimBoard(_:)` 提供 Feature 4 所需的 claim board slot；claim control plane 不再停留在 Feature 3 的 shell 状态。
- 当前 [agentGui/Services/Team/AgentTeamSessionFactory.swift](../../agentGui/Services/Team/AgentTeamSessionFactory.swift) 已会在创建 team session 时基于 canonical brief bootstrap 最小 claim board，因此新建 Team 会话后已有可认领 card。
- 当前 [agentGui/Services/Team/AgentTeamClaimCoordinator.swift](../../agentGui/Services/Team/AgentTeamClaimCoordinator.swift) 已实现 claim 提交、同一卡唯一 accepted owner 选择和确定性 tie-break；同一卡的 owner 决策已具备稳定 contract。
- 当前 [agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift](../../agentGui/Views/../ViewModels/AgentTeamWorkbenchPresentation.swift) 与 [agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift](../../agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift) 已经把 claim board 投影到真实 workbench：用户可以看到 card、claim 数、accepted owner 和 claim 状态，而不再只是 Feature 2 的 placeholder board。
- 当前 [agentGui/Models/ExecutionPayloadDraft.swift](../../agentGui/Models/ExecutionPayloadDraft.swift)、[agentGui/Models/ExecutionJob.swift](../../agentGui/Models/ExecutionJob.swift)、[agentGui/Services/Team/AgentTeamClaimExecutionGate.swift](../../agentGui/Services/Team/AgentTeamClaimExecutionGate.swift) 和 [agentGui/Services/Execution/ConversationExecutionOrchestrator.swift](../../agentGui/Services/Execution/ConversationExecutionOrchestrator.swift) 已经支持 `teamContext` 与 enqueue / dispatch 双重 gate，因此“未 claim / 错 owner 不得执行”的校验链路已经存在。
- 当前真正未对齐设计文档的缺口只剩一条主路径： [agentGui/Services/ClaudeService/ClaudeService+Messaging.swift](../../agentGui/Services/ClaudeService/ClaudeService+Messaging.swift) 仍然先用 `session.defaultExecutionProviderReference` 解析 dispatch provider，再尝试反查 `teamContext`；这意味着 team execution 还是“session 默认 provider 决定派发，claim gate 负责拦截”，而不是“accepted claim owner 直接决定派发 provider”。
- 当前 [agentGui/Services/ConversationExecutionProviderRegistry.swift](../../agentGui/Services/ConversationExecutionProviderRegistry.swift) 与 [agentGui/Models/ExecutionProviderReference.swift](../../agentGui/Models/ExecutionProviderReference.swift) 已经提供稳定 provider identity，因此剩余改动不需要新造 provider key，只需要把 team provider 解析入口切到 accepted claim owner。
- 当前 Feature 4 的 claim contract、coordinator、workbench projection、execution gate 和 UI smoke tests 都已存在；本轮实现文档需要从“预实施计划”更新为“缺口收尾计划”，聚焦 accepted-owner-driven dispatch。

## 2. Feature 4 目标态

完成后系统应满足以下条件：

1. 每个 `agentTeam` session 在 brief 解析完成后都会拥有至少一组可认领的 team cards，作为 provider claim 的目标，而不是继续显示纯 placeholder board。
2. provider 或 conductor service 提交 claim 时，系统会记录：`providerReference`、`taskCardID`、`confidence`、`rationaleSummary`、`requiredCapabilities`、`expectedArtifacts`、`estimatedCost`、`claimStatus`。
3. conductor 可以对同一张 card 的多个候选 claim 做 owner 决策，且同一时刻每张 card 最多只有一个 accepted owner。
4. Team Workbench 默认主视图能显示：当前 cards、每张 card 的 claim 摘要、accepted owner、仍待认领或存在竞争 claim 的状态。
5. 如果 team card 还没有 accepted claim，则任何 team-scoped execution enqueue / dispatch 都会被统一 gate 拦下，而不是让 provider 直接执行。
6. 一旦某张 card 产生 accepted claim，后续 team-scoped execution 必须直接使用该 accepted owner 作为 `EnqueueExecutionCommand.providerReference`，而不是继续从 `session.defaultExecutionProviderReference` 取值。
7. 如果 payload 中携带的 provider reference 与 accepted claim owner 不匹配，execution gate 会拒绝该作业并留下可调试的错误信息。
8. Focused tests 能覆盖：claim contract round-trip、owner assignment 规则、team session bootstrap、workbench claim projection、以及 accepted-owner dispatch / execution gate 对未 claim / 错 owner / 正确 owner 三条路径的判断。

## 3. Scope Guardrails

- 不实现完整 `AgentTeamTaskCard` 依赖图、`briefed/claimed/working/reviewing/done/blocked` 全状态机；Feature 4 只引入能支撑 claim 的最小 team card contract，完整状态流转放到 Feature 5。
- 不实现 typed artifact payload、artifact inspector drill-down 或 artifact versioning；Feature 4 只在 claim 中记录 `expectedArtifacts` 的 typed intent，不真正落盘 artifact 对象。
- 不实现 memo feed、handoff、reviewer 交互或 merge gate；这些能力必须留到 Feature 9 / 10，以免 Feature 4 变成半套 blackboard。
- 不要求 remote ACP provider 真正用自然语言“自己写 claim”；首版 claim 可以由 Team runtime 根据 provider roster、brief 和当前 card 生成或接收结构化 submission，但 contract 必须可直接对接未来真正的 provider-produced claim。
- 不重构整个 execution system 为 team-first 编排平台；只在 team session 相关入口、payload metadata、provider 解析和 orchestrator 上加最小增量修改。
- 不把普通 `.local` / `.channel` / `.backgroundTask` session 也纳入 claim gate；claim 规则只对 `.agentTeam` 生效。

## 4. Relevant Existing Files

### 已有 Team Session / Brief 基座

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamSessionState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamMissionBrief.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamSessionFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamMissionBriefResolver.swift`

### 已有 Team Workbench 展示层

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamSessionView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamMissionHeaderView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift`

### 已有 Provider / Execution 基础设施

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionProviderReference.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionProviderRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionPayloadDraft.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionJob.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionPersistenceStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`

### 已有相关测试

- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionStateTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionFactoryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamMissionBriefResolverTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamWorkbenchPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchConversationPaneTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/AgentTeamWorkbenchShellUITests.swift`

## 5. Target File Plan

### New Files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamClaim.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamClaimCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamClaimExecutionGate.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamClaimTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamClaimCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamClaimExecutionGateTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/AgentTeamClaimWorkbenchUITests.swift`

### Modified Files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamSessionState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamSessionFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamMissionHeaderView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamSessionView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionPayloadDraft.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionJob.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionProviderRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionPersistenceStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionStateTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionFactoryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamWorkbenchPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchConversationPaneTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/README.md`

如果 `AgentTeamClaim.swift` 超过约 250 行，可以拆成 `AgentTeamClaimBoardState.swift` 与 `AgentTeamClaimExecutionContext.swift`；但 Feature 4 首版建议先集中在一个 contract file，避免把同一套 claim enum 和 payload metadata 分散到多个文件。

## 6. 数据设计建议

### 6.1 Claim Contract

首版 contract 建议采用以下最小形态：

```swift
struct AgentTeamClaim: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let providerReference: ExecutionProviderReference
    let taskCardID: UUID
    let confidence: Double
    let rationaleSummary: String
    let requiredCapabilities: [String]
    let expectedArtifacts: [String]
    let estimatedCostSummary: String
    let status: AgentTeamClaimStatus
    let submittedAt: Date
}

enum AgentTeamClaimStatus: String, Codable, Sendable {
    case pending
    case accepted
    case rejected
    case released
}

struct AgentTeamClaimCard: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var goal: String
    var phase: AgentTeamClaimCardPhase
    var owner: ExecutionProviderReference?
    var claimIDs: [UUID]
}
```

这里先把 `expectedArtifacts` 和 `estimatedCost` 收敛为轻量文本或字符串数组，目的是先锁住协议字段和 UI，可在 Feature 6/8 再把它们演进成真正的 typed artifact kind / cost estimate value object。

### 6.2 Persistence Strategy

和 Feature 3 一样，`AgentTeamSessionState` 增量添加：

- `claimBoardJSON`
- `claimHistoryJSON` 或直接把 claims 内嵌到 board state
- 计算属性 `claimBoardState`
- 统一写入口 `updateClaimBoard(_:)`

这样可以避免现在就把 `TaskCard` / `Claim` / `Assignment` 变成多个 SwiftData `@Model`，同时保持 team state 的单一聚合点。

### 6.3 Execution Metadata

为了把 claim gate 接到现有执行系统，需要给 `ExecutionPayloadDraft` 增加最小 team context，例如：

```swift
struct AgentTeamExecutionContext: Codable, Equatable, Sendable {
    let taskCardID: UUID
    let claimID: UUID
}
```

然后让 `.userPrompt(...)` payload 额外挂上可选 `teamContext`。普通 chat session 仍传 `nil`；只有 team-scoped 作业才必须带 `teamContext`。

## 7. 验证命令

### Focused Feature 4 tests

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-agent-team-feature4 \
  -only-testing:agentGuiTests/AgentTeamClaimTests \
  -only-testing:agentGuiTests/AgentTeamClaimCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamClaimExecutionGateTests \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests \
  -only-testing:agentGuiTests/AgentTeamSessionFactoryTests \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  -only-testing:agentGuiTests/WorkbenchConversationPaneTests \
  -only-testing:agentGuiUITests/AgentTeamClaimWorkbenchUITests \
  CODE_SIGNING_ALLOWED=NO
```

Expected:

- claim contract round-trip、claim coordinator owner assignment、team state persistence 和 workbench claim projection 全部通过。
- 未 claim / 错 owner / 正确 owner 三条 execution gate 路径都被锁住。
- UI smoke 至少能验证一张 card 已显示 accepted owner，且 team workbench 不再只是 placeholder。

### Compile fallback

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-agent-team-feature4-build \
  CODE_SIGNING_ALLOWED=NO
```

Expected: Team claim contract、execution payload metadata 和 workbench projection 编译成功；如果 UI automation 夹带宿主波动，至少先保留编译与 unit/integration gates 作为主验证面。

## 8. Implementation Order

当前仓库已经完成 claim contract、session bootstrap、owner assignment、workbench projection、execution gate 和 UI smoke。本轮收尾顺序改为：先锁住 accepted-owner dispatch 的失败测试，再修改 team provider 解析入口，最后回归现有 Feature 4 focused suite。

---

### Task 0: 收口 accepted owner 驱动的实际派发 provider

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamClaimExecutionGateTests.swift`

**Step 1: Write the failing tests**

先锁住设计文档中“owner 被选中后，系统能自动把对应 card 派发给正确的 provider”这一条当前仍未完全兑现的能力。测试至少覆盖：

- team session 的 `session.defaultExecutionProviderReference` 如果仍指向 conductor，但 accepted claim owner 是另一位 provider，team execution 应该选择 accepted owner，而不是继续沿用 session 默认 provider。
- 当 accepted claim owner 与默认 provider 不一致时，系统仍能生成匹配 accepted owner 的 `providerReference + teamContext` 组合，不会在 enqueue 前就落入 `providerIsNotCurrentOwner`。
- 普通非 team session 不受这条新解析规则影响，仍继续沿用原有 provider 解析逻辑。

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
    -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature4-task0 \
    -only-testing:agentGuiTests/AgentTeamClaimExecutionGateTests \
    CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为当前消息层仍先取 `session.defaultExecutionProviderReference`，accepted owner 只参与 gate，不参与 provider 选择。

**Step 3: Write the minimal implementation**

建议把 `ClaudeService+Messaging` 的 team provider 解析收敛成一条统一 helper：

```swift
private func resolveExecutionTarget(
        session: Session,
        fallbackProviderReference: ExecutionProviderReference
) -> (providerReference: ExecutionProviderReference, teamContext: AgentTeamExecutionContext?)
```

规则要求：

- 非 `.agentTeam` session 继续返回原有 fallback provider。
- `.agentTeam` session 若存在唯一 accepted owner，则直接返回 accepted owner + 对应 `teamContext`。
- 若当前 team board 尚无 accepted owner，再回退到原有默认 provider 解析，让现有 gate 去拒绝未 claim 执行。

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS。

---

### Task 1: 建立 claim contract、claim board state 与 team state 持久化槽位

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamClaim.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamSessionState.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamClaimTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionStateTests.swift`

**Step 1: Write the failing tests**

先锁住 Feature 4 最关键的 typed contract，避免 UI、factory 和 execution gate 各自定义不同的 claim shape。测试需要覆盖：

- `AgentTeamClaim`、`AgentTeamClaimCard`、`AgentTeamClaimBoardState` JSON round-trip 后仍保留 provider reference、taskCardID、owner 与 claim status。
- `AgentTeamSessionState` 新增 `claimBoardJSON` / `claimBoardState` 后，可以安全写入与读取 claim board。
- `updateClaimBoard(_:)` 会刷新 `updatedAt`，与现有 `missionBrief` / `status` 保持同样的更新时间语义。
- accepted claim card 只能有一个 owner；contract 层至少要提供可以被 coordinator 消费的唯一 owner 表示，而不是靠 UI 推断。

测试草图：

```swift
import Testing
@testable import agentGui

struct AgentTeamClaimTests {
    @Test
    func claimBoardRoundTripsThroughJSON() throws {
        let cardID = UUID()
        let claim = AgentTeamClaim(
            id: UUID(),
            providerReference: .builtIn,
            taskCardID: cardID,
            confidence: 0.92,
            rationaleSummary: "适合负责 SwiftUI workbench 改造",
            requiredCapabilities: ["swiftui", "team-workbench"],
            expectedArtifacts: ["implementationPlan"],
            estimatedCostSummary: "medium",
            status: .accepted,
            submittedAt: Date(timeIntervalSince1970: 1)
        )

        let board = AgentTeamClaimBoardState(
            cards: [
                .init(id: cardID, title: "认领主任务", goal: "选择 owner", phase: .claiming, owner: .builtIn, claimIDs: [claim.id])
            ],
            claims: [claim]
        )

        let data = try JSONEncoder().encode(board)
        let decoded = try JSONDecoder().decode(AgentTeamClaimBoardState.self, from: data)

        #expect(decoded == board)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature4-task1 \
  -only-testing:agentGuiTests/AgentTeamClaimTests \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 claim contract 和 `AgentTeamSessionState.claimBoardState` 尚不存在。

**Step 3: Write the minimal implementation**

建议先引入以下最小 contract：

```swift
struct AgentTeamClaimBoardState: Codable, Equatable, Sendable {
    var cards: [AgentTeamClaimCard]
    var claims: [AgentTeamClaim]
}

extension AgentTeamSessionState {
    var claimBoardState: AgentTeamClaimBoardState? { ... }

    func updateClaimBoard(_ board: AgentTeamClaimBoardState?) {
        ...
    }
}
```

要求：

- 所有 JSON 编码解码都集中在 `AgentTeamSessionState` 的统一入口，不要在多个 service 重复手写编码逻辑。
- contract 保持纯 Swift type，不依赖 SwiftData，以便 future provider runtime、UI presentation 和 tests 都能直接复用。
- accepted owner 不要作为“从 claims 里找第一个 accepted”这种隐式约定，而要明确写到 card 上。

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/AgentTeamClaim.swift agentGui/Models/AgentTeamSessionState.swift agentGuiTests/AgentTeamClaimTests.swift agentGuiTests/AgentTeamSessionStateTests.swift
git commit -m "feat: add agent team claim contract"
```

### Task 2: 用 canonical brief bootstrap claimable cards，并实现 claim 提交与 owner assignment

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamClaimCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamSessionFactory.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamClaimCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionFactoryTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamMissionBriefResolverTests.swift`

**Step 1: Write the failing tests**

锁住 brief -> claimable cards -> accepted owner 这条控制面主路径。测试至少覆盖：

- 新建 team session 时，会基于 resolved brief 生成最小 claim board，而不是空 board。
- `AgentTeamClaimCoordinator` 可以向同一张 card 提交多个 claim，并按确定性规则选出 owner。
- owner 选择规则建议明确：优先 accepted claim；accepted 由 conductor service 根据 `confidence` 最高优先，分数相同则优先 `session.defaultExecutionProviderReference`，再按 `providerReference.persistedValue` 做稳定 tie-break。
- 当一张 card 已有 accepted owner 后，新的 competing claim 默认保留为 pending 或 rejected，但不能覆盖已 accepted owner，除非显式 release / reassign。

测试草图：

```swift
import Testing
@testable import agentGui

@MainActor
struct AgentTeamClaimCoordinatorTests {
    @Test
    func coordinatorAcceptsHighestConfidenceClaimForCard() {
        let cardID = UUID()
        let coordinator = AgentTeamClaimCoordinator()
        let brief = AgentTeamMissionBrief(...)
        var board = coordinator.bootstrapBoard(from: brief, preferredProvider: .builtIn)

        board = coordinator.submitClaim(
            .init(... providerReference: .builtIn, taskCardID: cardID, confidence: 0.91, ...),
            into: board
        )
        board = coordinator.submitClaim(
            .init(... providerReference: .externalACP(profileID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!), taskCardID: cardID, confidence: 0.72, ...),
            into: board
        )

        let resolved = coordinator.acceptBestClaim(for: cardID, in: board, preferredProvider: .builtIn)
        let card = try #require(resolved.card(id: cardID))

        #expect(card.owner == .builtIn)
        #expect(resolved.acceptedClaim(for: cardID)?.providerReference == .builtIn)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature4-task2 \
  -only-testing:agentGuiTests/AgentTeamClaimCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamSessionFactoryTests \
  -only-testing:agentGuiTests/AgentTeamMissionBriefResolverTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 claim bootstrap、claim submission 和 owner assignment 逻辑尚不存在。

**Step 3: Write the minimal implementation**

建议 `AgentTeamClaimCoordinator` 先承担三类职责：

1. `bootstrapBoard(from:preferredProvider:)`
   从 canonical brief 生成 1 到 2 张最小 claimable cards。首版至少包含一张“mission primary card”，标题与 goal 取自 brief objective / acceptance summary。
2. `submitClaim(_:into:)`
   追加或覆盖同一 provider 对同一卡的 pending claim，不允许一个 provider 对同一卡保留多份活跃 claim。
3. `acceptBestClaim(for:in:preferredProvider:)`
   执行确定性 owner 决策，并同步更新 card.owner、claim.status。

`AgentTeamSessionFactory` 增量方向：

- 创建 team session 时，在写入 `missionBrief` 之后立即 bootstrap 一份 claim board。
- 如 source session 或 team session 已存在 `defaultExecutionProviderReference`，把它作为 deterministic tie-break 的 preferred provider。

要求：

- bootstrap board 的输入只能来自 `AgentTeamMissionBriefResolver` / brief 本体，不要重新从 `Session.title` 或 UI placeholder 拼装任务。
- claim coordinator 只负责 claim 和 owner 选择，不要在这个阶段把 memo / artifact / review 也塞进去。
- 接口要保持纯函数式或低副作用，方便被 unit test 覆盖。

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/Team/AgentTeamClaimCoordinator.swift agentGui/Services/Team/AgentTeamSessionFactory.swift agentGuiTests/AgentTeamClaimCoordinatorTests.swift agentGuiTests/AgentTeamSessionFactoryTests.swift agentGuiTests/AgentTeamMissionBriefResolverTests.swift
git commit -m "feat: bootstrap agent team claim board"
```

### Task 3: 把 claim board 和 owner assignment 投影到 Team Workbench

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamMissionHeaderView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamSessionView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamWorkbenchPresentationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchConversationPaneTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/AgentTeamClaimWorkbenchUITests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

**Step 1: Write the failing tests**

先把 UI 契约锁住，避免 Feature 4 最后退化成“后台有 claim 数据，前台仍是占位板”。测试需要覆盖：

- `AgentTeamWorkbenchPresentation.make(...)` 能把 `claimBoardState` 投影为真实 board columns / cards，而不是继续输出硬编码 placeholder。
- 每张 card 至少能展示：title、goal summary、claim count、accepted owner title、当前 claim phase。
- `AgentTeamSessionView` 增加稳定 accessibility identifiers，例如 `agentTeam.claimBoard`、`agentTeam.claim.owner`、`agentTeam.claim.status`。
- UI smoke fixture 可以种出至少一张已被 accepted claim 的 card，并断言 Workbench 上看得到 owner 名称。

测试草图：

```swift
import Testing
@testable import agentGui

@MainActor
struct AgentTeamWorkbenchPresentationTests {
    @Test
    func presentationProjectsAcceptedOwnerFromClaimBoard() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session)
        state.missionBrief = AgentTeamMissionBrief(...)
        state.claimBoardState = AgentTeamClaimBoardState.fixtureAcceptedBuiltInClaim()

        let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: state)

        #expect(presentation.boardColumns.first?.cards.first?.owner == "Built-In Agent")
        #expect(presentation.boardColumns.first?.cards.first?.claimStatusText == "已认领")
        #expect(presentation.header.objectiveSummary.isEmpty == false)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature4-task3 \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  -only-testing:agentGuiTests/WorkbenchConversationPaneTests \
  -only-testing:agentGuiUITests/AgentTeamClaimWorkbenchUITests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为现有 workbench 仍然只渲染 placeholder roster / board。

**Step 3: Write the minimal implementation**

`AgentTeamWorkbenchPresentation` 建议新增：

```swift
struct ClaimSummary: Equatable {
    let claimCountText: String
    let ownerDisplayName: String
    let claimStatusText: String
}

struct BoardCard: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String
    let owner: String
    let claimStatusText: String
    let claimCountText: String
}
```

UI 层要求：

- mission header 可以增加一条 team summary，如“已认领 X / 待认领 Y”，但不要把 assignment 规则写进 header view。
- board 卡片上要直观展示 accepted owner 和 claim 状态，pending card 不能看起来像已经开始执行。
- roster 可以暂时继续保留 conductor / worker / reviewer 三个角色，但 readiness / focus 要根据 accepted claim 结果生成，不再是纯静态文案。
- UI test fixture 直接在 in-memory store 里种入带 claim board 的 team session，避免 UI 自动化依赖真实 provider 执行。

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift agentGui/Views/Team/AgentTeamMissionHeaderView.swift agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift agentGui/Views/Team/AgentTeamSessionView.swift agentGui/Utilities/TestLaunchOptions.swift agentGui/agentGuiApp.swift agentGuiTests/AgentTeamWorkbenchPresentationTests.swift agentGuiTests/WorkbenchConversationPaneTests.swift agentGuiUITests/AgentTeamClaimWorkbenchUITests.swift
git commit -m "feat: project agent team claims into workbench"
```

### Task 4: 把 claim gate 接入 execution payload、enqueue 和 dispatch

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamClaimExecutionGate.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionPayloadDraft.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionJob.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionProviderRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionPersistenceStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamClaimExecutionGateTests.swift`

**Step 1: Write the failing tests**

最后锁住 Feature 4 最重要的产品验收：没有 claim 不得执行。测试至少覆盖：

- 普通 chat session 的 enqueue / dispatch 不受影响，team gate 只对 `.agentTeam` 生效。
- `agentTeam` session 在 payload 缺少 `teamContext` 时会被 `AgentTeamClaimExecutionGate` 拒绝。
- `agentTeam` session 在 payload 携带 `taskCardID + claimID` 但 provider 不是 accepted owner 时仍被拒绝。
- 只有 accepted owner + matching claimID 的作业能通过 gate。
- gate 错误信息要可调试，例如明确指出“task card 未认领”或“provider 不是当前 owner”，而不是统一抛一个模糊失败。

测试草图：

```swift
import Testing
@testable import agentGui

@MainActor
struct AgentTeamClaimExecutionGateTests {
    @Test
    func teamExecutionRequiresAcceptedClaimOwner() throws {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session)
        state.claimBoardState = AgentTeamClaimBoardState.fixtureAcceptedBuiltInClaim()

        let gate = AgentTeamClaimExecutionGate()

        #expect(throws: AgentTeamClaimExecutionGate.Error.self) {
            try gate.validate(
                session: session,
                state: state,
                providerReference: .externalACP(profileID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!),
                teamContext: .init(taskCardID: ..., claimID: ...)
            )
        }
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature4-task4 \
  -only-testing:agentGuiTests/AgentTeamClaimExecutionGateTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 execution payload 还没有 team context，orchestrator 也没有 team claim gate。

**Step 3: Write the minimal implementation**

建议改动顺序：

1. 扩展 `ExecutionPayloadDraft.userPrompt`，增加可选 `teamContext: AgentTeamExecutionContext?`。
2. 让 `ClaudeService+Messaging` 在 team session 场景下只通过新的 team-aware enqueue helper 生成命令；普通 chat path 继续传 `nil`。
3. 在 `ConversationExecutionOrchestrator.enqueue(_:)` 先做一次轻量预检，尽早拒绝明显无 claim 的 team job。
4. 在 `dispatch(_:)` 或 `prepareDispatchContext(...)` 再做一次基于最新 `AgentTeamSessionState.claimBoardState` 的 revalidation，避免 queued 期间 owner 被改写后仍继续执行旧 job。

`AgentTeamClaimExecutionGate` 建议只做纯校验，不直接写 UI：

```swift
struct AgentTeamClaimExecutionGate {
    func validate(
        session: Session,
        state: AgentTeamSessionState?,
        providerReference: ExecutionProviderReference,
        teamContext: AgentTeamExecutionContext?
    ) throws
}
```

要求：

- gate 只依赖 `session.kind`、`claimBoardState` 和 payload metadata，不直接访问 network / runtime。
- orchestrator 里的 gate 失败要以可测试方式收敛为 job failure，而不是 silent drop。
- 不要把 claim 逻辑散落到各 provider 子类里；provider 层最多只消费扩展后的 `ConversationExecutionRequest.teamContext`，统一校验仍放在 team service / orchestrator。

**Step 4: Re-run the focused tests**

Run the same command from Step 2, then再运行完整 focused Feature 4 suite。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/ExecutionPayloadDraft.swift agentGui/Models/ExecutionJob.swift agentGui/Services/ConversationExecutionProviderRegistry.swift agentGui/Services/Execution/ExecutionPersistenceStore.swift agentGui/Services/Execution/ConversationExecutionOrchestrator.swift agentGui/Services/ClaudeService/ClaudeService+Messaging.swift agentGui/Services/Team/AgentTeamClaimExecutionGate.swift agentGuiTests/AgentTeamClaimExecutionGateTests.swift
git commit -m "feat: enforce agent team claim gate before execution"
```

## 9. Documentation Follow-up

Feature 4 完成后，顺手更新以下文档，避免仓库中的 quality / architecture 说明继续停留在 Feature 3：

- 在 `/Volumes/T7/文稿/Projects/agentGui/README.md` 的 Agent Team focused tests 一节加入 Feature 4 focused suite。
- 如 UI fixture 有新增 test launch option，在 `/Volumes/T7/文稿/Projects/agentGui/docs/quality/test-matrix-2026-03-11.md` 补一条 claim board UI smoke 的说明。
- 如果 execution payload 增加了 `teamContext`，在后续 execution/runtime 技术文档里补充“仅 team session 使用该字段”的约束，避免普通 chat 误用。

## 10. 风险清单

1. 最大风险是为了 Feature 4 过早引入完整 task/artifact/memo schema，导致 scope 失控。这个计划通过 `AgentTeamSessionState` JSON slot 把范围压在 claim control plane。
2. 第二个风险是 claim gate 只做 UI 显示、不接 execution path。这个计划把 gate 明确接到 `ExecutionPayloadDraft`、orchestrator enqueue 和 dispatch 两处，避免“看起来有 claim，实际上仍能偷跑执行”。
3. 第三个风险是 owner 选择规则不稳定，导致测试 flaky。这个计划要求 `confidence -> preferred provider -> persistedValue` 的确定性 tie-break。
4. 第四个风险是 Workbench 仍保留大段 placeholder，用户看不出 Feature 4 的价值。这个计划要求 Team Workbench 的 board 必须投影真实 owner / claim state，并通过 UI smoke 锁住。

## 11. 完成定义

Feature 4 可以视为完成，当且仅当：

1. 新建 team session 后，workbench 能看到至少一张真实 claim card，而不是纯 placeholder。
2. 同一卡上的多个 candidate claims 能被 coordinator 收敛成唯一 accepted owner。
3. UI 能明确显示谁认领了什么，以及 card 当前是否仍待认领。
4. 没有 accepted claim 的 team execution 会被统一 gate 拦下。
5. Focused Feature 4 tests 和 team claim UI smoke 全部通过。

Plan complete and saved to `docs/plans/2026-03-31-acp-agent-team-feature4-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

**Which approach?**
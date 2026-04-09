# ACP Agent Team Feature 5 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 agentGui 落地 Feature 5 的 Task Card Board：把 Team Workbench 的协作单位从当前的 claim-only board 演进为真正的 task card board，使 team session 能持久化多张任务卡、表达 `briefed`/`claimed`/`working`/`reviewing`/`done`/`blocked` 状态、声明 card 依赖关系，并让用户在工作台上直接看见当前 cards 和并行工作面。

**Architecture:** 延续 Feature 1 到 4 已建立的 `Session(kind: .agentTeam)`、`AgentTeamSessionState`、mission brief、claim 协议和 accepted-owner execution gate，不重新发明第二套黑板。Feature 5 采用“在现有 claim board 之上升级为 task board”的增量路线：新增 typed `AgentTeamTaskCard` / `AgentTeamTaskBoardState` / transition coordinator，把原来 claim card 的最小字段迁移成真正的 task card 状态机，并继续复用 `AgentTeamClaim` 作为 owner 决策来源；Team Workbench 再从 claim projection 升级为按 task status 分栏的 board，同时在 inspector 中展示 dependency 和 blocker 摘要。Feature 6 的 typed artifacts、Feature 8 的真实多卡并发执行、Feature 10 的 review gate 仍保持后续增量接入，不在本 feature 内抢跑。

**Tech Stack:** Swift 6、SwiftUI for macOS、SwiftData、现有 `AgentTeamSessionState` JSON persistence、`AgentTeamClaim` / `AgentTeamClaimExecutionGate`、`AgentTeamWorkbenchPresentation`、Swift Testing、XCTest UI tests。

**Depends On:** [docs/plans/2026-03-30-acp-agent-team-design.md](../plans/2026-03-30-acp-agent-team-design.md), [docs/plans/2026-03-30-acp-agent-team-feature1-implementation-plan.md](../plans/2026-03-30-acp-agent-team-feature1-implementation-plan.md), [docs/plans/2026-03-30-acp-agent-team-feature2-implementation-plan.md](../plans/2026-03-30-acp-agent-team-feature2-implementation-plan.md), [docs/plans/2026-03-31-acp-agent-team-feature3-implementation-plan.md](../plans/2026-03-31-acp-agent-team-feature3-implementation-plan.md), [docs/plans/2026-03-31-acp-agent-team-feature4-implementation-plan.md](../plans/2026-03-31-acp-agent-team-feature4-implementation-plan.md)

---

## 0. 执行约束

- 我正在使用 writing-plans skill 来编写这份 implementation plan。
- 这份计划只覆盖 Feature 5，不提前实现 Feature 6 的 typed artifact board、Feature 7 的 creative divergence/synthesis、Feature 8 的真实多卡并发调度、Feature 9 的 memo feed、Feature 10 的 review report / merge gate。
- Feature 5 必须直接承接 Feature 4 已落地的 claim contract，不能绕开 `AgentTeamClaim` 另造一套 ownership 机制。accepted claim 仍然是 `claimed` 状态和 team execution context 的单一真相源。
- 不把 team board 一次性扩成复杂 SwiftData 关系图。优先沿用 `AgentTeamSessionState` 的 JSON persistence 方式，在现有 model 上增量增加 task board 持久化槽位与兼容读取逻辑。
- Task card 状态机只覆盖设计文档里明确要求的六态：`briefed`、`claimed`、`working`、`reviewing`、`done`、`blocked`。不要顺手引入额外状态如 `cancelled`、`archived`、`draft`，除非测试证明现有状态无法表达需求。
- 依赖关系只做显式 card-to-card 依赖，不实现通用 DAG 编辑器、跨 team run 依赖、跨 session 依赖或可视化连线编辑器。
- Workbench 的主视图必须从“按 claim 粗分待认领/已认领”升级为“按 task status 分栏”，但要尽量保留已有 accessibility identifier 和测试夹具，避免无意义打断 Feature 4 的 UI 自动化基线。
- 依赖阻塞规则必须是可测试的纯 Swift 逻辑，不能把“依赖未满足所以不能开始工作”的判断散落进 SwiftUI view body。
- 对现有历史数据要有兼容策略。已有 team session 只持久化了 `claimBoardJSON`；Feature 5 不能让这些会话打不开。要么在读取时做 claim-board-to-task-board fallback migration，要么在启动时做单次转换，但方案必须有稳定单元测试覆盖。
- 如果 `AgentTeamSessionState` 新增持久化字段导致本地 store 需要 schema 调整，文档中必须明确检查 [agentGui/agentGuiApp.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift) 内 `PersistenceSchema.currentVersion` 与默认 store 兼容性，不要默默假设 SwiftData 会自动兜底。
- 遵循 @swiftui-expert-skill：task board 的排序、状态映射、dependency 摘要和 blocker 文案都放进 presentation/helper/coordinator，不把业务判断散落在 view 层。
- 严格按 @test-driven-development 执行：每个任务先写失败测试，再写最小实现，再回归验证。
- 全部任务完成后，用 @requesting-code-review 做一次 focused review，重点检查：board 是否已经真正以 task 为中心、状态流转是否可解释、历史 claim board 是否兼容、以及 UI 是否清楚展示并行 cards 与依赖阻塞。

## 1. 当前状态摘要

- 当前 [agentGui/Models/AgentTeamSessionState.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamSessionState.swift) 只持久化 `briefJSON` 和 `claimBoardJSON`，没有真正的 task board 持久化槽位。`claimBoardState` 仍然是 Feature 4 的主数据源。
- 当前 [agentGui/Models/AgentTeamClaim.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamClaim.swift) 里的 `AgentTeamClaimCard` 只有 `title`、`goal`、`phase`、`owner`、`claimIDs` 五个最小字段，`phase` 也只有 `.claiming` 和 `.claimed` 两态，无法表达 working、reviewing、done、blocked 和 dependencies。
- 当前 [agentGui/Services/Team/AgentTeamClaimCoordinator.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamClaimCoordinator.swift) 负责 bootstrap 一张认领卡、提交 claim 和选择 accepted owner，但并没有管理 task lifecycle，也没有依赖满足判定。
- 当前 [agentGui/Services/Team/AgentTeamSessionFactory.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamSessionFactory.swift) 创建 team session 时只会从 brief bootstrap 单张 claim card。用户还看不到多张 task cards，更看不到并行 workstreams。
- 当前 [agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift) 只会把 board 投影成“待认领”和“已认领”两列，核心文案仍然围绕 claim 而不是 task status。
- 当前 [agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift) 的 board 卡片只显示 title、summary、owner、claim status、claim count。没有 dependency、blocker、status badge，也没有多列任务板结构。
- 当前 inspector 仍是占位说明，尚未承接 task dependency / blocker / review readiness 摘要，这意味着 Feature 5 至少要把 dependency 关系投影进去，给后续 Feature 6/10 留接口。
- 当前 [agentGui/Services/Team/AgentTeamClaimExecutionGate.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamClaimExecutionGate.swift) 只验证 claim owner，不关注 task status 或 dependencies。Feature 5 不需要把它扩成完整调度器，但至少要定义 task status 与 execution 之间的边界，避免 future drift。
- 当前测试已经覆盖 claim board 的 JSON round-trip、owner assignment、session bootstrap 和 workbench claim projection，相关文件包括 [agentGuiTests/AgentTeamClaimTests.swift](/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamClaimTests.swift)、[agentGuiTests/AgentTeamClaimCoordinatorTests.swift](/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamClaimCoordinatorTests.swift)、[agentGuiTests/AgentTeamSessionFactoryTests.swift](/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionFactoryTests.swift)、[agentGuiTests/AgentTeamWorkbenchPresentationTests.swift](/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamWorkbenchPresentationTests.swift)。Feature 5 需要在这套基线上做演进，而不是从零起一套新测试矩阵。

## 2. Feature 5 目标态

完成后系统应满足以下条件：

1. 每个 `agentTeam` session 都有一个 typed task board 数据源，board 可以包含多张 task cards，而不是只能持有单张 claim card。
2. 每张 task card 都能明确表示 `briefed`、`claimed`、`working`、`reviewing`、`done`、`blocked` 之一，并保留 owner、accepted claim、dependency 和 blocker 摘要。
3. 任务卡可以显式声明依赖项，系统能够计算“依赖未满足”“依赖已完成”“依赖导致 blocked”等可投影状态。
4. accepted claim 继续决定 card 的 owner；Feature 5 不会破坏 Feature 4 的 claim gate 和 execution context contract。
5. Team Workbench 默认主视图按 task status 分栏显示 cards，用户能够直观看到当前有哪些 cards、每张卡处于哪个阶段，以及哪些 workstreams 可以并行推进。
6. Inspector 至少能显示：当前 card 的 owner、dependency 摘要、blocked 原因、上游/下游卡片摘要，为后续 artifact/review 视图预留结构。
7. 旧的 `claimBoardJSON` 历史数据能被兼容读取并映射成最小 task board，而不会导致老 team session 白屏或崩溃。
8. focused tests 能覆盖：task card contract、状态流转规则、dependency guard、session bootstrap/migration、workbench projection 和最小 UI smoke。

## 3. Scope Guardrails

- 不实现 typed artifact 对象、artifact 引用列表或 artifact inspector 正文；Feature 5 只为 Feature 6 留 `artifactIDs` 或占位字段的接口，不做实体化消费。
- 不实现 provider 之间的 memo、handoff feed 或 review report 对象；Feature 5 的 `reviewing` 状态只表示 card 生命周期进入 review stage，不等于 Feature 10 已完成。
- 不在这个 feature 里做真实多 provider 自动并发调度。Feature 5 只需要让多卡并行“可表达、可显示、可持久化”；真正的并发 admission 与 dispatch orchestration 留给 Feature 8。
- 不要求任务板支持拖拽排序、lane 切换、折叠分组或复杂看板交互。首版只需提供稳定的状态分栏和 inspector 选中态。
- 不把 `AgentTeamClaimExecutionGate` 扩成“依赖满足后自动启动”引擎。Feature 5 只需要明确好 coordinator/presentation 如何判断 blocked/readiness，真正的自动派发仍留给后续 feature。
- 不在这个 feature 里替换普通 chat transcript；team result 发布回聊天仍按 Feature 1 到 4 的既有路径处理。

## 4. 设计建议

### 4.1 Task Board Contract

建议新增一个独立 contract file，而不是继续把 task 状态塞回 claim-only 类型名中：

```swift
struct AgentTeamTaskBoardState: Codable, Equatable, Sendable {
    var cards: [AgentTeamTaskCard]
    var claims: [AgentTeamClaim]
}

struct AgentTeamTaskCard: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var goal: String
    var status: AgentTeamTaskStatus
    var owner: ExecutionProviderReference?
    var acceptedClaimID: UUID?
    var dependencyIDs: [UUID]
    var blockerSummary: String?
    var lastUpdatedAt: Date
}

enum AgentTeamTaskStatus: String, Codable, Equatable, Sendable {
    case briefed
    case claimed
    case working
    case reviewing
    case done
    case blocked
}
```

这里刻意保留 `claims` 在同一 board state 内，原因是 Feature 4 已经把 claim 作为 owner 决策的事实来源。Feature 5 的目标不是拆散这层关系，而是把 claim 之上的 task lifecycle 补齐。

### 4.2 Legacy 兼容策略

建议采用“新增 `taskBoardJSON`，读取时对 `claimBoardJSON` 做 fallback migration”的方案：

- 新写入统一走 `taskBoardJSON`。
- 读取 `taskBoardState` 时，先解码 `taskBoardJSON`。
- 如果 `taskBoardJSON` 为空，再尝试把旧 `AgentTeamClaimBoardState` 映射成最小 `AgentTeamTaskBoardState`：
  - `phase.claiming -> status.briefed`
  - `phase.claimed -> status.claimed`
  - `claimIDs` 中 accepted claim 映射到 `acceptedClaimID`
  - dependency 为空，blocker 为空
- 可选：在首次成功 fallback 后回写 `taskBoardJSON` 并保留 `claimBoardJSON` 兼容读；不要立刻删除旧字段，避免历史版本切换时损坏数据。

### 4.3 状态流转规则

建议由纯 Swift coordinator 统一维护以下最小规则：

1. `briefed -> claimed`：必须存在 accepted claim 且 owner 已确定。
2. `claimed -> working`：只有当所有依赖 card 均为 `done` 时才允许进入；否则返回 dependency-blocked 错误。
3. `working -> reviewing`：允许由 owner 或 conductor 推进。
4. `reviewing -> done`：允许完成收敛。
5. `working/reviewing -> blocked`：必须附带 `blockerSummary`。
6. `blocked -> claimed` 或 `blocked -> working`：要求 blocker 清空，并且依赖满足。

不要在 Feature 5 引入隐式自动流转；所有状态变化先通过可测试的 coordinator API 完成。

### 4.4 Board Projection

Workbench 展示层建议把 board 固定投影成六列：

1. Briefed
2. Claimed
3. Working
4. Reviewing
5. Done
6. Blocked

每张卡首版至少展示：

- title
- goal summary
- owner display name
- status text
- dependency count / unresolved dependency count
- blocker summary（如果存在）

Inspector 首版至少展示：

- 当前卡片标题与状态
- owner / accepted claim 摘要
- upstream dependencies
- downstream dependents
- blocker summary

## 5. Relevant Existing Files

### 已有 Team 状态与 claim 基座

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamSessionState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamClaim.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamMissionBrief.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamClaimCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamSessionFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamClaimExecutionGate.swift`

### 已有 Team Workbench 展示层

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamSessionView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamMissionHeaderView.swift`

### 已有测试与夹具

- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamClaimTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamClaimCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionStateTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionFactoryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamWorkbenchPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchConversationPaneTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

## 6. Target File Plan

### New Files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamTaskBoard.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamTaskBoardCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamTaskBoardTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamTaskBoardCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/AgentTeamTaskBoardUITests.swift`

### Modified Files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamSessionState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamClaim.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamClaimCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamSessionFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamSessionView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamClaimTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamClaimCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionStateTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionFactoryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamWorkbenchPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchConversationPaneTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

如果 `AgentTeamTaskBoardCoordinator.swift` 变得过大，可以拆成 `AgentTeamTaskBoardBootstrapper.swift` 与 `AgentTeamTaskTransitionCoordinator.swift`；但第一版建议先集中在一个 coordinator file，避免把状态规则分散到太多位置。

## 7. 验证命令

### Focused Feature 5 tests

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-agent-team-feature5 \
  -only-testing:agentGuiTests/AgentTeamTaskBoardTests \
  -only-testing:agentGuiTests/AgentTeamTaskBoardCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamClaimTests \
  -only-testing:agentGuiTests/AgentTeamClaimCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests \
  -only-testing:agentGuiTests/AgentTeamSessionFactoryTests \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  -only-testing:agentGuiTests/WorkbenchConversationPaneTests \
  -only-testing:agentGuiUITests/AgentTeamTaskBoardUITests \
  CODE_SIGNING_ALLOWED=NO
```

Expected:

- task board contract、legacy fallback migration、状态流转规则、dependency guard 和 workbench 投影全部通过。
- UI smoke 能看到多列 task board 和至少一张带 dependency 或 blocked 信息的 card。

### Compile fallback

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-agent-team-feature5-build \
  CODE_SIGNING_ALLOWED=NO
```

Expected: task board model、presentation、UI 和 session persistence 编译通过；如果 UI automation 受宿主环境影响，至少保留 unit/integration suite 作为主验证面。

## 8. Implementation Order

先锁住 task board contract 和历史迁移，再补状态机与依赖规则，然后把 session bootstrap 和 workbench 升级到 task board，最后补 UI fixture 和 focused 回归。

---

### Task 1: 定义 task board contract 并兼容旧 claim board 数据

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamTaskBoard.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamSessionState.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamClaim.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamTaskBoardTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionStateTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

**Step 1: Write the failing tests**

先锁住 Feature 5 的底层数据契约，避免后续 UI 和 coordinator 在不稳定的 board shape 上实现。测试至少覆盖：

- `AgentTeamTaskBoardState` / `AgentTeamTaskCard` / `AgentTeamTaskStatus` JSON round-trip。
- 旧 `AgentTeamClaimBoardState` 可以被映射成最小 task board，且 `claiming -> briefed`、`claimed -> claimed`。
- `AgentTeamSessionState.taskBoardState` 优先读取 `taskBoardJSON`，为空时 fallback 到 `claimBoardJSON`。
- fallback migration 不会丢失 accepted owner / accepted claim。
- 如果 `AgentTeamSessionState` 新增 `taskBoardJSON` 字段，`updatedAt` 在写入 task board 时会刷新。

测试草图：

```swift
@Test
func legacyClaimBoardMigratesIntoTaskBoard() {
    let cardID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let claimID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let legacyBoard = AgentTeamClaimBoardState(
        cards: [
            AgentTeamClaimCard(
                id: cardID,
                title: "修复主路径",
                goal: "建立 claim gate",
                phase: .claimed,
                owner: .builtIn,
                claimIDs: [claimID]
            )
        ],
        claims: [acceptedClaimFixture(id: claimID, taskCardID: cardID)]
    )

    let migrated = AgentTeamTaskBoardState.migrating(legacyBoard)

    #expect(migrated.cards.first?.status == .claimed)
    #expect(migrated.cards.first?.acceptedClaimID == claimID)
    #expect(migrated.cards.first?.owner == .builtIn)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature5-task1 \
  -only-testing:agentGuiTests/AgentTeamTaskBoardTests \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 task board contract 和 migration accessors 还不存在。

**Step 3: Write the minimal implementation**

建议最小实现：

```swift
struct AgentTeamTaskBoardState: Codable, Equatable, Sendable {
    var cards: [AgentTeamTaskCard]
    var claims: [AgentTeamClaim]

    static func migrating(_ legacy: AgentTeamClaimBoardState) -> Self {
        Self(
            cards: legacy.cards.map { legacyCard in
                AgentTeamTaskCard(
                    id: legacyCard.id,
                    title: legacyCard.title,
                    goal: legacyCard.goal,
                    status: legacyCard.phase == .claimed ? .claimed : .briefed,
                    owner: legacyCard.owner,
                    acceptedClaimID: legacy.acceptedClaim(for: legacyCard.id)?.id,
                    dependencyIDs: [],
                    blockerSummary: nil,
                    lastUpdatedAt: Date()
                )
            },
            claims: legacy.claims
        )
    }
}
```

`AgentTeamSessionState` 建议新增：

- `taskBoardJSON: String = ""`
- `var taskBoardState: AgentTeamTaskBoardState?`
- `func updateTaskBoard(_:)`
- 兼容读取逻辑：先读 `taskBoardJSON`，再 fallback `claimBoardJSON`

如果新增字段引发 store 兼容问题，在 [agentGui/agentGuiApp.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift) 里同步处理 `PersistenceSchema.currentVersion`，并在测试中验证 in-memory schema 正常创建。

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/AgentTeamTaskBoard.swift agentGui/Models/AgentTeamSessionState.swift agentGui/Models/AgentTeamClaim.swift agentGui/agentGuiApp.swift agentGuiTests/AgentTeamTaskBoardTests.swift agentGuiTests/AgentTeamSessionStateTests.swift
git commit -m "feat: add agent team task board contract"
```

### Task 2: 实现 task 状态机与依赖协调器

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamTaskBoardCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamClaimCoordinator.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamTaskBoardCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamClaimCoordinatorTests.swift`

**Step 1: Write the failing tests**

先把状态流转和 dependency guard 锁住，避免 feature 实现成一堆 UI 文案更新。测试至少覆盖：

- `acceptClaim` 后对应 card 从 `briefed` 进入 `claimed`，并记录 `acceptedClaimID`。
- 有未完成依赖时，card 不能从 `claimed` 进入 `working`。
- `working -> reviewing -> done` 正常流转。
- 进入 `blocked` 必须带 `blockerSummary`。
- 上游依赖变为 `done` 后，下游 card 才能进入 `working`。
- 一个 board 可以同时存在多张处于 `working` 的 cards，从而表达并行 workstreams。

测试草图：

```swift
@Test
func taskCannotStartWorkingUntilDependenciesAreDone() throws {
    let upstreamID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    let downstreamID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    let board = AgentTeamTaskBoardState(
        cards: [
            .fixture(id: upstreamID, status: .working),
            .fixture(id: downstreamID, status: .claimed, dependencyIDs: [upstreamID])
        ],
        claims: []
    )

    #expect(throws: AgentTeamTaskBoardCoordinator.Error.unresolvedDependencies([upstreamID])) {
        try AgentTeamTaskBoardCoordinator().transitionCard(
            downstreamID,
            to: .working,
            in: board
        )
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature5-task2 \
  -only-testing:agentGuiTests/AgentTeamTaskBoardCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamClaimCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 coordinator 及其 transition rules 尚未存在。

**Step 3: Write the minimal implementation**

建议 coordinator 提供这些入口：

```swift
struct AgentTeamTaskBoardCoordinator {
    enum Error: LocalizedError, Equatable {
        case cardNotFound(UUID)
        case acceptedClaimMissing(UUID)
        case unresolvedDependencies([UUID])
        case blockerSummaryRequired
    }

    func applyingAcceptedClaim(
        taskCardID: UUID,
        in board: AgentTeamTaskBoardState
    ) throws -> AgentTeamTaskBoardState

    func transitionCard(
        _ cardID: UUID,
        to status: AgentTeamTaskStatus,
        blockerSummary: String? = nil,
        in board: AgentTeamTaskBoardState
    ) throws -> AgentTeamTaskBoardState
}
```

实现要点：

- `AgentTeamClaimCoordinator.acceptBestClaim(...)` 在 accepted owner 决策完成后，委托 task board coordinator 把对应 card 状态推进到 `.claimed`。
- dependency 判定只看 `dependencyIDs` 对应 cards 是否全部为 `.done`。
- `blocked` 状态允许保留 owner，不需要在 Feature 5 清空 accepted claim。
- 不实现自动 cascade；状态推进只改目标 card，其他卡的 readiness 由读取时即时计算。

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/Team/AgentTeamTaskBoardCoordinator.swift agentGui/Services/Team/AgentTeamClaimCoordinator.swift agentGuiTests/AgentTeamTaskBoardCoordinatorTests.swift agentGuiTests/AgentTeamClaimCoordinatorTests.swift
git commit -m "feat: add agent team task transitions"
```

### Task 3: 用 task board 取代 session bootstrap 的单张 claim card

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamSessionFactory.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamClaimCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionFactoryTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamClaimTests.swift`

**Step 1: Write the failing tests**

锁住 team session 初始 board 的形态，避免 Feature 5 做完后仍然只有一张卡。测试至少覆盖：

- 从 canonical brief 创建 team session 时，会生成 `taskBoardState`，而不是只写 `claimBoardState`。
- bootstrap 至少生成一张主卡；当 brief 有多条 acceptance criteria 时，允许拆出多张初始 cards。
- 初始 cards 的默认状态是 `.briefed`，owner 为空，dependencyIDs 明确可预测。
- 历史 `claimBoardState` 仍可被读取，不会影响新 session 直接落 `taskBoardState`。

测试草图：

```swift
@Test
func createFromChatBootstrapsTaskBoardFromCanonicalBrief() throws {
    let result = try AgentTeamSessionFactory().create(from: source, draft: draft, modelContext: context)
    let board = try #require(result.state.taskBoardState)

    #expect(board.cards.isEmpty == false)
    #expect(board.cards.first?.status == .briefed)
    #expect(board.cards.first?.owner == nil)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature5-task3 \
  -only-testing:agentGuiTests/AgentTeamSessionFactoryTests \
  -only-testing:agentGuiTests/AgentTeamClaimTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 factory 还只写 claim board。

**Step 3: Write the minimal implementation**

建议把 bootstrap 逻辑切换成：

- `AgentTeamTaskBoardCoordinator.bootstrapBoard(from: brief, preferredProvider: ...)`
- session 创建时优先写 `state.taskBoardState`
- 为保持兼容，`state.claimBoardState` 可继续由 `taskBoardState.claimBoardProjection` 推导，或者在过渡期双写，但要明确只把 `taskBoardState` 视为主数据源

初始拆卡策略保持保守：

1. 第一张主卡使用 `brief.objective`
2. 对前 1 到 3 条非空 `acceptanceCriteria` 生成附属卡
3. 附属卡依赖主卡或按 acceptance 顺序串联，避免无依据地生成复杂 DAG

不要在 Feature 5 就引入 AI 自动拆卡；初版用确定性规则先让 board 结构成立。

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/Team/AgentTeamSessionFactory.swift agentGui/Services/Team/AgentTeamClaimCoordinator.swift agentGuiTests/AgentTeamSessionFactoryTests.swift agentGuiTests/AgentTeamClaimTests.swift
git commit -m "feat: bootstrap agent team task board"
```

### Task 4: 将 Team Workbench 升级为按 task status 分栏的 board

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamSessionView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamWorkbenchPresentationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchConversationPaneTests.swift`

**Step 1: Write the failing tests**

先锁住 UI projection 契约，避免实现停留在“数据结构升级了，但用户看到的还是 claim-only board”。测试至少覆盖：

- board 默认生成六个状态列。
- 不同状态的 cards 被投影到对应列，而不是只分“待认领/已认领”。
- 每张 card 至少显示 owner、status、dependency 摘要和 blocker 文案。
- inspector 能返回当前选中 card 的 upstream/downstream dependency 摘要。
- 已有 `agentTeam.claimBoard` accessibility identifier 可以保留，或在必要时新增 `agentTeam.taskBoard` 并同步测试，不要无计划地打断 UI smoke。

测试草图：

```swift
@Test
func presentationBuildsTaskBoardColumnsFromStatuses() {
    let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: state)

    #expect(presentation.boardColumns.map(\.id) == [
        "briefed", "claimed", "working", "reviewing", "done", "blocked"
    ])
    #expect(presentation.boardColumns.first(where: { $0.id == "blocked" })?.cards.first?.blockerText == "等待用户补充上下文")
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature5-task4 \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  -only-testing:agentGuiTests/WorkbenchConversationPaneTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为现有 presentation 还只有 claim 分栏。

**Step 3: Write the minimal implementation**

presentation 建议新增字段：

```swift
struct BoardCard: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String
    let owner: String
    let statusText: String
    let dependencyText: String
    let blockerText: String?
}

struct InspectorSummary: Equatable {
    let title: String
    let artifactSummary: String
    let reviewSummary: String
    let traceSummary: String
    let dependencySummary: String
    let blockerSummary: String
}
```

UI 实现要求：

- board 卡片的视觉层级仍保持现有 workbench card style，不重做整套设计系统。
- blocked 列必须足够显眼，避免和普通 claimed/working 卡视觉同质化。
- 不在 view body 里现场查找 dependencies；所有 dependency 文案都由 presentation 生成。

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift agentGui/Views/Team/AgentTeamSessionView.swift agentGuiTests/AgentTeamWorkbenchPresentationTests.swift agentGuiTests/WorkbenchConversationPaneTests.swift
git commit -m "feat: render agent team task board"
```

### Task 5: 补 UI fixture、回归 smoke，并收口兼容细节

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/AgentTeamTaskBoardUITests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionStateTests.swift`

**Step 1: Write the failing tests**

最后锁住用户能看见并行 cards 和 blocked/dependency 信息这件事。UI smoke 至少覆盖：

- 启动测试夹具后，team session detail 区可见 task board。
- 至少两列有 cards，证明并行 workstreams 可见。
- blocked card 能显示 blocker 文案。
- inspector 或卡片正文能显示 dependency 摘要。

测试草图：

```swift
func testAgentTeamTaskBoardShowsParallelCards() {
    let app = XCUIApplication()
    app.launchArguments += ["--ui-test-fixture", "agent-team-task-board"]
    app.launch()

    XCTAssertTrue(app.otherElements["agentTeam.claimBoard"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Working"].exists)
    XCTAssertTrue(app.staticTexts["Blocked"].exists)
    XCTAssertTrue(app.staticTexts["等待用户补充上下文"].exists)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature5-task5 \
  -only-testing:agentGuiUITests/AgentTeamTaskBoardUITests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 UI fixture 还没有 task-board 专用种子数据。

**Step 3: Write the minimal implementation**

夹具建议直接种出一个 in-memory team session，其中包含：

- 1 张 `working` 卡
- 1 张 `reviewing` 卡
- 1 张 `blocked` 卡，依赖 `done` 未满足或缺少用户输入
- 1 张 `done` 卡，供 dependency summary 引用

这样 UI smoke 能稳定覆盖“并行可见”和“阻塞可见”两条核心验收，而不依赖真实 provider 执行。

同时补一个非 UI 单测，确认 `taskBoardState` 与 legacy `claimBoardState` 同时存在时，读取优先级稳定，避免夹具和真实数据路径不一致。

**Step 4: Re-run the focused tests**

先跑 Step 2 的 UI smoke，再跑 [第 7 节](#7-验证命令) 的完整 focused suite。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGuiUITests/AgentTeamTaskBoardUITests.swift agentGui/Utilities/TestLaunchOptions.swift agentGui/agentGuiApp.swift agentGuiTests/AgentTeamSessionStateTests.swift
git commit -m "test: add agent team task board smoke coverage"
```

## 9. 交付检查清单

在宣布 Feature 5 完成前，逐项确认：

1. `taskBoardState` 已成为 team board 的主数据源，且旧 `claimBoardJSON` 仍可兼容读取。
2. task card 六态都有明确 typed enum，不再用 `claiming/claimed` 二态假扮任务板。
3. 至少存在纯 Swift 单测覆盖 dependency guard 和 blocked 规则。
4. Team Workbench 默认显示六列 task board，而不是 claim-only 两列。
5. 卡片或 inspector 中能看到 dependency / blocker 摘要。
6. Feature 4 的 accepted claim owner contract 未被破坏。
7. focused tests 与最小 UI smoke 均通过。

## 10. 后续衔接

Feature 5 完成后，后续 feature 应直接复用这套 task board：

- Feature 6 在 `AgentTeamTaskCard` 上挂接 typed artifact 引用与 inspector artifact summary。
- Feature 8 在 `working` / `blocked` / dependency readiness 基础上接入真实多卡并发执行 admission。
- Feature 10 在 `reviewing` 状态基础上接入 reviewer artifacts、review decisions 和 merge gate。

Plan complete and saved to `docs/plans/2026-03-31-acp-agent-team-feature5-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - 我按任务顺序在当前会话里逐步实现、回归、review。

**2. Parallel Session (separate)** - 你开一个新会话，用 executing-plans skill 按这份计划分批执行。

Which approach?
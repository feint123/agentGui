# Agent Team 重构设计文档

> 分析基准：oh-my-claudecode `src/team/` vs agentGui `Services/Team/` + 相关模型  
> 原则：不需要迁移兼容，冗余/不合适的设计直接删除替换。  
> 参考源码：`/Users/feint/Temp/agentGuiTest/oh-my-claudecode/src/team/`

---

## 背景：两套系统的本质差异

### oh-my-claudecode 的设计

oh-my-claudecode 的 team 模块是一个**文件系统驱动的多进程编排层**：

- Worker 是独立 tmux pane（真正并发进程），通过 `.omc/state/team/{name}/` 目录下 JSON 文件通信
- 有两代 Runtime（V1 done.json 轮询、V2 事件驱动 CLI 状态转换）
- 有明确的 contracts（状态机约束），phase controller（阶段推断），capabilities（能力标签），permissions（路径沙箱），allocation policy（纯函数路由算法），summary report（会话报告），sentinel gate（就绪门控）
- Worker 生命周期：`pending → in_progress → completed | failed`（`pending/blocked` 不能直接转 `completed`）

### agentGui 的设计

agentGui 的 team 是一个**内存驱动的单进程 Provider 编排层**：

- 所有 Provider 在同一进程内串行执行（Wave Loop 每轮顺序 `sendMessage`）
- 通过 SwiftData JSON 字段持久化 Board 状态（`AgentTeamSessionState`）
- 有 TaskBoard（主）和 ClaimBoard（legacy 遗留）**两套并行状态**，靠 `claimBoardProjection` 桥接
- Task 状态机：`briefed → claimed → working → reviewing → done | blocked`（更细粒度，但迁移路径混乱）

---

## 核心问题分析

### 问题 1：ClaimBoardState 遗留层（Critical）

agentGui 同时维护两套 Board 状态：

```
TaskBoardState (新，主数据)
  AgentTeamTaskCard（含 status、claims、dependencies、artifacts）

ClaimBoardState (legacy，投影)
  AgentTeamClaimCard（仅 phase/owner）
  AgentTeamClaimCardPhase（.claiming / .claimed，已被 AgentTeamTaskStatus 覆盖）
```

遗留层的实际引用点：

| 位置 | 引用 | 问题 |
|------|------|------|
| `AgentTeamSessionState.claimBoardJSON` | SwiftData 存储字段 | 冗余存储 |
| `ClaudeService+Messaging.swift:232,251` | routing 用 claimBoardState 查找 executionContext | 应直接读 TaskBoardState |
| `AgentTeamClaimExecutionGate.swift:52` | 执行前门控读 claimBoardState | 应读 TaskBoardState |
| `AgentTeamClaimCoordinator` 3 个方法 | 返回/操作 ClaimBoardState | 应删除，仅保留 TaskBoardState 版本 |
| `AgentTeamLaunchCoordinator` 多处 | 写回 `claimBoardProjection` | 应停止同步维护 |
| `agentGuiApp.swift:506` | 预览代码手动构造 ClaimBoardState | 应改为构造 TaskBoardState |

### 问题 2：Wave 执行器是串行的（Performance-Critical）

```swift
// ClaudeService+TeamDispatch.swift — 当前（串行）
for result in batch {
    await sendMessage(result.missionPrompt)   // 每张卡等待前一张完成
    markCardDone(result.primaryCardID)
    save()
}
```

oh-my-claudecode 的 Worker 是真正并行进程（tmux pane），单 Wave 可同时执行多个 task。agentGui 的 ACP Provider 也支持并发（`ConversationExecutionRuntimeCoordinator` 本身就是 actor），但 Wave Loop 未利用这一点。

### 问题 3：`AgentTeamDispatchPolicy` 死代码

```swift
enum AgentTeamDispatchPolicy {
    case manualSelection      // ← 实际使用的唯一值
    case sourceSessionSeeded  // ← 在 prefilled() 中被设置，但行为上与 manualSelection 完全相同
    case autoClaim            // ← 从未被设置
}
```

`sourceSessionSeeded` 的语义应该是"从来源会话自动推荐 provider"，但 `claimBatch` 里没有任何地方区分这两种 policy，只是记录了用一个值占位。

### 问题 4：`AgentTeamLaunchCoordinator.launch()` 遗留单步方法

```swift
// MARK: - Legacy single-step launch (kept for tests)
func launch(state: AgentTeamSessionState) throws -> LaunchResult {
    // 直接调用两阶段 claimPrimaryCard + beginWorking
}
```

**10 个测试**直接调用 `.launch(state:)`，这些测试没有覆盖两阶段 UI 流程，实际验证力度不足。

### 问题 5：ClaimCoordinator 双重重载混乱

`AgentTeamClaimCoordinator` 有 4 个方法，3 个操作旧 `ClaimBoardState`，1 个（throws 版本）操作新 `TaskBoardState`：

```swift
// 旧版（应删除）
func submitClaim(_:into: AgentTeamClaimBoardState) -> AgentTeamClaimBoardState
func acceptBestClaim(for:in: AgentTeamClaimBoardState, ...) -> AgentTeamClaimBoardState
func createInitialClaimBoard(for:) -> AgentTeamClaimBoardState

// 新版（保留）
func acceptBestClaim(for:taskBoard:claimBoard:...) throws -> (claimBoard:, taskBoard:)
```

### 问题 6：`ClaudeService+Messaging` Routing 走 Legacy 路径

`ClaudeService+Messaging.swift:232-251` 中做 Provider routing 时读取的是 `claimBoardState`：

```swift
guard let board = session.agentTeamState?.claimBoardState else { return }
// 通过 ClaimBoardState 查找 executionContext
```

这意味着 routing 依赖于一个 legacy projection，而不是 TaskBoardState（真实数据源）。

### 问题 7：BriefComposerProviderWarmupCoordinator 临时 Session

`BriefComposerProviderWarmupCoordinator.warmup()` 在没有 sourceSession 时创建一个 `title: "__warmup_probe__"` 的临时 Session，执行后用 `defer { modelContext.delete(probeSession) }` 删除。

这污染 SwiftData context，并依赖 defer 机制的可靠性（Task 取消时 defer 是否始终执行）。

### 问题 8：缺乏执行阶段推断（Phase Controller）

oh-my-claudecode 有清晰的 `TeamPhase`（initializing/planning/executing/fixing/completed/failed），由 `phase-controller.ts` 从任务状态分布推算。agentGui 只有 `AgentTeamRunStatus`（created/active/completed/failed），粒度不足，无法驱动 UI 上的阶段提示。

### 问题 9：缺乏任务超时和 Blocked 恢复机制

oh-my-claudecode 有 `worker-health.ts` + `applyDeadPaneTransition()`：检测 hung/dead worker，按重试次数决定 requeue 或 fail。agentGui 的 Wave Loop 没有任何超时或恢复机制——一个 Provider 的长时执行会无限期阻塞整个 Wave。

### 问题 10：缺乏 Team 会话摘要报告

oh-my-claudecode 的 `summary-report.ts` 在 Wave 全部完成后生成结构化 Markdown 报告（任务完成率、工件列表、Worker 性能、活动时间线）。agentGui 只有 Kanban Board 视图，没有会话结束后的聚合报告。

---

## 保留的设计（不变）

以下设计与 oh-my-claudecode 已良好对齐：

| 组件 | 说明 |
|------|------|
| `AgentTeamTaskBoardCoordinator` | 值语义协调器，纯函数变换，良好 |
| `AgentTeamMergeGateEvaluator` | 四维门控逻辑（incomplete/pending-reviews/blocked/unresolved-conflicts）|
| `AgentTeamReviewCoordinator` | Review decision → card 状态驱动器 |
| `AgentTeamArtifactBoardCoordinator` | 工件提交与状态更新 |
| `AgentTeamMissionPromptBuilder` | 三类 prompt 生成（standard/creativeDraft/synthesis）|
| `AgentTeamSessionFactory` | 从 Brief/Source 创建 SessionState，职责清晰 |
| `MissionBriefExtractionService` | AI 提取 brief JSON，接口合理 |
| `AgentTeamWorkbenchPresentation` | 纯函数 UI 表示层，分离展示与数据 |
| `WorkflowRoleDefinition` + `WorkflowModels` | 专用于内置 subagent 路径，与 Team 外部 Provider 路径不交叉 |

---

## Feature 拆分

---

### Feature T-01：清除 ClaimBoardState 遗留层

**目标**：彻底移除 `AgentTeamClaimBoardState`、`AgentTeamClaimCard`、`AgentTeamClaimCardPhase`，以及所有引用点。

**删除的类型（`Models/AgentTeamClaim.swift`）**：
```swift
// 删除：
enum AgentTeamClaimCardPhase         // .claiming / .claimed
struct AgentTeamClaimCard            // id/title/goal/phase/owner/claimIDs
struct AgentTeamClaimBoardState      // cards: [AgentTeamClaimCard] + claims: [AgentTeamClaim]
                                     // + func card(id:) / func acceptedClaim(for:) 等辅助方法
// 保留：
struct AgentTeamClaim                // 保留（TaskBoardState 内联使用）
enum AgentTeamClaimStatus            // 保留
struct AgentTeamExecutionTarget      // 保留
struct AgentTeamExecutionContext     // 保留
```

**修改 `Models/AgentTeamSessionState.swift`**：
- 删除 `var claimBoardJSON: String`
- 删除 `var claimBoardState: AgentTeamClaimBoardState?` computed property
- 删除 `func updateClaimBoard(_:)`
- `init` 中删除 `claimBoardJSON` 参数

**修改 `Models/AgentTeamTaskBoard.swift`**：
- 删除 `var claimBoardProjection: AgentTeamClaimBoardState` computed property
- 删除 `static func migrating(_ legacy: AgentTeamClaimBoardState) -> Self`
- 删除 `var legacyClaimPhase: AgentTeamClaimCardPhase` extension
- 删除 `private extension AgentTeamClaimCardPhase`

**修改 `agentGuiApp.swift`**：
- 将预览代码中的 `AgentTeamClaimBoardState` 构造改为使用 `AgentTeamTaskBoardState`（直接写入带 claims 的 TaskCard）

**完成标志**：无 `ClaimBoardState`、`ClaimCard`、`ClaimCardPhase`、`claimBoardJSON` 编译引用。

---

### Feature T-02：ClaimCoordinator / ClaimExecutionGate / Messaging 路径迁移

**目标**：删除 `AgentTeamClaimCoordinator` 的旧版 `ClaimBoardState` 方法，修复 `ClaudeService+Messaging` 和 `AgentTeamClaimExecutionGate` 使用的 legacy 路径。

**修改 `Services/Team/AgentTeamClaimCoordinator.swift`**：
- 删除 3 个操作 `AgentTeamClaimBoardState` 的旧方法：
  ```swift
  // 删除：
  func createInitialClaimBoard(for:) -> AgentTeamClaimBoardState
  func submitClaim(_:into: AgentTeamClaimBoardState) -> AgentTeamClaimBoardState
  func acceptBestClaim(for:in: AgentTeamClaimBoardState, ...) -> AgentTeamClaimBoardState
  ```
- 重命名保留方法（去掉 throws 版本的 overload 命名歧义）：
  ```swift
  // 保留并重命名为主要入口：
  func acceptBestClaim(for taskCardID: UUID, in taskBoard: AgentTeamTaskBoardState, ...) throws -> AgentTeamTaskBoardState
  func submitClaim(_:into: AgentTeamTaskBoardState) -> AgentTeamTaskBoardState
  ```

**修改 `Services/ClaudeService/ClaudeService+Messaging.swift`**（routing 路径）：
- 将 `session.agentTeamState?.claimBoardState` 替换为 `session.agentTeamState?.taskBoardState`
- 通过 `taskBoardState.preferredExecutionTarget()` / `taskBoardState.executionContext(for:)` 查找

**修改 `Services/Team/AgentTeamClaimExecutionGate.swift`**：
- 将 `state?.claimBoardState` 替换为 `state?.taskBoardState`
- 通过 `taskBoardState` 的方法完成 7 步验证

**修改 `Services/Team/AgentTeamLaunchCoordinator.swift`**：
- 删除所有 `state.claimBoardState = taskBoard.claimBoardProjection` 同步写回（不再需要维护 legacy projection）

**完成标志**：无通过 `claimBoardState` 做路由或门控的代码路径；`ClaudeService+Messaging` 直接用 TaskBoardState。

---

### Feature T-03：删除 `AgentTeamLaunchCoordinator.launch()` 遗留方法 + 测试重写

**目标**：删除标注为 "Legacy single-step launch" 的方法，将相关 10 个测试迁移为两阶段流程。

**删除 `Services/Team/AgentTeamLaunchCoordinator.swift`**：
```swift
// MARK: - Legacy single-step launch (kept for tests)
// 删除：
struct LaunchResult { ... }               // 仅此方法使用的结果类型
func launch(state: AgentTeamSessionState) throws -> LaunchResult { ... }
```

**重写 `agentGuiTests/AgentTeamLaunchCoordinatorTests.swift`**：
- 将所有 `launch(state:)` 调用替换为两步：
  ```swift
  let claimResult = try AgentTeamLaunchCoordinator().claimPrimaryCard(state: state)
  try AgentTeamLaunchCoordinator().beginWorking(cardID: claimResult.primaryCardID, in: state)
  ```
- 确保测试验证两阶段后的完整状态（`status == .active`，card 为 `.working`）

**完成标志**：`launch(state:)` 方法和 `LaunchResult` 类型不存在；所有测试通过。

---

### Feature T-04：消除 `AgentTeamDispatchPolicy` 死代码

**目标**：`AgentTeamDispatchPolicy` 的三个 case 中，`.sourceSessionSeeded` 和 `.autoClaim` 没有差异化行为，应删除。

**分析当前语义**：
- `.manualSelection`：用户手动在 BriefComposerSheet 中选择了 Provider
- `.sourceSessionSeeded`：由来源会话自动填充了 Provider（行为上 claimBatch 完全相同）
- `.autoClaim`：从未被设置，从未在 claimBatch 中分支

**修改 `Models/AgentTeamMissionBrief.swift`**：
```swift
// 删除 enum，改为 Bool 语义（是否由来源会话种子化）
// 原来：
enum AgentTeamDispatchPolicy { case manualSelection, sourceSessionSeeded, autoClaim }

// 替换为（在 AgentTeamProviderPlan 上）：
var isSourceSessionSeeded: Bool   // 取代 dispatchPolicy == .sourceSessionSeeded
```

**修改所有引用**（`AgentTeamMissionBriefDraft`, `AgentTeamMissionBriefResolver`, `AgentTeamSessionFactory`）：
- 将 `dispatchPolicy` 字段改为 `isSourceSessionSeeded: Bool`
- 在 `prefilled(fromSourceContext:)` 中 `seededProvider != nil` 时设为 `true`

**完成标志**：`AgentTeamDispatchPolicy` enum 不存在；Codable 迁移保留（旧 JSON 中 `dispatchPolicy: "manualSelection"` 解码为 `false`，`"sourceSessionSeeded"` 解码为 `true`，`"autoClaim"` 解码为 `false`）。

---

### Feature T-05：Wave 引擎改为并发执行

**目标**：`ClaudeService+TeamDispatch.launchTeamMission` 当前是串行 Wave Loop，改为 `withTaskGroup` 在同一 Wave 内并发执行多个 Provider 的 `sendMessage`，并对 Provider 成功/失败独立处理。

**修改 `Services/ClaudeService/ClaudeService+TeamDispatch.swift`**：

```swift
// 当前（串行）：
for result in batch {
    try await sendMessage(result.missionPrompt, ...)
    markCardDone(result.primaryCardID, ...)
}

// 目标（并发）：
try await withThrowingTaskGroup(of: WaveOutcome.self) { group in
    for result in batch {
        group.addTask {
            do {
                try await self.sendMessage(result.missionPrompt, ...)
                return .success(result.primaryCardID)
            } catch {
                return .failure(result.primaryCardID, error)
            }
        }
    }
    for try await outcome in group {
        switch outcome {
        case .success(let cardID):
            markCardDone(cardID, in: state)
        case .failure(let cardID, let error):
            markCardBlocked(cardID, reason: error.localizedDescription, in: state)
        }
        save()
    }
}
```

**注意事项**：
- `sendMessage` 本身可能读写 SwiftData context，需确认 `@MainActor` 调度
- 并发 Wave 时 `state` 的写入需要在 `@MainActor` 串行化（每个 `markCardDone/Blocked` 在主线程执行）

**完成标志**：同一 Wave 内多张卡的 `sendMessage` 并发发出；单卡失败不阻塞其他卡；Wave 完成后所有卡均有终态（done/blocked）。

---

### Feature T-06：去除 Wave 中的 `sleep(400ms)`

**目标**：删除 `ClaudeService+TeamDispatch.swift:36` 的硬编码 `Task.sleep(nanoseconds: 400_000_000)`，此 sleep 仅为了让 SwiftUI 有机会"看到" `.claimed` 状态。

**背景**：两阶段启动（phase 1 持久化 `.claimed`，pause，phase 2 推进 `.working`）的原意是让 UI 先渲染 "Claimed" 列，再渲染 "Working" 列。但用 sleep 实现是脆弱的。

**替换方案**：在 phase 1 之后 `save()` 并用 `await Task.yield()` 让出主线程一个 runloop tick。如果需要更可靠的 UI 更新保证，可以在 `AgentTeamSessionView` 中添加 `.onChange(of: state.taskBoardJSON)` 触发动画刷新，彻底去掉 sleep。

```swift
// 修改前：
try await save()
try? await Task.sleep(nanoseconds: 400_000_000)

// 修改后：
try await save()
await Task.yield()    // 让出一个 runloop tick
```

**完成标志**：Wave Loop 中无 `Task.sleep` 调用。

---

### Feature T-07：BriefComposerProviderWarmupCoordinator 去除临时 Session

**目标**：删除 `__warmup_probe__` 临时 Session 的创建/删除模式，改为不依赖 SwiftData 对象的轻量探测。

**问题**：
```swift
// 当前：
let probeSession = Session(title: "__warmup_probe__", kind: .local)
modelContext.insert(probeSession)
defer { modelContext.delete(probeSession) }
await claudeService.handleExecutionProviderSelectionChange(session: probeSession, ...)
```

- `modelContext.delete` 在 Task 取消时 `defer` 不一定可靠执行（Swift structured concurrency 中 defer 在 Task 取消路径是否执行依赖调用栈）
- 临时 Session 可能短暂出现在 Session 列表中
- `handleExecutionProviderSelectionChange` 如果只是为了初始化 ACP Provider registry，应有更轻量的 probe 接口

**修改**：
- 在 `ConversationExecutionRuntimeCoordinator` / provider registry 上添加 `probe(for:)` 方法，只加载配置快照，不需要 `Session` 对象
- `BriefComposerProviderWarmupCoordinator.warmup()` 改为调用 `probe(for:)` 获取 `modes` 和 `modelOptions`

**如无法立即添加 probe 接口的简化方案**：  
使用已有的"空 Session"（不插入 SwiftData，仅在内存中创建临时对象），用 `@discardableResult` 值对象传入，不走 modelContext：
```swift
let ephemeral = Session(title: "__probe__", kind: .local) // 不 insert
defer { /* noop */ }                                       // 不需要 delete
```

**完成标志**：`BriefComposerProviderWarmupCoordinator` 不向 `modelContext` 插入/删除任何对象。

---

### Feature T-08：添加 `AgentTeamPhase` 执行阶段推断

**目标**：从 `AgentTeamTaskBoardState` 推断当前团队执行阶段，对齐 oh-my-claudecode 的 `phase-controller.ts`，驱动更细粒度的 UI 反馈。

**新增 `Models/AgentTeamPhase.swift`**：
```swift
enum AgentTeamPhase: Equatable, Sendable {
    case initializing     // board 为空或只有 briefed 卡、无 active/done
    case executing        // 有 working/claimed 卡
    case reviewing        // 有 reviewing 卡，无 working 卡
    case fixing           // 有 blocked 卡，同时有 working 卡（在修复阻塞项）
    case completed        // 所有卡 done，无 blocked
    case failed           // status == .failed 或 所有卡都 blocked 且无 working
}
```

**新增 `Services/Team/AgentTeamPhaseEvaluator.swift`**（纯函数，无副作用）：
```swift
struct AgentTeamPhaseEvaluator {
    func evaluate(runStatus: AgentTeamRunStatus, taskBoard: AgentTeamTaskBoardState?) -> AgentTeamPhase
}
```

推断规则（按优先级）：
1. `runStatus == .failed` → `.failed`
2. `taskBoard == nil || cards.isEmpty` → `.initializing`
3. `all done, no blocked` → `.completed`
4. `has working or claimed` AND `has blocked` → `.fixing`
5. `has working or claimed` → `.executing`
6. `has reviewing, no working/claimed` → `.reviewing`
7. `all blocked, no working` → `.failed`
8. `all briefed, none active/done` → `.initializing`
9. fallback → `.executing`

**集成 `AgentTeamWorkbenchPresentation`**：
- `Header` 中新增 `phase: AgentTeamPhase` 字段
- `CommitBarState` 基于 `phase` 显示更细粒度的状态标签（"Executing 2/4 tasks…" / "All done, ready to review" 等）

**完成标志**：新增 `AgentTeamPhaseEvaluatorTests.swift` 覆盖全部 7 条规则；UI 表现层使用 `phase` 推断。

---

### Feature T-09：任务超时 + Blocked 卡恢复机制

**目标**：为 Wave Loop 中的每个 `sendMessage` 添加超时保护；超时后将卡推入 `.blocked` 并记录原因，允许用户手动恢复或重试。

**修改 `Services/ClaudeService/ClaudeService+TeamDispatch.swift`**：
```swift
// T-05 的并发 Wave 中添加超时包装：
group.addTask {
    try await withTimeout(.seconds(300)) {   // 5 分钟超时
        try await self.sendMessage(result.missionPrompt, ...)
    }
}

// 超时错误统一转为 WaveOutcome.failure
```

**新增超时枚举到 `AgentTeamTaskBoardCoordinator`**：
- `.blocked` 原因可以是 `"Timed out after 5 minutes"` 或 provider 返回的错误
- Board 视图中 blocked 卡显示超时原因

**"Retry Card" 功能**（可选，本 feature 简化为只添加 UI 入口）：
- CommitBar 或 Inspector 中对 `.blocked` 卡增加 "Retry" 按钮
- `AgentTeamTaskBoardCoordinator.retryingCard(_:in:)` → 将卡从 `.blocked` 推回 `.briefed`（清空 `blockerSummary`、`acceptedClaimID`、`owner`）
- 下一次 Wave 触发时（用户手动点 Run 或自动）该卡重新参与 `dispatchableCards`

**完成标志**：长时间执行的 provider 不再无限期阻塞 Wave；blocked 卡通过 Retry 可重新进入调度。

---

### Feature T-10：Allocation Policy 提取为独立类型

**目标**：将 `AgentTeamLaunchCoordinator.claimBatch` 中的 Provider 分配算法提取为独立的 `AgentTeamAllocationPolicy` 纯函数类型，对齐 oh-my-claudecode 的 `allocation-policy.ts`，提升可测试性。

**新增 `Services/Team/AgentTeamAllocationPolicy.swift`**：
```swift
/// 纯函数 Provider 分配算法，无副作用。
struct AgentTeamAllocationPolicy {

    /// 从 eligibleProviders 中为 card 选择最合适的 Provider。
    /// - Parameters:
    ///   - card: 待分配的任务卡
    ///   - eligibleProviders: brief 中配置的可用 provider 列表
    ///   - currentAssignments: 本次 Wave 中已分配的 (cardID → provider) 映射（用于负载均衡）
    ///   - preferredConductor: brief 的主导 conductor（synthesis 卡固定分配）
    /// - Returns: 选中的 ExecutionProviderReference
    func assign(
        card: AgentTeamTaskCard,
        eligibleProviders: [ExecutionProviderReference],
        currentAssignments: [UUID: ExecutionProviderReference],
        preferredConductor: ExecutionProviderReference
    ) -> ExecutionProviderReference
}
```

分配算法（与现有 `claimBatch` 逻辑一致，只是提取出来）：
- `synthesis` 卡 → 强制返回 `preferredConductor`
- `creativeDraft` / `standard` 卡 → 按 `currentAssignments` 中各 provider 的分配数量做 round-robin（负载最小者优先）

**修改 `AgentTeamLaunchCoordinator.claimBatch`**：内部改为调用 `AgentTeamAllocationPolicy().assign(...)` 取代内联逻辑。

**新增 `agentGuiTests/AgentTeamAllocationPolicyTests.swift`**：验证 round-robin、synthesis 固定分配、负载均衡等场景。

**完成标志**：`claimBatch` 中的分配逻辑完全委托给 `AgentTeamAllocationPolicy`；policy 有独立测试覆盖。

---

### Feature T-11：Team 会话摘要报告

**目标**：Wave 全部完成（`state.status == .completed`）后，生成结构化 Markdown 摘要，显示在 Team Workbench 的独立 Report Panel 或导出文件，对齐 oh-my-claudecode 的 `summary-report.ts`。

**新增 `Services/Team/AgentTeamSummaryReportBuilder.swift`**：
```swift
struct AgentTeamSummaryReportBuilder {
    func build(state: AgentTeamSessionState, wallClockDuration: TimeInterval) -> String
}
```

报告 Markdown 节（对齐 oh-my-claudecode 的 `summary-report.ts`）：
```markdown
# Team Mission Report: {objective}

## Summary
- Status: Completed / Failed
- Duration: {minutes} minutes
- Tasks: {done}/{total} completed, {blocked} blocked

## Task Results
| Task | Provider | Status | Artifacts |
|------|----------|--------|-----------|
| ... | ... | ✅ done / ❌ blocked | ... |

## Artifacts Produced
| Kind | Title | Task |
|------|-------|------|
...

## Blocked Tasks
| Task | Reason |
|------|--------|
...
```

**集成**：
- `AgentTeamWorkbenchPresentation` 新增 `summaryReport: String?` 字段（仅 `runStatus == .completed || .failed` 时非空）
- `AgentTeamSessionView` 的 Inspector Panel 或独立 "Report" Tab 中显示 summary

**完成标志**：Session 完成后 UI 展示 Markdown 格式的会话报告；`AgentTeamSummaryReportBuilderTests.swift` 验证输出格式。

---

## 执行优先级

| Feature | 依赖 | 优先级 | 预估工作量 |
|---------|------|--------|----------|
| T-01 清除 ClaimBoardState 遗留层 | 无 | P0 | 中（需删除多处引用） |
| T-02 ClaimCoordinator/Gate/Messaging 迁移 | T-01 | P0 | 中 |
| T-03 删除 launch() 遗留方法 + 测试重写 | 无 | P1 | 中（10 个测试迁移） |
| T-04 清除 DispatchPolicy 死代码 | 无 | P1 | 小 |
| T-05 Wave 引擎改为并发执行 | T-01、T-02 | P1 | 中 |
| T-06 去 Wave 中 sleep(400ms) | T-05 | P1 | 小 |
| T-07 WarmupCoordinator 去临时 Session | 无 | P2 | 小 |
| T-08 AgentTeamPhase 阶段推断 | T-01 | P2 | 小 |
| T-09 任务超时 + Blocked 恢复 | T-05 | P2 | 中 |
| T-10 Allocation Policy 提取 | T-03 | P2 | 小 |
| T-11 Team 会话摘要报告 | T-01 | P3 | 中 |

---

## 补充说明：不在此次重构范围内

以下 oh-my-claudecode 的特性不适用于 agentGui（或需要单独专项规划），**本次不实现**：

| oh-my-claudecode 特性 | 不实现原因 |
|----------------------|-----------|
| `permissions.ts` 路径沙箱 | agentGui 已有 `ToolAuthorizationPolicy` / `ToolGovernance` 体系，路径授权通过工具授权实现，不需要额外 advisory 层 |
| `scaling.ts` 动态扩缩容 | agentGui 的 Provider 数量由用户配置，无运行时动态增减需求 |
| `sentinel-gate.ts` factcheck | agentGui 没有对应的 factcheck 框架，需要单独规划 |
| `worker-bootstrap.ts` AGENTS.md overlay | ACP Provider 有自己的 bootstrapping 协议，不通过 AGENTS.md 注入 |
| `heartbeat.ts` / `idle-nudge.ts` | 基于 tmux pane 生命周期，agentGui 是进程内执行，不需要心跳文件 |
| `followup-planner.ts` | 需要 ralplan 规划周期集成，是更大规模特性 |
| Git worktree 合并（`merge-coordinator.ts`）| 当前 Wave 执行未创建 worktree，T-05 并发后也不需要，因为每个 Provider 执行在同一 workspace |

---

## 关于 WorkflowModels / WorkflowRoleDefinition 与 AgentTeam 的边界

这两套看似平行的体系（`WorkflowRoleDefinition` vs `AgentTeamProviderRole`，`WorkflowArtifactKind` vs `AgentTeamArtifactKind`）**实际上是正交的两层**：

- **`WorkflowRoleDefinition`** + `WorkflowModels` — 专用于**内置 subagent 执行路径**（`AgentCatalog`、`ClaudeService+SkillFork`）。这是 agentGui built-in agents（claude-code 内置、记忆整合守护进程等）的配置层。
- **`AgentTeamProviderRole`** + `AgentTeamArtifact` — 专用于**外部 Provider Team Mission 路径**（ACP Providers 编排）。

两者无代码交叉，仅命名重叠。**不需要重构，只需要在代码注释中明确边界文档**（可在各自顶部加 `// Used by: internal subagent execution pipeline` / `// Used by: external provider Team Mission` 注释）。

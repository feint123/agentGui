# Feature 17: Per-Agent Virtual Session — 并行 Agent 独立运行时管理 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 team mode 中每个并行运行的 agent 分配独立的虚拟 session，使 `ExecutionScheduler` 能同时 admit 多个来自不同 schedulingSessionID 的 job，从而让 Feature 8（Execution Parallelism）真正做到多 provider 同时工作。

**Architecture:** 三层变更。(1) 调度层——`EnqueueExecutionCommand` 新增可选 `schedulingSessionID`，`ConversationExecutionOrchestrator` 用它作为 mailbox/scheduler 的 key，同时用 `job.sessionID` 做持久层 session 查找；(2) Claim 层——`AgentTeamLaunchCoordinator.ClaimPhaseResult` 新增 `virtualSessionID`，`claimBatch` 为每张多卡任务分配独立虚拟 session；(3) 保活层——`ConversationExecutionRuntimeCoordinator` 新增 `teamActiveVirtualSessionIDs`，确保虚拟 session 对应的 provider 进程在 team 运行期间不被 kill。

**Tech Stack:** Swift 6, SwiftUI, SwiftData，现有 `ExecutionScheduler`、`SessionExecutionMailbox`、`ConversationExecutionOrchestrator`、`ConversationExecutionRuntimeCoordinator`。

---

## 依赖说明

- **依赖 Feature 8**：`claimBatch` 多卡路径必须已就绪（`AgentTeamLaunchCoordinator.claimBatch`）。
- 不引入新的 SwiftData model；虚拟 session 为纯内存记录。
- 降级规则：batch 结果数 ≤ 1（单卡）时不分配虚拟 session，直接使用父 team session ID，完全向后兼容。

---

## 关键现有文件速查

| 文件 | Feature 17 关联作用 |
|---|---|
| `agentGui/Models/ExecutionProjection.swift` | `EnqueueExecutionCommand` 结构体（新增 `schedulingSessionID`） |
| `agentGui/Services/Execution/ConversationExecutionOrchestrator.swift` | `enqueue()`、`dispatch()`（mailbox key 与 session 查找分离） |
| `agentGui/Services/Execution/ExecutionScheduler.swift` | `admitReadyJobs`、`runningJobsBySessionID`（不修改，设计目标） |
| `agentGui/Services/Team/AgentTeamLaunchCoordinator.swift` | `ClaimPhaseResult`、`claimBatch`（虚拟 session 分配） |
| `agentGui/Services/ClaudeService/ClaudeService+TeamDispatch.swift` | `launchTeamMission`（多卡路径使用 `schedulingSessionID`） |
| `agentGui/Services/ConversationExecutionRuntimeCoordinator.swift` | `ScopeState`（`teamActiveVirtualSessionIDs` 保活） |
| `agentGui/Views/Team/AgentTeamSessionView.swift` | `.task` 维护 `teamActiveVirtualSessionIDs` |
| `agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift` | 通过虚拟 session ID 读取各 card 的 projection |
| `agentGuiTests/AgentTeamLaunchCoordinatorTests.swift` | 追加 claimBatch virtualSessionID 测试 |

---

## Task 1：新增 `AgentTeamVirtualSession` 值类型与 `AgentTeamVirtualSessionRegistry`

**Files:**
- Create: `agentGui/Services/Team/AgentTeamVirtualSessionRegistry.swift`
- Create: `agentGuiTests/AgentTeamVirtualSessionRegistryTests.swift`

### 背景

虚拟 session 是一个纯内存的轻量记录，为每个被接受的 claim 提供独立的 scheduler key，从而让 `ExecutionScheduler.admitReadyJobs` 能同时 admit 来自同一 team 的多个 job。Registry 生命周期与 team dispatch 上下文绑定，最终挂载在 `ClaudeService`。

### Step 1：写失败测试

新建 `agentGuiTests/AgentTeamVirtualSessionRegistryTests.swift`：

```swift
import Testing
@testable import agentGui

@MainActor
struct AgentTeamVirtualSessionRegistryTests {

    @Test
    func allocateReturnsDifferentIDsForDifferentClaims() {
        let registry = AgentTeamVirtualSessionRegistry()
        let claimA = makeAcceptedClaim(taskCardID: UUID())
        let claimB = makeAcceptedClaim(taskCardID: UUID())
        let vsA = registry.allocate(for: claimA, parentTeamSessionID: "team-1")
        let vsB = registry.allocate(for: claimB, parentTeamSessionID: "team-1")
        #expect(vsA.id != vsB.id)
    }

    @Test
    func allocateIsIdempotent() {
        let registry = AgentTeamVirtualSessionRegistry()
        let claim = makeAcceptedClaim(taskCardID: UUID())
        let first = registry.allocate(for: claim, parentTeamSessionID: "team-1")
        let second = registry.allocate(for: claim, parentTeamSessionID: "team-1")
        #expect(first.id == second.id)
    }

    @Test
    func resolveReturnsParentTeamSessionIDAndCardID() {
        let registry = AgentTeamVirtualSessionRegistry()
        let cardID = UUID()
        let claim = makeAcceptedClaim(taskCardID: cardID)
        let vs = registry.allocate(for: claim, parentTeamSessionID: "team-abc")
        let resolved = registry.resolve(virtualSessionID: vs.id)
        #expect(resolved?.teamSessionID == "team-abc")
        #expect(resolved?.taskCardID == cardID)
    }

    @Test
    func resolveReturnsNilAfterRelease() {
        let registry = AgentTeamVirtualSessionRegistry()
        let cardID = UUID()
        let claim = makeAcceptedClaim(taskCardID: cardID)
        let vs = registry.allocate(for: claim, parentTeamSessionID: "team-1")
        registry.release(for: cardID)
        #expect(registry.resolve(virtualSessionID: vs.id) == nil)
    }

    @Test
    func activeVirtualSessionIDsFiltersTeamSessionID() {
        let registry = AgentTeamVirtualSessionRegistry()
        let claimA = makeAcceptedClaim(taskCardID: UUID())
        let claimB = makeAcceptedClaim(taskCardID: UUID())
        let claimC = makeAcceptedClaim(taskCardID: UUID())
        _ = registry.allocate(for: claimA, parentTeamSessionID: "team-1")
        _ = registry.allocate(for: claimB, parentTeamSessionID: "team-1")
        _ = registry.allocate(for: claimC, parentTeamSessionID: "team-2")
        let active = registry.activeVirtualSessionIDs(for: "team-1")
        #expect(active.count == 2)
    }

    @Test
    func releaseDoesNotAffectOtherCards() {
        let registry = AgentTeamVirtualSessionRegistry()
        let cardA = UUID()
        let cardB = UUID()
        let claimA = makeAcceptedClaim(taskCardID: cardA)
        let claimB = makeAcceptedClaim(taskCardID: cardB)
        let vsA = registry.allocate(for: claimA, parentTeamSessionID: "team-1")
        _ = registry.allocate(for: claimB, parentTeamSessionID: "team-1")
        registry.release(for: cardA)
        #expect(registry.resolve(virtualSessionID: vsA.id) == nil)
        #expect(registry.activeVirtualSessionIDs(for: "team-1").count == 1)
    }

    // MARK: - Helpers

    private func makeAcceptedClaim(taskCardID: UUID) -> AgentTeamClaim {
        AgentTeamClaim(
            id: UUID(),
            providerReference: .builtIn,
            taskCardID: taskCardID,
            confidence: 1.0,
            rationaleSummary: "test",
            requiredCapabilities: [],
            expectedArtifacts: [],
            estimatedCostSummary: "",
            status: .accepted,
            submittedAt: Date()
        )
    }
}
```

### Step 2：运行测试验证失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-task1 \
  -only-testing:agentGuiTests/AgentTeamVirtualSessionRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译错误，`AgentTeamVirtualSessionRegistry`、`AgentTeamVirtualSession` 未定义。

### Step 3：实现 `AgentTeamVirtualSessionRegistry.swift`

新建 `agentGui/Services/Team/AgentTeamVirtualSessionRegistry.swift`：

```swift
import Foundation

/// 纯内存轻量记录，为每个被接受的 claim 分配独立的调度 session ID，
/// 以便 ExecutionScheduler 能同时 admit 来自同一 team 的多个 job。
///
/// 虚拟 session ID 仅用于 scheduler 和 mailbox 分派层；
/// 不出现在 SwiftData 存储中，父 team session 仍是持久化主键。
struct AgentTeamVirtualSession: Identifiable, Sendable {
    let id: String                      // 作为 schedulingSessionID 使用的 UUID 字符串
    let parentTeamSessionID: String
    let taskCardID: UUID
    let claimID: UUID
    let providerReference: ExecutionProviderReference
    let allocatedAt: Date
}

/// 管理 AgentTeamVirtualSession 的生命周期。
/// 生命周期与父 team session 绑定，挂载在 ClaudeService。
@MainActor
final class AgentTeamVirtualSessionRegistry: Observable {

    private(set) var sessions: [String: AgentTeamVirtualSession] = [:]

    /// 为一个被接受的 claim 分配虚拟 session。
    /// 同一 claimID 重复调用幂等，返回已存在的记录。
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

    /// 通过 virtualSessionID 查找父 team session 和 card ID，
    /// 用于 projection 路由和 workbench 状态读取。
    func resolve(virtualSessionID: String) -> (teamSessionID: String, taskCardID: UUID)? {
        guard let vs = sessions[virtualSessionID] else { return nil }
        return (vs.parentTeamSessionID, vs.taskCardID)
    }

    /// 父 team session 所有活跃虚拟 session 的 ID 集合，
    /// 用于 runtime retention。
    func activeVirtualSessionIDs(for teamSessionID: String) -> Set<String> {
        Set(sessions.values
            .filter { $0.parentTeamSessionID == teamSessionID }
            .map { $0.id })
    }

    /// 清除指定父 team session 的所有虚拟 session（team 停止或完成时调用）。
    func releaseAll(for teamSessionID: String) {
        sessions = sessions.filter { $0.value.parentTeamSessionID != teamSessionID }
    }
}
```

### Step 4：运行测试验证通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-task1 \
  -only-testing:agentGuiTests/AgentTeamVirtualSessionRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：全部 PASS。

### Step 5：提交

```
git add agentGui/Services/Team/AgentTeamVirtualSessionRegistry.swift \
        agentGuiTests/AgentTeamVirtualSessionRegistryTests.swift
git commit -m "feat(f17): add AgentTeamVirtualSession + Registry"
```

---

## Task 2：`EnqueueExecutionCommand` 新增 `schedulingSessionID` 字段

**Files:**
- Modify: `agentGui/Models/ExecutionProjection.swift`

### 背景

`EnqueueExecutionCommand.sessionID` 当前同时用于两个目的：(1) 持久层 session 查找；(2) mailbox/scheduler 的 mutex key。Feature 17 需要把这两个用途分离：`sessionID` 继续用于 SwiftData 持久层，`schedulingSessionID`（可选）用于 mailbox/scheduler。当 `schedulingSessionID` 为 `nil` 时，行为与之前完全相同，向后兼容。

### Step 1：写失败测试

在 `agentGuiTests/AgentTeamVirtualSessionRegistryTests.swift` **末尾追加**：

```swift
// MARK: - EnqueueExecutionCommand schedulingSessionID (Task 2)

@Test
func enqueueCommandDefaultsSchedulingSessionIDToNil() {
    let cmd = EnqueueExecutionCommand(
        sessionID: "session-1",
        providerReference: .builtIn,
        payload: .userPrompt(text: "hi", modelID: "m", selectedFilePath: nil,
                             selectedText: nil, directives: [], teamContext: nil),
        sourceUserMessageID: UUID()
    )
    #expect(cmd.effectiveSchedulingSessionID == "session-1")
}

@Test
func enqueueCommandUsesOverriddenSchedulingSessionID() {
    let cmd = EnqueueExecutionCommand(
        sessionID: "session-real",
        schedulingSessionID: "vsid-virtual",
        providerReference: .builtIn,
        payload: .userPrompt(text: "hi", modelID: "m", selectedFilePath: nil,
                             selectedText: nil, directives: [], teamContext: nil),
        sourceUserMessageID: UUID()
    )
    #expect(cmd.effectiveSchedulingSessionID == "vsid-virtual")
    #expect(cmd.sessionID == "session-real")
}
```

### Step 2：运行测试验证失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-task2 \
  -only-testing:agentGuiTests/AgentTeamVirtualSessionRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译错误，`schedulingSessionID`/`effectiveSchedulingSessionID` 未定义。

### Step 3：修改 `agentGui/Models/ExecutionProjection.swift`

在 `EnqueueExecutionCommand` 结构体中，找到 `sourceUserMessageID` 字段后新增 `schedulingSessionID?`，并新增计算属性 `effectiveSchedulingSessionID`：

```swift
struct EnqueueExecutionCommand: Sendable {
    let sessionID: String
    let schedulingSessionID: String?    // 新增：nil 时退回 sessionID
    let providerReference: ExecutionProviderReference
    let payload: ExecutionPayloadDraft
    let sourceUserMessageID: UUID

    /// mailbox 和 scheduler 应使用的 session ID。
    /// 多卡并行路径为虚拟 session ID；单卡或普通消息路径为 nil（退回 sessionID）。
    var effectiveSchedulingSessionID: String {
        schedulingSessionID ?? sessionID
    }
```

为原有两个 `init` (基于 `providerID` 和基于 `providerReference`) 保持向后兼容（新增 `schedulingSessionID: String? = nil` 参数默认值 nil）：

```swift
    init(
        sessionID: String,
        schedulingSessionID: String? = nil,
        providerID: ConversationExecutionProviderID,
        payload: ExecutionPayloadDraft,
        sourceUserMessageID: UUID
    ) {
        self.init(
            sessionID: sessionID,
            schedulingSessionID: schedulingSessionID,
            providerReference: . ...,  // 保持原有逻辑
            payload: payload,
            sourceUserMessageID: sourceUserMessageID
        )
    }

    init(
        sessionID: String,
        schedulingSessionID: String? = nil,
        providerReference: ExecutionProviderReference,
        payload: ExecutionPayloadDraft,
        sourceUserMessageID: UUID
    ) {
        self.sessionID = sessionID
        self.schedulingSessionID = schedulingSessionID
        self.providerReference = providerReference
        self.payload = payload
        self.sourceUserMessageID = sourceUserMessageID
    }
```

> **注意**：只在两个 `init` 上加 `schedulingSessionID: String? = nil` 默认参数，不修改任何已有调用点。

### Step 4：运行测试验证通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-task2 \
  -only-testing:agentGuiTests/AgentTeamVirtualSessionRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：全部 PASS，现有其他测试无 regression。

### Step 5：提交

```
git add agentGui/Models/ExecutionProjection.swift \
        agentGuiTests/AgentTeamVirtualSessionRegistryTests.swift
git commit -m "feat(f17): add schedulingSessionID to EnqueueExecutionCommand"
```

---

## Task 3：`ConversationExecutionOrchestrator` 调度 session ID 与持久 session ID 分离

**Files:**
- Modify: `agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`

### 背景

`enqueue()` 当前用 `command.sessionID` 作为 mailbox key，`dispatch()` 用 `candidate.sessionID` 查找 SwiftData `Session`。Feature 17 要求：

1. `enqueue()` mailbox key = `command.effectiveSchedulingSessionID`（可能是虚拟 ID）
2. `dispatch()` session 查找 = `job.sessionID`（始终是真实 session ID，存于 SwiftData）

不修改 `ExecutionScheduler` 本身，它的 `runningJobsBySessionID` 自然以虚拟 ID 作 key，实现并发。

### Step 1：写失败测试

在 `agentGuiTests/AgentTeamVirtualSessionRegistryTests.swift` **末尾追加**（或新建 `AgentTeamSchedulingTests.swift`）：

```swift
// MARK: - Scheduler parallelism with virtual session IDs (Task 3)

@Test
func schedulerAdmitsTwoJobsWithDifferentVirtualSessionIDs() async {
    let scheduler = ExecutionScheduler(maxConcurrentJobs: 4)

    // Simulate two cards with different virtual session IDs
    let candidateA = ExecutionSchedulingCandidate(
        sessionID: "vsid-A",
        jobID: UUID(),
        providerReference: .builtIn,
        capacityPolicy: .default
    )
    let candidateB = ExecutionSchedulingCandidate(
        sessionID: "vsid-B",
        jobID: UUID(),
        providerReference: .builtIn,
        capacityPolicy: .default
    )

    let admitted = await scheduler.admitReadyJobs([candidateA, candidateB])
    #expect(admitted.count == 2)
}

@Test
func schedulerBlocksSecondJobWithSameSessionID() async {
    let scheduler = ExecutionScheduler(maxConcurrentJobs: 4)
    let jobA = UUID()
    let jobB = UUID()
    // First: admit candidate A
    let candidateA = ExecutionSchedulingCandidate(
        sessionID: "session-shared",
        jobID: jobA,
        providerReference: .builtIn,
        capacityPolicy: .default
    )
    let admitted1 = await scheduler.admitReadyJobs([candidateA])
    #expect(admitted1.count == 1)

    // Second: same session ID -> blocked
    let candidateB = ExecutionSchedulingCandidate(
        sessionID: "session-shared",
        jobID: jobB,
        providerReference: .builtIn,
        capacityPolicy: .default
    )
    let admitted2 = await scheduler.admitReadyJobs([candidateB])
    #expect(admitted2.count == 0)
}
```

这两个测试验证调度器在不同 virtual session ID 下的并发行为，不依赖 orchestrator 修改即可通过（scheduler 已按 sessionID 做 mutex）。

### Step 2：运行 scheduler 测试验证行为正确

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-task3 \
  -only-testing:agentGuiTests/AgentTeamVirtualSessionRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：PASS（`ExecutionScheduler` 行为已正确，无需修改）。

### Step 3：修改 `ConversationExecutionOrchestrator.enqueue()`

在 `enqueue()` 方法内，找到：

```swift
        let mailbox = mailbox(for: command.sessionID)
        await mailbox.enqueue(jobID: result.job.id)

        projectionWriter.apply(
            .enqueued(
                sessionID: command.sessionID,
                jobID: result.job.id,
                providerReference: command.providerReference
            )
        )

        await dispatchReadyJobs()

        return ExecutionJobHandle(jobID: result.job.id, sessionID: command.sessionID)
```

替换为：

```swift
        let schedulingID = command.effectiveSchedulingSessionID
        let mailbox = mailbox(for: schedulingID)
        await mailbox.enqueue(jobID: result.job.id)

        projectionWriter.apply(
            .enqueued(
                sessionID: schedulingID,
                jobID: result.job.id,
                providerReference: command.providerReference
            )
        )

        await dispatchReadyJobs()

        return ExecutionJobHandle(jobID: result.job.id, sessionID: schedulingID)
```

> `persistenceStore.session(id: command.sessionID)` 保持不变——这一行仍用真实 session ID 做持久层 session 有效性校验。

### Step 4：修改 `ConversationExecutionOrchestrator.dispatch()`

在 `dispatch(_:)` 方法内，找到：

```swift
        guard let job = try? persistenceStore.job(id: candidate.jobID),
              let session = try? persistenceStore.session(id: candidate.sessionID) else {
            _ = await mailbox.finishRunning(jobID: candidate.jobID)
            await scheduler.markFinished(jobID: candidate.jobID, sessionID: candidate.sessionID)
            _ = await pruneInvalidQueuedJob(sessionID: candidate.sessionID, jobID: candidate.jobID, mailbox: mailbox)
```

替换为（使用 `job.sessionID` 查找真实 session）：

```swift
        guard let job = try? persistenceStore.job(id: candidate.jobID),
              let session = try? persistenceStore.session(id: job.sessionID) else {
            _ = await mailbox.finishRunning(jobID: candidate.jobID)
            await scheduler.markFinished(jobID: candidate.jobID, sessionID: candidate.sessionID)
            _ = await pruneInvalidQueuedJob(sessionID: candidate.sessionID, jobID: candidate.jobID, mailbox: mailbox)
```

> 日志/trace 中显示的 sessionID 保留 `candidate.sessionID`（即 virtual session ID），这是正确的——projection 以 virtual session ID 为 key 追踪各卡的执行状态。

### Step 5：运行现有测试确认无 regression

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-task3 \
  -only-testing:agentGuiTests/AgentTeamVirtualSessionRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：全部 PASS。

### Step 6：提交

```
git add agentGui/Services/Execution/ConversationExecutionOrchestrator.swift \
        agentGuiTests/AgentTeamVirtualSessionRegistryTests.swift
git commit -m "feat(f17): decouple scheduling sessionID from persistence sessionID in orchestrator"
```

---

## Task 4：`ClaimPhaseResult.virtualSessionID` + `claimBatch` 虚拟 session 分配

**Files:**
- Modify: `agentGui/Services/Team/AgentTeamLaunchCoordinator.swift`
- Modify: `agentGuiTests/AgentTeamLaunchCoordinatorTests.swift`

### 背景

`ClaimPhaseResult` 是 claim 阶段的输出，目前不携带 session ID 信息。Feature 17 要求多卡路径的每个 result 携带独立的 `virtualSessionID`，供 TeamDispatch 层传递给 `EnqueueExecutionCommand.schedulingSessionID`。

规则：
- `claimBatch` 结果数 ≤ 1 → `virtualSessionID` = 父 team session ID（向后兼容，不分配虚拟 session）
- `claimBatch` 结果数 > 1 → 通过 registry 为每张卡分配独立虚拟 session ID

### Step 1：写失败测试

在 `agentGuiTests/AgentTeamLaunchCoordinatorTests.swift` **末尾追加**  
（`// MARK: - Feature 17: Virtual Session ID` 注释块）：

```swift
// MARK: - Feature 17: Virtual Session ID

@Test
func claimBatchSingleCardUsesParentSessionID() throws {
    let state = makeState(maxActiveProviders: 1)
    let registry = AgentTeamVirtualSessionRegistry()
    let batch = try AgentTeamLaunchCoordinator().claimBatch(
        state: state,
        virtualSessionRegistry: registry,
        parentTeamSessionID: "team-session-1"
    )
    #expect(batch.count == 1)
    // 单卡：virtualSessionID 等于父 session ID（不分配虚拟 session）
    #expect(batch[0].virtualSessionID == "team-session-1")
}

@Test
func claimBatchMultipleCardsAllocatesUniqueVirtualSessionIDs() throws {
    let state = makeMultiCardState(maxActiveProviders: 3)
    let registry = AgentTeamVirtualSessionRegistry()
    let batch = try AgentTeamLaunchCoordinator().claimBatch(
        state: state,
        virtualSessionRegistry: registry,
        parentTeamSessionID: "team-session-2"
    )
    guard batch.count >= 2 else {
        #expect(Bool(false), "需要至少 2 张可 dispatch 的卡")
        return
    }
    let ids = Set(batch.map(\.virtualSessionID))
    // 多卡：每张卡有独立虚拟 session ID
    #expect(ids.count == batch.count)
    // 虚拟 ID 不等于父 session ID
    #expect(!ids.contains("team-session-2"))
}

@Test
func claimBatchWithNilRegistryUsesParentSessionIDForAllCards() throws {
    let state = makeMultiCardState(maxActiveProviders: 3)
    let batch = try AgentTeamLaunchCoordinator().claimBatch(
        state: state,
        virtualSessionRegistry: nil,
        parentTeamSessionID: "team-session-3"
    )
    for result in batch {
        #expect(result.virtualSessionID == "team-session-3")
    }
}

// MARK: - Multi-card helper

private func makeMultiCardState(maxActiveProviders: Int) -> AgentTeamSessionState {
    let session = Session.fixture(title: "Parallel Team", kind: .agentTeam)
    let state = AgentTeamSessionState(session: session, mode: .executionDelivery, status: .created)
    let cardA = AgentTeamTaskCard(
        id: UUID(), title: "Card A", goal: "goal A",
        status: .briefed, owner: nil, acceptedClaimID: nil,
        dependencyIDs: [], blockerSummary: nil, lastUpdatedAt: Date()
    )
    let cardB = AgentTeamTaskCard(
        id: UUID(), title: "Card B", goal: "goal B",
        status: .briefed, owner: nil, acceptedClaimID: nil,
        dependencyIDs: [], blockerSummary: nil, lastUpdatedAt: Date()
    )
    let board = AgentTeamTaskBoard(claims: [], cards: [cardA, cardB])
    state.missionBrief = AgentTeamMissionBrief(
        objective: "Parallel test",
        constraints: [],
        acceptanceCriteria: [],
        mode: .executionDelivery,
        dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: maxActiveProviders),
        initialContextSummary: "",
        providerPlan: .init(
            roleAssignments: [
                AgentTeamProviderRoleAssignment(providerReference: .builtIn, roles: [.conductor, .worker])
            ],
            dispatchPolicy: .autoClaim
        )
    )
    state.taskBoardState = board
    state.claimBoardState = board.claimBoardProjection
    return state
}
```

### Step 2：运行测试验证失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-task4 \
  -only-testing:agentGuiTests/AgentTeamLaunchCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译错误，`ClaimPhaseResult.virtualSessionID`、`claimBatch(state:virtualSessionRegistry:parentTeamSessionID:)` 未定义。

### Step 3：修改 `AgentTeamLaunchCoordinator.ClaimPhaseResult`

在 `AgentTeamLaunchCoordinator.swift` 的 `ClaimPhaseResult` 结构体中新增字段：

```swift
    struct ClaimPhaseResult: Equatable {
        let primaryCardID: UUID
        let executionTarget: AgentTeamExecutionTarget
        let missionPrompt: String
        let virtualSessionID: String   // 新增：单卡=父 sessionID，多卡=注册表分配的虚拟 ID
    }
```

### Step 4：修改 `claimBatch` 签名，增加 registry 和 parentTeamSessionID 参数

在 `claimBatch` 方法签名中新增两个参数（均有默认值以保持向后兼容）：

```swift
    func claimBatch(
        state: AgentTeamSessionState,
        virtualSessionRegistry: AgentTeamVirtualSessionRegistry? = nil,
        parentTeamSessionID: String = ""
    ) throws -> [ClaimPhaseResult] {
```

### Step 5：更新 `claimBatch` 内部逻辑，在 `results` 构建完成后分配虚拟 session

在 `claimBatch` 方法末尾的 `state.taskBoardState = taskBoard` 之前，找到 `results.append(...)` 调用，将原始 `ClaimPhaseResult` 初始化修改为包含 `virtualSessionID: missionPrompt` 占位，然后在 `state.taskBoardState = taskBoard` 之后增加 virtualSessionID 回填逻辑：

具体：在原有 `return results` 前加一段：

```swift
        // Feature 17: 多卡路径使用虚拟 session ID，单卡路径退回父 session ID
        let useVirtualSessions = results.count > 1 && virtualSessionRegistry != nil
        let finalResults: [ClaimPhaseResult] = results.enumerated().map { (index, result) in
            let vsid: String
            if useVirtualSessions, let registry = virtualSessionRegistry,
               let claim = taskBoard.acceptedClaim(for: result.primaryCardID) {
                vsid = registry.allocate(for: claim, parentTeamSessionID: parentTeamSessionID).id
            } else {
                vsid = parentTeamSessionID.isEmpty ? result.primaryCardID.uuidString : parentTeamSessionID
            }
            return ClaimPhaseResult(
                primaryCardID: result.primaryCardID,
                executionTarget: result.executionTarget,
                missionPrompt: result.missionPrompt,
                virtualSessionID: vsid
            )
        }
        return finalResults
```

并删除原有的 `return results`。

> **向后兼容**：原有调用 `claimBatch(state: state)` 不传 registry → `useVirtualSessions = false` → `virtualSessionID = parentTeamSessionID`（为空字符串）。已有测试不感知 `virtualSessionID`，不会失败。

### Step 6：更新 `claimBatch` 内原始 `results.append` 调用，初始 `virtualSessionID` 用临时值

在方法内部找到现有所有 `results.append(ClaimPhaseResult(...))` 调用，为每个调用补充 `virtualSessionID: ""` 参数（临时值，由步骤 5 的回填逻辑覆写）：

```swift
results.append(ClaimPhaseResult(
    primaryCardID: card.id,
    executionTarget: executionTarget,
    missionPrompt: prompt,
    virtualSessionID: ""   // 临时值，由末尾虚拟 session 分配逻辑覆写
))
```

### Step 7：运行测试验证通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-task4 \
  -only-testing:agentGuiTests/AgentTeamLaunchCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：全部 PASS（含既有测试）。

### Step 8：提交

```
git add agentGui/Services/Team/AgentTeamLaunchCoordinator.swift \
        agentGuiTests/AgentTeamLaunchCoordinatorTests.swift
git commit -m "feat(f17): ClaimPhaseResult.virtualSessionID + claimBatch registry allocation"
```

---

## Task 5：`ClaudeService` 挂载 Registry + TeamDispatch 使用虚拟 session ID

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+TeamDispatch.swift`
- Modify: `agentGui/Services/ClaudeService/ClaudeService.swift`（或 `ClaudeService+Properties.swift`）

### 背景

`ClaudeService` 需要持有一个 `AgentTeamVirtualSessionRegistry` 实例，供 TeamDispatch 在 `launchTeamMission` 时使用。`launchTeamMission` 中多卡路径（`batch.count > 1`）改为传递 `schedulingSessionID = result.virtualSessionID` 给 `EnqueueExecutionCommand`。

### Step 1：写失败测试

在 `agentGuiTests/AgentTeamVirtualSessionRegistryTests.swift` **末尾追加**：

```swift
// MARK: - Task 5: TeamDispatch virtual session routing

@Test
func claimBatchResultCarriesVirtualSessionIDForParallelBatch() throws {
    // 验证多卡 batch 的 virtualSessionID 不全相同
    // 使用真实 AgentTeamLaunchCoordinator + 真实 registry
    let session = Session.fixture(title: "Parallel", kind: .agentTeam)
    let state = AgentTeamSessionState(session: session, mode: .executionDelivery, status: .created)
    let cardA = AgentTeamTaskCard(id: UUID(), title: "A", goal: "A",
                                     status: .briefed, owner: nil, acceptedClaimID: nil,
                                     dependencyIDs: [], blockerSummary: nil, lastUpdatedAt: Date())
    let cardB = AgentTeamTaskCard(id: UUID(), title: "B", goal: "B",
                                     status: .briefed, owner: nil, acceptedClaimID: nil,
                                     dependencyIDs: [], blockerSummary: nil, lastUpdatedAt: Date())
    let board = AgentTeamTaskBoard(claims: [], cards: [cardA, cardB])
    state.missionBrief = AgentTeamMissionBrief(
        objective: "parallel dispatch",
        constraints: [], acceptanceCriteria: [],
        mode: .executionDelivery,
        dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: 4),
        initialContextSummary: "",
        providerPlan: .init(
            roleAssignments: [AgentTeamProviderRoleAssignment(providerReference: .builtIn, roles: [.conductor, .worker])],
            dispatchPolicy: .autoClaim
        )
    )
    state.taskBoardState = board
    state.claimBoardState = board.claimBoardProjection

    let registry = AgentTeamVirtualSessionRegistry()
    let batch = try AgentTeamLaunchCoordinator().claimBatch(
        state: state,
        virtualSessionRegistry: registry,
        parentTeamSessionID: "parent-session"
    )

    #expect(batch.count == 2)
    // 虚拟 ID 各不相同
    #expect(batch[0].virtualSessionID != batch[1].virtualSessionID)
    // 虚拟 ID 均已注册
    #expect(registry.resolve(virtualSessionID: batch[0].virtualSessionID) != nil)
    #expect(registry.resolve(virtualSessionID: batch[1].virtualSessionID) != nil)
}
```

### Step 2：运行测试验证失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-task5 \
  -only-testing:agentGuiTests/AgentTeamVirtualSessionRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：FAIL 或编译错误（`claimBatch` 新的 Task 4 签名未通过 `makeMultiCardState` type check 等，需要确保 Task 4 已完成）。

### Step 3：在 `ClaudeService` 上新增 registry 属性

在 `ClaudeService`（主文件或属性文件）中，在合适位置新增：

```swift
/// 当前活跃的 team session 虚拟 session 注册表。
/// launchTeamMission 使用，AgentTeamSessionView 读取用于 retention 同步。
let virtualSessionRegistry = AgentTeamVirtualSessionRegistry()
```

### Step 4：修改 `ClaudeService+TeamDispatch.launchTeamMission`

在 `launchTeamMission` 的 wave loop 中，找到：

```swift
                let batch = try coordinator.claimBatch(state: state)
```

替换为：

```swift
                let batch = try coordinator.claimBatch(
                    state: state,
                    virtualSessionRegistry: virtualSessionRegistry,
                    parentTeamSessionID: session.sessionId
                )
```

找到 dispatch 循环：

```swift
                // Dispatch each card sequentially; mark done after each execution completes
                for result in batch {
                    try await sendMessage(
                        text: result.missionPrompt,
                        session: session,
                        modelId: modelId,
                        modelContext: modelContext
                    )
                    try? coordinator.markCardDone(result.primaryCardID, in: state)
                    try? modelContext.save()
                }
```

替换为（区分单卡 vs. 多卡路径）：

```swift
                // Dispatch 路径：
                // - 单卡（batch.count == 1）：使用父 session ID，行为与之前完全相同
                // - 多卡（batch.count > 1）：使用虚拟 session ID，允许 scheduler 并发 admit
                for result in batch {
                    if batch.count > 1 {
                        try await sendTeamCardMessage(
                            schedulingSessionID: result.virtualSessionID,
                            text: result.missionPrompt,
                            session: session,
                            modelId: modelId,
                            providerReference: result.executionTarget.providerReference,
                            teamContext: result.executionTarget.teamContext,
                            modelContext: modelContext
                        )
                    } else {
                        try await sendMessage(
                            text: result.missionPrompt,
                            session: session,
                            modelId: modelId,
                            modelContext: modelContext
                        )
                    }
                    try? coordinator.markCardDone(result.primaryCardID, in: state)
                    try? modelContext.save()
                }
                // 多卡 wave 结束：释放本波虚拟 session（card 已标记 done）
                if batch.count > 1 {
                    for result in batch {
                        virtualSessionRegistry.release(for: result.primaryCardID)
                    }
                }
```

### Step 5：新增 `sendTeamCardMessage` 私有方法

在 `ClaudeService+TeamDispatch.swift` 或 `ClaudeService+Messaging.swift` 末尾添加（私有，仅供 TeamDispatch 使用）：

```swift
    /// 以指定的 schedulingSessionID 将 team card 任务提交到执行调度器。
    /// schedulingSessionID 作为 mailbox/scheduler key，使多卡并行 dispatch 不互相阻塞；
    /// 实际持久化 session 仍为 session.sessionId。
    private func sendTeamCardMessage(
        schedulingSessionID: String,
        text: String,
        session: Session,
        modelId: String,
        providerReference: ExecutionProviderReference,
        teamContext: AgentTeamExecutionContext?,
        modelContext: ModelContext
    ) async throws {
        let orchestrator = await resolveExecutionOrchestrator(for: modelContext)
        let sourceUserMessageID = resolveOrCreateSourceUserMessageID(
            text: text,
            session: session,
            modelContext: modelContext
        )
        let command = EnqueueExecutionCommand(
            sessionID: session.sessionId,
            schedulingSessionID: schedulingSessionID,
            providerReference: providerReference,
            payload: .userPrompt(
                text: text,
                modelID: modelId,
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                teamContext: teamContext
            ),
            sourceUserMessageID: sourceUserMessageID
        )
        _ = try await orchestrator.enqueue(command)
    }
```

### Step 6：运行测试验证通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-task5 \
  -only-testing:agentGuiTests/AgentTeamVirtualSessionRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：全部 PASS。

### Step 7：运行 Feature 8 相关测试（不应有 regression）

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-task5b \
  -only-testing:agentGuiTests/AgentTeamLaunchCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamCreativeParallelismTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：全部 PASS。

### Step 8：提交

```
git add agentGui/Services/ClaudeService/ClaudeService+TeamDispatch.swift \
        agentGui/Services/ClaudeService/ClaudeService+Messaging.swift \
        agentGui/Services/ClaudeService/ClaudeService.swift \
        agentGuiTests/AgentTeamVirtualSessionRegistryTests.swift
git commit -m "feat(f17): ClaudeService.virtualSessionRegistry + sendTeamCardMessage parallel dispatch"
```

---

## Task 6：`ConversationExecutionRuntimeCoordinator` 保活虚拟 session

**Files:**
- Modify: `agentGui/Services/ConversationExecutionRuntimeCoordinator.swift`

### 背景

当 N 张 task card 并行运行后，前 N-1 张完成时 `reconcileRuntimeRetention` 可能把对应的 ACP provider 进程 kill 掉，导致第 N 张卡运行中断。解决方案：`ScopeState` 新增 `teamActiveVirtualSessionIDs`，`retainedSessionIDs()` 将这些 ID 全部视为 retained，防止 provider 进程被提前释放。

`AgentTeamSessionView` 负责通过 `ClaudeService.virtualSessionRegistry` 实时更新这个集合（见 Task 7）。

### Step 1：写失败测试

在 `agentGuiTests/AgentTeamVirtualSessionRegistryTests.swift` **末尾追加**：

```swift
// MARK: - Task 6: RetentionCoordinator teamActiveVirtualSessionIDs

@Test
func runtimeCoordinatorRetainsTeamVirtualSessionIDs() async {
    // 构造一个仅含 builtIn scope 的 minimal registry
    let runtimeCoordinator = ConversationExecutionRuntimeCoordinator(
        runtimeSnapshotStore: InMemorySessionRuntimeSnapshotStore()
    )
    // 设置两个虚拟 session 为活跃
    runtimeCoordinator.setTeamActiveVirtualSessionIDs(
        ["vsid-A", "vsid-B"],
        scope: .builtIn  // 假设 builtIn scope
    )
    // 触发 reconcile，验证虚拟 ID 被保留（不被 release plan 删除）
    // 由于这是纯 unit 测试，用一个空的 registry + modelContext 验证 scope state
    let retainedIDs = runtimeCoordinator.retainedVirtualSessionIDs(scope: .builtIn)
    #expect(retainedIDs.contains("vsid-A"))
    #expect(retainedIDs.contains("vsid-B"))
}
```

> **注意**：这个测试可能需要 `ConversationExecutionRuntimeCoordinator` 暴露 `retainedVirtualSessionIDs(scope:)` 测试辅助方法，或通过 `@testable import` 访问内部状态。如果暴露 internal method 的代价太高，可跳过此单测，仅集成测试验证。

### Step 2：修改 `ConversationExecutionRuntimeCoordinator.ScopeState`

在 `private struct ScopeState` 中新增字段：

```swift
    private struct ScopeState {
        var foregroundSessionID: String?
        var executionLeaseProviderReferencesBySessionID: [String: Set<ExecutionProviderReference>] = [:]
        var retainedSessionIDs: Set<String> = []
        var teamActiveVirtualSessionIDs: Set<String> = []   // 新增
    }
```

### Step 3：修改 `retainedSessionIDs()` 私有方法，包含 `teamActiveVirtualSessionIDs`

在 `retainedSessionIDs(for:currentState:activatingSessionID:registry:)` 中，找到最后 `return retainedSessionIDs` 前，加入：

```swift
        // Feature 17: team 并行卡运行期间保活所有虚拟 session 对应的 provider
        retainedSessionIDs.formUnion(currentState.teamActiveVirtualSessionIDs)
```

### Step 4：新增公开方法 `setTeamActiveVirtualSessionIDs`

在 `ConversationExecutionRuntimeCoordinator` 中新增：

```swift
    /// 更新指定 scope 的活跃 team 虚拟 session ID 集合。
    /// 由 AgentTeamSessionView 在 registry 变化时调用，确保虚拟 session 对应的 provider 进程不被 kill。
    func setTeamActiveVirtualSessionIDs(_ ids: Set<String>, scope: ConversationExecutionRuntimeScope) {
        var state = scopeStates[scope] ?? ScopeState()
        state.teamActiveVirtualSessionIDs = ids
        scopeStates[scope] = state
    }
```

### Step 5：运行测试验证

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-task6 \
  -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamVirtualSessionRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：PASS（如有 `ConversationExecutionRuntimeCoordinatorTests` 存在则不 regression；否则只需新增测试通过）。

### Step 6：提交

```
git add agentGui/Services/ConversationExecutionRuntimeCoordinator.swift \
        agentGuiTests/AgentTeamVirtualSessionRegistryTests.swift
git commit -m "feat(f17): retain teamActiveVirtualSessionIDs in runtime coordinator"
```

---

## Task 7：`AgentTeamSessionView` 维护 `teamActiveVirtualSessionIDs`

**Files:**
- Modify: `agentGui/Views/Team/AgentTeamSessionView.swift`

### 背景

`AgentTeamSessionView` 需要感知 `ClaudeService.virtualSessionRegistry` 的变化，将当前活跃的虚拟 session ID 集合同步到 `executionRuntimeCoordinator`，确保 provider 进程保活。同时，`isExecuting` 需要同时检查父 session 和所有虚拟 session 的 projection 状态，确保 "执行中" 指示器在任意卡运行时都显示。

### Step 1：修改 `AgentTeamSessionView.isExecuting`

`isExecuting` 当前只读父 session ID，改为 OR 所有虚拟 session：

```swift
    private var isExecuting: Bool {
        // 检查父 session
        if claudeService.executionProjectionStore.projection(for: session.sessionId).isRunning {
            return true
        }
        // 检查所有活跃虚拟 session（Feature 17 多卡并行路径）
        let virtualIDs = claudeService.virtualSessionRegistry.activeVirtualSessionIDs(for: session.sessionId)
        return virtualIDs.contains { claudeService.executionProjectionStore.projection(for: $0).isRunning }
    }
```

### Step 2：新增 `.task` 同步 `teamActiveVirtualSessionIDs` 到 runtime coordinator

在 `AgentTeamSessionView.body` 末尾（在已有 `.task(id: session.sessionId)` 之后）新增：

```swift
        .task(id: claudeService.virtualSessionRegistry.sessions.keys.sorted().joined()) {
            // registry 内 sessions 变化时，同步活跃虚拟 session ID 到 runtime coordinator
            let activeIDs = claudeService.virtualSessionRegistry.activeVirtualSessionIDs(for: session.sessionId)
            // 同步给 executionRuntimeCoordinator 的所有 ACP scope
            // 注意：仅更新 externalACP scope（虚拟 session 只影响 ACP provider 进程保活）
            await claudeService.executionRuntimeCoordinator.setTeamActiveVirtualSessionIDs(
                activeIDs,
                scope: .externalACP
            )
        }
```

> **注意**：`claudeService.executionRuntimeCoordinator` 需要是可访问的（`internal` 或通过方法代理）。如果当前不可访问，通过 `ClaudeService` 新增代理方法 `updateTeamVirtualSessionRetention(teamSessionID:)` 封装。

### Step 3：新增 `ClaudeService` 代理方法（如需要）

如果 `executionRuntimeCoordinator` 不可从外部访问，在 `ClaudeService` 中新增：

```swift
    /// 同步 team 虚拟 session 保活状态到 runtime coordinator。
    /// 由 AgentTeamSessionView 调用，当 virtualSessionRegistry 变化时触发。
    func updateTeamVirtualSessionRetention(teamSessionID: String) async {
        let activeIDs = virtualSessionRegistry.activeVirtualSessionIDs(for: teamSessionID)
        let coordinator = executionRuntimeCoordinator
        // 更新所有 ACP scope（只在有活跃虚拟 session 时才有意义）
        coordinator.setTeamActiveVirtualSessionIDs(activeIDs, scope: .externalACP)
    }
```

然后将 `AgentTeamSessionView` 的 `.task` 改为调用此方法：

```swift
        .task(id: claudeService.virtualSessionRegistry.sessions.keys.sorted().joined()) {
            await claudeService.updateTeamVirtualSessionRetention(teamSessionID: session.sessionId)
        }
```

### Step 4：构建验证（无单测，行为通过集成测试覆盖）

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -derivedDataPath /tmp/agentGui-f17-task7 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：Build succeeded，无编译错误。

### Step 5：提交

```
git add agentGui/Views/Team/AgentTeamSessionView.swift \
        agentGui/Services/ClaudeService/ClaudeService.swift
git commit -m "feat(f17): sync teamActiveVirtualSessionIDs in AgentTeamSessionView"
```

---

## Task 8：`AgentTeamWorkbenchPresentation` 虚拟 session projection 路由

**Files:**
- Modify: `agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift`
- Modify: `agentGui/Views/Team/AgentTeamSessionView.swift`（传入新参数）

### 背景

当前 `AgentTeamBoardPanelView` 的"执行中"状态通过 `isExecuting: Bool`（全局 flag）传入。Feature 17 希望各 card 能独立显示各自的运行状态。`AgentTeamWorkbenchPresentation` 通过 registry 查找 card 对应的虚拟 session ID，然后读取对应的 projection 状态。

这是一个功能增强而非阻塞性 bug，如果时间有限可在 Feature 18 中补全。

### Step 1：扩展 `AgentTeamWorkbenchPresentation.BoardColumn.BoardCard`，新增 `isRunning: Bool`

在 `AgentTeamWorkbenchPresentation` 的内嵌类型中，找到代表 board card 的结构，新增 `isRunning: Bool = false` 字段。

### Step 2：修改 `AgentTeamWorkbenchPresentation.make()` 签名，增加可选 registry 和 projectionStore 参数

```swift
static func make(
    session: Session,
    state: AgentTeamSessionState?,
    virtualSessionRegistry: AgentTeamVirtualSessionRegistry? = nil,
    projectionStore: ExecutionProjectionStore? = nil,
    modelContext: ModelContext? = nil
) -> Self
```

### Step 3：在 `make()` 构建 board card 时写入 `isRunning`

在 card 构建循环中，查找 card 对应的虚拟 session ID：

```swift
let vsid = virtualSessionRegistry?.sessions.values
    .first(where: { $0.taskCardID == card.id })?.id
let isRunning: Bool
if let vsid, let projectionStore {
    isRunning = projectionStore.projection(for: vsid).isRunning
} else {
    isRunning = false
}
```

### Step 4：`AgentTeamSessionView` 传入 registry 和 projectionStore

更新 `presentation` 计算属性：

```swift
    private var presentation: AgentTeamWorkbenchPresentation {
        .make(
            session: session,
            state: state,
            virtualSessionRegistry: claudeService.virtualSessionRegistry,
            projectionStore: claudeService.executionProjectionStore,
            modelContext: modelContext
        )
    }
```

### Step 5：构建验证

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -derivedDataPath /tmp/agentGui-f17-task8 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：Build succeeded。

### Step 6：提交

```
git add agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift \
        agentGui/Views/Team/AgentTeamSessionView.swift
git commit -m "feat(f17): route per-card projection via virtualSessionID in WorkbenchPresentation"
```

---

## Task 9：完整测试套件运行 + 回归验证

**Files:** 无修改，仅运行

### Step 1：运行所有 Feature 17 相关测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-final \
  -only-testing:agentGuiTests/AgentTeamVirtualSessionRegistryTests \
  -only-testing:agentGuiTests/AgentTeamLaunchCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```

预期：全部 PASS。

### Step 2：运行 Feature 8 并行化涉及的现有测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-final2 \
  -only-testing:agentGuiTests/AgentTeamCreativeParallelismTests \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests \
  -only-testing:agentGuiTests/AgentTeamTaskBoardCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：全部 PASS，无 regression。

### Step 3：运行 Feature 8 Actorization Tests（跨 ACP actor 并发）

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-final3 \
  -only-testing:agentGuiTests/ACPProviderSessionActorTests \
  -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：全部 PASS。

### Step 4：最终提交标签

```
git tag feature/17-virtual-session-parallel-dispatch
```

---

## 验收标准核查

| 验收标准 | 验证方式 |
|---|---|
| 两张 `.working` task card 同时显示"执行中" | `AgentTeamVirtualSessionRegistryTests.allocateReturnsDifferentIDsForDifferentClaims` + WorkbenchPresentation `isRunning` per-card |
| `ExecutionScheduler.runningJobsBySessionID` 在并行执行期间包含至少两个不同虚拟 session ID | `schedulerAdmitsTwoJobsWithDifferentVirtualSessionIDs` 测试 |
| 一张 card 完成后，其他 card 继续执行，provider 进程未被 kill | `setTeamActiveVirtualSessionIDs` 纳入 `retainedSessionIDs`；`runtimeCoordinatorRetainsTeamVirtualSessionIDs` 测试 |
| Card 完成后，对应虚拟 session 从 registry 中移除，不造成内存泄漏 | `resolveReturnsNilAfterRelease`；`launchTeamMission` 末尾调用 `registry.release(for:)` |
| 单卡路径（Feature 4/13）行为无变化，不引入虚拟 session | `claimBatchSingleCardUsesParentSessionID`；向后兼容 init 默认参数 |

---

## 降级规则说明

| 场景 | 降级行为 |
|---|---|
| `claimBatch` 结果数 ≤ 1 | `virtualSessionID` = 父 team session ID，不分配虚拟 session，等同于现有行为 |
| `virtualSessionRegistry` 为 `nil` | 所有卡使用父 session ID，并行退化为串行 |
| registry 分配失败（理论上不会，分配是纯内存操作） | log 并回退到父 session ID |
| 调度器 `maxConcurrentJobs < 2` | scheduler 自动限制并发，但不影响正确性 |
| ACP provider CLI 不支持多 session 并发 | provider `maxConcurrentSessions ≤ 1` 时，`admitReadyJobs` 的 `providerSessionCount` 检查会阻塞；系统退化为串行，但不崩溃 |

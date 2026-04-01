# Feature 8: Execution Parallelism 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让 executionDelivery 模式下的多张独立 task card 由不同 eligible provider 分批认领并自动串行推进，支持 dependency-unlock 级联、`maxActiveProviders` 上限管控，并在 Board UI 上显示依赖锁定状态。

**Architecture:** 在现有 `AgentTeamLaunchCoordinator`（单卡 claim/dispatch）基础上新增批量认领方法和 dispatch wave 循环：`claimBatch` 一次认领所有可派发的 `.briefed` 卡、provider 按 `eligibleProviders` 数组 round-robin 分配；`ClaudeService+TeamDispatch.launchTeamMission` 改为 wave 循环（claim → beginWorking → dispatch all → markDone → repeat），在每张卡执行完成后自动 unlock 其下游依赖并触发下一批；Board 投影层增加 `isLocked` 字段，View 层展示锁定徽章。

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test` / `#expect`)，现有 `AgentTeamTaskBoardState`、`AgentTeamLaunchCoordinator`、`AgentTeamClaimCoordinator`、`ClaudeService+TeamDispatch`。

---

## 前置知识

### 已有相关文件

| 文件 | 作用 |
|---|---|
| `agentGui/Models/AgentTeamTaskBoard.swift` | `AgentTeamTaskCard`、`AgentTeamTaskBoardState`、`unresolvedDependencies(for:)` |
| `agentGui/Services/Team/AgentTeamLaunchCoordinator.swift` | 已有 `claimPrimaryCard`、`beginWorking`、`markCardDone` |
| `agentGui/Services/Team/AgentTeamClaimCoordinator.swift` | `acceptBestClaim(for:in:preferredProvider:updating:taskBoardCoordinator:)` |
| `agentGui/Services/Team/AgentTeamTaskBoardCoordinator.swift` | `transitionCard(_:to:in:)`，`transitionToWorking` 已校验 dependency |
| `agentGui/Services/ClaudeService/ClaudeService+TeamDispatch.swift` | `launchTeamMission` — 当前只派发一张卡 |
| `agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift` | `BoardCard`、`makeBoardColumns` |
| `agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift` | `AgentTeamBoardCardView` |
| `agentGuiTests/AgentTeamLaunchCoordinatorTests.swift` | 现有测试，需扩充 |
| `agentGuiTests/AgentTeamTaskBoardTests.swift` | 参考 `acceptedClaimFixture`、`#expect` 写法 |

### 当前行为 vs Feature 8 目标

| 方面 | 当前行为（Feature 1–6） | Feature 8 目标 |
|---|---|---|
| 认领数量 | `claimPrimaryCard` 只认领第一张 `.briefed` 卡 | `claimBatch` 认领所有满足 dependency 的 `.briefed` 卡（上限 `maxActiveProviders`） |
| Provider 分配 | 全部分配给 `preferredConductor` | Round-robin 分配 `eligibleProviders` |
| 卡完成后 | `markCardDone` 只更新状态，不派发后续 | 完成后自动触发下一批（dependency-unlock 级联） |
| UI 锁定状态 | `dependencySummary` 已有文本说明 | 新增 `isLocked: Bool`，Board 卡上显示锁定徽章 |

### 现有 `claimPrimaryCard` 不受影响

`claimPrimaryCard` 保留不变，供原有测试使用。`claimBatch` 是新增方法，`launchTeamMission` 切换为调用 `claimBatch`。

### 测试运行命令

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature8-exec-parallelism \
  -only-testing:agentGuiTests/AgentTeamTaskBoardTests \
  -only-testing:agentGuiTests/AgentTeamLaunchCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  CODE_SIGNING_ALLOWED=NO
```

---

## Task 1：`AgentTeamTaskBoardState.dispatchableCards(upTo:)`

**Files:**
- Modify: `agentGui/Models/AgentTeamTaskBoard.swift`
- Modify: `agentGuiTests/AgentTeamTaskBoardTests.swift`

### Step 1：写失败测试

在 `AgentTeamTaskBoardTests.swift` 末尾（`}` 之前）增加以下测试 struct：

```swift
// MARK: - AgentTeamTaskBoardDispatchableCardsTests

struct AgentTeamTaskBoardDispatchableCardsTests {

    // 没有 card 时返回空数组
    @Test
    func emptyBoardReturnsNoDispatchableCards() {
        let board = AgentTeamTaskBoardState(cards: [], claims: [])
        #expect(board.dispatchableCards(upTo: 2).isEmpty)
    }

    // 单张无依赖 briefed 卡，完整 budget
    @Test
    func singleBriefedCardWithNoDependenciesIsDispatchable() {
        let card = makeBriefedCard(id: uuid(1))
        let board = AgentTeamTaskBoardState(cards: [card], claims: [])
        #expect(board.dispatchableCards(upTo: 2).count == 1)
    }

    // 有未完成依赖的 briefed 卡不可派发
    @Test
    func briefedCardWithUnresolvedDependencyIsNotDispatchable() {
        let depCardID = uuid(1)
        let depCard = AgentTeamTaskCard(
            id: depCardID, title: "上游", goal: "上游任务",
            status: .working, owner: .builtIn, acceptedClaimID: UUID(),
            dependencyIDs: [], lastUpdatedAt: Date()
        )
        let childCard = makeBriefedCard(id: uuid(2), dependencyIDs: [depCardID])
        let board = AgentTeamTaskBoardState(cards: [depCard, childCard], claims: [])
        #expect(board.dispatchableCards(upTo: 2).isEmpty)
    }

    // 依赖已完成（.done）时可派发
    @Test
    func briefedCardWithResolvedDependencyIsDispatchable() {
        let depCardID = uuid(1)
        let depCard = AgentTeamTaskCard(
            id: depCardID, title: "上游", goal: "上游已完成",
            status: .done, owner: .builtIn, acceptedClaimID: UUID(),
            dependencyIDs: [], lastUpdatedAt: Date()
        )
        let childCard = makeBriefedCard(id: uuid(2), dependencyIDs: [depCardID])
        let board = AgentTeamTaskBoardState(cards: [depCard, childCard], claims: [])
        #expect(board.dispatchableCards(upTo: 2).count == 1)
    }

    // maxActiveProviders 限制 — 已有 1 个 active card，limit=1 → 返回空
    @Test
    func activeCardCountReducesDispatchableLimit() {
        let activeCard = AgentTeamTaskCard(
            id: uuid(1), title: "进行中", goal: "执行中",
            status: .working, owner: .builtIn, acceptedClaimID: UUID(),
            dependencyIDs: [], lastUpdatedAt: Date()
        )
        let waitingCard = makeBriefedCard(id: uuid(2))
        let board = AgentTeamTaskBoardState(cards: [activeCard, waitingCard], claims: [])
        #expect(board.dispatchableCards(upTo: 1).isEmpty)
    }

    // 3 张可派发卡，limit=2 → 只返回前 2 张
    @Test
    func dispatchableCappedByMaxActiveProviders() {
        let cards = [uuid(1), uuid(2), uuid(3)].map { makeBriefedCard(id: $0) }
        let board = AgentTeamTaskBoardState(cards: cards, claims: [])
        #expect(board.dispatchableCards(upTo: 2).count == 2)
    }

    // .claimed 卡也计入 active 数（占用 budget）
    @Test
    func claimedCardCountsAsActiveForBudget() {
        let claimedCard = AgentTeamTaskCard(
            id: uuid(1), title: "已认领", goal: "进入 claimed",
            status: .claimed, owner: .builtIn, acceptedClaimID: UUID(),
            dependencyIDs: [], lastUpdatedAt: Date()
        )
        let briefedCard = makeBriefedCard(id: uuid(2))
        let board = AgentTeamTaskBoardState(cards: [claimedCard, briefedCard], claims: [])
        #expect(board.dispatchableCards(upTo: 1).isEmpty)
    }

    // MARK: - Helpers

    private func uuid(_ n: UInt8) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02x", n))")!
    }

    private func makeBriefedCard(id: UUID, dependencyIDs: [UUID] = []) -> AgentTeamTaskCard {
        AgentTeamTaskCard(
            id: id, title: "任务 \(id.uuidString.prefix(4))", goal: "执行此任务",
            status: .briefed, owner: nil, acceptedClaimID: nil,
            dependencyIDs: dependencyIDs, lastUpdatedAt: Date()
        )
    }
}
```

### Step 2：运行测试，确认编译失败（`dispatchableCards` 未定义）

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature8-exec-parallelism \
  -only-testing:agentGuiTests/AgentTeamTaskBoardTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

Expected: 编译错误 `value of type 'AgentTeamTaskBoardState' has no member 'dispatchableCards'`

### Step 3：实现 `dispatchableCards(upTo:)`

在 `agentGui/Models/AgentTeamTaskBoard.swift` 的 `AgentTeamTaskBoardState` extension 末尾（`unresolvedDependencies` 之后）添加：

```swift
/// Returns `.briefed` cards that have all dependencies resolved,
/// limited to the remaining capacity given the current active count and `maxActiveProviders`.
///
/// "Active" includes both `.working` and `.claimed` cards.
func dispatchableCards(upTo maxActiveProviders: Int) -> [AgentTeamTaskCard] {
    let activeCount = cards.filter { $0.status == .working || $0.status == .claimed }.count
    let remaining = max(0, maxActiveProviders - activeCount)
    guard remaining > 0 else { return [] }
    return cards
        .filter { $0.status == .briefed }
        .filter { unresolvedDependencies(for: $0.id).isEmpty }
        .prefix(remaining)
        .map { $0 }
}
```

### Step 4：运行测试，确认全部通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature8-exec-parallelism \
  -only-testing:agentGuiTests/AgentTeamTaskBoardTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|BUILD"
```

Expected: 所有 `AgentTeamTaskBoardDispatchableCardsTests` 测试通过，原有测试也仍然通过。

### Step 5：Commit

```bash
git add agentGui/Models/AgentTeamTaskBoard.swift
git add agentGuiTests/AgentTeamTaskBoardTests.swift
git commit -m "feat(team): add dispatchableCards(upTo:) on AgentTeamTaskBoardState"
```

---

## Task 2：`AgentTeamLaunchCoordinator.claimBatch(state:)` — 多卡批量认领

**Files:**
- Modify: `agentGui/Services/Team/AgentTeamLaunchCoordinator.swift`
- Modify: `agentGuiTests/AgentTeamLaunchCoordinatorTests.swift`

### Step 1：写失败测试

在 `AgentTeamLaunchCoordinatorTests.swift` 内 `@MainActor struct AgentTeamLaunchCoordinatorTests` 的末尾添加以下测试（保留现有测试不变）：

```swift
// MARK: - claimBatch

@Test
func claimBatchReturnsEmptyWhenNoBriefedCards() throws {
    let state = makeState(maxActiveProviders: 2)
    // 把所有 briefed 卡设为 done
    guard var taskBoard = state.taskBoardState else {
        #expect(Bool(false), "Expected task board"); return
    }
    taskBoard.cards = taskBoard.cards.map {
        AgentTeamTaskCard(id: $0.id, title: $0.title, goal: $0.goal,
                          status: .done, owner: .builtIn, acceptedClaimID: UUID(),
                          dependencyIDs: $0.dependencyIDs, lastUpdatedAt: Date())
    }
    state.taskBoardState = taskBoard

    let results = try AgentTeamLaunchCoordinator().claimBatch(state: state)
    #expect(results.isEmpty)
}

@Test
func claimBatchClaimsAllDispatchableBriefedCardsUpToBudget() throws {
    // Brief 中有 2 张独立 briefed 卡，maxActiveProviders=2
    let state = makeStateWithTwoIndependentBriefedCards(maxActiveProviders: 2)

    let results = try AgentTeamLaunchCoordinator().claimBatch(state: state)

    #expect(results.count == 2)
    // 两张卡都应进入 .claimed 状态
    let claimedCount = state.taskBoardState?.cards.filter { $0.status == .claimed }.count ?? 0
    #expect(claimedCount == 2)
}

@Test
func claimBatchRespectsBudgetWhenAlreadyAtMax() throws {
    let state = makeStateWithTwoIndependentBriefedCards(maxActiveProviders: 1)

    let results = try AgentTeamLaunchCoordinator().claimBatch(state: state)

    // 只能认领 1 张（budget=1）
    #expect(results.count == 1)
}

@Test
func claimBatchAssignsProvidersRoundRobin() throws {
    // eligibleProviders = [.builtIn, acp(X)]，2 张卡
    let acpID = UUID()
    let state = makeStateWithTwoIndependentBriefedCards(
        maxActiveProviders: 2,
        eligibleProviders: [.builtIn, .externalACP(profileID: acpID)]
    )

    let results = try AgentTeamLaunchCoordinator().claimBatch(state: state)

    #expect(results.count == 2)
    let providers = results.map { $0.executionTarget.providerReference }
    #expect(providers[0] == .builtIn)
    #expect(providers[1] == .externalACP(profileID: acpID))
}

@Test
func claimBatchSetsStatusToActive() throws {
    let state = makeStateWithTwoIndependentBriefedCards(maxActiveProviders: 2)
    _ = try AgentTeamLaunchCoordinator().claimBatch(state: state)
    #expect(state.status == .active)
}

@Test
func claimBatchThrowsMissingBriefWhenBriefAbsent() throws {
    let session = Session.fixture(title: "Team", kind: .agentTeam)
    let state = AgentTeamSessionState(session: session, mode: .executionDelivery, status: .created)
    // no brief set

    #expect(throws: AgentTeamLaunchCoordinator.Error.missingBrief) {
        try AgentTeamLaunchCoordinator().claimBatch(state: state)
    }
}

@Test
func claimBatchSkipsCardsWithUnresolvedDependencies() throws {
    // 1 张主卡（.briefed，no deps） + 1 张依赖主卡的子卡（.briefed）
    let state = makeState(maxActiveProviders: 2)
    // bootstrapBoard 会生成 1 主卡 + acceptance criteria 子卡（依赖主卡）
    // 只有主卡无依赖，子卡有依赖 → claimBatch 只认领主卡

    let results = try AgentTeamLaunchCoordinator().claimBatch(state: state)

    // 主卡 1 张可派发（子卡依赖主卡，未完成）
    #expect(results.count == 1)
    guard let primaryCard = state.taskBoardState?.cards.first(where: { $0.dependencyIDs.isEmpty }) else {
        #expect(Bool(false), "Expected primary card with no deps"); return
    }
    #expect(results[0].primaryCardID == primaryCard.id)
}
```

同时在同一文件末尾（`AgentTeamLaunchCoordinatorTests` 之外）添加辅助工厂：

```swift
// MARK: - Test helpers for Feature 8

@MainActor
private extension AgentTeamLaunchCoordinatorTests {
    func makeStateWithTwoIndependentBriefedCards(
        maxActiveProviders: Int = 2,
        eligibleProviders: [ExecutionProviderReference] = [.builtIn]
    ) -> AgentTeamSessionState {
        let cardA = UUID()
        let cardB = UUID()
        let session = Session.fixture(title: "Team (Parallel)", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session, mode: .executionDelivery, status: .created)
        state.missionBrief = AgentTeamMissionBrief(
            objective: "并行执行两个独立子任务",
            constraints: [],
            acceptanceCriteria: [],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: maxActiveProviders,
                          tokenBudgetText: "20k", costBudgetText: "medium"),
            initialContextSummary: "",
            providerPlan: .init(
                eligibleProviders: eligibleProviders,
                preferredConductor: eligibleProviders.first ?? .builtIn,
                preferredReviewer: nil,
                dispatchPolicy: .autoClaim
            )
        )
        // 手动构造两张独立 briefed 卡（无依赖）
        let board = AgentTeamTaskBoardState(
            cards: [
                AgentTeamTaskCard(id: cardA, title: "子任务 A", goal: "执行 A",
                                  status: .briefed, owner: nil, acceptedClaimID: nil,
                                  dependencyIDs: [], lastUpdatedAt: Date()),
                AgentTeamTaskCard(id: cardB, title: "子任务 B", goal: "执行 B",
                                  status: .briefed, owner: nil, acceptedClaimID: nil,
                                  dependencyIDs: [], lastUpdatedAt: Date())
            ],
            claims: []
        )
        state.taskBoardState = board
        state.claimBoardState = board.claimBoardProjection
        return state
    }
}
```

### Step 2：运行测试，确认编译失败（`claimBatch` 未定义）

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature8-exec-parallelism \
  -only-testing:agentGuiTests/AgentTeamLaunchCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

Expected: 编译错误 `value of type 'AgentTeamLaunchCoordinator' has no member 'claimBatch'`

### Step 3：实现 `claimBatch(state:)` 与 `assignedProvider(at:eligibleProviders:)`

在 `agentGui/Services/Team/AgentTeamLaunchCoordinator.swift` 的 `// MARK: - Card Completion` 区域之前插入新的 `// MARK: - Batch Claim` 区域：

```swift
// MARK: - Batch Claim

/// Assigns a provider from `eligibleProviders` using round-robin by `cardIndex`.
/// Falls back to `.builtIn` when the list is empty.
func assignedProvider(
    at cardIndex: Int,
    eligibleProviders: [ExecutionProviderReference]
) -> ExecutionProviderReference {
    guard !eligibleProviders.isEmpty else { return .builtIn }
    return eligibleProviders[cardIndex % eligibleProviders.count]
}

/// Claims all dispatchable `.briefed` cards (no unresolved dependencies) up to
/// `brief.budget.maxActiveProviders`, assigns providers via round-robin from
/// `brief.providerPlan.eligibleProviders`, and advances each card to `.claimed`.
///
/// Returns a `ClaimPhaseResult` per claimed card. Returns `[]` when no dispatchable
/// cards remain (all done, all blocked, or budget exhausted).
///
/// Call `beginWorking(cardID:in:)` for each result after persisting the claimed state.
func claimBatch(state: AgentTeamSessionState) throws -> [ClaimPhaseResult] {
    guard let brief = state.missionBrief else {
        throw Error.missingBrief
    }

    let taskBoardCoordinator = AgentTeamTaskBoardCoordinator()
    let claimCoordinator = AgentTeamClaimCoordinator()
    let conductor = brief.providerPlan.preferredConductor
    let eligibleProviders = brief.providerPlan.eligibleProviders
    let maxActive = brief.budget.maxActiveProviders

    var taskBoard = state.taskBoardState
        ?? taskBoardCoordinator.bootstrapBoard(from: brief, preferredProvider: conductor)

    let dispatchable = taskBoard.dispatchableCards(upTo: maxActive)
    guard !dispatchable.isEmpty else {
        return []
    }

    var results: [ClaimPhaseResult] = []

    for (index, card) in dispatchable.enumerated() {
        let providerRef = assignedProvider(at: index, eligibleProviders: eligibleProviders)

        let claim = AgentTeamClaim(
            id: UUID(),
            providerReference: providerRef,
            taskCardID: card.id,
            confidence: 1.0,
            rationaleSummary: "Batch auto-claim for execution parallelism.",
            requiredCapabilities: [],
            expectedArtifacts: [],
            estimatedCostSummary: brief.budget.costBudgetText,
            status: .pending,
            submittedAt: Date()
        )
        taskBoard.claims.append(claim)

        let (_, updatedBoard) = try claimCoordinator.acceptBestClaim(
            for: card.id,
            in: taskBoard.claimBoardProjection,
            preferredProvider: providerRef,
            updating: taskBoard,
            taskBoardCoordinator: taskBoardCoordinator
        )
        taskBoard = updatedBoard

        guard let acceptedClaim = taskBoard.acceptedClaim(for: card.id) else { continue }

        let executionTarget = AgentTeamExecutionTarget(
            providerReference: providerRef,
            teamContext: AgentTeamExecutionContext(
                taskCardID: card.id,
                claimID: acceptedClaim.id
            )
        )
        let prompt = AgentTeamMissionPromptBuilder().buildPrompt(brief: brief, card: card)
        results.append(ClaimPhaseResult(
            primaryCardID: card.id,
            executionTarget: executionTarget,
            missionPrompt: prompt
        ))
    }

    state.taskBoardState = taskBoard
    state.claimBoardState = taskBoard.claimBoardProjection
    state.status = .active

    return results
}
```

### Step 4：运行测试，确认全部通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature8-exec-parallelism \
  -only-testing:agentGuiTests/AgentTeamLaunchCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|BUILD"
```

Expected: 所有新增 `claimBatch` 测试通过，原有测试仍然通过。

### Step 5：Commit

```bash
git add agentGui/Services/Team/AgentTeamLaunchCoordinator.swift
git add agentGuiTests/AgentTeamLaunchCoordinatorTests.swift
git commit -m "feat(team): add claimBatch with round-robin provider assignment"
```

---

## Task 3：Dispatch Wave 循环 — `ClaudeService+TeamDispatch` 更新

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+TeamDispatch.swift`

> 这一步没有纯单元测试（需要集成环境），通过编译+人工验证。

### Step 1：阅读现有实现（确认改动范围）

当前 `launchTeamMission` 结构：
1. `coordinator.claimPrimaryCard(state)` → 单卡
2. `try? modelContext.save()` + 400ms sleep
3. `coordinator.beginWorking(cardID:in:)`
4. `try? modelContext.save()`
5. `sendMessage(text: missionPrompt, ...)`

需要改为 wave 循环：
1. `coordinator.claimBatch(state)` → 多卡（可能为空 = 全部完成）
2. 持久化 + 400ms yield
3. 对每张卡 `coordinator.beginWorking(cardID:in:)`
4. 持久化
5. 对每张卡 `sendMessage`，每张完成后 `coordinator.markCardDone(cardID:in:)` + 持久化
6. 回到步骤 1，直到 `claimBatch` 返回空

### Step 2：替换 `launchTeamMission` 实现

将 `ClaudeService+TeamDispatch.swift` 中的 `launchTeamMission` 方法全部替换为：

```swift
/// Launches all ready task cards in waves:
///   Wave N:
///     1. claimBatch — claim all dispatchable `.briefed` cards (dependency-clear, within budget)
///     2. Save + 400ms yield — SwiftUI renders "Claimed" column
///     3. beginWorking for each card
///     4. Save
///     5. Dispatch each card sequentially via sendMessage
///     6. After each sendMessage returns, markCardDone + save
///   Repeat until claimBatch returns [] (no more eligible cards).
func launchTeamMission(
    session: Session,
    modelContext: ModelContext
) async throws {
    lastError = nil
    do {
        guard let state = session.agentTeamState else { return }
        let coordinator = AgentTeamLaunchCoordinator()
        let settings = AppSettings.getOrCreate(in: modelContext)
        let modelId = SessionExecutionPreferencesResolver.builtInModelID(
            for: session,
            settings: settings
        )

        // Wave dispatch loop
        while true {
            let batch = try coordinator.claimBatch(state: state)
            guard !batch.isEmpty else { break }

            // Persist claimed state so SwiftUI sees "Claimed" column
            try? modelContext.save()
            try? await Task.sleep(nanoseconds: 400_000_000) // 400 ms

            // Advance all claimed cards to .working
            for result in batch {
                try coordinator.beginWorking(cardID: result.primaryCardID, in: state)
            }
            try? modelContext.save()

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
            // Loop again — newly dependency-unlocked cards (if any) will be claimed next wave
        }
    } catch {
        lastError = error.localizedDescription
        throw error
    }
}
```

`stopTeamMission` 保持不变。

### Step 3：编译验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-feature8-exec-parallelism \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `BUILD SUCCEEDED`。

### Step 4：运行已有测试，确认无回归

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature8-exec-parallelism \
  -only-testing:agentGuiTests/AgentTeamLaunchCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamTaskBoardTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|BUILD"
```

### Step 5：Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+TeamDispatch.swift
git commit -m "feat(team): replace single-card dispatch with wave loop in launchTeamMission"
```

---

## Task 4：`BoardCard.isLocked` — 依赖锁定状态投影

**Files:**
- Modify: `agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift`
- Modify: `agentGuiTests/AgentTeamWorkbenchPresentationTests.swift`

### Step 1：写失败测试

在 `AgentTeamWorkbenchPresentationTests.swift` 中找到 `AgentTeamWorkbenchPresentationTests` struct，在末尾添加：

```swift
// MARK: - isLocked (Feature 8)

@Test
@MainActor
func boardCardIsLockedWhenBriefedAndHasUnresolvedDependency() throws {
    let session = Session.fixture(title: "Team", kind: .agentTeam)
    let state = AgentTeamSessionState(session: session, mode: .executionDelivery, status: .created)
    state.missionBrief = AgentTeamMissionBrief(
        objective: "依赖锁定测试",
        constraints: [], acceptanceCriteria: [],
        mode: .executionDelivery,
        budget: .init(maxActiveProviders: 2, tokenBudgetText: "10k", costBudgetText: "low"),
        initialContextSummary: ""
    )

    let parentID = UUID(uuidString: "aaaa0000-0000-0000-0000-000000000001")!
    let childID  = UUID(uuidString: "aaaa0000-0000-0000-0000-000000000002")!

    let board = AgentTeamTaskBoardState(
        cards: [
            AgentTeamTaskCard(id: parentID, title: "主卡", goal: "执行主任务",
                              status: .working, owner: .builtIn, acceptedClaimID: UUID(),
                              dependencyIDs: [], lastUpdatedAt: Date()),
            AgentTeamTaskCard(id: childID,  title: "子卡", goal: "执行子任务",
                              status: .briefed, owner: nil, acceptedClaimID: nil,
                              dependencyIDs: [parentID], lastUpdatedAt: Date())
        ],
        claims: []
    )
    state.taskBoardState = board
    state.claimBoardState = board.claimBoardProjection

    let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: state)
    let briefedColumn = presentation.boardColumns.first { $0.id == "briefed" }
    let childCard = briefedColumn?.cards.first { $0.id == childID.uuidString }

    #expect(childCard?.isLocked == true)
}

@Test
@MainActor
func boardCardIsNotLockedWhenBriefedWithNoUnresolvedDependency() throws {
    let session = Session.fixture(title: "Team", kind: .agentTeam)
    let state = AgentTeamSessionState(session: session, mode: .executionDelivery, status: .created)
    state.missionBrief = AgentTeamMissionBrief(
        objective: "无锁定测试",
        constraints: [], acceptanceCriteria: [],
        mode: .executionDelivery,
        budget: .init(maxActiveProviders: 2, tokenBudgetText: "10k", costBudgetText: "low"),
        initialContextSummary: ""
    )

    let cardID = UUID(uuidString: "bbbb0000-0000-0000-0000-000000000001")!
    let board = AgentTeamTaskBoardState(
        cards: [
            AgentTeamTaskCard(id: cardID, title: "独立卡", goal: "独立执行",
                              status: .briefed, owner: nil, acceptedClaimID: nil,
                              dependencyIDs: [], lastUpdatedAt: Date())
        ],
        claims: []
    )
    state.taskBoardState = board
    state.claimBoardState = board.claimBoardProjection

    let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: state)
    let briefedColumn = presentation.boardColumns.first { $0.id == "briefed" }
    let card = briefedColumn?.cards.first { $0.id == cardID.uuidString }

    #expect(card?.isLocked == false)
}

@Test
@MainActor
func boardCardIsNotLockedWhenDependencyIsDone() throws {
    let session = Session.fixture(title: "Team", kind: .agentTeam)
    let state = AgentTeamSessionState(session: session, mode: .executionDelivery, status: .created)
    state.missionBrief = AgentTeamMissionBrief(
        objective: "依赖已完成测试",
        constraints: [], acceptanceCriteria: [],
        mode: .executionDelivery,
        budget: .init(maxActiveProviders: 2, tokenBudgetText: "10k", costBudgetText: "low"),
        initialContextSummary: ""
    )

    let parentID = UUID(uuidString: "cccc0000-0000-0000-0000-000000000001")!
    let childID  = UUID(uuidString: "cccc0000-0000-0000-0000-000000000002")!

    let board = AgentTeamTaskBoardState(
        cards: [
            AgentTeamTaskCard(id: parentID, title: "已完成主卡", goal: "done",
                              status: .done, owner: .builtIn, acceptedClaimID: UUID(),
                              dependencyIDs: [], lastUpdatedAt: Date()),
            AgentTeamTaskCard(id: childID, title: "子卡", goal: "dep resolved",
                              status: .briefed, owner: nil, acceptedClaimID: nil,
                              dependencyIDs: [parentID], lastUpdatedAt: Date())
        ],
        claims: []
    )
    state.taskBoardState = board
    state.claimBoardState = board.claimBoardProjection

    let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: state)
    let briefedColumn = presentation.boardColumns.first { $0.id == "briefed" }
    let childCard = briefedColumn?.cards.first { $0.id == childID.uuidString }

    #expect(childCard?.isLocked == false)
}
```

### Step 2：运行测试，确认编译失败（`isLocked` 字段未定义）

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature8-exec-parallelism \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

Expected: 编译错误 `value of type 'BoardCard' has no member 'isLocked'`

### Step 3：在 `AgentTeamWorkbenchPresentation.BoardCard` 添加 `isLocked`

在 `agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift` 的 `struct BoardCard` 末尾加一个字段：

```swift
struct BoardCard: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String
    let owner: String
    let statusText: String
    let claimCountText: String
    let dependencySummary: String
    let blockerSummary: String?
    let artifactCountText: String
    let isLocked: Bool          // ← 新增：.briefed 且有未完成依赖时为 true
}
```

### Step 4：在 `makeBoardColumns` 中计算 `isLocked`

找到 `makeBoardColumns` 中的 `BoardCard(...)` 构造器（约 221 行），在 `unresolvedDependencies` 计算之后，补充 `isLocked`：

```swift
// 已有：
let unresolvedDependencies = board.unresolvedDependencies(for: card.id)
// 新增：
let isLocked = card.status == .briefed && !unresolvedDependencies.isEmpty

return BoardCard(
    id: card.id.uuidString,
    title: card.title,
    summary: card.goal,
    owner: ownerReference.map { displayName(for: $0, modelContext: modelContext) } ?? "待认领",
    statusText: title(for: status),
    claimCountText: "\(claims.count) 个 claim",
    dependencySummary: dependencySummary(for: card, unresolvedDependencies: unresolvedDependencies, in: board),
    blockerSummary: card.blockerSummary,
    artifactCountText: artifactCountText(artifactCount),
    isLocked: isLocked                         // ← 新增
)
```

同时在 `makeBoardColumns` 的占位符分支（`guard let board else { ... }`）中，占位 `BoardCard` 增加 `isLocked: false`：

```swift
BoardCard(
    id: "task-placeholder",
    title: "等待 task board 初始化",
    summary: "当前会话尚未生成可执行 task card。",
    owner: "待认领",
    statusText: title(for: .briefed),
    claimCountText: "0 个 claim",
    dependencySummary: "无依赖",
    blockerSummary: nil,
    artifactCountText: "无工件",
    isLocked: false                             // ← 新增
)
```

### Step 5：运行测试，确认全部通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature8-exec-parallelism \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|BUILD"
```

### Step 6：Commit

```bash
git add agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift
git add agentGuiTests/AgentTeamWorkbenchPresentationTests.swift
git commit -m "feat(team): add isLocked field to BoardCard for dependency-blocked briefed cards"
```

---

## Task 5：Board 卡 View 层 — 依赖锁定徽章

**Files:**
- Modify: `agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift`

> 纯 UI 变更，无单元测试，通过运行 app 验证渲染效果。

### Step 1：找到 `AgentTeamBoardCardView` 的 header 区域

在 `agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift` 中搜索 `AgentTeamBoardCardView`，找到 card title 行（`Text(card.title)`）。

当前 header 大致结构（参考现有代码）：
```swift
VStack(alignment: .leading, spacing: 4) {
    HStack {
        Text(card.title).font(.headline)
        // ... status badge 等
    }
    ...
}
```

### Step 2：在 title 行的 badge 区域添加 lock 图标

在 `card.title` 旁边（或 status badge 附近），在 `HStack` 中添加锁定徽章：

```swift
if card.isLocked {
    Image(systemName: "lock.fill")
        .foregroundStyle(.orange)
        .font(.caption)
        .help("此卡有未完成的上游依赖，无法派发")
}
```

将这段代码紧接在 `Text(card.title)` 之后、或放在 HStack 末尾 spacer 之前，保持现有布局不变。

### Step 3：编译验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-feature8-exec-parallelism \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `BUILD SUCCEEDED`。

### Step 4：Commit

```bash
git add agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift
git commit -m "feat(team-ui): show lock badge on briefed cards with unresolved dependencies"
```

---

## Task 6：全量验证

### Step 1：运行 Feature 8 全量测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature8-exec-parallelism \
  -only-testing:agentGuiTests/AgentTeamTaskBoardTests \
  -only-testing:agentGuiTests/AgentTeamLaunchCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:|BUILD"
```

Expected: 所有测试通过，无回归。

### Step 2：运行更宽泛的 AgentTeam 相关测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature8-exec-parallelism \
  -only-testing:agentGuiTests/AgentTeamTaskBoardCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamClaimCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests \
  -only-testing:agentGuiTests/AgentTeamMergeGateEvaluatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|BUILD"
```

Expected: 所有通过，无回归。

### Step 3：如有失败，定位并修复后重新提交

---

## 验收检查清单

完成所有 Task 后，对照设计文档 Feature 8 验收标准逐项确认：

| # | 验收标准 | 验证方式 |
|---|---|---|
| 1 | 两个以上 provider 能并行推进独立 cards | 创建有 2 张独立 briefed 卡的 team，执行 launch，观察两张卡均进入 Working |
| 2 | card 间依赖与阻塞可见 | 创建有依赖关系的 board，Briefed 列中子卡应显示锁定图标 |
| 3 | dependency-resolved 子卡在主卡 done 后自动派发 | 主卡完成后，观察子卡自动进入 Claimed → Working |
| 4 | `maxActiveProviders` 限制生效 | 设 maxActive=1，两张 briefed 独立卡 → 只有 1 张进入 Working |
| 5 | 所有卡完成后 team 状态变为 `.completed` | 全部 card done 后，Mission Header 显示"已完成" |

---

## 设计约束说明

1. **单会话顺序执行**：当前执行 runtime 每个 session 同一时刻只能有 1 个 running job（`ExecutionScheduler` per-session 约束）。因此 wave 内多张卡实际仍按顺序执行。Feature 8 实现的是**结构性并行**（多 owner + dependency-aware dispatch）而非**物理并发执行**，后者依赖未来 runtime 架构调整。

2. **`sendMessage` 使用 session 默认 modelId**：不同 owner 的 provider reference 已正确写入 task card 的 `owner` 字段和 claim 记录，但实际执行路径目前统一走 session 配置的 ACP 进程。真正的 per-card provider routing 将在后续迭代中实现。

3. **`claimPrimaryCard` 保留**：原有两步式单卡认领方法（`claimPrimaryCard` + `beginWorking`）保留不变，供旧测试和向后兼容使用。`launchTeamMission` 切换为 `claimBatch` + wave loop。

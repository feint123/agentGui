# F-B1 ContextWindowBudgetTracker 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 built-in agent loop 中建立显式的上下文窗口预算追踪系统，提供四级阈值状态（`normal`/`warning`/`critical`/`autoCompactReady`）和 diminishing returns 检测，当 agent 在 token 将尽时连续低效输出时主动停止。

**Architecture:** 分三层落地：(1) 纯值类型 `ContextWindowBudgetTracker`——无副作用的阈值计算器，从 Claude Code `autoCompact.ts` 的 `calculateTokenWarningState()` 移植；(2) `BudgetRunTracker`——每次 run 的可变 diminishing returns 状态，从 Claude Code `query/tokenBudget.ts` 的 `BudgetTracker` 移植；(3) 集成层——把新状态挂入 `AgentLoopRoundExecutor`、`BuiltInSessionExecutionContext`、`ContextUsageRingView`。

**Tech Stack:** Swift 6, SwiftUI, SwiftAnthropic（`AgentLoopRoundExecutor`、`AgentLoopRunState`、`BuiltInSessionExecutionContext`）

**Claude Code 对应源码（参考，不复制）:**
- `/Users/feint/Downloads/claude-code-source-code-main/src/services/compact/autoCompact.ts` — `calculateTokenWarningState()`, `getAutoCompactThreshold()`, `getEffectiveContextWindowSize()`
- `/Users/feint/Downloads/claude-code-source-code-main/src/query/tokenBudget.ts` — `BudgetTracker`, `checkTokenBudget()`, `DIMINISHING_THRESHOLD = 500`

---

## 常量说明

以下常量直接映射自 Claude Code 的 BQ 数据支撑值：

| 常量 | 值 | 来源 |
|------|-----|------|
| `maxOutputTokensReserved` | 20,000 | Claude Code `MAX_OUTPUT_TOKENS_FOR_SUMMARY = 20_000` |
| `autocompactBufferTokens` | 13,000 | Claude Code `AUTOCOMPACT_BUFFER_TOKENS = 13_000` |
| `warningBufferTokens` | 20,000 | Claude Code `WARNING_THRESHOLD_BUFFER_TOKENS = 20_000` |
| `diminishingDeltaThreshold` | 500 | Claude Code `DIMINISHING_THRESHOLD = 500` |
| `diminishingReturnsContinuationMin` | 3 | Claude Code `continuationCount >= 3` 时才启用检测 |

对于 Claude 3/4 系列（agentGui 当前默认 200k context）：
- `effectiveContextWindow` = 200_000 − 20_000 = **180,000**
- `autoCompactReady` 阈值 = 180,000 − 13,000 = **167,000**
- `warning` 阈值 = 180,000 − 20,000 = **160,000**（与 autoCompact 阈值之间的区间即 `critical` 区）
- `normal` ：< 160,000 tokens

---

## 集成点全貌

```
AgentLoopRoundExecutor.executeStreamingRound()
  └── countTokens() 返回 inputTokens
       ├── sharedState.setCurrentInputTokens(inputTokens)   ← 已有
       ├── [新增] tracker.evaluate(inputTokens, modelId)    ← Task 3
       │    └── sharedState.updateContextBudget(state)      ← Task 3
       └── [新增] runState.budgetRunTracker.recordRound      ← Task 4
            └── if isDiminishing: state.loopCtx.forceStop() ← Task 4

BuiltInSessionExecutionContext
  └── [新增] contextBudgetState: ContextBudgetState?        ← Task 3

ContextUsageRingView
  └── [修改] 使用 contextBudgetState.level 决定颜色         ← Task 5
```

---

## Task 1：ContextWindowBudgetTracker 核心类型与阈值计算

**Files:**
- Create: `agentGui/Services/ContextGovernance/ContextWindowBudgetTracker.swift`
- Test: `agentGuiTests/ContextWindowBudgetTrackerTests.swift`

---

**Step 1: 创建测试文件，写第一个失败测试（normal 级别）**

```swift
// agentGuiTests/ContextWindowBudgetTrackerTests.swift
import XCTest
@testable import agentGui

final class ContextWindowBudgetTrackerTests: XCTestCase {

    // MARK: - Helpers

    private let tracker = ContextWindowBudgetTracker()

    /// 200k context, 20k reserved → effectiveWindow = 180k
    /// warning 阈值 = 180k - 20k = 160k
    /// normal: tokenUsage < 160k

    func test_normal_whenTokensBelowWarningThreshold() {
        let state = tracker.evaluate(tokenUsage: 100_000, contextWindow: 200_000)
        XCTAssertEqual(state.level, .normal)
        XCTAssertFalse(state.isAutoCompactReady)
    }
}
```

**Step 2: 验证测试失败**

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ContextWindowBudgetTrackerTests \
  -derivedDataPath /tmp/agentGui-fb1-task1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAIL|PASS|Build"
```

期望：编译报错（类型未定义）。

**Step 3: 实现最小代码**

```swift
// agentGui/Services/ContextGovernance/ContextWindowBudgetTracker.swift
import Foundation

// MARK: - Constants
// 直接对应 Claude Code autoCompact.ts 中的值

private let kMaxOutputTokensReserved = 20_000   // MAX_OUTPUT_TOKENS_FOR_SUMMARY
private let kAutocompactBufferTokens  = 13_000   // AUTOCOMPACT_BUFFER_TOKENS
private let kWarningBufferTokens      = 20_000   // WARNING_THRESHOLD_BUFFER_TOKENS

// MARK: - BudgetLevel

/// 上下文预算的四级状态，对应 Claude Code calculateTokenWarningState() 的输出。
enum BudgetLevel: String, Equatable, Sendable {
    /// 使用量低于 warning 阈值，正常运行。
    case normal
    /// 使用量超过 warning 阈值，UI 可显示黄色警告。
    case warning
    /// 使用量超过 autoCompact 阈值，应触发自动压缩。
    case critical
    /// 使用量极高，超过 blocking 阈值，可能需要阻断继续运行。
    case autoCompactReady
}

// MARK: - ContextBudgetState

/// 一次 evaluate() 调用的完整输出快照。
struct ContextBudgetState: Equatable, Sendable {
    let tokenUsage: Int
    let contextWindow: Int
    let effectiveContextWindow: Int
    let level: BudgetLevel
    let percentRemaining: Int

    var isAutoCompactReady: Bool { level == .autoCompactReady || level == .critical }
}

// MARK: - ContextWindowBudgetTracker

/// 纯无副作用的上下文预算计算器。
/// 不持有状态，任意线程可安全调用。
struct ContextWindowBudgetTracker: Sendable {

    /// 从 token 用量和 context window 大小计算当前预算级别。
    /// - Parameters:
    ///   - tokenUsage: 当前请求的累计输入 token 数（来自 countTokens 或 usage 字段）。
    ///   - contextWindow: 模型标称 context window 大小（例如 200_000）。
    func evaluate(tokenUsage: Int, contextWindow: Int) -> ContextBudgetState {
        let effectiveWindow = max(contextWindow - kMaxOutputTokensReserved, 1)

        let autoCompactThreshold = effectiveWindow - kAutocompactBufferTokens
        let warningThreshold     = effectiveWindow - kWarningBufferTokens

        let percentRemaining = max(
            0,
            Int(round(Double(effectiveWindow - tokenUsage) / Double(effectiveWindow) * 100))
        )

        let level: BudgetLevel
        if tokenUsage >= autoCompactThreshold {
            level = .autoCompactReady
        } else if tokenUsage >= warningThreshold {
            // warning 与 autoCompact 阈值之间的区域，对应 Claude Code 的 isAboveWarningThreshold
            level = .critical
        } else if tokenUsage >= warningThreshold - kWarningBufferTokens / 2 {
            // 给 UI 一个宽裕的 early warning 区间
            level = .warning
        } else {
            level = .normal
        }

        return ContextBudgetState(
            tokenUsage: tokenUsage,
            contextWindow: contextWindow,
            effectiveContextWindow: effectiveWindow,
            level: level,
            percentRemaining: percentRemaining
        )
    }
}
```

> **⚠️ 注意：** 上面 `warning` 区间的定义是为了给 UI 提供一个宽裕的过渡区（70%~89%），与 Claude Code 只有 `warning/error/autoCompact` 三档的实现略有不同，主要是为了让 `ContextUsageRingView` 有更平滑的颜色过渡。以单元测试中的期望行为为准。

**Step 4: 验证 test_normal 通过后，补全其余阈值测试**

```swift
// 在 ContextWindowBudgetTrackerTests.swift 添加：

func test_warning_whenTokensInEarlyWarningZone() {
    // effectiveWindow = 180k, warning 阈值 = 160k
    // 早期警告区间: 160k - 20k/2 = 150k ~ 160k
    let state = tracker.evaluate(tokenUsage: 155_000, contextWindow: 200_000)
    XCTAssertEqual(state.level, .warning)
}

func test_critical_whenTokensAboveWarningThreshold() {
    // warning 阈值 (160k) 到 autoCompact 阈值 (167k) 之间
    let state = tracker.evaluate(tokenUsage: 163_000, contextWindow: 200_000)
    XCTAssertEqual(state.level, .critical)
    XCTAssertTrue(state.isAutoCompactReady)
}

func test_autoCompactReady_whenTokensAboveAutoCompactThreshold() {
    // autoCompact 阈值 = 200k - 20k - 13k = 167k
    let state = tracker.evaluate(tokenUsage: 168_000, contextWindow: 200_000)
    XCTAssertEqual(state.level, .autoCompactReady)
    XCTAssertTrue(state.isAutoCompactReady)
}

func test_percentRemaining_returnsCorrectValue() {
    // effectiveWindow = 180k, usage = 90k → 50% remaining
    let state = tracker.evaluate(tokenUsage: 90_000, contextWindow: 200_000)
    XCTAssertEqual(state.percentRemaining, 50)
}

func test_percentRemaining_clampedToZero_whenOverBudget() {
    let state = tracker.evaluate(tokenUsage: 190_000, contextWindow: 200_000)
    XCTAssertGreaterThanOrEqual(state.percentRemaining, 0)
}

func test_smallContextWindow_doesNotCrash() {
    // 极端情况：context window 小于 reserved tokens
    let state = tracker.evaluate(tokenUsage: 1_000, contextWindow: 4_096)
    XCTAssertNotNil(state)
}
```

**Step 5: 运行所有 Task 1 测试通过**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ContextWindowBudgetTrackerTests \
  -derivedDataPath /tmp/agentGui-fb1-task1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：所有测试 PASS。

**Step 6: Commit**

```bash
git add agentGui/Services/ContextGovernance/ContextWindowBudgetTracker.swift \
        agentGuiTests/ContextWindowBudgetTrackerTests.swift
git commit -m "feat(F-B1): add ContextWindowBudgetTracker with 4-level threshold system"
```

---

## Task 2：BudgetRunTracker — Diminishing Returns 检测

**Files:**
- Modify: `agentGui/Services/ContextGovernance/ContextWindowBudgetTracker.swift` （追加 `BudgetRunTracker`）
- Modify: `agentGuiTests/ContextWindowBudgetTrackerTests.swift` （追加测试）

---

**Step 1: 写失败测试**

```swift
// 在 ContextWindowBudgetTrackerTests.swift 追加：

final class BudgetRunTrackerTests: XCTestCase {

    func test_notDiminishing_whenContinuationCountLessThan3() {
        var tracker = BudgetRunTracker()
        _ = tracker.recordRound(currentGlobalTokens: 1_000)
        _ = tracker.recordRound(currentGlobalTokens: 1_200)
        let result = tracker.recordRound(currentGlobalTokens: 1_210)
        // continuationCount = 3? 还是说前两次的 delta 很小，第三次才开始检测？
        // 关键：检测需要 continuationCount >= 3 AND last two deltas < 500
        XCTAssertFalse(result.isDiminishing)
    }

    func test_notDiminishing_whenDeltaLargeEvenAfter3Rounds() {
        var tracker = BudgetRunTracker()
        // 3 次 delta 都超过 500
        _ = tracker.recordRound(currentGlobalTokens: 1_000)
        _ = tracker.recordRound(currentGlobalTokens: 2_000)  // delta=1000
        _ = tracker.recordRound(currentGlobalTokens: 3_100)  // delta=1100
        let result = tracker.recordRound(currentGlobalTokens: 4_300) // delta=1200
        XCTAssertFalse(result.isDiminishing)
    }

    func test_isDiminishing_whenContinuationCount3AndBothDeltasSmall() {
        // 对应 Claude Code: continuationCount >= 3 && deltaSinceLastCheck < 500 && lastDeltaTokens < 500
        var tracker = BudgetRunTracker()
        _ = tracker.recordRound(currentGlobalTokens: 100_000)
        _ = tracker.recordRound(currentGlobalTokens: 100_100) // delta=100 (small)
        _ = tracker.recordRound(currentGlobalTokens: 100_200) // delta=100 (small)
        let result = tracker.recordRound(currentGlobalTokens: 100_280) // delta=80 (small), count=3
        XCTAssertTrue(result.isDiminishing)
    }

    func test_notDiminishing_whenOnlyCurrentDeltaSmall() {
        // lastDeltaTokens 大，当前 delta 小 → 不触发
        var tracker = BudgetRunTracker()
        _ = tracker.recordRound(currentGlobalTokens: 100_000)
        _ = tracker.recordRound(currentGlobalTokens: 101_000) // delta=1000 (large)
        _ = tracker.recordRound(currentGlobalTokens: 101_100) // delta=100 (small)
        let result = tracker.recordRound(currentGlobalTokens: 101_180) // delta=80 (small)
        // continuationCount=3, currentDelta=80 (small), lastDelta=100 (small)
        // 两个 delta 都小 → isDiminishing
        // 注意：这个测试实际上期望 true，因为两个都 < 500
        XCTAssertTrue(result.isDiminishing)
    }

    func test_continuationCount_incrementsEachRound() {
        var tracker = BudgetRunTracker()
        _ = tracker.recordRound(currentGlobalTokens: 1_000)
        _ = tracker.recordRound(currentGlobalTokens: 1_500)
        let result = tracker.recordRound(currentGlobalTokens: 2_000)
        XCTAssertEqual(result.continuationCount, 3)
    }
}
```

**Step 2: 验证测试失败**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ContextWindowBudgetTrackerTests/BudgetRunTrackerTests \
  -derivedDataPath /tmp/agentGui-fb1-task2 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAIL"
```

期望：编译错误（`BudgetRunTracker` 未定义）。

**Step 3: 在 `ContextWindowBudgetTracker.swift` 末尾追加**

```swift
// MARK: - BudgetRunTracker

/// 单次 agent loop run 的 diminishing returns 检测器。
/// 每次 API 响应后调用 recordRound()；内部维护最多两个 delta 以检测连续低效输出。
///
/// 对应 Claude Code query/tokenBudget.ts 中的 BudgetTracker。
struct BudgetRunTracker: Sendable {

    private(set) var continuationCount: Int = 0
    private(set) var lastDeltaTokens: Int = 0
    private(set) var lastGlobalTurnTokens: Int = 0
    let startedAt: Date

    init(startedAt: Date = .now) {
        self.startedAt = startedAt
    }

    struct RoundResult: Equatable, Sendable {
        let continuationCount: Int
        let currentDeltaTokens: Int
        let isDiminishing: Bool
    }

    /// 记录一次 round 的 token 消耗并返回检测结果。
    /// - Parameter currentGlobalTokens: 本次 round 结束后的累计会话 token 数。
    @discardableResult
    mutating func recordRound(currentGlobalTokens: Int) -> RoundResult {
        let delta = currentGlobalTokens - lastGlobalTurnTokens

        // Diminishing returns 检测：
        // continuationCount 已经 >= 2（加上本次即 >= 3）
        // 且本次 delta 和上次 delta 都低于 DIMINISHING_THRESHOLD (500)
        let isDiminishing =
            continuationCount >= 2 &&
            delta < 500 &&
            lastDeltaTokens < 500

        continuationCount += 1
        lastDeltaTokens = delta
        lastGlobalTurnTokens = currentGlobalTokens

        return RoundResult(
            continuationCount: continuationCount,
            currentDeltaTokens: delta,
            isDiminishing: isDiminishing
        )
    }

    var durationMs: Int {
        Int(Date.now.timeIntervalSince(startedAt) * 1000)
    }
}
```

> **逻辑说明（对应 Claude Code）：**
> Claude Code 检测条件为 `continuationCount >= 3 && deltaSinceLastCheck < 500 && lastDeltaTokens < 500`。
> 在 `recordRound` 执行前，`continuationCount` 已经记录了之前的轮数。当 `continuationCount >= 2` 时，说明 `recordRound` 被调用了至少两次（第一次设为 1，第二次设为 2），本次是第三次调用，调用结束后 `continuationCount` 将变为 3。这样检测条件在本次调用时即可生效，与 Claude Code 的语义一致。

**Step 4: 运行所有测试通过**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ContextWindowBudgetTrackerTests \
  -derivedDataPath /tmp/agentGui-fb1-task2 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：全部 PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ContextGovernance/ContextWindowBudgetTracker.swift \
        agentGuiTests/ContextWindowBudgetTrackerTests.swift
git commit -m "feat(F-B1): add BudgetRunTracker with diminishing returns detection"
```

---

## Task 3：BuiltInSessionExecutionContext 扩展 + SharedStateAccess 更新

**Files:**
- Modify: `agentGui/Services/Execution/BuiltInSessionExecutionRegistry.swift`
- Modify: `agentGui/Models/AgentLoopSharedStateAccess.swift`
- Modify: `agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift`

---

**Step 1: 写测试验证 context 可以存储 budgetState**

在 `ContextWindowBudgetTrackerTests.swift` 添加集成层测试：

```swift
// 在 ContextWindowBudgetTrackerTests.swift 追加（独立 test class）：

@MainActor
final class BuiltInSessionContextBudgetTests: XCTestCase {

    func test_contextBudgetState_initiallyNil() async {
        let ctx = BuiltInSessionExecutionContext(sessionID: "test-session")
        XCTAssertNil(ctx.contextBudgetState)
    }

    func test_contextBudgetState_canBeSet() async {
        let ctx = BuiltInSessionExecutionContext(sessionID: "test-session")
        let tracker = ContextWindowBudgetTracker()
        let state = tracker.evaluate(tokenUsage: 50_000, contextWindow: 200_000)
        ctx.contextBudgetState = state
        XCTAssertEqual(ctx.contextBudgetState?.level, .normal)
    }
}
```

**Step 2: 验证测试失败**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ContextWindowBudgetTrackerTests/BuiltInSessionContextBudgetTests \
  -derivedDataPath /tmp/agentGui-fb1-task3 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAIL"
```

期望：编译错误（`contextBudgetState` 属性未定义）。

**Step 3: 修改 `BuiltInSessionExecutionRegistry.swift`**

```swift
// 在 BuiltInSessionExecutionContext 中添加一个属性：

@Observable
@MainActor
final class BuiltInSessionExecutionContext {
    let sessionID: String
    var currentInputTokens: Int = 0
    var currentModelID: String = ""
    var pendingUserQuestion: AskUserQuestionRequest?
    var contextBudgetState: ContextBudgetState?    // ← 新增

    init(sessionID: String) {
        self.sessionID = sessionID
    }
}
```

**Step 4: 修改 `AgentLoopSharedStateAccess.swift`**

```swift
// 在 AgentLoopSharedStateAccess 末尾添加一个新回调：

struct AgentLoopSharedStateAccess {
    let readVerification: @MainActor (String) -> CompletionVerification?
    let writeVerification: @MainActor (String, CompletionVerification) -> Void
    let readExecutionEvidence: @MainActor (String) -> Set<ExecutionEvidenceKind>
    let writeExecutionEvidence: @MainActor (String, Set<ExecutionEvidenceKind>) -> Void
    let readEpistemicInputs: @MainActor (String) -> [EpistemicInputEnvelope]
    let writeEpistemicInputs: @MainActor (String, [EpistemicInputEnvelope]) -> Void
    let setCurrentModelId: @MainActor (String) -> Void
    let setCurrentInputTokens: @MainActor (Int) -> Void
    let updateContextBudget: @MainActor (ContextBudgetState) -> Void   // ← 新增
}
```

**Step 5: 修改 `ClaudeService+AgenticLoop.swift`，填充新回调**

找到构造 `AgentLoopSharedStateAccess` 的位置（`setCurrentInputTokens` 那一行附近），追加：

```swift
// 找到这段代码：
setCurrentInputTokens: { self.builtInExecutionContext(for: runtime.sessionId).currentInputTokens = $0 }
// 在其后追加（注意保持尾随逗号正确）：
updateContextBudget: { [weak self] state in
    self?.builtInExecutionContext(for: runtime.sessionId).contextBudgetState = state
}
```

**Step 6: 运行测试通过**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ContextWindowBudgetTrackerTests \
  -derivedDataPath /tmp/agentGui-fb1-task3 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：全部 PASS（包括 BuiltInSessionContextBudgetTests）。

**Step 7: 验证编译无错误**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-fb1-task3-build \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

期望：`Build succeeded`。

**Step 8: Commit**

```bash
git add agentGui/Services/Execution/BuiltInSessionExecutionRegistry.swift \
        agentGui/Models/AgentLoopSharedStateAccess.swift \
        agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift
git commit -m "feat(F-B1): add contextBudgetState to BuiltInSessionExecutionContext and SharedStateAccess"
```

---

## Task 4：AgentLoopRoundExecutor 集成 + AgentLoopRunState 添加 BudgetRunTracker

**Files:**
- Modify: `agentGui/Models/AgentLoopRunState.swift`
- Modify: `agentGui/Services/AgentLoopRoundExecutor.swift`

---

**Step 1: 写集成测试（验证 diminishing returns 能让 loop 停止）**

创建新测试文件：

```swift
// agentGuiTests/ContextWindowBudgetIntegrationTests.swift
import XCTest
@testable import agentGui

final class ContextWindowBudgetIntegrationTests: XCTestCase {

    func test_budgetRunTracker_presentInInitialRunState() {
        let state = AgentLoopRunState()
        // budgetRunTracker 应存在，初始 continuationCount = 0
        XCTAssertEqual(state.budgetRunTracker.continuationCount, 0)
    }

    func test_diminishingReturns_detectedAfterThreeSmallDeltas() {
        var tracker = BudgetRunTracker()
        _ = tracker.recordRound(currentGlobalTokens: 100_000)
        _ = tracker.recordRound(currentGlobalTokens: 100_050) // delta=50
        let result = tracker.recordRound(currentGlobalTokens: 100_090) // delta=40
        // continuationCount 记录为 2 之前，isDiminishing 检测：count >= 2 && delta < 500 && last < 500
        XCTAssertTrue(result.isDiminishing, "连续两次小 delta 后应触发 diminishing returns")
    }
}
```

**Step 2: 验证测试失败**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ContextWindowBudgetIntegrationTests \
  -derivedDataPath /tmp/agentGui-fb1-task4 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAIL"
```

期望：编译错误（`budgetRunTracker` 属性未定义）。

**Step 3: 修改 `AgentLoopRunState.swift`，添加 budgetRunTracker**

```swift
// 在 AgentLoopRunState 结构体中添加属性：

struct AgentLoopRunState {
    let runID: String
    var accumulatedText: String
    var loopCtx: AgentLoopContext
    var loopMemory: ContextMemory
    var executionEvidence: Set<ExecutionEvidenceKind>
    var verificationState: VerificationState?
    let hookState: AgentLoopBuiltInHookFactory.State
    var budgetRunTracker: BudgetRunTracker    // ← 新增

    init(
        runID: String = UUID().uuidString,
        accumulatedText: String = "",
        loopCtx: AgentLoopContext = AgentLoopContext(phase: .executing),
        loopMemory: ContextMemory = ContextMemory(),
        executionEvidence: Set<ExecutionEvidenceKind> = [],
        verificationState: VerificationState? = nil,
        hookState: AgentLoopBuiltInHookFactory.State = AgentLoopBuiltInHookFactory.State(),
        budgetRunTracker: BudgetRunTracker = BudgetRunTracker()   // ← 新增
    ) {
        self.runID = runID
        self.accumulatedText = accumulatedText
        self.loopCtx = loopCtx
        self.loopMemory = loopMemory
        self.executionEvidence = executionEvidence
        self.verificationState = verificationState
        self.hookState = hookState
        self.budgetRunTracker = budgetRunTracker   // ← 新增
    }
}
```

**Step 4: 修改 `AgentLoopRoundExecutor.swift`，在 countTokens 后集成 budget tracking**

找到 `executeStreamingRound` 中的 `countTokens` 调用段（约 194-200 行）：

```swift
// 找到：
if let tokenCount = try? await request.service.countTokens(
    parameter: MessageTokenCountParameter(...)
) {
    sharedState.setCurrentInputTokens(tokenCount.inputTokens)
}
```

替换为（追加 budget 计算逻辑）：

```swift
if let tokenCount = try? await request.service.countTokens(
    parameter: MessageTokenCountParameter(
        model: .other(modelId),
        messages: messages,
        system: system,
        tools: tools.isEmpty ? nil : tools
    )
) {
    let inputTokens = tokenCount.inputTokens
    sharedState.setCurrentInputTokens(inputTokens)

    // F-B1: 计算 context budget 级别并更新 session 上下文
    let budgetTracker = ContextWindowBudgetTracker()
    let windowSize = claudeService.contextWindowSize(for: modelId)
    let budgetState = budgetTracker.evaluate(tokenUsage: inputTokens, contextWindow: windowSize)
    sharedState.updateContextBudget(budgetState)

    // F-B1: Diminishing returns 检测 — 每次 countTokens 后记录
    let roundResult = state.budgetRunTracker.recordRound(currentGlobalTokens: inputTokens)
    if roundResult.isDiminishing {
        await emitter.emit(
            .didDetectDiminishingReturns,
            state: state,
            messages: messages,
            overrides: .init(metadata: [
                "continuationCount": roundResult.continuationCount,
                "currentDeltaTokens": roundResult.currentDeltaTokens,
                "budgetLevel": budgetState.level.rawValue
            ])
        )
        state.loopCtx.forceStop(reason: "diminishing_returns")
    }
}
```

> **注意：** `AgentLoopHookEvent.didDetectDiminishingReturns` 和 `AgentLoopContext.forceStop(reason:)` 需要同步检查是否已存在。若不存在，只发 emit 部分即可，直接设置 `state.loopCtx.shouldContinue = false`。

**Step 4b: 检查并补充必要的类型扩展**

```bash
grep -n "shouldContinue\|forceStop\|didDetectDiminishing" \
  /Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopPhase.swift \
  /Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopRunState.swift \
  /Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHookEmitter.swift
```

若 `shouldContinue` 是 `AgentLoopContext` 上的计算属性，直接设置其底层 flag；若 `didDetectDiminishingReturns` 事件不存在，跳过 emit，只做停止逻辑。**不要因此往无关文件里加过多代码**——如果只需要 flag 停止，则直接 `state.loopCtx.shouldContinue` 对应字段设为 false 即可。

**Step 5: 运行测试通过**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ContextWindowBudgetIntegrationTests \
  -only-testing:agentGuiTests/ContextWindowBudgetTrackerTests \
  -derivedDataPath /tmp/agentGui-fb1-task4 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：全部 PASS。

**Step 6: 验证编译无错误**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-fb1-task4-build \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

**Step 7: Commit**

```bash
git add agentGui/Models/AgentLoopRunState.swift \
        agentGui/Services/AgentLoopRoundExecutor.swift \
        agentGuiTests/ContextWindowBudgetIntegrationTests.swift
git commit -m "feat(F-B1): integrate BudgetRunTracker into AgentLoopRunState and RoundExecutor"
```

---

## Task 5：ContextUsageRingView 更新 — 使用 BudgetLevel 决定颜色

**Files:**
- Modify: `agentGui/Views/ContextUsageRingView.swift`

---

**Step 1: 理解现有颜色逻辑**

当前实现（大约第 19-23 行）：
```swift
private var ringColor: Color {
    if ratio < 0.6 { return .green }
    if ratio < 0.8 { return .yellow }
    return .red
}
```

现在改为使用 `contextBudgetState.level` 来决定颜色，更准确地反映基于 token 绝对数量的阈值状态。

**Step 2: 修改 `ContextUsageRingView.swift`**

```swift
// 将原有 ringColor / statusLabel 计算属性改为基于 budgetLevel：

private var budgetLevel: BudgetLevel {
    service.builtInExecutionContext(for: sessionID).contextBudgetState?.level ?? .normal
}

private var ringColor: Color {
    switch budgetLevel {
    case .normal:          return .green
    case .warning:         return .yellow
    case .critical:        return .orange
    case .autoCompactReady: return .red
    }
}

private var statusLabel: String {
    switch budgetLevel {
    case .normal:          return "正常"
    case .warning:         return "较高"
    case .critical:        return "临近限制"
    case .autoCompactReady: return "需压缩"
    }
}
```

同时更新 tooltip 中显示 `percentRemaining`（如果存在 budgetState）：

```swift
// 在 tooltip/popover 中，原有的 windowSize 显示可以改为显示 percentRemaining：
private var percentRemainingLabel: String {
    if let pct = service.builtInExecutionContext(for: sessionID).contextBudgetState?.percentRemaining {
        return "\(pct)% 剩余"
    }
    return ""
}
```

**Step 3: 手动构建验证**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-fb1-task5-build \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

期望：`Build succeeded`，无 error。

**Step 4: 回归测试（确保已有测试不破坏）**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ContextWindowBudgetTrackerTests \
  -only-testing:agentGuiTests/ContextWindowBudgetIntegrationTests \
  -derivedDataPath /tmp/agentGui-fb1-task5 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

**Step 5: Commit**

```bash
git add agentGui/Views/ContextUsageRingView.swift
git commit -m "feat(F-B1): update ContextUsageRingView to use BudgetLevel for coloring"
```

---

## Task 6：清理与结项验证

**Files:**
- Read: `agentGui/Services/ContextGovernance/` （确认目录结构完整）
- Read: 测试报告

---

**Step 1: 验证 ContextGovernance 目录结构**

```bash
ls /Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ContextGovernance/
```

期望：
```
ContextWindowBudgetTracker.swift
```

**Step 2: 在 Xcode 项目中检查新文件是否已加入编译目标**

```bash
grep -l "ContextWindowBudgetTracker" \
  /Volumes/T7/文稿/Projects/agentGui/agentGui.xcodeproj/project.pbxproj
```

如果没有输出，说明文件已创建但未加入 Xcode target，需要在 Xcode 中手动 Add Files 或通过 `agentGui.xcodeproj/project.pbxproj` 添加文件引用。可以运行一次完整 build 来确认。

**Step 3: 完整编译通过**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-fb1-final-build \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning:|Build succeeded"
```

期望：`Build succeeded`，无 error。

**Step 4: 完整 F-B1 相关测试通过**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/ContextWindowBudgetTrackerTests \
  -only-testing:agentGuiTests/ContextWindowBudgetIntegrationTests \
  -derivedDataPath /tmp/agentGui-fb1-final \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

期望：全部 PASS。

**Step 5: Final Commit**

```bash
git add .
git commit -m "feat(F-B1): ContextWindowBudgetTracker complete — 4-level thresholds + diminishing returns detection"
```

---

## 验收标准对照

| 设计文档要求 | 实现对应 | 验证方式 |
|---|---|---|
| tracker 在 token 达到 warning 阈值（~85%）时更新状态为 `.warning` | `ContextWindowBudgetTracker.evaluate()` + `BuiltInSessionExecutionContext.contextBudgetState` | `ContextWindowBudgetTrackerTests.test_warning_*` |
| 视图层可响应式展示警告 | `ContextUsageRingView` 使用 `budgetLevel` 决定颜色 | 手动构建验证颜色变化 |
| diminishing returns 检测在连续低效输出后正确触发 stop | `BudgetRunTracker.recordRound()` + `AgentLoopRoundExecutor` 中检测 `isDiminishing` | `ContextWindowBudgetTrackerTests/BudgetRunTrackerTests.test_isDiminishing_*` |
| 单元测试覆盖边界条件 | Tasks 1-2 的所有测试 | 全部 PASS |

---

## 后续依赖提示

- **F-B3 (CompactionCoordinator)** 将订阅 `ContextBudgetState.isAutoCompactReady` 信号来触发压缩。届时可直接从 `BuiltInSessionExecutionContext.contextBudgetState` 读取，无需修改 F-B1 代码。
- **F-B5 (ToolBatchSummaryService)** 的触发时机与 token budget 无关，可独立并行开发。
- **F-E5 (WorkerIdentity 内存上限)** 同样独立，不依赖本 feature。

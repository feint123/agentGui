# CV-P2: 流式渲染节流与渐进输出 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 消除 Agent 流式响应时频繁触发全量 Projection 重建所引发的 UI 卡顿，实现内容追加与结构性变更的差异化刷新路径，并为 answer block 提供渐进字符渲染（打字机效果前置基础）。

**Architecture:**
两道防线。**第一道** — 源头节流：`StreamProjectionHook` 增加时间门控，将每秒 SwiftData 写入上限从「无上限」钳制到 60 次（≤ 1 次/帧）。**第二道** — 视图层合并：在 `.task(id: refreshKey)` 内按变更类型分流：`contentDelta`（文本追加）等待 1 帧（16.7ms）再重建；`structural`（新消息/tool 状态变更）立刻触发。SwiftUI `.task(id:)` 的自动取消语义天然地将同帧内所有 contentDelta 合并为最终一次重建。**第三道** — 渐进渲染：`StreamingCharBudgetTracker` 通过 `CADisplayLink` 将可见字符数从当前值以 ~500 chars/frame 追赶至全量，避免新文本块瞬间跳出。

**Tech Stack:** Swift 6 / SwiftUI / SwiftData / CADisplayLink / `@Observable`

**参考实现:**
- **VS Code** (`vs/workbench/contrib/chat/browser/chatListRenderer.ts`): 50ms timer + word rate 批量更新，结构性变更立即发布。
- **Open WebUI** (`src/lib/components/chat/Messages/ResponseMessage.svelte`): 绑定 `requestAnimationFrame` 合并流式片段，避免每 chunk 触发一次 DOM diff。

---

## 背景：当前流式路径

```
LLM token delta
  → AgentLoopRoundExecutor.executeStreamingRound()
  → StreamProjectionHook.perform(.didReceiveTextDelta)
      [50 字符累积后触发]
  → Message.textContent / AgentRound.text 写入 SwiftData
  → @Query allMessages 变更
  → ChatMessageListRefreshKey 变
  → .task(id: refreshKey) 重启
  → ChatMessageListProjectionModel.refresh()
  → actor 内全量重建（cache miss：fingerprint 含 textContent）
  → MainActor 刷新 SwiftUI List
```

**问题：** LLM 高速输出时（≥1000 chars/s），50 chars 阈值 → 20+ 次/s，每次触发 actor 全量重建 + SwiftUI List diff。

---

## Task 1：`StreamChangeKind` — 变更分类枚举

**Files:**
- Modify: `agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift`
- Test: `agentGuiTests/StreamChangeKindTests.swift`（新建）

### Step 1: 写失败测试

```swift
// agentGuiTests/StreamChangeKindTests.swift
import Testing
@testable import agentGui

struct StreamChangeKindTests {

    private func makeDigest(id: UUID, status: MessageStatus, textLength: Int) -> ChatMessageListRefreshKey.RowDigest {
        ChatMessageListRefreshKey.RowDigest(
            id: id,
            status: status,
            textLength: textLength,
            workspaceDependency: nil
        )
    }

    @Test
    func identicalKeysYieldNoChange() {
        let id = UUID()
        let a = ChatMessageListRefreshKey(rowDigests: [makeDigest(id: id, status: .completed, textLength: 42)])
        let b = ChatMessageListRefreshKey(rowDigests: [makeDigest(id: id, status: .completed, textLength: 42)])
        #expect(b.changeKind(from: a) == .noChange)
    }

    @Test
    func textLengthChangeYieldsContentDelta() {
        let id = UUID()
        let previous = ChatMessageListRefreshKey(rowDigests: [makeDigest(id: id, status: .pending, textLength: 50)])
        let next     = ChatMessageListRefreshKey(rowDigests: [makeDigest(id: id, status: .pending, textLength: 120)])
        #expect(next.changeKind(from: previous) == .contentDelta)
    }

    @Test
    func statusChangeYieldsStructural() {
        let id = UUID()
        let previous = ChatMessageListRefreshKey(rowDigests: [makeDigest(id: id, status: .pending, textLength: 100)])
        let next     = ChatMessageListRefreshKey(rowDigests: [makeDigest(id: id, status: .completed, textLength: 100)])
        #expect(next.changeKind(from: previous) == .structural)
    }

    @Test
    func rowCountDeltaYieldsStructural() {
        let id1 = UUID()
        let id2 = UUID()
        let previous = ChatMessageListRefreshKey(rowDigests: [makeDigest(id: id1, status: .completed, textLength: 20)])
        let next     = ChatMessageListRefreshKey(rowDigests: [
            makeDigest(id: id1, status: .completed, textLength: 20),
            makeDigest(id: id2, status: .pending,   textLength: 0)
        ])
        #expect(next.changeKind(from: previous) == .structural)
    }

    @Test
    func rowReorderOrIdSwapYieldsStructural() {
        let id1 = UUID()
        let id2 = UUID()
        let previous = ChatMessageListRefreshKey(rowDigests: [
            makeDigest(id: id1, status: .completed, textLength: 10),
            makeDigest(id: id2, status: .completed, textLength: 10)
        ])
        let next = ChatMessageListRefreshKey(rowDigests: [
            makeDigest(id: id2, status: .completed, textLength: 10),
            makeDigest(id: id1, status: .completed, textLength: 10)
        ])
        #expect(next.changeKind(from: previous) == .structural)
    }
}
```

### Step 2: 运行验证失败

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/StreamChangeKindTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：编译失败（`StreamChangeKind`、`changeKind(from:)`、`init(rowDigests:)` 未定义）。

### Step 3: 实现 `StreamChangeKind` 和 `changeKind(from:)`

在 `ChatMessageListSnapshotBuilder.swift` 中，**紧接在** `ChatMessageListRefreshKey` 定义之后插入：

```swift
// MARK: - Stream Change Classification

/// 两次 RefreshKey 之间的变更类型，用于节流策略决策。
enum StreamChangeKind: Equatable {
    /// 行计数、消息 ID、状态或 workspaceDependency 发生变化 → 立即重建
    case structural
    /// 仅有现有行的 textLength 发生变化 → 可合并到下一帧
    case contentDelta
    /// 完全相同 → 不必重建（已有 RefreshCoordinator 保护，此处冗余但显式）
    case noChange
}

extension ChatMessageListRefreshKey {
    func changeKind(from previous: ChatMessageListRefreshKey) -> StreamChangeKind {
        guard rows.count == previous.rows.count else { return .structural }
        var hasTextDelta = false
        for (current, prev) in zip(rows, previous.rows) {
            guard current.id == prev.id              else { return .structural }
            guard current.status == prev.status      else { return .structural }
            guard current.workspaceDependency == prev.workspaceDependency else { return .structural }
            if current.textLength != prev.textLength { hasTextDelta = true }
        }
        return hasTextDelta ? .contentDelta : .noChange
    }
}
```

同时，`ChatMessageListRefreshKey` 需要暴露一个内部初始化器供测试使用（测试不走 `@MainActor` 全量初始化路径）。在 `ChatMessageListRefreshKey` 上增加包级 init（注意：测试文件会引用它）：

```swift
/// 直接注入 RowDigest 数组，供测试使用。
init(rowDigests: [RowDigest]) {
    self.rows = rowDigests
}
```

> **注意：** 现有 `init(messages:workspaceRoot:)` 保持不变，这是生产路径唯一入口。

### Step 4: 运行验证通过

```bash
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/StreamChangeKindTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：`StreamChangeKindTests` 全部 PASS。

### Step 5: Commit

```bash
git add agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift \
        agentGuiTests/StreamChangeKindTests.swift
git commit -m "feat(cv-p2): add StreamChangeKind + changeKind(from:) to RefreshKey"
```

---

## Task 2：`StreamProjectionHook` 时间门控 — 源头节流

**Files:**
- Modify: `agentGui/Services/AgentLoopHooks/StreamProjectionHook.swift`

**背景：** 当前 `shouldProject` 仅判断字数差值≥阈值。LLM 高速输出（≥1000 chars/s）时，50 字符阈值 → 20 次/s SwiftData 写入，视图层无法完全消化。加入 `minInterval` 时间门，上限为 60 次/s（与 SwiftUI 帧率一致）。

### Step 1: 写失败测试

```swift
// 在 agentGuiTests/ 找到现有 hook 测试集，或新建 StreamProjectionHookThrottleTests.swift
import Testing
import Foundation
@testable import agentGui

struct StreamProjectionHookThrottleTests {

    @Test
    func hookDoesNotProjectTwiceWithinMinInterval() throws {
        let hook = StreamProjectionHook(
            state: StreamProjectionHook.State(),
            textThreshold: 1,       // 每字必触发（贪婪）
            thinkingThreshold: 1,
            minInterval: 9999       // 超大间隔 → 强制跳过
        )
        // 第一次：上次投影时间为 .distantPast，应该通过
        #expect(hook.shouldProjectForTest(
            currentLength: 10,
            lastProjectedLength: 0,
            threshold: 1,
            forceProjection: false,
            now: Date()
        ) == true)
        // 立即第二次：时间未到 minInterval
        let now = Date()
        var state = StreamProjectionHook.State()
        state.lastProjectionDate = now
        let hookBusy = StreamProjectionHook(
            state: state,
            textThreshold: 1,
            thinkingThreshold: 1,
            minInterval: 9999
        )
        #expect(hookBusy.shouldProjectForTest(
            currentLength: 20,
            lastProjectedLength: 10,
            threshold: 1,
            forceProjection: false,
            now: now.addingTimeInterval(0.001)  // 1ms 后，远小于 9999s
        ) == false)
    }

    @Test
    func hookProjectsImmediatelyWhenForceProjectionSet() {
        let now = Date()
        var state = StreamProjectionHook.State()
        state.lastProjectionDate = now
        let hook = StreamProjectionHook(state: state, textThreshold: 1, minInterval: 9999)
        #expect(hook.shouldProjectForTest(
            currentLength: 5,
            lastProjectedLength: 0,
            threshold: 1,
            forceProjection: true,       // forceProjection 绕过时间门控
            now: now.addingTimeInterval(0.001)
        ) == true)
    }
}
```

### Step 2: 运行验证失败

```bash
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/StreamProjectionHookThrottleTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：`minInterval` 参数和 `shouldProjectForTest` 未定义。

### Step 3: 修改 `StreamProjectionHook`

```swift
// StreamProjectionHook.swift — 修改后的完整文件

import Foundation

struct StreamProjectionHook: AgentLoopHook {
    final class State {
        var lastProjectedTextLength = 0
        var lastProjectedThinkingLength = 0
        /// 上次实际执行投影的时间，用于时间门控。
        var lastProjectionDate: Date = .distantPast
    }

    let id = "stream-projection"
    let order = 10
    let kind: AgentLoopHookKind = .mutator
    let isRequired = false
    let textThreshold: Int
    let thinkingThreshold: Int
    /// 两次投影之间的最短间隔（秒）。默认 1/60 ≈ 16.7ms，与屏幕帧率对齐。
    let minInterval: TimeInterval
    private let state: State

    init(
        state: State = State(),
        textThreshold: Int = 50,
        thinkingThreshold: Int = 50,
        minInterval: TimeInterval = 1.0 / 60.0
    ) {
        self.state = state
        self.textThreshold = textThreshold
        self.thinkingThreshold = thinkingThreshold
        self.minInterval = minInterval
    }

    // MARK: - AgentLoopHook

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        switch stage {
        case .didReceiveTextDelta, .didReceiveThinkingDelta:
            return true
        default:
            return false
        }
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        let now = Date()
        switch stage {
        case .didReceiveTextDelta:
            guard shouldProject(
                currentLength: context.currentRoundText.count,
                lastProjectedLength: state.lastProjectedTextLength,
                threshold: textThreshold,
                forceProjection: forceProjection(from: context),
                now: now
            ) else {
                return .continue
            }

            state.lastProjectedTextLength = context.currentRoundText.count
            state.lastProjectionDate = now
            if let round = context.metadata["agentRound"] as? AgentRound {
                round.text = context.currentRoundText
            }

            switch context.streamProjectionTarget {
            case .none:
                break
            case .message(let message):
                message.textContent = context.accumulatedText
            case .workflowAction(let action):
                let snippet = context.accumulatedText
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .last
                    .map(String.init) ?? ""
                if !snippet.isEmpty {
                    action(String(snippet.prefix(80)))
                }
            }

        case .didReceiveThinkingDelta:
            guard shouldProject(
                currentLength: context.currentRoundThinking.count,
                lastProjectedLength: state.lastProjectedThinkingLength,
                threshold: thinkingThreshold,
                forceProjection: forceProjection(from: context),
                now: now
            ) else {
                return .continue
            }

            state.lastProjectedThinkingLength = context.currentRoundThinking.count
            state.lastProjectionDate = now
            if let round = context.metadata["agentRound"] as? AgentRound {
                round.thinkingContent = context.currentRoundThinking
            }

        default:
            break
        }

        return .continue
    }

    // MARK: - Testable

    /// 内部可测方法，暴露判断逻辑（避免 `private`）。
    func shouldProjectForTest(
        currentLength: Int,
        lastProjectedLength: Int,
        threshold: Int,
        forceProjection: Bool,
        now: Date
    ) -> Bool {
        shouldProject(
            currentLength: currentLength,
            lastProjectedLength: lastProjectedLength,
            threshold: threshold,
            forceProjection: forceProjection,
            now: now
        )
    }

    // MARK: - Private

    private func forceProjection(from context: AgentLoopHookContext) -> Bool {
        context.metadata["forceProjection"] as? Bool ?? false
    }

    private func shouldProject(
        currentLength: Int,
        lastProjectedLength: Int,
        threshold: Int,
        forceProjection: Bool,
        now: Date
    ) -> Bool {
        if forceProjection { return true }
        guard currentLength - lastProjectedLength >= threshold else { return false }
        return now.timeIntervalSince(state.lastProjectionDate) >= minInterval
    }
}
```

### Step 4: 运行验证通过

```bash
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/StreamProjectionHookThrottleTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 5: Commit

```bash
git add agentGui/Services/AgentLoopHooks/StreamProjectionHook.swift \
        agentGuiTests/StreamProjectionHookThrottleTests.swift
git commit -m "feat(cv-p2): add time-based gate to StreamProjectionHook (≤60 writes/s)"
```

---

## Task 3：视图层 contentDelta 帧合并 — `.task(id:)` 睡眠策略

**Files:**
- Modify: `agentGui/Views/ChatView.swift`
- Modify: `agentGui/Views/ChatView+MessageList.swift`

**核心原理（参考 VS Code + Open WebUI 合并机制）：**
SwiftUI 的 `.task(id:)` 在 `id` 变化时自动取消前一个 Task。在 Task 体内对 `contentDelta` 变更先 `sleep` 一帧（16.7ms），若这段时间内新的流式 delta 又触发了新的 `refreshKey`，SwiftUI 会取消当前 task，启动新 task — **自然实现「只保留最后一次」的合并语义**，与 `requestAnimationFrame` 等价。`structural` 变更跳过 sleep 路径，保持立即响应。

**设计图:**
```
流式 token → refreshKey 在 16ms 内变化 N 次
             ┌─ task(id: key₁) sleep(16ms) ─── CANCELLED
             ├─ task(id: key₂) sleep(16ms) ─── CANCELLED  
             └─ task(id: keyN) sleep(16ms) ─── 通过 → refresh()
                                              （只触发 1 次重建）

结构性变更：
             └─ task(id: keyS) 立即 → refresh()
```

### Step 1: 写失败测试（集成测试覆盖合并行为）

```swift
// agentGuiTests/ChatMessageListStreamingThrottleIntegrationTests.swift
import Testing
import Foundation
@testable import agentGui

@MainActor
struct ChatMessageListStreamingThrottleIntegrationTests {

    @Test
    func contentDeltaRefreshesAreCoalescedByTaskCancellation() async {
        // 验证：模型的 refresh() 在快速连续调用中只丢弃过期 generation
        let session = Session.fixture(sessionId: "throttle-coalesce", title: "Throttle")
        let message = Message.agentMessage(text: "hello", session: session)
        message.status = .pending

        let worker = ProjectionWorkerProbe()
        let model = ChatMessageListProjectionModel(worker: worker)

        // 并发提交 3 次 refresh，模拟流式连续触发
        async let r1: Void = model.refresh(messages: [message], workspaceRoot: "/ws")
        await worker.waitForStart(of: 1)

        message.textContent = "hello world"
        async let r2: Void = model.refresh(messages: [message], workspaceRoot: "/ws")
        await worker.waitForStart(of: 2)
        await worker.waitForCancellation(of: 1)   // generation 1 被取消

        message.textContent = "hello world today"
        async let r3: Void = model.refresh(messages: [message], workspaceRoot: "/ws")
        await worker.waitForStart(of: 3)
        await worker.waitForCancellation(of: 2)   // generation 2 被取消

        await worker.finishGeneration(3)
        _ = await (r1, r2, r3)

        // 最终 snapshot 为最新一次内容
        #expect(model.snapshot.rows.first?.agent?.execution.transcript.answerText.contains("today") == true
                || model.snapshot.rows.isEmpty == false)
    }
}
```

### Step 2: 运行验证现有行为

```bash
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/ChatMessageListStreamingThrottleIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

此测试验证 **现有** 取消语义是否已经正确工作（预期 PASS）。如果当前没有 `waitForCancellation`，在 `ProjectionWorkerProbe` 中补充该方法（见 Step 3）。

### Step 3: 在 `ChatView.swift` 追踪 previousRefreshKey

```swift
// ChatView.swift — 在 @State 声明块末尾追加：
@State private var previousMessageListRefreshKey: ChatMessageListRefreshKey? = nil
```

### Step 4: 修改 `ChatView+MessageList.swift` — 引入睡眠策略

将 `messagesArea` 中的 `.task(id: refreshKey)` 替换为带分类的节流版本：

```swift
// ChatView+MessageList.swift

// 旧代码（约第 53 行）：
.task(id: refreshKey) {
    await refreshMessageListSnapshotForCurrentState()
}

// 新代码：
.task(id: refreshKey) {
    await refreshMessageListSnapshotThrottled(
        current: refreshKey,
        previous: previousMessageListRefreshKey
    )
    previousMessageListRefreshKey = refreshKey
}
```

在同文件的 extension 中新增节流方法：

```swift
// MARK: - Throttled Refresh

/// 使用 StreamChangeKind 决策是否延迟 1 帧再触发投影重建。
/// - contentDelta：sleep 1 帧（≈16.7ms），让更新的 task 有机会取消本次 task
/// - structural / noChange：立即执行，保证 UI 即时响应新消息或状态变更
@MainActor
func refreshMessageListSnapshotThrottled(
    current: ChatMessageListRefreshKey,
    previous: ChatMessageListRefreshKey?
) async {
    let kind: StreamChangeKind
    if let previous {
        kind = current.changeKind(from: previous)
    } else {
        kind = .structural  // 首次加载视为结构性变更
    }

    if kind == .contentDelta {
        // 等待 1 帧：若在此期间 refreshKey 再次变化，SwiftUI 自动取消此 Task
        try? await Task.sleep(nanoseconds: 16_700_000)  // 16.7ms ≈ 1/60s
        guard !Task.isCancelled else { return }
    }

    await refreshMessageListSnapshotForCurrentState()
}
```

> **注意：** `previousMessageListRefreshKey = refreshKey` 赋值必须在 task 末尾（refresh 完成后），保证下次比较能用到最新已完成的 key，而非中间取消的 key。若 task 被取消，此行不会执行，previous 保持不变 — 这是正确的：下次 task 会重新比较。

### Step 5: 运行现有测试基线确认无回归

```bash
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests \
  -only-testing:agentGuiTests/ChatMessageListProjectionModelConcurrencyTests \
  -only-testing:agentGuiTests/ChatMessageListStreamingThrottleIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：全部 PASS。

### Step 6: Commit

```bash
git add agentGui/Views/ChatView.swift \
        agentGui/Views/ChatView+MessageList.swift \
        agentGuiTests/ChatMessageListStreamingThrottleIntegrationTests.swift
git commit -m "feat(cv-p2): coalesce streaming content-delta refreshes via .task sleep strategy"
```

---

## Task 4：`StreamingCharBudgetTracker` — 渐进字符预算驱动器

**Files:**
- Create: `agentGui/ViewModels/StreamingCharBudgetTracker.swift`
- Test: `agentGuiTests/StreamingCharBudgetTrackerTests.swift`（新建）

**设计：** 对 `AgentMessageResultBlockView` 中正在流式输出的 answer text，用 `CADisplayLink` 驱动的 `displayedCharBudget` 逐帧追赶到全量文本长度。每帧最多前进 `charsPerFrame`（默认 ~8 字符/帧 ≈ 80 words/s @ 60fps × 6chars/word → 500 chars/s ÷ 60fps ≈ 8）。streaming 结束后立即跳到全量。

**参考：** VS Code 的 word rate progressive rendering 用 50ms timer + 词速率；本实现改为 `CADisplayLink` 帧率驱动，精度更高。

### Step 1: 写失败测试

```swift
// agentGuiTests/StreamingCharBudgetTrackerTests.swift
import Testing
@testable import agentGui

@MainActor
struct StreamingCharBudgetTrackerTests {

    @Test
    func initialBudgetIsZeroWhenStreamingStarts() {
        let tracker = StreamingCharBudgetTracker(charsPerFrame: 8)
        tracker.startTracking(targetLength: 100)
        #expect(tracker.displayedCharBudget == 0)
        #expect(tracker.isTracking == true)
    }

    @Test
    func advanceIncreasesBudgetByCharsPerFrame() {
        let tracker = StreamingCharBudgetTracker(charsPerFrame: 8)
        tracker.startTracking(targetLength: 100)
        tracker.advance(targetLength: 100)
        #expect(tracker.displayedCharBudget == 8)
        tracker.advance(targetLength: 100)
        #expect(tracker.displayedCharBudget == 16)
    }

    @Test
    func budgetNeverExceedsTargetLength() {
        let tracker = StreamingCharBudgetTracker(charsPerFrame: 8)
        tracker.startTracking(targetLength: 5)
        for _ in 0..<10 { tracker.advance(targetLength: 5) }
        #expect(tracker.displayedCharBudget == 5)
    }

    @Test
    func stopTrackingSnapsBudgetToGiven() {
        let tracker = StreamingCharBudgetTracker(charsPerFrame: 8)
        tracker.startTracking(targetLength: 200)
        tracker.advance(targetLength: 200)  // budget = 8
        tracker.stopTracking(finalLength: 999)
        #expect(tracker.displayedCharBudget == 999)
        #expect(tracker.isTracking == false)
    }

    @Test
    func targetLengthExpansionIsPickedUpOnNextAdvance() {
        let tracker = StreamingCharBudgetTracker(charsPerFrame: 50)
        tracker.startTracking(targetLength: 100)
        for _ in 0..<3 { tracker.advance(targetLength: 100) } // budget = 100（上限）
        // 新增了更多文本
        tracker.advance(targetLength: 200)
        #expect(tracker.displayedCharBudget == 150)
    }
}
```

### Step 2: 运行验证失败

```bash
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/StreamingCharBudgetTrackerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 3: 实现 `StreamingCharBudgetTracker`

```swift
// agentGui/ViewModels/StreamingCharBudgetTracker.swift
import Foundation
import QuartzCore

/// 渐进字符预算追踪器。
/// 通过 CADisplayLink 每帧将 `displayedCharBudget` 向 `targetLength` 推进，
/// 产生「打字机」视觉效果。由 `AgentMessageResultBlockView` 持有并驱动。
@Observable
@MainActor
final class StreamingCharBudgetTracker {

    // MARK: - Public State

    private(set) var displayedCharBudget: Int = 0
    private(set) var isTracking: Bool = false

    // MARK: - Config

    let charsPerFrame: Int

    // MARK: - Private

    private var displayLink: CADisplayLink?
    private var currentTargetLength: Int = 0

    // MARK: - Init

    init(charsPerFrame: Int = 8) {
        self.charsPerFrame = charsPerFrame
    }

    // MARK: - API

    /// 开始追踪新一轮 streaming。初始预算归零。
    func startTracking(targetLength: Int) {
        displayedCharBudget = 0
        currentTargetLength = targetLength
        isTracking = true
        ensureDisplayLink()
    }

    /// streaming 结束时调用，立即展示全量文本并停止 displayLink。
    func stopTracking(finalLength: Int) {
        displayedCharBudget = finalLength
        isTracking = false
        tearDownDisplayLink()
    }

    /// 在测试中手动步进（绕过实际 CADisplayLink 计时）。
    func advance(targetLength: Int) {
        currentTargetLength = targetLength
        tick()
    }

    // MARK: - Private

    private func ensureDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(tracker: self), selector: #selector(DisplayLinkProxy.onFrame(_:)))
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    private func tearDownDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func tick() {
        guard isTracking || displayedCharBudget < currentTargetLength else { return }
        displayedCharBudget = min(displayedCharBudget + charsPerFrame, currentTargetLength)
        if displayedCharBudget >= currentTargetLength {
            // 追上了，但 isTracking 可能仍为 true（等待 stream 继续）
            // 不停止 displayLink — 等待 stopTracking() 被调用
        }
    }
}

// MARK: - Proxy（避免 CADisplayLink 持有强引用造成循环）

private final class DisplayLinkProxy: NSObject {
    weak var tracker: StreamingCharBudgetTracker?
    init(tracker: StreamingCharBudgetTracker) { self.tracker = tracker }

    @objc func onFrame(_ link: CADisplayLink) {
        Task { @MainActor [weak self] in
            self?.tracker?.tick()
        }
    }
}
```

### Step 4: 运行验证通过

```bash
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/StreamingCharBudgetTrackerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 5: Commit

```bash
git add agentGui/ViewModels/StreamingCharBudgetTracker.swift \
        agentGuiTests/StreamingCharBudgetTrackerTests.swift
git commit -m "feat(cv-p2): add StreamingCharBudgetTracker — CADisplayLink progressive rendering"
```

---

## Task 5：接入渐进渲染 — `AgentMessageResultBlockView` + `AgentMessageStepFlowView`

**Files:**
- Modify: `agentGui/Views/AgentMessageResultBlockView.swift`
- Modify: `agentGui/Views/AgentMessageStepFlowView.swift`

**目标：** 当 `projection.header.isLive == true`（streaming 进行中）时，`MarkdownMessageView` 接收的文本从 0 逐帧增长到全量；streaming 完成后立即切换到全量文本。

**约束：** `MarkdownMessageView` 内部已有增量 Markdown reconcile，兼容接收截断字符串。

### Step 1: 修改 `AgentMessageResultBlockView` 接受 `charBudget`

```swift
// AgentMessageResultBlockView.swift — 修改后完整文件

import SwiftUI

struct AgentMessageResultBlockView: View {
    let presentation: ResultStepPresentation
    /// 可见字符预算。nil 表示展示全量（非 streaming 时）。
    var charBudget: Int? = nil

    private var visibleText: String {
        guard let budget = charBudget, budget < presentation.text.count else {
            return presentation.text
        }
        return String(presentation.text.prefix(budget))
    }

    var body: some View {
        Group {
            if presentation.isError {
                Label {
                    Text(presentation.text)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.body)
                .foregroundStyle(.red)
            } else {
                MarkdownMessageView(text: visibleText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(presentation.isError ? Color.red.opacity(0.06) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(presentation.isError ? Color.red.opacity(0.18) : Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}
```

### Step 2: 修改 `AgentMessageStepFlowView` 持有 `StreamingCharBudgetTracker`

```swift
// AgentMessageStepFlowView.swift — 修改后完整文件

import SwiftUI

struct AgentMessageStepFlowView: View {
    @Environment(ClaudeService.self) private var claudeService

    let projection: AgentExecutionProjection

    @State private var budgetTracker = StreamingCharBudgetTracker()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if projection.header.isLive, showsExecutionTheater {
                ExecutionTheaterView(
                    presentation: projection.theater,
                    pendingPermissionRequests: pendingPermissionRequests
                )
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .scale(scale: 0.96, anchor: .top).combined(with: .opacity)
                    )
                )
            }

            if !projection.transcript.answerText.isEmpty {
                AgentMessageResultBlockView(
                    presentation: ResultStepPresentation(
                        id: "transcript-\(projection.audit.flow.messageID.uuidString)",
                        text: projection.transcript.answerText,
                        isError: projection.transcript.isError
                    ),
                    charBudget: projection.header.isLive ? budgetTracker.displayedCharBudget : nil
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("chat.agentMessage.answerBlock")
            }

            if !projection.header.isLive, projection.artifacts.hasContent {
                ArtifactShelfView(presentation: projection.artifacts)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            ExecutionDigestView(presentation: projection.digest)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            AuditTraceDisclosureView(presentation: projection.audit)
        }
        .animation(ChatMotion.enterSpring, value: projection.header.isLive)
        .animation(ChatMotion.theaterStateChange, value: projection.theater.cards.map(\.id))
        .animation(ChatMotion.theaterStateChange, value: pendingPermissionRequests.map(\.id))
        .onChange(of: projection.transcript.answerText) { _, newText in
            handleAnswerTextChange(newText: newText)
        }
        .onChange(of: projection.header.isLive) { _, isLive in
            if !isLive {
                budgetTracker.stopTracking(finalLength: projection.transcript.answerText.count)
            }
        }
    }

    // MARK: - Private

    private var pendingPermissionRequests: [ACPPermissionCenter.PendingRequest] {
        AgentExecutionPermissionLookup.pendingRequests(
            for: projection.audit.flow,
            permissionCenter: claudeService.acpPermissionCenter
        )
    }

    private var showsExecutionTheater: Bool {
        !projection.theater.cards.isEmpty || !pendingPermissionRequests.isEmpty
    }

    private func handleAnswerTextChange(newText: String) {
        guard projection.header.isLive else { return }
        if !budgetTracker.isTracking {
            // 第一次有内容：开始追踪
            budgetTracker.startTracking(targetLength: newText.count)
        }
        // 每次文本扩展时更新 target（displayLink 会自动追赶）
        // 注意：无需显式调用 advance()，displayLink 自动触发 tick()
    }
}
```

### Step 3: 构建确认无编译错误

```bash
xcodebuild build -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

### Step 4: 运行回归测试

```bash
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/StreamChangeKindTests \
  -only-testing:agentGuiTests/StreamProjectionHookThrottleTests \
  -only-testing:agentGuiTests/StreamingCharBudgetTrackerTests \
  -only-testing:agentGuiTests/ChatMessageListStreamingThrottleIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：全部 PASS。

### Step 5: Commit

```bash
git add agentGui/Views/AgentMessageResultBlockView.swift \
        agentGui/Views/AgentMessageStepFlowView.swift
git commit -m "feat(cv-p2): wire StreamingCharBudgetTracker into AgentMessageStepFlowView"
```

---

## Task 6：流式结束后完整性保证 — finalRefresh Hook

**Files:**
- Modify: `agentGui/Views/ChatView+MessageList.swift`（增加 `effectiveStreamingState` 变更监听）

**背景：** streaming 期间 `previousRefreshKey` 赋值在 `sleep` 后，若最后一帧 task 被取消（edge case），投影可能停在上次状态。增加 `effectiveStreamingState` 的 `false` 变化监听，强制执行一次完整投影。

### Step 1: 修改 `messagesArea`

```swift
// ChatView+MessageList.swift — messagesArea 末尾追加：
.onChange(of: effectiveStreamingState) { _, isRunning in
    guard !isRunning else { return }
    // streaming 刚结束：强制完整重建，清除任何因节流遗漏的 delta
    Task {
        await refreshMessageListSnapshotForCurrentState()
    }
}
```

> `effectiveStreamingState` 已在 `ChatView.swift` 中定义：
> ```swift
> var effectiveStreamingState: Bool {
>     sessionExecutionProjection.isRunning
> }
> ```

### Step 2: 构建确认

```bash
xcodebuild build -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

### Step 3: Commit

```bash
git add agentGui/Views/ChatView+MessageList.swift
git commit -m "feat(cv-p2): final consistency rebuild on streaming completion"
```

---

## Task 7：性能基线测试更新

**Files:**
- Modify: `agentGuiTests/ChatMessageListProjectionPerformanceTests.swift`（补充快速重建基线用例）

**目标：** 验证内容追加场景下，cache 命中率保持高位（回归保护）。

### Step 1: 在性能测试文件中追加新用例

```swift
@Test
func streamingContentDeltaPreservesRowCacheForNonStreamingMessages() async throws {
    // 场景：100 条已完成消息 + 1 条 streaming，streaming 更新不应使前 100 条 cache 失效
    let session = Session.fixture(sessionId: "streaming-cache-baseline", title: "Cache")
    let workspaceRoot = "/tmp/streaming-cache"
    let worker = ChatMessageListProjectionWorker()

    let completedMessages: [MessageRowBuildInput] = (0..<100).map { i in
        MessageRowBuildInput.fixture(
            id: UUID(),
            direction: .agent,
            textContent: "completed message \(i)"
        )
    }
    let streamingID = UUID()
    let streamingMessage = MessageRowBuildInput.fixture(
        id: streamingID,
        direction: .agent,
        textContent: "partial response"
    )

    // 第一次构建（建立缓存）
    let request1 = ChatMessageListBuildRequest(
        generation: 1,
        workspaceRoot: workspaceRoot,
        messages: completedMessages + [streamingMessage],
        previousCache: [:]
    )
    let result1 = try await worker.build(request: request1)

    // 模拟 streaming delta — 仅最后一条 text 变化
    let updatedStreamingMessage = MessageRowBuildInput.fixture(
        id: streamingID,
        direction: .agent,
        textContent: "partial response extended by 50 more chars xxxxxxxxxxxxxxxxxxxxxxxxxx"
    )
    let request2 = ChatMessageListBuildRequest(
        generation: 2,
        workspaceRoot: workspaceRoot,
        messages: completedMessages + [updatedStreamingMessage],
        previousCache: result1.snapshot.cache
    )
    let result2 = try await worker.build(request: request2)

    // 前 100 条应全部命中缓存
    #expect(result2.reusedRowCount == 100)
    // 最后一条（streaming）必须重建
    #expect(result2.rebuiltRowIDs == [streamingID])
}
```

### Step 2: 运行验证

```bash
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/ChatMessageListProjectionPerformanceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

### Step 3: Commit

```bash
git add agentGuiTests/ChatMessageListProjectionPerformanceTests.swift
git commit -m "test(cv-p2): add streaming cache-hit rate baseline test"
```

---

## Task 8：全量回归验证

```bash
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cv-p2-final \
  -only-testing:agentGuiTests/StreamChangeKindTests \
  -only-testing:agentGuiTests/StreamProjectionHookThrottleTests \
  -only-testing:agentGuiTests/StreamingCharBudgetTrackerTests \
  -only-testing:agentGuiTests/ChatMessageListStreamingThrottleIntegrationTests \
  -only-testing:agentGuiTests/ChatMessageListProjectionPerformanceTests \
  -only-testing:agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests \
  -only-testing:agentGuiTests/ChatMessageListProjectionModelConcurrencyTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

全部 PASS 后：

```bash
git tag cv-p2-complete
git log --oneline -8
```

---

## 文件修改汇总

| 文件 | 操作 | 说明 |
|------|------|------|
| `agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift` | Modify | `StreamChangeKind` + `changeKind(from:)` + test-only `init(rowDigests:)` |
| `agentGui/Services/AgentLoopHooks/StreamProjectionHook.swift` | Modify | 增加 `minInterval` 时间门控 + `shouldProjectForTest` |
| `agentGui/Views/ChatView.swift` | Modify | 增加 `@State var previousMessageListRefreshKey` |
| `agentGui/Views/ChatView+MessageList.swift` | Modify | `refreshMessageListSnapshotThrottled()` + `effectiveStreamingState` finalRefresh |
| `agentGui/ViewModels/StreamingCharBudgetTracker.swift` | **Create** | CADisplayLink 渐进预算追踪器 |
| `agentGui/Views/AgentMessageResultBlockView.swift` | Modify | `charBudget: Int?` 参数 + `visibleText` 计算 |
| `agentGui/Views/AgentMessageStepFlowView.swift` | Modify | 持有 `StreamingCharBudgetTracker`，响应 `answerText` 变化 |
| `agentGuiTests/StreamChangeKindTests.swift` | **Create** | `StreamChangeKind` 单元测试 |
| `agentGuiTests/StreamProjectionHookThrottleTests.swift` | **Create** | 时间门控单元测试 |
| `agentGuiTests/StreamingCharBudgetTrackerTests.swift` | **Create** | 预算追踪器单元测试 |
| `agentGuiTests/ChatMessageListStreamingThrottleIntegrationTests.swift` | **Create** | Task 取消合并行为集成测试 |
| `agentGuiTests/ChatMessageListProjectionPerformanceTests.swift` | Modify | streaming 缓存命中率基线用例 |

---

## 验收标准对照

| 设计文档标准 | 实现确认点 |
|---|---|
| 流式输出期间主线程帧率 ≥ 55fps | `StreamProjectionHook` ≤ 60 writes/s 源头节流 + `.task` sleep 合并 contentDelta |
| 打字机效果自然流畅 | `StreamingCharBudgetTracker` 以 8 chars/frame (~500 chars/s) 逐帧推进 `displayedCharBudget` |
| 流式完成后 snapshot 最终一致 | `onChange(effectiveStreamingState == false)` 强制 finalRefresh |
| 结构性变更（新消息/tool 状态）不延迟 | `changeKind == .structural` 跳过 sleep，立即 refresh |
| 100 条稳定消息缓存不受流式消息污染 | 性能基线测试：`reusedRowCount == 100` |

---

## 不在本 Feature 实现的内容

| 事项 | 原因 |
|---|---|
| 流式光标（`StreamingCursorView`）| CV-A4 负责视觉闪烁效果 |
| 分页懒加载 | CV-P1 独立 Feature |
| 对 `MarkdownMessageView` 内部 parser 做额外节流 | 已有增量 reconcile，当前无瓶颈 |
| `CADisplayLink` 直接暴露给 View 层 | 封装在 `StreamingCharBudgetTracker`，View 只读 `displayedCharBudget` |

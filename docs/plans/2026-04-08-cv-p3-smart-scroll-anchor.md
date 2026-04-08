# CV-P3: 智能滚动锚定 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 重构 ChatView 的滚动策略，使用户回溯阅读时新消息不再强制跳底，并在右下角显示"↓ N 条新消息"badge，点击后恢复自动追踪。

**Architecture:** 将现有的布尔 flag + `onAppear/onDisappear` 锚点方案，升级为状态机驱动的滚动策略：`ChatScrollState` 枚举区分"追踪中"和"用户回溯"两个模式；`ChatMessageListAutoScrollPolicy` 扩展纯逻辑方法；新建 `NewMessagesBadgeView` overlay；`isProgrammaticMessageListScrollInFlight` 改为 `Task`-based 协程取消而非 `DispatchQueue.asyncAfter`。

**Tech Stack:** SwiftUI 6, Swift 6 strict concurrency, @Observable, SwiftTesting

**参考源码:**
- VS Code `chatListWidget.ts` — `_scrollLock`/`setScrollLock()`/`_withPersistedAutoScroll()` / `_isProgrammaticScroll` flag
- Open WebUI `Chat.svelte` — `autoScroll` reactive boolean, 50px lenient threshold, `requestAnimationFrame` scroll throttle
- 本项目现有: `ChatMessageListAutoScrollPolicy.swift`, `ChatView+MessageList.swift`, `ChatView.swift` (line 46–47), `ChatMotionTokens.swift`

---

## 现状说明

| 文件 | 相关内容 |
|------|---------|
| `agentGui/ViewModels/ChatMessageListAutoScrollPolicy.swift` | 现有策略枚举（静态方法，完整重写） |
| `agentGui/Views/ChatView+MessageList.swift` | 锚点 onAppear/onDisappear，scrollToBottom，两个 onChange |
| `agentGui/Views/ChatView.swift` L46–47 | `isMessageListPinnedToBottom`、`isProgrammaticMessageListScrollInFlight` |
| `agentGui/Views/ChatMotionTokens.swift` | `ChatMotion.scrollToBottom` token |

**已知缺陷（需修复）:**
1. `DispatchQueue.main.asyncAfter(0.3)` — streaming 高频时 flag 提前重置，导致用户轻微上滑即误判为"在底部"
2. `onChange(of: textContent)` 每个 delta 均触发 `proxy.scrollTo`，高频有额外性能压力
3. 用户回溯后新消息到来会被强制跳底（现有逻辑 `isUserMessage || isPinnedToBottom`）
4. 无新消息 badge，用户无法感知错过了多少条消息

---

## Task 1: 扩展 ChatScrollState 状态机

**Files:**
- Modify: `agentGui/ViewModels/ChatMessageListAutoScrollPolicy.swift`
- Test: `agentGuiTests/ChatMessageListAutoScrollPolicyTests.swift` ← 新建

### Step 1: 新建测试文件，写第一批 failing tests

```swift
// agentGuiTests/ChatMessageListAutoScrollPolicyTests.swift
import Testing
@testable import agentGui

struct ChatMessageListAutoScrollPolicyTests {

    // MARK: - ChatScrollState transitions

    @Test func trackingState_isTrackingBottom() {
        let state = ChatScrollState.tracking
        #expect(state.isTrackingBottom == true)
        #expect(state.isPaused == false)
    }

    @Test func pausedState_isNotTrackingBottom() {
        let state = ChatScrollState.paused(unseenCount: 3)
        #expect(state.isTrackingBottom == false)
        #expect(state.isPaused == true)
        #expect(state.unseenCount == 3)
    }

    @Test func pausedState_unseenCountZeroMeansNoBadge() {
        let state = ChatScrollState.paused(unseenCount: 0)
        #expect(state.showsBadge == false)
    }

    @Test func pausedState_unseenCountPositiveShowsBadge() {
        let state = ChatScrollState.paused(unseenCount: 2)
        #expect(state.showsBadge == true)
    }

    // MARK: - shouldScrollOnMessageAppend

    @Test func shouldScroll_whenTracking_andNewMessageArrives() {
        #expect(ChatMessageListAutoScrollPolicy.shouldScrollOnMessageAppend(
            scrollState: .tracking,
            lastMessageIsUser: false
        ) == true)
    }

    @Test func shouldNotScroll_whenPaused_andAgentReply() {
        #expect(ChatMessageListAutoScrollPolicy.shouldScrollOnMessageAppend(
            scrollState: .paused(unseenCount: 0),
            lastMessageIsUser: false
        ) == false)
    }

    @Test func shouldScroll_whenPaused_butNewMessageIsUser() {
        // User sent message → always scroll to show their own message
        #expect(ChatMessageListAutoScrollPolicy.shouldScrollOnMessageAppend(
            scrollState: .paused(unseenCount: 1),
            lastMessageIsUser: true
        ) == true)
    }

    // MARK: - shouldScrollForStreaming

    @Test func shouldStream_whenTracking() {
        #expect(ChatMessageListAutoScrollPolicy.shouldScrollForStreaming(
            scrollState: .tracking,
            isStreaming: true
        ) == true)
    }

    @Test func shouldNotStream_whenPaused() {
        #expect(ChatMessageListAutoScrollPolicy.shouldScrollForStreaming(
            scrollState: .paused(unseenCount: 0),
            isStreaming: true
        ) == false)
    }

    @Test func shouldNotStream_whenNotStreaming() {
        #expect(ChatMessageListAutoScrollPolicy.shouldScrollForStreaming(
            scrollState: .tracking,
            isStreaming: false
        ) == false)
    }

    // MARK: - incrementUnseenCount

    @Test func incrementUnseen_fromTracking_returnsPaused_count1() {
        let next = ChatMessageListAutoScrollPolicy.incrementUnseenCount(state: .tracking)
        #expect(next == .paused(unseenCount: 1))
    }

    @Test func incrementUnseen_fromPaused_incrementsCount() {
        let next = ChatMessageListAutoScrollPolicy.incrementUnseenCount(state: .paused(unseenCount: 4))
        #expect(next == .paused(unseenCount: 5))
    }

    @Test func incrementUnseen_capped_at99() {
        let next = ChatMessageListAutoScrollPolicy.incrementUnseenCount(state: .paused(unseenCount: 99))
        #expect(next == .paused(unseenCount: 99))
    }
}
```

### Step 2: Run to verify tests fail

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ChatMessageListAutoScrollPolicyTests \
  -derivedDataPath /tmp/agentGui-cv-p3-task1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: FAIL — `ChatScrollState` not found, `incrementUnseenCount` not found

### Step 3: 重写 `ChatMessageListAutoScrollPolicy.swift`

```swift
// agentGui/ViewModels/ChatMessageListAutoScrollPolicy.swift
import Foundation

// MARK: - Scroll State Machine

enum ChatScrollState: Equatable {
    case tracking
    case paused(unseenCount: Int)

    var isTrackingBottom: Bool { self == .tracking }
    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    var unseenCount: Int {
        if case .paused(let n) = self { return n }
        return 0
    }

    var showsBadge: Bool { unseenCount > 0 }

    var badgeLabel: String {
        unseenCount >= 99 ? "99+" : "\(unseenCount)"
    }
}

// MARK: - Policy (pure logic, no UI dependencies)

enum ChatMessageListAutoScrollPolicy {
    static let bottomAnchorID = "chat.messageList.bottomAnchor"

    /// 新消息到达时是否执行滚动
    static func shouldScrollOnMessageAppend(
        scrollState: ChatScrollState,
        lastMessageIsUser: Bool
    ) -> Bool {
        // 用户自己发的消息：始终滚动到底（让用户看到自己的输入）
        if lastMessageIsUser { return true }
        // 正在追踪底部：跟随
        return scrollState.isTrackingBottom
    }

    /// streaming delta 时是否执行滚动
    static func shouldScrollForStreaming(
        scrollState: ChatScrollState,
        isStreaming: Bool
    ) -> Bool {
        isStreaming && scrollState.isTrackingBottom
    }

    /// 用户回溯后新消息到达时累计未读计数
    /// - 若已在追踪状态则切换为 paused(1)
    /// - 若已暂停则 +1，上限 99
    static func incrementUnseenCount(state: ChatScrollState) -> ChatScrollState {
        switch state {
        case .tracking:
            return .paused(unseenCount: 1)
        case .paused(let n):
            return .paused(unseenCount: min(n + 1, 99))
        }
    }
}
```

### Step 4: Run tests to verify pass

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ChatMessageListAutoScrollPolicyTests \
  -derivedDataPath /tmp/agentGui-cv-p3-task1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: All `ChatMessageListAutoScrollPolicyTests` pass

### Step 5: Commit

```bash
git add agentGui/ViewModels/ChatMessageListAutoScrollPolicy.swift \
        agentGuiTests/ChatMessageListAutoScrollPolicyTests.swift
git commit -m "feat(CV-P3): introduce ChatScrollState machine + updated policy logic"
```

---

## Task 2: 新建 NewMessagesBadgeView

**Files:**
- Create: `agentGui/Views/NewMessagesBadgeView.swift`

> 无需 unit test（纯展示组件）；视觉正确性在 Task 4 集成后人工验证。

### Step 1: 新建文件

```swift
// agentGui/Views/NewMessagesBadgeView.swift
import SwiftUI

/// 当用户回溯阅读、底部有未读消息时，右下角浮现的引导 badge。
/// 点击后调用 onTap 回调（由父视图执行 scrollToBottom + 状态重置）。
struct NewMessagesBadgeView: View {
    let label: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                Text(label.isEmpty ? "新消息" : "\(label) 条新消息")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.85).combined(with: .opacity)
                    .animation(ChatMotion.enterSpring),
                removal: .scale(scale: 0.85).combined(with: .opacity)
                    .animation(.easeOut(duration: ChatMotion.exitDuration))
            )
        )
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 16) {
        NewMessagesBadgeView(label: "3", onTap: {})
        NewMessagesBadgeView(label: "99+", onTap: {})
        NewMessagesBadgeView(label: "", onTap: {})
    }
    .padding()
}
#endif
```

### Step 2: Build 验证编译通过

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-cv-p3-task2 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add agentGui/Views/NewMessagesBadgeView.swift
git commit -m "feat(CV-P3): add NewMessagesBadgeView overlay component"
```

---

## Task 3: 迁移 ChatView 状态变量

**Files:**
- Modify: `agentGui/Views/ChatView.swift` (L46–47)

将两个旧滚动 flag 替换为 `ChatScrollState` + `Task`-based programmatic guard，消除 `DispatchQueue.asyncAfter`。

### Step 1: 修改 ChatView.swift 状态声明

找到（约 L46–47）：
```swift
    @State var isMessageListPinnedToBottom = true
    @State var isProgrammaticMessageListScrollInFlight = false
```

替换为：
```swift
    @State var scrollState: ChatScrollState = .tracking
    @State var programmaticScrollTask: Task<Void, Never>?
```

> **说明:**
> - `scrollState` 替代了 `isMessageListPinnedToBottom`（`.tracking` ≡ pinned to bottom）
> - `programmaticScrollTask` 持有当前程序化滚动的 Task，取代不可靠的 `asyncAfter` 定时器

### Step 2: Build 确认编译错误定位正确（预期报错 isMessageListPinnedToBottom 未找到）

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep "error:" | head -20
```

Expected: 报错约 4–6 处引用旧变量名（在 ChatView+MessageList.swift）

---

## Task 4: 重构 ChatView+MessageList.swift

**Files:**
- Modify: `agentGui/Views/ChatView+MessageList.swift`

这是本 Feature 的核心修改。包含以下子改动：
1. `scrollToBottom` — 用 Task + `withCheckedContinuation` 替代 `asyncAfter`
2. 底部锚点 — `onDisappear` 改用 `scrollState` 进行判定
3. `onChange(of: allMessages.last?.id)` — 新消息到达时：追踪则滚底；回溯时累计 unseenCount
4. `onChange(of: allMessages.last?.textContent)` — streaming delta：保留逻辑
5. badge overlay — `ZStack` 包裹 List，右下角条件显示 `NewMessagesBadgeView`

### Step 1: 阅读 ChatView+MessageList.swift 165–215 行上下文（已在调研阶段完成）

### Step 2: 替换底部锚点的 onAppear/onDisappear

找到：
```swift
                    .onAppear {
                        isMessageListPinnedToBottom = true
                    }
                    .onDisappear {
                        if !isProgrammaticMessageListScrollInFlight {
                            isMessageListPinnedToBottom = false
                        }
                    }
```

替换为：
```swift
                    .onAppear {
                        // 底部锚点可见 → 恢复追踪，清零未读计数
                        scrollState = .tracking
                        programmaticScrollTask?.cancel()
                        programmaticScrollTask = nil
                    }
                    .onDisappear {
                        // 仅当不是程序化滚动引起的消失时，才切换为暂停
                        guard programmaticScrollTask == nil else { return }
                        if case .tracking = scrollState {
                            // 从追踪切到暂停（unseenCount 从 0 开始）
                            scrollState = .paused(unseenCount: 0)
                        }
                    }
```

### Step 3: 替换 onChange(of: allMessages.last?.id)

找到：
```swift
            .onChange(of: allMessages.last?.id) { _, _ in
                guard let last = allMessages.last else { return }
                if ChatMessageListAutoScrollPolicy.shouldScrollOnMessageAppend(
                    lastMessageIsUser: last.isUserMessage,
                    isPinnedToBottom: isMessageListPinnedToBottom
                ) {
                    scrollToBottom(proxy: proxy)
                }
            }
```

替换为：
```swift
            .onChange(of: allMessages.last?.id) { _, _ in
                guard let last = allMessages.last else { return }
                if ChatMessageListAutoScrollPolicy.shouldScrollOnMessageAppend(
                    scrollState: scrollState,
                    lastMessageIsUser: last.isUserMessage
                ) {
                    scrollToBottom(proxy: proxy)
                } else {
                    // 用户正在回溯 → 累计未读数（仅对 agent 回复计数）
                    if !last.isUserMessage {
                        scrollState = ChatMessageListAutoScrollPolicy.incrementUnseenCount(state: scrollState)
                    }
                }
            }
```

### Step 4: 替换 onChange(of: allMessages.last?.textContent)

找到：
```swift
            .onChange(of: allMessages.last?.textContent) { _, _ in
                if ChatMessageListAutoScrollPolicy.shouldScrollForStreaming(
                    isStreaming: effectiveStreamingState,
                    isPinnedToBottom: isMessageListPinnedToBottom
                ) {
                    scrollToBottom(proxy: proxy)
                }
            }
```

替换为：
```swift
            .onChange(of: allMessages.last?.textContent) { _, _ in
                if ChatMessageListAutoScrollPolicy.shouldScrollForStreaming(
                    scrollState: scrollState,
                    isStreaming: effectiveStreamingState
                ) {
                    scrollToBottom(proxy: proxy)
                }
            }
```

### Step 5: 替换 scrollToBottom 函数实现

找到：
```swift
    func scrollToBottom(proxy: ScrollViewProxy) {
        isProgrammaticMessageListScrollInFlight = true
        withAnimation(ChatMotion.scrollToBottom) {
            proxy.scrollTo(ChatMessageListAutoScrollPolicy.bottomAnchorID, anchor: .bottom)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isProgrammaticMessageListScrollInFlight = false
        }
    }
```

替换为：
```swift
    func scrollToBottom(proxy: ScrollViewProxy) {
        // 取消之前未完成的程序化滚动保护
        programmaticScrollTask?.cancel()
        programmaticScrollTask = Task { @MainActor in
            withAnimation(ChatMotion.scrollToBottom) {
                proxy.scrollTo(ChatMessageListAutoScrollPolicy.bottomAnchorID, anchor: .bottom)
            }
            // 等待动画完成（0.25s）后释放保护 flag
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            programmaticScrollTask = nil
        }
    }
```

> **为什么 280ms:** `ChatMotion.scrollToBottom` 是 `easeOut(duration: 0.22)`，加 60ms 余量确保锚点 onAppear 先触发。

### Step 6: 用 ZStack 包裹 List，添加 badge overlay

在 `messageListView` 的 body 内，找到 `ScrollViewReader` 的顶层 return 结构：

定位 `messageListView` computed var 的 returns（约框架顶部），将整个 `ScrollViewReader` 包裹在 `ZStack(alignment: .bottomTrailing)` 中，并在底部追加 badge：

```swift
    @ViewBuilder
    var messageListView: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollViewReader { proxy in
                List {
                    // ... existing List content (unchanged) ...
                }
                .listStyle(.plain)
                .accessibilityIdentifier("chat.messageList")
                .onChange(of: allMessages.last?.id) { /* ... */ }
                .onChange(of: allMessages.last?.textContent) { /* ... */ }
            }

            // New messages badge — shown when user is reading history
            if case .paused(let count) = scrollState, count > 0 {
                NewMessagesBadgeView(
                    label: count >= 99 ? "99+" : "\(count)"
                ) {
                    // Reset state first so onAppear doesn't see paused
                    scrollState = .tracking
                    // Scroll using a temporary proxy — embed in GeometryReader workaround
                    // handled via scrollTrigger state below
                    scrollToBadgeBottom = true
                }
                .padding(.trailing, 16)
                .padding(.bottom, 12)
                .accessibilityIdentifier("chat.newMessagesBadge")
                .animation(ChatMotion.enterSpring, value: count)
            }
        }
    }
```

**注意:**  SwiftUI 的 `ScrollViewProxy` 只能在 `ScrollViewReader` 闭包内调用，badge 的 `onTap` 在 ZStack overlay 层无法直接访问 `proxy`。解决方案：增加一个 `@State var scrollToBadgeBottom = false`，在 `ScrollViewReader` 闭包内 `.onChange(of: scrollToBadgeBottom)` 监听。

在 `ChatView.swift` 的 State 区域新增：
```swift
    @State var scrollToBadgeBottom = false
```

在 `ScrollViewReader` 闭包内的 List 末尾 `.onChange` 之后追加：
```swift
            .onChange(of: scrollToBadgeBottom) { _, newValue in
                guard newValue else { return }
                scrollToBadgeBottom = false
                scrollToBottom(proxy: proxy)
            }
```

badge 的 `onTap` 闭包：
```swift
                ) {
                    scrollState = .tracking
                    scrollToBadgeBottom = true
                }
```

### Step 7: Build 验证

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED

### Step 8: Commit

```bash
git add agentGui/Views/ChatView.swift \
        agentGui/Views/ChatView+MessageList.swift
git commit -m "feat(CV-P3): refactor scroll anchor to ChatScrollState + NewMessagesBadge"
```

---

## Task 5: 补充测试

**Files:**
- Test: `agentGuiTests/ChatMessageListAutoScrollPolicyTests.swift` (追加 edge-case tests)
- Test: `agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests.swift` (追加一个回归测试)

### Step 1: 追加 edge-case tests 到已有测试文件

在 `ChatMessageListAutoScrollPolicyTests.swift` 末尾追加：

```swift
    // MARK: - Edge cases

    @Test func shouldScroll_userMessage_alwaysTrue_evenWhenPaused_highUnseenCount() {
        #expect(ChatMessageListAutoScrollPolicy.shouldScrollOnMessageAppend(
            scrollState: .paused(unseenCount: 50),
            lastMessageIsUser: true
        ) == true)
    }

    @Test func incrementUnseen_fromPaused_count0_becomesCount1() {
        let next = ChatMessageListAutoScrollPolicy.incrementUnseenCount(state: .paused(unseenCount: 0))
        #expect(next == .paused(unseenCount: 1))
    }

    @Test func badgeLabel_belowCap() {
        let state = ChatScrollState.paused(unseenCount: 7)
        #expect(state.badgeLabel == "7")
    }

    @Test func badgeLabel_atCap() {
        let state = ChatScrollState.paused(unseenCount: 99)
        #expect(state.badgeLabel == "99+")
    }
```

### Step 2: Run policy tests

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ChatMessageListAutoScrollPolicyTests \
  -derivedDataPath /tmp/agentGui-cv-p3-task5 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: All pass

### Step 3: Regression — run projection coordinator tests

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests \
  -derivedDataPath /tmp/agentGui-cv-p3-task5 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: All pass (这组测试不依赖滚动逻辑，验证 projection model 未被破坏)

### Step 4: Commit

```bash
git add agentGuiTests/ChatMessageListAutoScrollPolicyTests.swift
git commit -m "test(CV-P3): edge-case coverage for ChatScrollState + badge label"
```

---

## Task 6: 人工验收 Checklist

在 Xcode Simulator / 真机运行应用后，手动执行以下场景：

| # | 场景 | 预期行为 |
|---|------|---------|
| 1 | 正常对话，Agent 流式回复 | 随 streaming 自动追底，无跳动 |
| 2 | 上滑超过 1 屏，Agent 继续流式回复 | **不跳底**；右下角出现 "N 条新消息" badge |
| 3 | 回溯期间多条 Agent 消息到达 | badge 计数累加（最大 99+） |
| 4 | 点击 badge | 平滑滚动到底，badge 消失，重新进入追踪模式 |
| 5 | 用户自己发送消息（在回溯状态下） | 自动滚底，显示用户消息 |
| 6 | 手动滚到底部（不点 badge） | badge 消失（onAppear 触发 → scroll state 复位为 .tracking） |
| 7 | 切换 Session | badge 消失，scroll state 重置 |
| 8 | 空会话发第一条消息 | 正常滚底 |

---

## Task 7: Session 切换时重置 scroll state

**Files:**
- Modify: `agentGui/Views/ChatView.swift` 或 `ChatView+MessageList.swift`

Session 切换时 `scrollState` 应重置为 `.tracking`，避免上一个 session 的 badge 残留在新 session。

### Step 1: 定位 session 切换的 onChange

在 `ChatView+MessageList.swift` 或 `ChatView.swift` 中搜索 `onChange(of: session.id)` 或 `session.persistentModelID`：

```bash
grep -n "session" /Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+MessageList.swift | head -20
grep -n "onChange.*session" /Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift | head -10
```

### Step 2: 在 messagesArea 或 messageListView 增加 onChange

在 `messagesArea` 的 `.task(id: refreshKey)` 之后或附近追加：

```swift
        .onChange(of: session.id) { _, _ in
            scrollState = .tracking
            programmaticScrollTask?.cancel()
            programmaticScrollTask = nil
            scrollToBadgeBottom = false
        }
```

### Step 3: Build + run projection coordinator tests

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

### Step 4: Commit

```bash
git add agentGui/Views/ChatView.swift agentGui/Views/ChatView+MessageList.swift
git commit -m "fix(CV-P3): reset scroll state on session switch"
```

---

## 依赖说明

| 前置条件 | 状态 |
|---------|------|
| CV-A1 (ChatMotionTokens) | ✅ 已完成（`ChatMotion.scrollToBottom`、`enterSpring`、`exitDuration` 已存在） |
| CV-P1 (分页懒加载) | ❌ 尚未实现；CV-P3 不依赖分页，独立交付 |
| CV-P2 (流式节流) | ❌ 尚未实现；CV-P3 `onChange(of: textContent)` 仍保留，与节流层兼容 |

## 不做的事

- 不实现"精确滚动位置恢复"（session 切回时记住滚动位置）
- 不统计 streaming delta 的未读数（只统计完整消息 id 变化）
- badge 不显示发送者名字，只显示条数
- 不将 badge 计数持久化到 SwiftData

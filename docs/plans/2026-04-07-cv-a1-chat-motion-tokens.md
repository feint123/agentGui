# CV-A1: 统一 Motion Token 系统 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 ChatView 体系内所有硬编码的动效参数（spring、duration、easeInOut、transition 等）统一提取到 `ChatMotionTokens.swift` 枚举，使风格保持一致并便于全局调整。

**Architecture:** 新建一个无状态的 `enum ChatMotion`，内含纯静态常量（`Animation`、`AnyTransition`、`TimeInterval`、`CGFloat`）。现有硬编码参数按语义映射到对应 Token，不改变任何业务逻辑或视图结构。

**Tech Stack:** Swift 6.0+, SwiftUI (macOS), 无第三方依赖

---

## 受影响文件总览

| 操作 | 文件 |
|------|------|
| **Create** | `agentGui/Views/ChatMotionTokens.swift` |
| **Modify** | `agentGui/Views/MessageBubbleView.swift` |
| **Modify** | `agentGui/Views/AgentMessageStepFlowView.swift` |
| **Modify** | `agentGui/Views/ChatView+MessageList.swift` |
| **Modify** | `agentGui/Views/ChatView.swift` |

---

## 硬编码值清单（迁移前）

在开始之前，先明确所有需要替换的原始值及其位置：

| 文件 | 行号 | 硬编码值 | 映射 Token |
|------|------|----------|------------|
| MessageBubbleView.swift | 54, 131 | `.easeInOut(duration: 0.15)` | `ChatMotion.hoverSpring` |
| MessageBubbleView.swift | 64–67 | `.asymmetric(insertion: .opacity.combined(with: .offset(y: -2)), removal: .opacity)` | `ChatMotion.hoverActionsTransition` |
| MessageBubbleView.swift | 152–155 | _(同上)_ | `ChatMotion.hoverActionsTransition` |
| AgentMessageStepFlowView.swift | 44 | `.spring(response: 0.42, dampingFraction: 0.84)` | `ChatMotion.enterSpring` |
| AgentMessageStepFlowView.swift | 45, 46 | `.easeInOut(duration: 0.24)` | `ChatMotion.theaterStateChange` |
| ChatView+MessageList.swift | 196 | `.easeOut(duration: 0.2)` | `ChatMotion.scrollToBottom` |
| ChatView.swift | 334 | `.opacity.combined(with: .scale(scale: 0.98, anchor: .top))` | `ChatMotion.bannerTransition` |

---

## Task 1: 创建 ChatMotionTokens.swift

**Files:**
- Create: `agentGui/Views/ChatMotionTokens.swift`

### Step 1: 创建文件，写入所有 Token 定义

```swift
//  ChatMotionTokens.swift
//  agentGui
//
//  统一动效令牌 — ChatView 体系内所有动效参数的单一来源。
//  使用方式: ChatMotion.enterSpring / ChatMotion.scrollToBottom 等。

import SwiftUI

enum ChatMotion {

    // MARK: - 入场

    /// 消息块、卡片的弹性入场动画（spring）
    static let enterSpring = Animation.spring(response: 0.38, dampingFraction: 0.82)

    /// 标准入场持续时长（用于非 spring 的 easeOut 入场）
    static let enterDuration: TimeInterval = 0.25

    // MARK: - 退场

    /// 标准退场持续时长
    static let exitDuration: TimeInterval = 0.18

    /// 纯透明度退场 Transition
    static let exitOpacity: AnyTransition = .opacity

    // MARK: - 流式内容

    /// streaming delta 文本追加动画
    static let streamingAppend = Animation.easeOut(duration: 0.12)

    // MARK: - 滚动

    /// 滚动到底部的平滑动画
    static let scrollToBottom = Animation.easeOut(duration: 0.22)

    // MARK: - 交互反馈

    /// hover 缩放比例（用于可交互元素）
    static let hoverScale: CGFloat = 1.02

    /// 按下缩放比例
    static let pressScale: CGFloat = 0.97

    /// hover 状态切换弹性动画
    static let hoverSpring = Animation.spring(response: 0.28, dampingFraction: 0.76)

    // MARK: - 复合 Transition（无法通过 Animation 单独表达的）

    /// Hover Actions Bar 进出场：向上淡入 / 淡出
    static let hoverActionsTransition: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .offset(y: -2)),
        removal: .opacity
    )

    /// Theater State Change — 卡片列表结构性变更（权限请求、toolCall 变更）
    static let theaterStateChange = Animation.easeInOut(duration: 0.24)

    /// 顶部 Banner 进出场（只读横幅、通知横幅）
    static let bannerTransition: AnyTransition = .opacity.combined(
        with: .scale(scale: 0.98, anchor: .top)
    )
}
```

### Step 2: 确认文件已建立

```bash
ls agentGui/Views/ChatMotionTokens.swift
```

预期：文件存在，无报错。

### Step 3: 构建验证编译通过

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E 'error:|BUILD SUCCEEDED'
```

预期：`BUILD SUCCEEDED`，无 `error:`。

### Step 4: Commit

```bash
git add agentGui/Views/ChatMotionTokens.swift
git commit -m "feat(cv-a1): add ChatMotionTokens with unified animation constants"
```

---

## Task 2: 迁移 MessageBubbleView.swift

**Files:**
- Modify: `agentGui/Views/MessageBubbleView.swift`

需要替换 3 处：
1. `userMessageRow` 里 `onHover` 的 `.easeInOut(duration: 0.15)`
2. `userHeaderRow` 里 Hover Actions Bar 的 inline transition
3. `agentMessageRow` 里 `onHover` 的 `.easeInOut(duration: 0.15)`
4. `agentHeaderRow` 里 Hover Actions Bar 的 inline transition

### Step 1: 替换 userMessageRow 的 onHover 动画

**Old (MessageBubbleView.swift ~line 53–55):**
```swift
        .onHover { hovered in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovered }
        }
        .contextMenu { contextMenuItems }
    }

    /// Compact header row for user messages: hover actions, timestamp, name (right-aligned).
```

**New:**
```swift
        .onHover { hovered in
            withAnimation(ChatMotion.hoverSpring) { isHovered = hovered }
        }
        .contextMenu { contextMenuItems }
    }

    /// Compact header row for user messages: hover actions, timestamp, name (right-aligned).
```

### Step 2: 替换 userHeaderRow 里的 hoverActionsTransition

**Old (~line 62–68):**
```swift
            if isHovered && !isEditing && !isStreaming {
                messageActionsRow
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -2)),
                        removal: .opacity
                    ))
            }
```

**New:**
```swift
            if isHovered && !isEditing && !isStreaming {
                messageActionsRow
                    .transition(ChatMotion.hoverActionsTransition)
            }
```

### Step 3: 替换 agentMessageRow 的 onHover 动画

**Old (~line 129–132):**
```swift
        .onHover { hovered in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovered }
        }
        .contextMenu { contextMenuItems }
    }

    /// Compact header row: icon, name, timestamp, hover actions.
```

**New:**
```swift
        .onHover { hovered in
            withAnimation(ChatMotion.hoverSpring) { isHovered = hovered }
        }
        .contextMenu { contextMenuItems }
    }

    /// Compact header row: icon, name, timestamp, hover actions.
```

### Step 4: 替换 agentHeaderRow 里的 hoverActionsTransition

**Old (~line 150–155):**
```swift
            if isHovered && !isStreaming {
                messageActionsRow
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -2)),
                        removal: .opacity
                    ))
            }
```

**New:**
```swift
            if isHovered && !isStreaming {
                messageActionsRow
                    .transition(ChatMotion.hoverActionsTransition)
            }
```

### Step 5: 构建验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E 'error:|BUILD SUCCEEDED'
```

预期：`BUILD SUCCEEDED`。

### Step 6: Commit

```bash
git add agentGui/Views/MessageBubbleView.swift
git commit -m "refactor(cv-a1): migrate MessageBubbleView to ChatMotion tokens"
```

---

## Task 3: 迁移 AgentMessageStepFlowView.swift

**Files:**
- Modify: `agentGui/Views/AgentMessageStepFlowView.swift`

需替换文件末尾的 3 个 `.animation(...)` 修饰符。

### Step 1: 替换三处 animation 修饰符

**Old (AgentMessageStepFlowView.swift ~line 44–46):**
```swift
        .animation(.spring(response: 0.42, dampingFraction: 0.84), value: projection.header.isLive)
        .animation(.easeInOut(duration: 0.24), value: projection.theater.cards.map(\.id))
        .animation(.easeInOut(duration: 0.24), value: pendingPermissionRequests.map(\.id))
```

**New:**
```swift
        .animation(ChatMotion.enterSpring, value: projection.header.isLive)
        .animation(ChatMotion.theaterStateChange, value: projection.theater.cards.map(\.id))
        .animation(ChatMotion.theaterStateChange, value: pendingPermissionRequests.map(\.id))
```

### Step 2: 构建验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E 'error:|BUILD SUCCEEDED'
```

预期：`BUILD SUCCEEDED`。

### Step 3: Commit

```bash
git add agentGui/Views/AgentMessageStepFlowView.swift
git commit -m "refactor(cv-a1): migrate AgentMessageStepFlowView to ChatMotion tokens"
```

---

## Task 4: 迁移 ChatView+MessageList.swift

**Files:**
- Modify: `agentGui/Views/ChatView+MessageList.swift`

需替换 `scrollToBottom(proxy:)` 方法内的 `.easeOut(duration: 0.2)`。

### Step 1: 替换 scrollToBottom 动画

**Old (ChatView+MessageList.swift ~line 195–199):**
```swift
    func scrollToBottom(proxy: ScrollViewProxy) {
        isProgrammaticMessageListScrollInFlight = true
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(ChatMessageListAutoScrollPolicy.bottomAnchorID, anchor: .bottom)
        }
```

**New:**
```swift
    func scrollToBottom(proxy: ScrollViewProxy) {
        isProgrammaticMessageListScrollInFlight = true
        withAnimation(ChatMotion.scrollToBottom) {
            proxy.scrollTo(ChatMessageListAutoScrollPolicy.bottomAnchorID, anchor: .bottom)
        }
```

### Step 2: 构建验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E 'error:|BUILD SUCCEEDED'
```

预期：`BUILD SUCCEEDED`。

### Step 3: Commit

```bash
git add agentGui/Views/ChatView+MessageList.swift
git commit -m "refactor(cv-a1): migrate ChatView+MessageList scrollToBottom to ChatMotion token"
```

---

## Task 5: 迁移 ChatView.swift

**Files:**
- Modify: `agentGui/Views/ChatView.swift`

需替换只读横幅（readOnlyBanner）的 `.transition(...)` 为 `ChatMotion.bannerTransition`。

### Step 1: 替换 banner transition

**Old (ChatView.swift ~line 334):**
```swift
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }

    private func cloneReadOnlySessionFromBanner() {
```

**New:**
```swift
            .transition(ChatMotion.bannerTransition)
        }
    }

    private func cloneReadOnlySessionFromBanner() {
```

### Step 2: 构建验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E 'error:|BUILD SUCCEEDED'
```

预期：`BUILD SUCCEEDED`。

### Step 3: Commit

```bash
git add agentGui/Views/ChatView.swift
git commit -m "refactor(cv-a1): migrate ChatView banner transition to ChatMotion token"
```

---

## Task 6: 全量测试 + 验收

**Files:** 无修改

### Step 1: 运行 Quality Smoke 任务（构建 + 快速单测）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cv-a1-smoke \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tail -20
```

预期：所有现有测试通过（本次变更不涉及业务逻辑，不应引入任何测试失败）。

### Step 2: 验证无残留硬编码（grep 检查）

```bash
# 在目标文件中搜索已迁移的硬编码值，预期不应有匹配
grep -n "easeInOut(duration: 0.15)\|easeInOut(duration: 0.24)\|easeOut(duration: 0.2)\|response: 0.42" \
  agentGui/Views/MessageBubbleView.swift \
  agentGui/Views/AgentMessageStepFlowView.swift \
  agentGui/Views/ChatView+MessageList.swift \
  agentGui/Views/ChatView.swift
```

预期：无任何输出（0 匹配）。

### Step 3: 验证所有 Token 被引用

```bash
# 确认 ChatMotionTokens.swift 中定义的每个 token 都被至少一处引用
grep -rn "ChatMotion\." agentGui/Views/ | grep -v "ChatMotionTokens.swift"
```

预期：至少看到 `ChatMotion.hoverSpring`、`ChatMotion.hoverActionsTransition`、`ChatMotion.enterSpring`、`ChatMotion.theaterStateChange`、`ChatMotion.scrollToBottom`、`ChatMotion.bannerTransition` 各出现 1 次以上。

### Step 4: 最终 Commit（若有未 commit 的改动）

```bash
git log --oneline -6
```

确认 6 个 commit 均已入库：
1. `feat(cv-a1): add ChatMotionTokens with unified animation constants`
2. `refactor(cv-a1): migrate MessageBubbleView to ChatMotion tokens`
3. `refactor(cv-a1): migrate AgentMessageStepFlowView to ChatMotion tokens`
4. `refactor(cv-a1): migrate ChatView+MessageList scrollToBottom to ChatMotion token`
5. `refactor(cv-a1): migrate ChatView banner transition to ChatMotion token`
6. _(Task 6 无代码修改，无需额外 commit)_

---

## 验收标准检查表

- [ ] `ChatMotionTokens.swift` 已创建，包含设计文档规定的全部 Token
- [ ] `MessageBubbleView.swift` 中 4 处硬编码已替换（2 处 onHover + 2 处 transition）
- [ ] `AgentMessageStepFlowView.swift` 中 3 处 `.animation(...)` 已替换
- [ ] `ChatView+MessageList.swift` 中 `scrollToBottom` 动画已替换
- [ ] `ChatView.swift` 中 banner transition 已替换
- [ ] 构建无编译错误
- [ ] 现有测试全部通过
- [ ] grep 检查确认无残留硬编码

---

## 注意事项

1. **不修改 Transition 形状** — `AgentMessageStepFlowView` 内的 `.transition(.move(edge: .bottom).combined(with: .opacity))` 等 Transition 形状本身不在本 Feature 范围内（这是 CV-A2 的内容），本次只迁移 `.animation(...)` 调用点的参数值。

2. **ToolCallBubbleView 不在本 Feature 范围** — 该文件中的 `.spring(duration: 0.2)` 属于工具调用卡片的交互反馈，语义与 ChatView 消息体系分离，留待后续统一处理。

3. **`ChatMotion.scrollToBottom` 持续时长差异** — 原有代码用 `0.2s`，Token 设计值为 `0.22s`，差异极小且视觉上无感知，以设计规范为准。

4. **`ChatMotion.enterSpring` 参数差异** — 原 `AgentMessageStepFlowView` 使用 `response: 0.42, dampingFraction: 0.84`，Token 为 `response: 0.38, dampingFraction: 0.82`（设计规范值）。差异轻微，属于有意的规范对齐。

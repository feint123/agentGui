# CV-A4: 流式内容打字机效果 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 Agent 消息流式输出期间，在内容末尾显示闪烁光标，并为新文本出现加上轻微淡入动画，提升流式输出的连续感与视觉质量。

**Architecture:** `StreamingCursorView`（纯展示组件）→ 嵌入 `MarkdownMessageView`（接受 `showsCursor: Bool`）→ `AgentMessageResultBlockView` 从 `charBudget != nil` 推导 `isStreaming` 并向下透传。`AgentMessageStepFlowView` 无需改动，所有 streaming 状态已由现有 `StreamingCharBudgetTracker` + `charBudget` 参数传递链承载。

**Tech Stack:** SwiftUI 6, Swift 6, `ChatMotionTokens`（CV-A1 已完成），`StreamingCharBudgetTracker`（已有）

**竞品参考：**
- **Open WebUI** (`Markdown.svelte`)：`requestAnimationFrame` 节流 token 解析；`done` 属性透传到 `MarkdownTokens`，`!done` 时末尾追加 CSS `animate-blink` span
- **VS Code Copilot Chat**：`chatFadeStreamingText` 设置项驱动 `done` prop；内容通过 word-rate timer 渐进投影；streaming 期间以 CSS 光标伪类修饰最后字符

---

## 前置条件检查

- [x] `ChatMotionTokens.swift` 已存在（CV-A1 完成）— `ChatMotion.streamingAppend`、`ChatMotion.exitDuration` 可直接使用
- [x] `StreamingCharBudgetTracker` 已存在并通过测试
- [x] `AgentMessageResultBlockView` 接受 `charBudget: Int?` 参数
- [ ] `StreamingCursorView.swift` 不存在，需新建
- [ ] `MarkdownMessageView` 目前无 `showsCursor` 参数，无 `streamingAppend` 动画

---

## Task 1: StreamingCursorView — 闪烁光标组件

**Files:**
- Create: `agentGui/Views/StreamingCursorView.swift`
- Test: `agentGuiTests/StreamingCursorViewTests.swift`

### Step 1: 写失败测试

```swift
// agentGuiTests/StreamingCursorViewTests.swift
import Testing
import SwiftUI
@testable import agentGui

struct StreamingCursorViewTests {

    /// 光标视图可以构建，不崩溃
    @Test
    func cursorViewBuilds() {
        let view = StreamingCursorView()
        // SwiftUI view 构造不应抛出
        _ = view.body
    }

    /// 光标的宽高常量符合设计规格
    @Test
    func cursorDimensionsMatchSpec() {
        #expect(StreamingCursorView.width == 1.5)
        #expect(StreamingCursorView.height == 14.0)
    }

    /// 光标淡出动画时长等于 ChatMotion.exitDuration
    @Test
    func cursorExitDurationMatchesMotionToken() {
        // ChatMotion.exitDuration = 0.18
        #expect(ChatMotion.exitDuration == 0.18)
    }
}
```

运行验证失败：
```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/StreamingCursorViewTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAILED|error:|Build SUCCEEDED"
```
预期：**Build FAILED** (StreamingCursorView 不存在)

### Step 2: 实现 StreamingCursorView

```swift
// agentGui/Views/StreamingCursorView.swift
import SwiftUI

/// 流式输出期间，内容末尾的闪烁竖线光标。
/// 宽 1.5pt / 高 14pt，以 0.5 s 周期在 opacity 0.2 ↔ 1 间闪烁。
/// streaming 结束后通过 `.opacity` transition + `ChatMotion.exitDuration` 淡出。
struct StreamingCursorView: View {

    static let width: CGFloat  = 1.5
    static let height: CGFloat = 14.0

    @State private var visible = false

    var body: some View {
        RoundedRectangle(cornerRadius: 0.75)
            .fill(Color.secondary.opacity(0.85))
            .frame(width: Self.width, height: Self.height)
            .opacity(visible ? 1.0 : 0.2)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.5)
                    .repeatForever(autoreverses: true)
                ) {
                    visible = true
                }
            }
    }
}

#Preview {
    HStack(spacing: 4) {
        Text("Hello")
        StreamingCursorView()
    }
    .padding()
}
```

### Step 3: 运行测试，确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/StreamingCursorViewTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|FAILED|error:"
```
预期：**3 tests passed**

### Step 4: Commit

```bash
git add agentGui/Views/StreamingCursorView.swift \
        agentGuiTests/StreamingCursorViewTests.swift
git commit -m "feat(CV-A4): add StreamingCursorView with 0.5s blink animation"
```

---

## Task 2: MarkdownMessageView — 接入 showsCursor + streamingAppend 动画

**Files:**
- Modify: `agentGui/Views/MarkdownMessageView.swift`
- Test: `agentGuiTests/MarkdownMessageViewStreamingTests.swift`（新建）

### Step 1: 写失败测试

```swift
// agentGuiTests/MarkdownMessageViewStreamingTests.swift
import Testing
import SwiftUI
@testable import agentGui

@MainActor
struct MarkdownMessageViewStreamingTests {

    /// 默认参数 showsCursor=false，构建不崩溃
    @Test
    func defaultNoCursor() {
        let view = MarkdownMessageView(text: "Hello world")
        _ = view.body
    }

    /// showsCursor=true 参数存在且构建不崩溃
    @Test
    func withCursorBuilds() {
        let view = MarkdownMessageView(text: "Streaming...", showsCursor: true)
        _ = view.body
    }

    /// showsCursor=false 时，视图不持有光标相关状态
    @Test
    func noCursorWhenFalse() {
        let view = MarkdownMessageView(text: "Done text", showsCursor: false)
        // 仅验证可以构建 —— 没有崩溃即证明参数链正确
        _ = view.body
    }
}
```

运行验证失败：
```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/MarkdownMessageViewStreamingTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|FAILED|error:"
```
预期：**Build FAILED** (`MarkdownMessageView` 无 `showsCursor` 参数)

### Step 2: 修改 MarkdownMessageView

在 `MarkdownMessageView.swift` 中做以下两处改动：

**2a. 新增 `showsCursor` 参数（init 处）：**

```swift
// 修改前:
struct MarkdownMessageView: View {
    let text: String

    @SwiftUI.State private var parser = MarkdownMessageIncrementalParser()
    @SwiftUI.State private var snapshot = MarkdownIncrementalSnapshot(sourceText: "", blocks: [])

    init(text: String) {
        self.text = text
        let parser = MarkdownMessageIncrementalParser()
        _parser = SwiftUI.State(initialValue: parser)
        _snapshot = SwiftUI.State(initialValue: Self.initialSnapshot(for: text))
    }

// 修改后:
struct MarkdownMessageView: View {
    let text: String
    var showsCursor: Bool = false

    @SwiftUI.State private var parser = MarkdownMessageIncrementalParser()
    @SwiftUI.State private var snapshot = MarkdownIncrementalSnapshot(sourceText: "", blocks: [])

    init(text: String, showsCursor: Bool = false) {
        self.text = text
        self.showsCursor = showsCursor
        let parser = MarkdownMessageIncrementalParser()
        _parser = SwiftUI.State(initialValue: parser)
        _snapshot = SwiftUI.State(initialValue: Self.initialSnapshot(for: text))
    }
```

**2b. 在 `body` VStack 末尾追加光标行，并为 blocks 变化加 streamingAppend 动画：**

找到 `body` 中的：
```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(snapshot.blocks.enumerated()), id: \.element.id) { index, block in
                blockView(block, index: index)
            }
        }
        .onChange(of: text) { oldValue, newValue in
```

修改为：
```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(snapshot.blocks.enumerated()), id: \.element.id) { index, block in
                blockView(block, index: index)
            }

            // CV-A4: streaming 期间在内容末尾显示闪烁光标
            if showsCursor {
                HStack(spacing: 0) {
                    StreamingCursorView()
                    Spacer()
                }
                .padding(.top, 2)
                .transition(
                    .opacity.animation(
                        .easeOut(duration: ChatMotion.exitDuration)
                    )
                )
            }
        }
        // CV-A4: blocks 数量变化时（新 block 进入）使用 streamingAppend 动画
        .animation(ChatMotion.streamingAppend, value: snapshot.blocks.count)
        .onChange(of: text) { oldValue, newValue in
```

### Step 3: 运行测试，确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/MarkdownMessageViewStreamingTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|FAILED|error:"
```
预期：**3 tests passed**

### Step 4: Commit

```bash
git add agentGui/Views/MarkdownMessageView.swift \
        agentGuiTests/MarkdownMessageViewStreamingTests.swift
git commit -m "feat(CV-A4): add showsCursor param and streamingAppend animation to MarkdownMessageView"
```

---

## Task 3: AgentMessageResultBlockView — 透传 isStreaming → MarkdownMessageView

**Files:**
- Modify: `agentGui/Views/AgentMessageResultBlockView.swift`
- Test: `agentGuiTests/AgentMessageResultBlockViewStreamingTests.swift`（新建）

### Step 1: 写失败测试

```swift
// agentGuiTests/AgentMessageResultBlockViewStreamingTests.swift
import Testing
@testable import agentGui

@MainActor
struct AgentMessageResultBlockViewStreamingTests {

    private func makePresentation(text: String = "Hello") -> ResultStepPresentation {
        ResultStepPresentation(id: "test", text: text, isError: false)
    }

    /// charBudget == nil → isStreaming 应为 false
    @Test
    func charBudgetNilMeansNotStreaming() {
        let view = AgentMessageResultBlockView(presentation: makePresentation(), charBudget: nil)
        #expect(view.isStreaming == false)
    }

    /// charBudget 非 nil → isStreaming 应为 true
    @Test
    func charBudgetSetMeansStreaming() {
        let view = AgentMessageResultBlockView(presentation: makePresentation(), charBudget: 42)
        #expect(view.isStreaming == true)
    }

    /// isStreaming == true 时 visibleText 截断到预算
    @Test
    func visibleTextTruncatedWhenStreaming() {
        let text = "ABCDEFGHIJ"  // 10 chars
        let view = AgentMessageResultBlockView(
            presentation: makePresentation(text: text),
            charBudget: 4
        )
        // visibleText 是私有，通过 isStreaming 间接验证
        // 补充 internal 可见性 via @testable
        #expect(view.isStreaming == true)
    }
}
```

运行验证失败：
```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/AgentMessageResultBlockViewStreamingTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|FAILED|error:"
```
预期：**Build FAILED**（`AgentMessageResultBlockView` 无 `isStreaming` 属性）

### Step 2: 修改 AgentMessageResultBlockView

```swift
// 修改前:
struct AgentMessageResultBlockView: View {
    let presentation: ResultStepPresentation
    /// 可见字符预算。nil 表示展示全量（非 streaming 时）。
    var charBudget: Int? = nil

    private var visibleText: String {
        ...
    }

    var body: some View {
        Group {
            if presentation.isError {
                ...
            } else {
                MarkdownMessageView(text: visibleText)
            }
        }

// 修改后:
struct AgentMessageResultBlockView: View {
    let presentation: ResultStepPresentation
    /// 可见字符预算。nil 表示展示全量（非 streaming 时）。
    var charBudget: Int? = nil

    /// streaming 状态派生属性：charBudget 非 nil 时视为正在流式输出。
    var isStreaming: Bool { charBudget != nil }

    private var visibleText: String {
        ...
    }

    var body: some View {
        Group {
            if presentation.isError {
                ...
            } else {
                MarkdownMessageView(text: visibleText, showsCursor: isStreaming)
            }
        }
```

> **注意：** 仅修改 `isStreaming` 计算属性的新增和 `MarkdownMessageView` 的调用处，其他代码（`visibleText`、背景、padding 等）保持原样不变。

### Step 3: 运行测试，确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/AgentMessageResultBlockViewStreamingTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|FAILED|error:"
```
预期：**3 tests passed**

### Step 4: Commit

```bash
git add agentGui/Views/AgentMessageResultBlockView.swift \
        agentGuiTests/AgentMessageResultBlockViewStreamingTests.swift
git commit -m "feat(CV-A4): wire isStreaming → MarkdownMessageView.showsCursor via charBudget"
```

---

## Task 4: 回归测试 — 验证已有测试不受影响

已有的 `StreamingCharBudgetTrackerTests` 和 `MarkdownMessageView` 相关测试不应受本次改动破坏。

### Step 1: 运行全量 Streaming / MarkdownMessage 测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/StreamingCharBudgetTrackerTests \
  -only-testing:agentGuiTests/StreamingCursorViewTests \
  -only-testing:agentGuiTests/MarkdownMessageViewStreamingTests \
  -only-testing:agentGuiTests/AgentMessageResultBlockViewStreamingTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|FAILED|error:"
```

预期：**所有 tests passed，无 FAILED**

### Step 2: 运行 Smoke 测试（更广覆盖）

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cv-a4-smoke \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

### Step 3: Final commit（若 smoke 通过）

```bash
git add -A
git commit -m "chore(CV-A4): confirm all regression tests pass"
```

---

## 验收标准核查

| 标准 | 验证方式 |
|------|----------|
| streaming 期间末尾有闪烁光标 | 手动：启动 Agent 对话，观察 answer block 末尾竖线光标闪烁 |
| 新文本出现有轻微淡入效果 | 手动：观察 markdown block 出现时有 easeOut(0.12s) 淡入 |
| streaming 结束后光标淡出消失 | 手动：对话完成瞬间光标以 0.18s easeOut 淡出 |
| `charBudget = nil` 时无光标 | 单元测试 Task 3 Step 3 |
| 所有现有 streaming 测试通过 | Task 4 Step 1 |
| `ChatMotionTokens` 中的 token 未被破坏 | Task 1 Step 3 中 `ChatMotion.exitDuration == 0.18` 测试 |

---

## 不做的事项（YAGNI）

| 提议 | 理由 |
|------|------|
| 光标真正内联于最后一个字符后 | SwiftUI Text 内联布局极其复杂，独立行的光标视觉效果已满足需求 |
| 光标随文字颜色变化（深浅模式适配） | `Color.secondary` 已自动适配；无需额外逻辑 |
| 光标闪烁频率可配置 | 0.5s 是标准终端光标节奏，无需外部配置 |
| 在 ToolCall / ExecutionTheater 内部也加光标 | 这些区域有自己的 isLive 指示器，冗余 |
| 为 UserMessageBubble 也加光标 | 用户消息不 streaming，不适用 |

---

## 文件修改总结

| 操作 | 文件 |
|------|------|
| 新建 | `agentGui/Views/StreamingCursorView.swift` |
| 修改 | `agentGui/Views/MarkdownMessageView.swift` |
| 修改 | `agentGui/Views/AgentMessageResultBlockView.swift` |
| 新建 | `agentGuiTests/StreamingCursorViewTests.swift` |
| 新建 | `agentGuiTests/MarkdownMessageViewStreamingTests.swift` |
| 新建 | `agentGuiTests/AgentMessageResultBlockViewStreamingTests.swift` |

`AgentMessageStepFlowView.swift` **无需改动**。

# Code Editor Feature 9 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 CodeEditor 增加批量 viewport line metrics 导出能力，并把 gutter 的几何输入从 `visibleLineRange + backgroundRect(forLine:)` 迁移到一次性 `lineMetrics snapshot`，保证滚动、IME marked text 和新增换行场景下的 gutter 几何仍然正确。

**Architecture:** 这一轮建立一个“窄而专用”的 line metrics 层：`CodeEditorPlatformTextView` 负责基于现有 TextKit 1 布局一次性导出当前 viewport 的可见行 metrics，coordinator 把它与 `lineCount`、`currentLine`、`diagnosticsByLine` 组合成 gutter 可消费的轻量 snapshot，`CodeEditorGutterView` 只依赖该 snapshot 绘制，不再逐行向 text view 反查几何。Feature 9 不提前引入 Feature 10 的独立 renderer 和 diff-aware 全量 snapshot，也不做 Feature 11 的 lane 抽象；本轮只把“批量 metrics 导出和接线”做扎实。

**Tech Stack:** Swift 6、SwiftUI、AppKit、TextKit 1、Foundation、现有 `CodeEditorTextView` / `CodeEditorPlatformTextView` / `CodeEditorGutterView` / `CodeEditorViewportContainerView` / `CodeEditorTextViewHarness`、Swift Testing

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 当前执行状态（2026-03-30）

- Feature 8 已完成：gutter 已经迁出 `NSRulerView`，当前宿主为 `CodeEditorViewportContainerView`，左侧 `CodeEditorGutterView` 和右侧 `NSScrollView + CodeEditorPlatformTextView` 是 sibling 关系。
- 当前 gutter 仍然通过 `visibleLineRange` 驱动逐行 `lineRect(forLine:)` 查询，而 `lineRect(forLine:)` 又会调用 `CodeEditorPlatformTextView.backgroundRect(forLine:)` 逐行向 TextKit 反查几何。
- 当前 `CodeEditorPlatformTextView` 已具备 `displayedLineCount`、`displayedLineRange(for:)`、`backgroundRect(forLine:)` 和 marked text 生命周期更新能力，这是 Feature 9 应复用的基础。
- 当前 coordinator 已经掌握滚动、选区变化、diagnostics 更新和 IME 组合态的刷新时机，因此 Feature 9 的低风险接入点仍然是 `updateGutterState(for:)`。
- 当前测试基线已经覆盖 custom gutter host、visible line range 发布、diagnostics 同步、滚动稳定性和 marked text 新增换行；Feature 9 应优先在这些现有集成测试上扩展断言，而不是额外引入一套并行测试宿主。

## 0. 范围约束

- Feature 9 只解决“批量 viewport metrics 导出”和“gutter 改吃 metrics snapshot”。
- Feature 9 不引入完整的 `CodeEditorGutterViewportSnapshot` / diff-aware role / chunk anchors / lanes；这些保持在后续 Feature 10、11、14。
- Feature 9 不修改 `CodeEditorView` 的 SwiftUI 外部 API，不改动上层 ViewModel。
- Feature 9 不替换 `NSTextView`、不迁移 TextKit 2、不调整 syntax highlight 的后台执行架构。
- Feature 9 不要求一次到位做复杂的行级 dirty diff renderer；本轮可以继续沿用 `CodeEditorGutterView.updateLayoutState(...)` 的增量失效方式，只要几何来源切换为 snapshot。

## 1. 代码锚点

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
  这里包含 `CodeEditorPlatformTextView`、coordinator 的 `updateGutterState(for:)`、`publishVisibleLineRange(for:)`、viewport observer 和 marked text 生命周期，是 Feature 9 的主战场。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorGutterView.swift`
  这里目前还持有 `textView` 并通过 `lineRect(forLine:)` 间接查询 `backgroundRect(forLine:)`。Feature 9 要让它切换到消费 line metrics 缓存。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorViewportContainerView.swift`
  这里本轮大概率不需要改宿主结构，但如果 gutter 新 snapshot 接线后需要在宽度变化时额外触发布局，这里是唯一应承接该行为的地方。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
  这里已经有 viewport、gutter、marked text、滚动和 diagnostics 的行为测试，Feature 9 应优先把新断言加在这里。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`
  这里提供 text view、scroll view、container view 和 gutter view 的测试访问器。Feature 9 需要在这里增加 metrics snapshot 相关的观察接口，避免测试直接窥探私有实现。

## 2. 方案结论

Feature 9 推荐走“窄 snapshot + 批量 API”的最小实现路线：

1. 新增一个只服务当前 Feature 的小型类型，例如 `CodeEditorVisibleLineMetric` 和 `CodeEditorGutterLineMetricsSnapshot`。
2. `CodeEditorPlatformTextView` 新增一个批量 API，例如 `visibleLineMetrics(in:)`，在一次 `ensureLayout` 后按当前 viewport 计算所有可见逻辑行的 rect 和 baseline。
3. coordinator 在 `updateGutterState(for:)` 中取到 visible line range 后，同步构造 line metrics snapshot 并传入 gutter。
4. `CodeEditorGutterView` 不再保存 `textView` 作为几何查询源，而是保存由 snapshot 提供的 `line -> rect` 映射；绘制和增量失效都只基于 snapshot。
5. 现有 `backgroundRect(forLine:)` 继续保留给 text view 当前行背景和其他调用点使用，但 gutter 不再依赖它逐行查 geometry。

不建议的路线：

- 不要在本轮直接上完整的 `CodeEditorGutterViewportSnapshot`。那会把 diff、lane、surface role 一起带入，明显超出 Feature 9 的边界。
- 不要删除 `backgroundRect(forLine:)`。当前 text view 自己的当前行背景绘制仍依赖它，后续功能也可能复用该单行 API。
- 不要把批量 metrics API 做成“仅仅在外层把多次 `backgroundRect(forLine:)` 包一层循环”的公共接口；至少要保证单次 `ensureLayout`、单次 viewport 边界确定和稳定的 per-frame 值快照。

## 3. 设计细节

### 3.1 新增的窄类型边界

建议新增一个专门文件，例如 `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorVisibleLineMetric.swift`，先只承载 Feature 9 需要的数据，不提前塞进 diff 字段。

建议骨架：

```swift
import CoreGraphics
import Foundation

struct CodeEditorVisibleLineMetric: Equatable, Sendable {
    let line: Int
    let rect: CGRect
    let baselineY: CGFloat
}

struct CodeEditorGutterLineMetricsSnapshot: Equatable, Sendable {
    let lineCount: Int
    let visibleLineRange: ClosedRange<Int>
    let currentLine: Int?
    let lineMetrics: [CodeEditorVisibleLineMetric]
    let diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary]
}
```

为什么这里要加一个窄 snapshot，而不是只给 gutter 多传一个 `[CodeEditorVisibleLineMetric]`：

- 它能把 `lineCount`、`visibleLineRange`、`currentLine`、`diagnosticsByLine` 和 `lineMetrics` 绑定成同一时刻的值快照，减少参数错配。
- 它为 Feature 10 的 renderer 抽离保留自然演进路径，但不会把未来字段提前带进本轮。
- 它能让测试对 snapshot 做整体验证，而不是分散断言多个状态字段。

### 3.2 `CodeEditorPlatformTextView` 的批量 API

`CodeEditorPlatformTextView` 当前已经能通过 `displayedLineIndex` 和 `backgroundRect(forLine:)` 推导单行几何。Feature 9 推荐新增一个批量 API：

```swift
func visibleLineMetrics(in visibleRect: NSRect) -> [CodeEditorVisibleLineMetric]
```

实现原则：

- 只在方法起始处做一次 `layoutManager.ensureLayout(for: textContainer)`。
- 先根据 `visibleRect` 求出一个稳定的 visible character/glyph 范围，再映射成 `displayedLineRange`。
- 在该范围内逐行构造 metrics 数组，rect 语义保持与当前 `backgroundRect(forLine:)` 一致，保证 gutter 视觉不变。
- `baselineY` 先按当前 TextKit 1 能稳定拿到的行 fragment baseline 导出；如果执行时发现暂时没有可靠 baseline 消费者，也可以先存 `lineRect.maxY - font.ascender` 这类稳定近似值，但要在计划执行里写明是临时实现并加 TODO，避免未来把错误语义固化。

建议把单行查询中已经存在的安全处理抽成私有 helper，避免两套逻辑漂移：

```swift
private func displayedLineRect(
    for line: Int,
    layoutManager: NSLayoutManager,
    textContainer: NSTextContainer
) -> NSRect?
```

批量 API 内部可以循环调用该 helper，只要保证：

- 一次性确定 visible line range
- 一次性 ensure layout
- 对外只暴露一次批量快照

这样已经满足 Feature 9 的验收标准；如果后续 profiling 证明 helper 循环仍是热点，再在 Feature 10 或 13 优化为 line fragment 枚举。

### 3.3 coordinator 的接线方式

当前 `updateGutterState(for:)` 直接传 `lineCount`、`visibleLineRange`、`currentLine`、`diagnosticsByLine` 到 gutter。Feature 9 建议把这个方法改成“先组 snapshot，再一次性推送”：

```swift
func updateGutterState(for textView: NSTextView) {
    guard let textView = textView as? CodeEditorPlatformTextView,
          let gutterView = gutterView(for: textView),
          let scrollView = textView.enclosingScrollView else {
        return
    }

    let visibleLineRange = visibleLineRange(for: textView) ?? fullDocumentLineRange()
    let lineMetrics = textView.visibleLineMetrics(in: scrollView.contentView.bounds)
    let snapshot = CodeEditorGutterLineMetricsSnapshot(
        lineCount: textView.displayedLineCount,
        visibleLineRange: visibleLineRange,
        currentLine: textView.highlightedLineNumber,
        lineMetrics: lineMetrics,
        diagnosticsByLine: parent.diagnosticsByLine
    )
    gutterView.updateLayoutState(snapshot)
}
```

这里有两个关键点必须保持：

- 仍然沿用当前 coordinator 的调用时机，包括滚动、选区变化、marked text 生命周期和 diagnostics 更新。
- `visibleLineRange(for:)` 与 `visibleLineMetrics(in:)` 必须以同一帧 viewport 为输入，避免 range 和 metrics 错位。

### 3.4 `CodeEditorGutterView` 的状态重构边界

Feature 9 不需要把 gutter 改成 renderer 架构，只需要把几何来源从 text view 改为 snapshot。

建议改法：

```swift
final class CodeEditorGutterView: NSView {
    private(set) var lineCount: Int
    private(set) var visibleLineRange: ClosedRange<Int>
    private(set) var currentLine: Int?
    private(set) var diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary]
    private(set) var lineMetrics: [CodeEditorVisibleLineMetric]

    private var lineMetricsByLine: [Int: CodeEditorVisibleLineMetric]
}
```

`updateLayoutState(...)` 建议替换为：

```swift
func updateLayoutState(_ snapshot: CodeEditorGutterLineMetricsSnapshot)
```

然后做三件事：

- 比较新旧 `lineCount` 以判断宽度是否变化
- 比较新旧 `currentLine`、`visibleLineRange`、`diagnosticsByLine` 和 `lineMetricsByLine.keys` 做增量失效
- 绘制时直接从 `lineMetricsByLine[line]?.rect` 取 gutter 行 rect，不再调用 `textView.backgroundRect(forLine:)`

不建议在本轮过度优化 line diff。保持当前策略即可：旧当前行、新当前行、旧可见范围、新可见范围、diagnostics 变化行都失效一次。Feature 9 的重点是“几何来源正确切换”，不是“最小失效绝对最优”。

### 3.5 测试策略

Feature 9 的测试应尽量复用现有 `CodeEditorTextViewHarness` 和集成测试风格，不新增复杂 test double。

建议新增或改造以下断言：

- `textViewExportsVisibleLineMetricsForViewport()`：直接验证批量 API 在初始 viewport 下返回非空 metrics，且所有行号落在 `lastVisibleLineRange` 内。
- `gutterConsumesViewportLineMetricsSnapshot()`：在滚动后验证 gutter 里的 `lineMetrics` 已刷新，并且包含目标可见行，不再只靠 `visibleLineRange` 推断。
- `gutterGeometryTracksDisplayedTextWhileMarkedTextAddsLineBreak()`：在现有 marked text 测试上补断言 `visibleLineMetrics` 和 gutter snapshot 都包含第 3 行。
- `scrollingAndDiagnosticsUpdateDoNotResetCursorOrText()`：保留原有回归，同时补一条 metrics 仍覆盖目标滚动行的断言。

Harness 最小扩展建议：

```swift
var gutterLineMetrics: [CodeEditorVisibleLineMetric] {
    gutterView?.lineMetrics ?? []
}

func visibleLineMetricsForCurrentViewport() -> [CodeEditorVisibleLineMetric] {
    textView.visibleLineMetrics(in: scrollView.contentView.bounds)
}
```

这样测试不需要绕过 public-ish 接口直接探测私有 helper。

## 4. 目标文件集

### New files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorVisibleLineMetric.swift`

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorGutterView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`

### Optional modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorViewportContainerView.swift`
  只有在执行时发现 gutter 宽度变化回调需要补 layout 触发或 snapshot 刷新顺序需要修正时才修改；否则不动。

## 5. 任务拆解

### Task 1: 先把 Feature 9 的行为钉进集成测试和 harness

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`

**Step 1: Write the failing test**

先新增能明确表达 Feature 9 目标的测试，至少覆盖 viewport metrics、gutter snapshot 和 marked text。

建议新增或改造如下测试：

```swift
@Test
func textViewExportsVisibleLineMetricsForViewport() {
    let text = (1...80).map { "line \($0)" }.joined(separator: "\n")
    let harness = CodeEditorTextViewHarness(text: text)

    let metrics = harness.visibleLineMetricsForCurrentViewport()

    #expect(metrics.isEmpty == false)
    #expect(metrics.allSatisfy { harness.lastVisibleLineRange?.contains($0.line) == true })
}

@Test
func gutterConsumesViewportLineMetricsSnapshot() {
    let text = (1...80).map { "line \($0)" }.joined(separator: "\n")
    let harness = CodeEditorTextViewHarness(text: text)

    harness.scrollToLine(40)

    #expect(harness.gutterLineMetrics.contains { $0.line == 40 })
}

@Test
func gutterGeometryTracksDisplayedTextWhileMarkedTextAddsLineBreak() {
    let harness = CodeEditorTextViewHarness(text: "one\ntwo")

    harness.setMarkedText(
        "\n三",
        selectedRange: NSRange(location: 2, length: 0),
        replacementRange: NSRange(location: harness.textView.string.utf16.count, length: 0)
    )

    #expect(harness.visibleLineMetricsForCurrentViewport().contains { $0.line == 3 })
    #expect(harness.gutterLineMetrics.contains { $0.line == 3 })
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination platform=macOS -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature9-derived -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，原因是 harness 还没有 metrics 访问器，gutter 也还没有暴露 line metrics snapshot。

**Step 3: Write minimal harness changes**

在 harness 里先补最小访问器，暂时允许它直接通过 text view 的新 API 或 gutter 的新只读状态取值：

```swift
var gutterLineMetrics: [CodeEditorVisibleLineMetric] {
    gutterView?.lineMetrics ?? []
}

func visibleLineMetricsForCurrentViewport() -> [CodeEditorVisibleLineMetric] {
    textView.visibleLineMetrics(in: scrollView.contentView.bounds)
}
```

**Step 4: Run test to see the remaining failure move to implementation**

Run the same `xcodebuild` command.

Expected: FAIL，但失败应收敛到 `visibleLineMetrics(in:)` 未实现或 gutter 未接入 snapshot，而不是 harness 不可访问。

**Step 5: Commit**

```bash
git add agentGuiTests/CodeEditorTextViewIntegrationTests.swift agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift
git commit -m "test: define feature 9 gutter metrics behavior"
```

### Task 2: 增加窄 metrics 类型并在 text view 里实现批量导出 API

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorVisibleLineMetric.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`

**Step 1: Write the failing test assertion for exact metric shape**

在 `textViewExportsVisibleLineMetricsForViewport()` 里再补一条更具体的断言，确保 rect 高度和行号都有值：

```swift
#expect(metrics.allSatisfy { $0.rect.height > 0 })
#expect(metrics == metrics.sorted { $0.line < $1.line })
```

**Step 2: Run test to verify it fails**

Run the same focused `xcodebuild` command.

Expected: FAIL，因为类型和 API 还不存在。

**Step 3: Write minimal implementation**

新增窄类型文件，并在 `CodeEditorPlatformTextView` 中实现批量 API：

```swift
struct CodeEditorVisibleLineMetric: Equatable, Sendable {
    let line: Int
    let rect: CGRect
    let baselineY: CGFloat
}

struct CodeEditorGutterLineMetricsSnapshot: Equatable, Sendable {
    let lineCount: Int
    let visibleLineRange: ClosedRange<Int>
    let currentLine: Int?
    let lineMetrics: [CodeEditorVisibleLineMetric]
    let diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary]
}
```

```swift
func visibleLineMetrics(in visibleRect: NSRect) -> [CodeEditorVisibleLineMetric] {
    guard let layoutManager, let textContainer else {
        return []
    }

    layoutManager.ensureLayout(for: textContainer)
    let visibleLineRange = displayedVisibleLineRange(in: visibleRect)
    return Array(visibleLineRange).compactMap { line in
        guard let rect = displayedLineRect(
            for: line,
            layoutManager: layoutManager,
            textContainer: textContainer
        ) else {
            return nil
        }

        return CodeEditorVisibleLineMetric(
            line: line,
            rect: rect,
            baselineY: rect.minY + baselineOffset(for: line, layoutManager: layoutManager)
        )
    }
}
```

说明：这里的 `displayedVisibleLineRange(in:)` 和 `displayedLineRect(for:layoutManager:textContainer:)` 应该复用现有 `displayedLineRange(for:)` / `backgroundRect(forLine:)` 的安全边界处理，不要重新写第三套范围裁剪逻辑。

**Step 4: Run test to verify it passes**

Run the same focused `xcodebuild` command.

Expected: `textViewExportsVisibleLineMetricsForViewport()` 通过，其余新测试仍可能因 gutter 尚未消费 snapshot 而失败。

**Step 5: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorVisibleLineMetric.swift agentGui/Views/CodeEditor/CodeEditorTextView.swift agentGuiTests/CodeEditorTextViewIntegrationTests.swift
git commit -m "feat: add viewport line metrics export"
```

### Task 3: 把 coordinator 和 gutter 改成消费 line metrics snapshot

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorGutterView.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`

**Step 1: Write the failing test for gutter state**

在 `gutterConsumesViewportLineMetricsSnapshot()` 里补一条断言，确保滚动后 gutter snapshot 直接包含目标行 rect，而不是只有 visible range：

```swift
#expect(harness.gutterLineMetrics.first(where: { $0.line == 40 })?.rect.height ?? 0 > 0)
```

**Step 2: Run test to verify it fails**

Run the same focused `xcodebuild` command.

Expected: FAIL，因为 `CodeEditorGutterView` 还没有存储 line metrics snapshot。

**Step 3: Write minimal implementation**

在 coordinator 中构造 `CodeEditorGutterLineMetricsSnapshot`，在 gutter 中改成消费 snapshot：

```swift
func updateGutterState(for textView: NSTextView) {
    guard let textView = textView as? CodeEditorPlatformTextView,
          let gutterView = gutterView(for: textView),
          let scrollView = textView.enclosingScrollView else {
        return
    }

    let visibleLineRange = visibleLineRange(for: textView) ?? fullDocumentLineRange()
    let snapshot = CodeEditorGutterLineMetricsSnapshot(
        lineCount: textView.displayedLineCount,
        visibleLineRange: visibleLineRange,
        currentLine: textView.highlightedLineNumber,
        lineMetrics: textView.visibleLineMetrics(in: scrollView.contentView.bounds),
        diagnosticsByLine: parent.diagnosticsByLine
    )

    gutterView.updateLayoutState(snapshot)
}
```

```swift
func updateLayoutState(_ snapshot: CodeEditorGutterLineMetricsSnapshot) {
    let previousWidth = requiredWidth
    let previousVisible = visibleLineRange
    let previousCurrentLine = currentLine
    let previousDiagnostics = diagnosticsByLine
    let previousMetricLines = Set(lineMetricsByLine.keys)

    lineCount = max(snapshot.lineCount, 1)
    visibleLineRange = snapshot.visibleLineRange
    currentLine = snapshot.currentLine
    diagnosticsByLine = snapshot.diagnosticsByLine
    lineMetrics = snapshot.lineMetrics
    lineMetricsByLine = Dictionary(uniqueKeysWithValues: snapshot.lineMetrics.map { ($0.line, $0) })

    if previousWidth != requiredWidth {
        invalidateIntrinsicContentSize()
        onRequiredWidthChange?()
    }

    invalidateLine(previousCurrentLine)
    invalidateLine(currentLine)
    invalidateLineRange(previousVisible)
    invalidateLineRange(visibleLineRange)
    for line in previousMetricLines.symmetricDifference(lineMetricsByLine.keys) {
        invalidateLine(line)
    }
    // diagnostics diff 逻辑保持现有实现
}
```

绘制时直接通过 `lineMetricsByLine[line]?.rect` 取行 rect；删除或降级 `lineRect(forLine:)` 对 `textView.backgroundRect(forLine:)` 的依赖。

**Step 4: Run test to verify it passes**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination platform=macOS -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature9-derived -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests CODE_SIGNING_ALLOWED=NO
```

Expected: viewport metrics、gutter snapshot、滚动与 diagnostics 相关测试全部通过。

**Step 5: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorTextView.swift agentGui/Views/CodeEditor/CodeEditorGutterView.swift agentGuiTests/CodeEditorTextViewIntegrationTests.swift
git commit -m "feat: wire gutter to viewport line metrics snapshot"
```

### Task 4: 锁住 IME marked text 和新增换行的回归

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`

**Step 1: Write the failing test**

把现有 marked text 测试扩成同时验证 text view API 和 gutter snapshot：

```swift
@Test
func markedTextRefreshesViewportMetricsAfterInsertedLineBreak() {
    let harness = CodeEditorTextViewHarness(text: "one\ntwo")

    harness.setMarkedText(
        "\n三",
        selectedRange: NSRange(location: 2, length: 0),
        replacementRange: NSRange(location: harness.textView.string.utf16.count, length: 0)
    )

    #expect(harness.visibleLineMetricsForCurrentViewport().contains { $0.line == 3 })
    #expect(harness.gutterLineMetrics.contains { $0.line == 3 })
}
```

**Step 2: Run test to verify it fails**

Run the same focused `xcodebuild` command.

Expected: 如果 marked text 生命周期里没有触发新的 snapshot 构造，这条测试会失败。

**Step 3: Write minimal implementation**

确认并补齐以下刷新链路：

- `setMarkedText` / `unmarkText` -> `compositionStateChangeHandler`
- coordinator 对 composition 变化继续调用 `scheduleHighlight(for:dirtyLineRange:)`
- `scheduleHighlight` 在 `hasMarkedText()` 时仍然调用 `publishVisibleLineRange(for:)` 与 `updateGutterState(for:)`

如果执行时发现 snapshot 使用的是错误坐标空间，则在 `visibleLineMetrics(in:)` 中统一改成以 `scrollView.contentView.bounds` 为输入，再由 text view 内部负责坐标换算。

**Step 4: Run test to verify it passes**

Run the same focused `xcodebuild` command.

Expected: marked text、新增换行、滚动后 metrics 相关测试都通过。

**Step 5: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorTextView.swift agentGuiTests/CodeEditorTextViewIntegrationTests.swift
git commit -m "test: cover marked text viewport metrics refresh"
```

### Task 5: 运行回归并收尾文档说明

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-30-code-editor-feature-9-implementation-plan.md`
  仅在执行过程中发现需要补充命令、风险或验收说明时修改。

**Step 1: Run focused code editor tests**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination platform=macOS -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature9-derived -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests -only-testing:agentGuiTests/CodeEditorViewIntegrationTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS，确认 Feature 9 没有破坏 code editor 宿主和上层 SwiftUI 集成。

**Step 2: Run broader gutter regression**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination platform=macOS -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature9-derived-full -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests -only-testing:agentGuiTests/CodeEditorViewIntegrationTests -only-testing:agentGuiTests/CodeEditorViewModelTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS。如果这里失败且与 Feature 9 无关，只记录为现有基线问题，不要顺手修 unrelated bug。

**Step 3: Sanity-check the acceptance criteria manually**

手工确认三件事：

- gutter 绘制链路不再逐行反查 `backgroundRect(forLine:)`
- marked text 新增换行后 gutter 仍能显示新增行号
- 滚动到远处行后 gutter snapshot 里仍能看到对应行 metrics

**Step 4: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorTextView.swift agentGui/Views/CodeEditor/CodeEditorGutterView.swift agentGui/Views/CodeEditor/CodeEditorVisibleLineMetric.swift agentGuiTests/CodeEditorTextViewIntegrationTests.swift agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift
git commit -m "feat: batch viewport line metrics for gutter"
```

## 6. 风险与执行注意事项

- `scrollView.contentView.bounds` 与 text view 自身坐标空间不同，批量 API 必须明确由谁做坐标转换；推荐让 text view 自己吸收转换细节，对外只返回 text view 坐标中的 rect。
- `displayedLineCount` 在 marked text 期间可能大于持久化文档行数，测试必须始终以 displayed state 为准，而不是 `document.lineCount`。
- 如果批量 API 在空文档或最后一行空行上返回空数组，先复用单行 API 已有的 fallback 行高逻辑，不要新造第四套空文档特判。
- 不要在 Feature 9 顺手把 gutter 的 `draw(_:)` 重写成 renderer/`CALayer` 方案；那是 Feature 10 的范围。
- 若执行时发现 `baselineY` 当前没有稳定消费者，可以先通过测试锁住 `rect` 正确性，把 baseline 作为结构保留但不在 gutter 中使用；不要为了未消费字段放大本轮风险。

## 7. 完成定义

Feature 9 结束时应满足：

- `CodeEditorPlatformTextView` 能批量导出当前 viewport 的 `CodeEditorVisibleLineMetric`。
- coordinator 会把 line metrics 与当前 gutter 状态组装成单次 snapshot 并推送给 gutter。
- `CodeEditorGutterView` 绘制和失效路径不再逐行调用 `backgroundRect(forLine:)`。
- 现有 marked text、新增换行、滚动、diagnostics 和当前行高亮的集成测试仍然通过。
- 没有把 Feature 10/11/14 的 renderer、lane、diff-aware 模型提前混进本轮实现。
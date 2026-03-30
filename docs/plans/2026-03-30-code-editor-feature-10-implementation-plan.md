# Code Editor Feature 10 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为自定义 gutter 引入独立 renderer、稳定的样式与宽度缓存，以及由 snapshot diff 驱动的最小失效路径，确保 current line 切换、diagnostics 更新和普通滚动都不再退化为整列无差别重绘。

**Architecture:** Feature 10 建立一个明确的“状态快照 -> renderer -> invalidate plan -> draw”链路。`CodeEditorTextView.Coordinator` 继续负责把 text view viewport 数据转换成 gutter 可消费的 snapshot；`CodeEditorGutterRenderer` 负责缓存数字绘制属性、测量宽度、比较旧新 snapshot 并生成最小失效计划；`CodeEditorGutterView` 退化成一个薄宿主，只保存前后 snapshot、应用 renderer 的 invalidate plan，并在 `draw(_:)` 中委托 renderer 完成绘制。本轮不提前实现 Feature 11 的 lane 抽象，也不把 Feature 14 的 diff-aware 字段提前塞进 snapshot。

**Tech Stack:** Swift 6、SwiftUI、AppKit、TextKit 1、Foundation、现有 `CodeEditorViewportContainerView` / `CodeEditorTextView` / `CodeEditorGutterView` / `CodeEditorVisibleLineMetric` / `CodeEditorTextViewHarness`、Swift Testing

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 当前执行状态（2026-03-30）

- Feature 8 已完成：gutter 已经脱离 `NSRulerView`，当前由 `CodeEditorViewportContainerView` 以 sibling column 方式承载。
- Feature 9 已完成：`CodeEditorPlatformTextView.visibleLineMetrics(in:)` 会批量导出 viewport line metrics，coordinator 也已经把这些 metrics 转成 `CodeEditorGutterLineMetricsSnapshot` 推给 gutter。
- 当前 `CodeEditorGutterView` 仍然同时承担“状态保存、diff 比较、invalidate、绘制”四种职责，`updateLayoutState(_:)` 里还保留了 `needsDisplay = true`，这会直接触发整列重绘，违背 Feature 10 的验收目标。
- 当前 `draw(_:)` 每次都会新建 `NSMutableParagraphStyle`、字体属性字典和字符串绘制属性，`requiredWidth(for:)` 也还是基于 `digits * 8 + 20` 的经验公式，而不是实际测量结果缓存。
- 当前测试只验证了 gutter 几何与 viewport metrics 接线正确，还没有独立覆盖“current line 只重绘两行”“diagnostics 只重绘变化行”“滚动不触发 full redraw fallback”这三条关键回归。

## 0. 范围约束

- Feature 10 只实现 renderer 抽离、样式/宽度缓存和最小失效；不提前做 Feature 11 的 lane 化。
- Feature 10 可以把现有 `CodeEditorGutterLineMetricsSnapshot` 升级为更明确的 renderer snapshot，但不要提前加入 `surface role`、`diffByLine`、`chunkAnchors` 等 Feature 14 字段。
- Feature 10 不修改 `CodeEditorView` 的 SwiftUI 外部 API，不改变上层 `CodeEditorViewModel` 或 `FileEditorView` 的调用方式。
- Feature 10 不迁移 TextKit 2，不改写 `CodeEditorPlatformTextView.visibleLineMetrics(in:)` 的主语义；它仍然是 gutter 几何的唯一来源。
- Feature 10 不要求在这一轮把 breakpoint、folding、hover affordance 做出来；只需要把 renderer 结构设计成未来可承接这些 lane。
- Feature 10 必须显式消除 `CodeEditorGutterView.updateLayoutState(_:)` 中的 unconditional `needsDisplay = true`，否则本 Feature 的核心目标没有真正达成。

## 1. 代码锚点

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorGutterView.swift`
  当前最大的根问题在这里：状态 diff、局部失效和实际绘制耦合在一个 `NSView` 里，而且 `updateLayoutState(_:)` 先全量 `needsDisplay = true`，再追加按行 `setNeedsDisplay(rect)`，导致前面的局部失效努力被直接抵消。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
  coordinator 的 `updateGutterState(for:)` 是 snapshot 组装入口。Feature 10 需要让这个入口产出 renderer 真正需要的稳定快照，同时避免把 gutter 宽度硬编码进每个 metric 的布局语义里。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorVisibleLineMetric.swift`
  当前这里只定义了 Feature 9 的窄类型。Feature 10 需要决定是扩展这个文件，还是拆出新的 `CodeEditorGutterViewportSnapshot.swift` 以承载 renderer 相关的状态和 invalidate plan 类型。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorViewportContainerView.swift`
  本轮大概率只需要维持现有 gutter 宽度变化回调；如果 renderer 的宽度缓存改成实际测量值，这里要确保新的 `requiredWidth` 变化仍能触发布局。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
  当前已有 gutter host、viewport metrics、diagnostics 和 marked text 的集成测试。Feature 10 应继续在这里补充最小失效的宿主级断言。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`
  需要扩展为能观察 gutter invalidate 结果、renderer 输出或最小必要的调试统计，否则无法稳定验证“没有 full redraw fallback”。

## 2. 方案结论

Feature 10 推荐按下面这条最窄且可验证的路线落地：

1. 新增一个 renderer 专用 snapshot 类型，例如 `CodeEditorGutterViewportSnapshot`，把 `lineCount`、`visibleLineRange`、`currentLine`、`lineMetrics` 和 `diagnosticsByLine` 收敛成单一值快照。
2. 新增 `CodeEditorGutterRenderer`，集中负责三类逻辑：
   - 根据字体、颜色、当前行态缓存数字绘制 attributes 与 paragraph style。
   - 基于真实测量结果缓存 gutter 所需宽度，而不是继续用 `digits * 8 + 20` 猜测。
   - 比较旧新 snapshot，生成一个最小失效计划，例如“仅重绘行集合”“滚动复制后只重绘暴露条带”“整列重绘”。
3. `CodeEditorGutterView` 自己不再决定应该 invalidates 哪些行，而是保存 `previousSnapshot` / `currentSnapshot`，调用 renderer 计算 invalidate plan，并把计划转换成 `setNeedsDisplay(_:)` 或滚动复制路径。
4. `draw(_:)` 只保留宿主层工作：清背景、裁剪 dirty rect、向 renderer 传入 snapshot 与 bounds。具体的 label rect、marker rect、颜色与字体选择全部移到 renderer。
5. 对普通滚动引入一个显式的“统一垂直位移”优化：当旧新 snapshot 的重叠行整体只发生等量垂直平移，且宽度、current line、diagnostics 都没有变化时，优先走 gutter 自己的滚动复制/暴露区重绘路径，而不是把所有可见行标成脏区。

不推荐的路线：

- 不要继续在 `CodeEditorGutterView` 里叠加更多 `invalidateLine(...)` 特判。那只会把 renderer 逻辑继续埋在 view 里，Feature 10 做完后仍然没有清晰的渲染边界。
- 不要把宽度缓存做成 `static` 全局单例。宽度至少要受字体、字号、digits 位数和当前 appearance 影响，否则测试与运行时切换外观时容易出现错误缓存。
- 不要依赖“没有调用 `needsDisplay = true`”作为唯一成功标准。真正要验证的是 renderer 产出的 invalidate plan 足够收敛，并且 view 没有退回整列全 bounds 重绘。

## 3. 新增类型建议

建议新增一个文件 `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorGutterViewportSnapshot.swift`，只承载 Feature 10 真正需要的 renderer 模型：

```swift
import AppKit
import Foundation

struct CodeEditorGutterViewportSnapshot: Equatable, Sendable {
    let lineCount: Int
    let visibleLineRange: ClosedRange<Int>
    let currentLine: Int?
    let lineMetrics: [CodeEditorVisibleLineMetric]
    let diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary]
}

enum CodeEditorGutterInvalidationPlan: Equatable, Sendable {
    case full
    case redraw(lines: Set<Int>, redrawSeparator: Bool)
    case scroll(deltaY: CGFloat, exposedLines: Set<Int>, redrawLines: Set<Int>, redrawSeparator: Bool)
}
```

这里不要把 line rect 的宽度当成 snapshot 真相。宽度属于 renderer 的布局结果，而不是 coordinator 的输入真相。执行时如果发现当前 `CodeEditorVisibleLineMetric.rect.width` 已经被消费，优先把 renderer 逻辑改成只依赖 `minY`、`height` 和 `baselineY`，并统一用 `bounds.width` 计算 label 与 marker 横向布局。

`CodeEditorGutterRenderer` 建议新增到 `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorGutterRenderer.swift`，最小 API 形状如下：

```swift
import AppKit

struct CodeEditorGutterRenderer {
    mutating func requiredWidth(for snapshot: CodeEditorGutterViewportSnapshot, appearance: NSAppearance?) -> CGFloat
    mutating func invalidationPlan(
        from previous: CodeEditorGutterViewportSnapshot?,
        to current: CodeEditorGutterViewportSnapshot
    ) -> CodeEditorGutterInvalidationPlan
    mutating func draw(
        snapshot: CodeEditorGutterViewportSnapshot,
        in dirtyRect: NSRect,
        bounds: NSRect,
        appearance: NSAppearance?
    )
}
```

这里 `mutating` 是合理的，因为 renderer 需要维护字体属性缓存、digits 宽度缓存和最近一次测量结果。不要把这些 cache 分散到 `CodeEditorGutterView` 和 helper 函数里。

## 4. 任务拆分

### Task 1: 建立 renderer snapshot 与最小失效单元测试

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorGutterViewportSnapshot.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorGutterRenderer.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorGutterRendererTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorVisibleLineMetric.swift`

**Step 1: 写失败的 renderer 单元测试**

先在 `CodeEditorGutterRendererTests.swift` 写最小失败用例，至少覆盖三类 diff：

```swift
@Test
func currentLineChangeInvalidatesOnlyOldAndNewLines() {
    let previous = makeSnapshot(currentLine: 10, diagnostics: [:], visibleRange: 8...18)
    let current = makeSnapshot(currentLine: 11, diagnostics: [:], visibleRange: 8...18)

    var renderer = CodeEditorGutterRenderer()

    #expect(renderer.invalidationPlan(from: previous, to: current) == .redraw(lines: [10, 11], redrawSeparator: false))
}

@Test
func diagnosticsChangeInvalidatesOnlyChangedLines() {
    let previous = makeSnapshot(currentLine: 10, diagnostics: [:], visibleRange: 8...18)
    let current = makeSnapshot(currentLine: 10, diagnostics: [12: .init(highestSeverity: .warning, messageCount: 1)], visibleRange: 8...18)

    var renderer = CodeEditorGutterRenderer()

    #expect(renderer.invalidationPlan(from: previous, to: current) == .redraw(lines: [12], redrawSeparator: false))
}
```

额外再写一个宽度缓存测试，断言 `99 -> 100` 会扩宽，而 `40 -> 41` 不会重新测量更宽结果。

**Step 2: 运行测试，确认当前失败**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature10-derived -only-testing:agentGuiTests/CodeEditorGutterRendererTests CODE_SIGNING_ALLOWED=NO
```

Expected: 编译失败，提示 `CodeEditorGutterRenderer`、`CodeEditorGutterViewportSnapshot` 或对应 API 尚不存在。

**Step 3: 写最小实现**

先只实现 snapshot、renderer 骨架和基于行集合的 invalidate diff，不要一开始就把滚动复制优化一起写进来。最小可工作的骨架可以像这样：

```swift
struct CodeEditorGutterRenderer {
    private var cachedWidthKey: WidthCacheKey?
    private var cachedWidth: CGFloat?

    mutating func requiredWidth(for snapshot: CodeEditorGutterViewportSnapshot, appearance: NSAppearance?) -> CGFloat {
        let digits = max(2, String(max(snapshot.lineCount, 1)).count)
        let key = WidthCacheKey(digits: digits, appearanceName: appearance?.name.rawValue)
        if key == cachedWidthKey, let cachedWidth {
            return cachedWidth
        }

        let width = measureWidth(forDigits: digits) + 20
        cachedWidthKey = key
        cachedWidth = width
        return width
    }

    mutating func invalidationPlan(
        from previous: CodeEditorGutterViewportSnapshot?,
        to current: CodeEditorGutterViewportSnapshot
    ) -> CodeEditorGutterInvalidationPlan {
        guard let previous else {
            return .full
        }
        let changedLines = changedCurrentLines(from: previous, to: current)
            .union(changedDiagnosticLines(from: previous, to: current))
        return changedLines.isEmpty ? .redraw(lines: [], redrawSeparator: false) : .redraw(lines: changedLines, redrawSeparator: false)
    }
}
```

注意这里的 `.redraw(lines: [])` 不是最终形态。执行时如果 view 应用空计划更麻烦，可以把它改成 `.redraw(lines: [], redrawSeparator: false)` 或单独的 `.none` case，但要在测试里保持语义清晰。

**Step 4: 再跑测试，确认通过**

Run 同上。

Expected: `CodeEditorGutterRendererTests` 全绿，且宽度缓存测试不再依赖 `digits * 8 + 20` 的魔法值断言。

**Step 5: 提交**

```bash
git add agentGui/Views/CodeEditor/CodeEditorGutterViewportSnapshot.swift agentGui/Views/CodeEditor/CodeEditorGutterRenderer.swift agentGui/Views/CodeEditor/CodeEditorVisibleLineMetric.swift agentGuiTests/CodeEditorGutterRendererTests.swift
git commit -m "feat: add gutter renderer snapshot and diff model"
```

### Task 2: 把 `CodeEditorGutterView` 改成薄宿主并移除 full redraw fallback

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorGutterView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`

**Step 1: 先写失败的集成测试和 harness 观察接口**

在 harness 里增加一个最小可见的 invalidate 观测接口，例如：

```swift
var gutterInvalidationSummary: CodeEditorGutterInvalidationSummary? {
    gutterView?.lastInvalidationSummary
}
```

然后在 `CodeEditorTextViewIntegrationTests.swift` 先写两个失败用例：

```swift
@Test
func currentLineSwitchOnlyInvalidatesOldAndNewLines() {
    let harness = CodeEditorTextViewHarness(text: (1...40).map { "line \($0)" }.joined(separator: "\n"))

    harness.selectLine(10)
    harness.clearGutterInvalidationSummary()
    harness.selectLine(11)

    #expect(harness.gutterInvalidationSummary?.redrawnLines == [10, 11])
    #expect(harness.gutterInvalidationSummary?.usedFullRedraw == false)
}

@Test
func diagnosticsUpdateOnlyInvalidatesChangedLines() {
    let harness = CodeEditorTextViewHarness(text: (1...40).map { "line \($0)" }.joined(separator: "\n"))

    harness.clearGutterInvalidationSummary()
    harness.updateDiagnosticsByLine([15: .init(highestSeverity: .error, messageCount: 1)])

    #expect(harness.gutterInvalidationSummary?.redrawnLines == [15])
    #expect(harness.gutterInvalidationSummary?.usedFullRedraw == false)
}
```

这里不要试图直接断言 `setNeedsDisplay` 被调用了几次。更稳定的做法是让 gutter view 在测试可见的内部状态里保存“renderer 产出的 invalidate plan 已被应用”的摘要。

**Step 2: 运行测试，确认当前失败**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature10-derived -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests -only-testing:agentGuiTests/CodeEditorGutterRendererTests CODE_SIGNING_ALLOWED=NO
```

Expected: 新增的 gutter invalidate 断言失败，因为当前实现还会走 `needsDisplay = true`，也没有调试摘要可读。

**Step 3: 写最小实现**

把 `CodeEditorGutterView` 重构成“宿主 + renderer”结构：

```swift
final class CodeEditorGutterView: NSView {
    private var renderer = CodeEditorGutterRenderer()
    private var snapshot: CodeEditorGutterViewportSnapshot?
    private(set) var lastInvalidationSummary: CodeEditorGutterInvalidationSummary?

    func updateLayoutState(_ snapshot: CodeEditorGutterViewportSnapshot) {
        let previous = self.snapshot
        self.snapshot = snapshot

        let previousWidth = requiredWidth
        let nextWidth = renderer.requiredWidth(for: snapshot, appearance: effectiveAppearance)
        if previousWidth != nextWidth {
            invalidateIntrinsicContentSize()
            onRequiredWidthChange?()
        }

        let plan = renderer.invalidationPlan(from: previous, to: snapshot)
        apply(plan, previous: previous, current: snapshot)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let snapshot else { return }
        renderer.draw(snapshot: snapshot, in: dirtyRect, bounds: bounds, appearance: effectiveAppearance)
    }
}
```

关键点：

- 删除 `needsDisplay = true`。
- 删除 `draw(_:)` 里临时创建 paragraph style 和 attributes 的逻辑，统一交给 renderer。
- `requiredWidth` 改成从 renderer 的缓存值读取，而不是 view 自己静态估算。
- 测试摘要只记录必要信息，例如 `redrawnLines`、`usedFullRedraw`、`scrollDeltaY`，不要把整个 view 内部状态都暴露给测试。

**Step 4: 再跑测试，确认通过**

Run 同上。

Expected: current line 与 diagnostics 的最小失效测试通过，且原有 gutter metrics / marked text 相关测试没有回归。

**Step 5: 提交**

```bash
git add agentGui/Views/CodeEditor/CodeEditorGutterView.swift agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift agentGuiTests/CodeEditorTextViewIntegrationTests.swift
git commit -m "refactor: route gutter invalidation through renderer"
```

### Task 3: 为普通滚动补上统一位移优化，避免整列重绘

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorGutterRenderer.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorGutterView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorGutterRendererTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`

**Step 1: 先写失败的滚动优化测试**

先在 renderer 单元测试里建一个稳定场景：旧快照 `10...20`，新快照 `11...21`，重叠行 `11...20` 的 `minY` 全部相差同一个 `deltaY`，且 current line 与 diagnostics 完全不变。断言 renderer 返回滚动计划而不是 full redraw：

```swift
@Test
func viewportScrollProducesScrollPlanInsteadOfFullRedraw() {
    let previous = makeSnapshot(visibleRange: 10...20, translatedBy: 0)
    let current = makeSnapshot(visibleRange: 11...21, translatedBy: -14)

    var renderer = CodeEditorGutterRenderer()

    let plan = renderer.invalidationPlan(from: previous, to: current)

    #expect(plan == .scroll(deltaY: -14, exposedLines: [21], redrawLines: [], redrawSeparator: false))
}
```

再在集成测试里加一条高层断言：滚动一行后，gutter invalidate 摘要不能标记 `usedFullRedraw == true`，并且暴露线集合应只包含新进入 viewport 的行或离开 viewport 的行。

**Step 2: 运行测试，确认当前失败**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature10-derived -only-testing:agentGuiTests/CodeEditorGutterRendererTests -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests CODE_SIGNING_ALLOWED=NO
```

Expected: 滚动相关断言失败，因为当前 diff 比较会把所有行位置变化都当成普通 changed metrics 处理。

**Step 3: 写最小实现**

renderer 里加入统一位移检测：

- 先求旧新 snapshot 的重叠行集合。
- 对重叠行比较 `metric.rect.minY` 差值；只有当所有差值一致、宽度未变、separator 状态未变、current line 和 diagnostics 仅在暴露行之外稳定时，才产出 `.scroll(...)`。
- `CodeEditorGutterView.apply(plan:...)` 收到 `.scroll(...)` 时，先走 AppKit 的视图内容平移/复制路径，再仅对暴露条带和额外 `redrawLines` 调用 `setNeedsDisplay(_:)`。

实现时要注意两点：

- 比较位移时统一使用 `.integral` 或明确的 `CGFloat` 容差，避免像素对齐导致的伪变化把优化打碎。
- 如果滚动同时伴随位数变化、字体变化或 diagnostics/current line 跨入新旧可见边界，允许安全地退回 `.redraw(...)` 或 `.full`；不要为了省一条 redraw 让逻辑变脆。

**Step 4: 再跑测试，确认通过**

Run 同上。

Expected: 滚动测试通过，renderer 的 invalidate plan 能区分“普通状态变更”和“统一垂直位移”。

**Step 5: 提交**

```bash
git add agentGui/Views/CodeEditor/CodeEditorGutterRenderer.swift agentGui/Views/CodeEditor/CodeEditorGutterView.swift agentGuiTests/CodeEditorGutterRendererTests.swift agentGuiTests/CodeEditorTextViewIntegrationTests.swift agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift
git commit -m "perf: minimize gutter redraw during viewport scroll"
```

### Task 4: 做端到端回归并收敛测试入口

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`
- Optional Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorViewportContainerView.swift`

**Step 1: 补齐最终验收测试**

把 Feature 10 的三条验收标准显式落到测试名里，建议至少保留这三条：

- `currentLineSwitchOnlyInvalidatesOldAndNewLines()`
- `diagnosticsUpdateOnlyInvalidatesChangedLines()`
- `viewportScrollDoesNotFallbackToFullGutterRedraw()`

如果在执行中发现宽度缓存容易回归，再加一条：

- `lineCountDigitBoundaryTriggersWidthRecalculationOnlyWhenNeeded()`

同时保留并重跑现有回归：`gutterConsumesViewportLineMetricsSnapshot()`、`gutterGeometryTracksDisplayedTextWhileMarkedTextAddsLineBreak()`、`emptyDocumentExportsViewportMetricsFallbackLine()`。

**Step 2: 运行 focused test 套件**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature10-derived -only-testing:agentGuiTests/CodeEditorGutterRendererTests -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests -only-testing:agentGuiTests/CodeEditorViewIntegrationTests CODE_SIGNING_ALLOWED=NO
```

Expected: Feature 10 新增测试与 Feature 8/9 既有 gutter 回归全部通过。

**Step 3: 运行已有 gutter 回归入口**

如果仓库中的 VS Code task `CodeEditor Gutter Fix Tests` 仍可用，再跑一次，确保 Feature 10 不只是单元测试通过，而是与现有集成脚本兼容。

Expected: 任务执行成功，没有新增 gutter 相关失败。

**Step 4: 如果需要，补最小布局修正**

只有在执行时发现 renderer 宽度缓存更新后 `CodeEditorViewportContainerView` 没有及时 relayout，才修改容器视图；否则不动，避免把 Feature 10 扩散成宿主层重构。

**Step 5: 提交**

```bash
git add agentGuiTests/CodeEditorTextViewIntegrationTests.swift agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift agentGui/Views/CodeEditor/CodeEditorViewportContainerView.swift
git commit -m "test: cover gutter minimal invalidation regressions"
```

## 5. 执行注意事项

- `CodeEditorTextView.Coordinator.updateGutterState(for:)` 当前在把 text view metrics 转为 gutter metrics 时，会把 `gutterView.requiredWidth` 写入每个 `CodeEditorVisibleLineMetric.rect.width`。执行 Feature 10 时，优先把 renderer 设计成不依赖这个宽度值，避免出现“先算旧宽度，再因新 snapshot 改变位数，导致同一帧 metric 宽度与真实 gutter 宽度不一致”的错配。
- 不要把 `CodeEditorGutterRenderer` 做成引用类型。值类型 renderer 更适合本轮的“缓存 + 纯函数式 diff”心智模型，也更容易在测试中构造和比较。
- 如果滚动复制路径在 AppKit 中实现起来比预期更脆，优先保持 renderer 单元测试的 invalidate plan 正确，并让 view 只在纯滚动时退回“暴露条带 + 重叠行局部 redraw”的安全路径；不要重新引入整列 `needsDisplay = true`。
- 测试辅助状态应保持最小，只暴露 `redrawnLines`、`usedFullRedraw`、`scrollDeltaY` 这类验收必须的信息，避免 harness 演变成对 gutter 内部实现的镜像。

## 6. 完成定义

Feature 10 完成时，应同时满足下面几点：

1. `CodeEditorGutterView` 不再拥有自己的绘制样式构建逻辑，也不再在 `updateLayoutState(_:)` 里直接 `needsDisplay = true`。
2. `CodeEditorGutterRendererTests` 能独立证明 current line diff、diagnostics diff、width cache 和普通滚动的 invalidate 计划正确。
3. `CodeEditorTextViewIntegrationTests` 能从宿主层证明：current line 切换只影响两行，diagnostics 更新只影响变化行，普通滚动没有回退为 full redraw。
4. 现有 Feature 8/9 的 viewport metrics、marked text、empty document 和 gutter host 回归仍保持通过。
5. 最终代码路径已经具备清晰的演进边界：Feature 11 只需要在 renderer 上继续做 lane 化，而不需要再次拆宿主或重写 invalidate 主链路。

Plan complete and saved to `docs/plans/2026-03-30-code-editor-feature-10-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - 我按任务逐步实现，每完成一段就回顾并继续推进。

**2. Parallel Session (separate)** - 另开一个会话，按 `executing-plans` 工作流逐任务执行。

**Which approach?**
# Code Editor Feature 8 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 把 CodeEditor 的 gutter 从 `NSScrollView.verticalRulerView` / `NSRulerView` 宿主迁出，替换为 editor-owned sibling column，同时保持现有 `NSTextView` 输入、选区、IME、撤销、当前行高亮和 diagnostics 行号标记行为不变。

**Architecture:** 这一轮只修正 gutter 的宿主关系，不提前实现 Feature 9 的批量 viewport metrics、Feature 10 的独立 renderer 或 Feature 11 的 lane 抽象。`CodeEditorTextView` 改为返回一个自定义编辑器容器视图，容器内部持有左侧 gutter column 和右侧现有 `NSScrollView + CodeEditorPlatformTextView`；现有 gutter 状态输入仍然沿用 `lineCount`、`visibleLineRange`、`currentLine` 和 `diagnosticsByLine`，几何仍继续通过 `CodeEditorPlatformTextView.backgroundRect(forLine:)` 获取，这样可以把改动限制在“宿主替换”这一层。

**Tech Stack:** Swift 6、SwiftUI、AppKit、TextKit 1、Foundation、现有 `CodeEditorView` / `CodeEditorTextView` / `CodeEditorGutterView` / `CodeEditorTextViewHarness`、Swift Testing

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 当前执行状态（2026-03-30）

- 当前 `CodeEditorTextView` 在 `makeNSView` 里直接返回 `NSScrollView`，并由 coordinator 的 `installGutter(for:textView:)` 把 `CodeEditorGutterView` 装到 `scrollView.verticalRulerView`。
- 当前 `CodeEditorGutterView` 仍然是 `NSRulerView` 子类，宽度靠 `ruleThickness`，绘制入口靠 `drawHashMarksAndLabels(in:)`，布局和生命周期都绑定在 AppKit 的 ruler 子系统上。
- 当前 gutter 已经只消费少量状态：`lineCount`、`visibleLineRange`、`currentLine`、`diagnosticsByLine`，这是 Feature 8 最应该保留的部分；本轮不需要把输入模型扩成 snapshot renderer。
- 当前行背景与 gutter 行号高亮依赖 `CodeEditorPlatformTextView.backgroundRect(forLine:)` 提供的行几何。这个 API 已经被 `CodeEditorGutterView.lineRect(forLine:)` 和测试 harness 复用，因此 Feature 8 可以继续沿用它，而不必提前做批量 metrics。
- 测试基线仍然按“ruler 已安装”建模：`CodeEditorTextViewIntegrationTests.textViewInstallsCodeEditorGutter()` 当前断言 `hasVerticalRuler == true`、`rulersVisible == true`，`CodeEditorTextViewHarness.gutterView` 也直接从 `scrollView.verticalRulerView` 取值。Feature 8 必须先把这些测试契约改成新宿主模型。
- `CodeEditorView` 只是 `CodeEditorTextView` 的 SwiftUI 壳层，本轮预计不需要改变它的外部 API；影响主要集中在 AppKit 宿主、coordinator 装配、gutter 视图类型和测试支撑。

## 0. 范围约束

- Feature 8 只做 gutter 宿主替换，不实现 Feature 9 的 `visibleLineMetrics(in:)` 批量导出。
- Feature 8 不引入新的 gutter snapshot、renderer、lane 配置或 diff-aware 模型；这些都留给后续 Feature。
- Feature 8 不改变 `CodeEditorView` 的 SwiftUI 使用方式，不引入新的上层状态或新的 ViewModel。
- Feature 8 不修改 `CodeEditorPlatformTextView` 的文本输入主路径，不动 syntax highlight 调度、IME 组合态处理、hover/definition/find intent 事件流。
- Feature 8 不要求一次性做最小失效优化；首轮允许继续沿用当前按行 `setNeedsDisplay` 策略，只要 gutter 已完全脱离 ruler 体系。
- Feature 8 必须满足三个验收标准：行号仍可见、`NSScrollView.hasVerticalRuler == false`、gutter 背景与 separator 完全由自定义视图拥有。

## 1. 代码锚点

当前与 Feature 8 直接相关的真实落点如下：

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
  这里是宿主替换的主入口：当前返回 `NSScrollView`，coordinator 里也同时负责 gutter 安装、viewport 观察和状态推送。Feature 8 的核心改动会落在这个文件。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorGutterView.swift`
  当前是 `NSRulerView` 子类。Feature 8 需要把它改写成 editor-owned `NSView`，但尽量保留 `updateLayoutState(...)`、按行绘制和宽度计算等既有逻辑。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorView.swift`
  本轮大概率只受宿主类型变更的间接影响。除非执行时发现 `NSViewRepresentable` 类型调整导致 SwiftUI 宿主需要补适配，否则应尽量不动。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`
  当前 harness 能找到 `NSScrollView` 和 `CodeEditorPlatformTextView`，但 gutter 仍通过 `verticalRulerView` 暴露。Feature 8 需要把它扩成“能找到 editor container 和 sibling gutter column”的新模型。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
  这里已经覆盖 gutter 装配、diagnostics 更新、marked text 行几何和滚动发布，是验证宿主替换不破坏现有文本区行为的主测试文件。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`
  这里适合补一条上层回归，确保 `CodeEditorView` 经过宿主替换后仍能保持原有高亮、状态栏和 reveal 主路径正常。

## 2. 方案结论

Feature 8 建议按下面这条最窄实现路线落地：

1. 新增一个 editor-owned 容器视图，例如 `CodeEditorViewportContainerView`，由它持有左侧 gutter 和右侧 `NSScrollView`。
2. `CodeEditorTextView.makeNSView` 不再直接返回 `NSScrollView`，而是返回这个容器视图；scroll view 变成容器的内部实现细节。
3. `CodeEditorGutterView` 从 `NSRulerView` 重写成普通 `NSView`，但继续暴露当前的 `updateLayoutState(...)` API，并继续通过 `CodeEditorPlatformTextView.backgroundRect(forLine:)` 取得每行几何。
4. coordinator 不再调用 `verticalRulerView` / `hasVerticalRuler` / `rulersVisible`，而是通过容器直接拿到 gutter 视图并推送状态。
5. 所有现有文本区能力原样保留：`NSTextView` 仍放在 `NSScrollView` 内，输入、选区、IME、撤销、hover、find、reveal 和 viewport 观察路径不变。

不建议采用的路线：

- 不要把 gutter 改成叠在 scroll view 之上的 overlay。那条路径虽然也能摆脱 `NSRulerView`，但会把 hit testing、裁剪边界和后续 lane 扩展变得更脆。
- 不要在 Feature 8 里一并上 `visibleLineMetrics(in:)` 批量 API。宿主替换和 metrics 批量化是两个不同风险面，本轮应先把 ownership 修正做好。
- 不要让 `CodeEditorGutterView` 继续保留 `NSRulerView` 类型只是“少用一点 ruler API”。只要类型还是 ruler，布局与生命周期仍然绑在旧体系里，Feature 8 的目标就没有真正完成。

## 3. 设计细节

### 3.1 新容器视图边界

建议新增 `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorViewportContainerView.swift`，只承担三件事：

- 拥有 `gutterView`、`scrollView`、`textView` 三个稳定子对象
- 在 `layout()` 中完成 `[gutter][scrollView]` 横向排布
- 在 gutter 宽度变化后触发重新布局

建议的骨架可以保持极小：

```swift
import AppKit

final class CodeEditorViewportContainerView: NSView {
    let gutterView: CodeEditorGutterView
    let scrollView: NSScrollView
    let textView: CodeEditorPlatformTextView

    init(scrollView: NSScrollView, textView: CodeEditorPlatformTextView) {
        self.scrollView = scrollView
        self.textView = textView
        self.gutterView = CodeEditorGutterView(textView: textView, lineCount: textView.displayedLineCount)
        super.init(frame: .zero)
        addSubview(gutterView)
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let gutterWidth = gutterView.requiredWidth
        gutterView.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(x: gutterWidth, y: 0, width: bounds.width - gutterWidth, height: bounds.height)
    }
}
```

这里不要把 viewport 同步、行几何或 diagnostics 逻辑塞进容器；容器只做宿主和布局。`CodeEditorTextView.Coordinator` 仍然是状态协调者，避免本轮额外引入第二个控制器对象。

### 3.2 `CodeEditorTextView` 的宿主替换方式

`CodeEditorTextView` 当前的 `NSViewRepresentable` 宿主类型是 `NSScrollView`。Feature 8 推荐直接把 `makeNSView` / `updateNSView` 的返回类型切到 `CodeEditorViewportContainerView`，原因如下：

- sibling gutter 方案要求 scroll view 不再是最外层根视图；如果继续把 representable 根节点定义成 `NSScrollView`，容器就只能外接一层 SwiftUI 包装，反而破坏现有 Coordinator 对 AppKit 子树的掌控。
- 把容器作为根节点后，coordinator 可以直接同时访问 `container.scrollView`、`container.textView` 和 `container.gutterView`，不再依赖 `verticalRulerView` 这类隐式宿主通道。
- 这一改动不会影响 `CodeEditorView` 的 SwiftUI 调用方式，因为它并不关心 representable 内部到底返回哪种 `NSView`。

推荐的修改方向：

```swift
func makeNSView(context: Context) -> CodeEditorViewportContainerView
func updateNSView(_ container: CodeEditorViewportContainerView, context: Context)
```

执行时要特别注意两点：

- `installViewportObserver(for:textView:)` 仍应订阅 `scrollView.contentView.boundsDidChangeNotification`，不要改成监听 container 自己的 frame/bounds。
- `publishVisibleLineRange(for:)` 和 `updateGutterState(for:)` 的调用时机要保持与当前一致，确保 marked text、程序性 reveal 和 programmatic text update 都不会丢 gutter 刷新。

### 3.3 `CodeEditorGutterView` 的重写边界

Feature 8 不需要推倒现有 gutter 的状态接口，建议只把它从 ruler 子类改成普通 `NSView`：

```swift
final class CodeEditorGutterView: NSView {
    private weak var textView: CodeEditorPlatformTextView?
    private(set) var lineCount: Int
    private(set) var visibleLineRange: ClosedRange<Int>
    private(set) var currentLine: Int?
    private(set) var diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary]

    var requiredWidth: CGFloat {
        Self.requiredWidth(for: lineCount)
    }
}
```

推荐保留的逻辑：

- `updateLayoutState(...)`
- `invalidateLine(_:)`
- `lineRect(forLine:)`
- severity color helper
- 基于行数位数的宽度计算

需要替换的点：

- `ruleThickness` 改成 `requiredWidth`
- `drawHashMarksAndLabels(in:)` 改成 `draw(_:)`
- `clientView` 改成持有 `weak textView`
- 背景填充和 separator 改由 `draw(_:)` 内部先画，不再依赖 scroll view/ruler 默认样式

建议让 `updateLayoutState(...)` 返回一个布尔值或通过闭包通知“宽度是否变化”，供容器决定是否 `needsLayout = true`。这比继续在 gutter 内部偷偷改宿主布局更干净。

### 3.4 宽度与布局同步契约

Feature 8 虽然不做复杂 renderer，但宽度变化仍然要明确收敛。建议 contract 如下：

- gutter 宽度只由 `lineCount` 位数决定，沿用当前 `requiredThickness(for:)` 的策略
- 只有在位数阈值跨越时才请求容器重新布局，例如 `99 -> 100`
- 普通滚动、当前行切换、diagnostics 变化都不应导致容器重新 layout

可以把宽度变化信号做成最小接口：

```swift
var onRequiredWidthChange: (() -> Void)?
```

然后在 `updateLayoutState(...)` 里判断新旧宽度是否变化，变化时调用它。容器收到回调后执行 `needsLayout = true` 即可。

### 3.5 测试支撑如何调整

当前 harness 和集成测试有三处必须一起更新：

1. `CodeEditorTextViewHarness` 不能再把 gutter 从 `scrollView.verticalRulerView` 取出，而应改为先找到 `CodeEditorViewportContainerView`，再暴露 `containerView.gutterView`。
2. `textViewInstallsCodeEditorGutter()` 需要改成断言：
   - `scrollView.hasVerticalRuler == false`
   - `scrollView.rulersVisible == false` 或至少未启用 ruler 路径
   - `gutterView != nil`
3. diagnostics 与当前行高亮测试应继续验证 `gutterView.currentLine`、`gutterView.diagnosticsByLine`，确保宿主替换没有破坏状态同步。

如果执行时发现某些测试需要知道 gutter 是否真的在左侧 sibling column，可以加一条 frame 断言：`gutterView.frame.maxX <= scrollView.frame.minX`。这条断言比检查具体像素值更稳定。

## 4. 目标文件集

### New files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorViewportContainerView.swift`

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorGutterView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`

### Optional modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorView.swift`
  只有在执行时发现 `NSViewRepresentable` 根视图类型切换导致 SwiftUI 壳层需要补兼容处理时才修改；首轮优先不动。

## 5. 任务拆解

### Task 1: 先把测试和 harness 改成新的宿主契约

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`

**Step 1: Write the failing tests**

先把验收标准钉进测试，而不是先改实现。至少补或改下面这些断言：

- gutter 仍然存在，但不再通过 `verticalRulerView` 安装
- `scrollView.hasVerticalRuler == false`
- gutter 与 scroll view 是 sibling 关系，而不是 ruler 附属区域
- diagnostics 更新后，自定义 gutter 仍收到新状态

示例：

```swift
@Test
func textViewUsesCustomGutterHostInsteadOfVerticalRuler() {
    let harness = CodeEditorTextViewHarness(text: "one\ntwo\nthree")

    #expect(harness.scrollView.hasVerticalRuler == false)
    #expect(harness.scrollView.verticalRulerView == nil)
    #expect(harness.gutterView != nil)
    #expect(harness.gutterView?.superview === harness.containerView)
}

@Test
func diagnosticsUpdateReachesCustomGutterHost() {
    let harness = CodeEditorTextViewHarness(text: "one\ntwo\nthree")

    harness.updateDiagnosticsByLine([
        3: CodeEditorLineDiagnosticSummary(highestSeverity: .warning, messageCount: 1)
    ])

    #expect(harness.gutterView?.diagnosticsByLine[3]?.highestSeverity == .warning)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature8-task1 -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests -only-testing:agentGuiTests/CodeEditorViewIntegrationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，原因应是当前实现仍在安装 `verticalRulerView`，harness 也还没有 `containerView` / 自定义 gutter 宿主的访问路径。

**Step 3: Write the minimal test-support implementation**

- 在 harness 中新增 `containerView` 查找逻辑
- 更新 `gutterView` 访问器，使其从容器直接暴露 gutter
- 保留 `scrollView` 和 `textView` 访问方式，避免一次性打散大量现有测试

**Step 4: Run test to verify it still fails for product code only**

重复上面的 `xcodebuild test` 命令。

Expected: 失败点应收敛到产品代码仍未实现新宿主，而不是测试支撑本身找不到视图。

**Step 5: Commit**

```bash
git add agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift agentGuiTests/CodeEditorTextViewIntegrationTests.swift agentGuiTests/CodeEditorViewIntegrationTests.swift
git commit -m "test: codify custom gutter host contract"
```

### Task 2: 新建 editor-owned 容器并切换 `CodeEditorTextView` 根宿主

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorViewportContainerView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`

**Step 1: Write the failing tests**

如果 Task 1 已经把“自定义宿主存在、scroll view 不再启用 ruler”写进测试，这一步可以直接复用那些失败测试，不再另起新测试文件。

**Step 2: Run test to verify it fails**

继续运行 Task 1 的测试命令。

Expected: FAIL，指向 `CodeEditorTextView` 仍返回 `NSScrollView` 或 coordinator 仍依赖 `verticalRulerView`。

**Step 3: Write the minimal implementation**

实现要点：

- 新增 `CodeEditorViewportContainerView`
- `CodeEditorTextView.makeNSView` 改为返回容器
- scroll view 仍在 `makeNSView` 中创建，但作为容器子视图注入
- `updateNSView` 改为接收 container，再从 container 取出 textView / scrollView
- viewport observer、selection observer、focus/reveal 逻辑继续绑定到内部 textView 与 scrollView

建议执行时保持 coordinator 接口尽量稳定，只把入参从 `scrollView` 扩成 `container` 或在需要处通过 `textView.enclosingScrollView` 拿回 scroll view，避免无关重写。

**Step 4: Run test to verify it passes or only剩下 gutter 类型问题**

继续运行 Task 1 的测试命令。

Expected: 如果容器切换成功，失败应只剩 `CodeEditorGutterView` 还没有脱离 `NSRulerView` 或状态推送仍走旧路径。

**Step 5: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorViewportContainerView.swift agentGui/Views/CodeEditor/CodeEditorTextView.swift
git commit -m "refactor: host code editor in viewport container"
```

### Task 3: 把 `CodeEditorGutterView` 从 `NSRulerView` 重写成自定义 sibling column

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorGutterView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`

**Step 1: Write the failing tests**

如果 Task 1 已包含以下断言，则直接复用：

- `scrollView.verticalRulerView == nil`
- `scrollView.hasVerticalRuler == false`
- 当前行和 diagnostics 仍能同步到 gutter
- 行号仍显示，gutter 宽度仍会随 `lineCount` 位数变化

可以额外补一条宽度回归：

```swift
@Test
func gutterWidthExpandsWhenLineCountCrossesDigitBoundary() {
    let harness = CodeEditorTextViewHarness(text: (1...99).map { "line \($0)" }.joined(separator: "\n"))
    let before = harness.gutterView?.bounds.width

    harness.updateFromHost(text: (1...100).map { "line \($0)" }.joined(separator: "\n"))

    #expect((harness.gutterView?.bounds.width ?? 0) > (before ?? 0))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature8-task3 -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，原因应是 `CodeEditorGutterView` 还是 ruler 子类，或宽度变化没有驱动容器重新布局。

**Step 3: Write the minimal implementation**

- 把 `CodeEditorGutterView` 基类切到 `NSView`
- 保留 `updateLayoutState(...)` 输入契约
- 引入 `requiredWidth`，替换 `ruleThickness`
- 用 `draw(_:)` 绘制背景、separator、当前行高亮、行号和 diagnostics dot
- 给 gutter 增加宽度变化回调，让容器在位数变化时重新 layout
- 在 coordinator 的 `updateGutterState(for:)` 中直接拿容器的 gutter view，而不是 `verticalRulerView`

建议 `draw(_:)` 的顺序固定为：背景 -> 当前行背景 -> 行号 -> diagnostics dot -> separator。这样可以明确“背景与 separator ownership”已经完全落在自定义视图自身。

**Step 4: Run test to verify it passes**

重复 Task 3 的 `xcodebuild test` 命令。

Expected: PASS，`CodeEditorTextViewIntegrationTests` 里的 gutter 装配、scrolling、diagnostics 和 marked text 几何回归都通过。

**Step 5: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorGutterView.swift agentGui/Views/CodeEditor/CodeEditorTextView.swift
git commit -m "refactor: replace ruler gutter with custom column"
```

### Task 4: 做一次上层回归并确认 Feature 8 验收标准

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`
  只在需要补宿主回归时修改。

**Step 1: Write or keep one end-to-end regression**

至少保留一条 `CodeEditorView` 级别回归，验证宿主替换后这些能力没有倒退：

- 文本编辑仍然转发到宿主
- reveal request 仍能选中目标位置
- syntax highlight / diagnostics 装饰主路径仍然工作

如果 Task 1 已经覆盖足够，也可以只保留现有测试并不新增断言。

**Step 2: Run focused regression suite**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature8-task4 -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests -only-testing:agentGuiTests/CodeEditorViewIntegrationTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS。

**Step 3: Run broader editor regression**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature8-task4b -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests -only-testing:agentGuiTests/CodeEditorViewIntegrationTests -only-testing:agentGuiTests/CodeEditorViewModelTests -only-testing:agentGuiTests/CodeEditorHighlightPipelineTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS。重点确认宿主替换没有误伤现有文本高亮与装饰主路径。

**Step 4: Validate acceptance criteria explicitly**

执行时逐条确认：

- 行号仍可见
- `NSScrollView.hasVerticalRuler == false`
- gutter 背景与 separator 只由 `CodeEditorGutterView.draw(_:)` 控制

**Step 5: Commit**

```bash
git add agentGuiTests/CodeEditorViewIntegrationTests.swift
git commit -m "test: verify custom gutter host regressions"
```

## 6. 实施细节检查单

执行 Task 2 和 Task 3 时，逐项自查下面这些细节：

- `CodeEditorTextView.updateNSView(...)` 是否仍会在 programmatic text update 后调用 `publishVisibleLineRange(for:)` 和 `updateGutterState(for:)`
- `installViewportObserver(for:textView:)` 是否仍然订阅 `scrollView.contentView` 的 bounds change
- `CodeEditorGutterView` 是否持有 `weak textView`，避免和容器形成不必要的强引用环
- gutter 宽度变化时，是否只触发布局，不触发无关文本区状态重置
- `CodeEditorTextViewHarness.findScrollView(in:)` 是否仍然能稳定找到内部 scroll view
- 任何旧的 `hasVerticalRuler = true`、`rulersVisible = true`、`verticalRulerView = ...` 代码路径是否都已删干净

## 7. 风险与回退策略

- 最大风险不是绘制代码，而是 `NSViewRepresentable` 根视图类型从 `NSScrollView` 切到容器后，测试 harness 和 update 生命周期可能出现空引用或时序变化。应先让 harness 和失败测试收敛，再改产品代码。
- 第二个风险是 gutter 宽度变化导致 layout 抖动。Feature 8 不需要复杂缓存，只要把重新布局严格限制在位数变化时即可。
- 第三个风险是 marked text 与可见区发布回归。因为当前 marked text 测试已经覆盖了显示行数和 `backgroundRect(forLine:)`，只要这些测试不退，就说明宿主替换没有破坏文本区主路径。
- 如果执行时发现 `CodeEditorTextView` 根宿主切换波及过大，可以短暂保留部分 coordinator 辅助方法签名不变，通过容器向下暴露 `scrollView` 和 `textView` 来降低改动面；不要为了“更纯”的 API 一次性重写全部 coordinator。

## 8. 完成定义

Feature 8 完成的标志是：

1. 产品代码里不再出现任何通过 `verticalRulerView` 安装 gutter 的路径。
2. `CodeEditorTextViewIntegrationTests` 明确断言 `hasVerticalRuler == false` 并通过。
3. 当前行高亮、diagnostics marker、marked text 行几何和滚动发布回归全部通过。
4. gutter 背景与 separator 由自定义 `NSView` 绘制，后续 Feature 9/10 可以在这个宿主上继续演进，而不需要再碰 ruler 体系。

# Code Editor Feature 4 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为现有 CodeEditor 主路径补上源码编辑器的基础观感层，包括行号 gutter、当前行高亮、diagnostics gutter 装饰和底部状态栏，同时保证滚动与编辑期间的绘制更新仍以 visible range 和局部失效为主。

**Architecture:** 本轮不把 diagnostics 或状态栏逻辑塞回文本存储，也不等待 Feature 5 才开始做 UI 层。编辑器继续以 `NSTextView` / `NSScrollView` 为输入与滚动内核，gutter 采用紧贴 scroll view 的 AppKit ruler/sidecar 视图负责轻量绘制，当前行高亮通过 `CodeEditorPlatformTextView` 的背景绘制完成，状态栏则由 SwiftUI 宿主层展示。LSP 状态与诊断数据在本轮临时复用现有 `ClaudeService.makeWorkspacePanelLSPStatus` 与 `LSPDiagnosticsStore`，等 Feature 5 再抽成专用协调器。

**Tech Stack:** Swift 6、SwiftUI、AppKit、TextKit、Foundation、现有 `CodeEditorView` / `CodeEditorTextView` / `CodeEditorLineIndex` / `LSPDiagnosticsStore` / `ClaudeService`、Swift Testing

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 当前执行状态（2026-03-30）

- 现有仓库已经具备 Feature 1-3 的核心骨架：`CodeEditorView`、`CodeEditorTextView`、`CodeEditorDocument`、`CodeEditorLineIndex`、`CodeEditorHighlightPipeline` 与 `CodeEditorHighlightScheduler` 已存在。
- `FileEditorView` 的文本分支已经切到 `CodeEditorView`，文件保存、dirty 状态、外部刷新与 LSP bootstrap 仍由 `FileEditorSessionController` 和 `FileEditorView` 宿主层负责。
- 代码编辑器当前已经能追踪选区和可见区，并能按 retained window 触发 Highlightr 局部高亮，但还没有 gutter、当前行背景、diagnostics 行级装饰或底部状态栏。
- 现有 LSP 诊断能力已通过 `LSPDiagnosticsStore` 和 `ClaudeService.makeWorkspacePanelLSPStatus` 暴露为文件级 / 项目级状态，因此 Feature 4 可以直接消费这些投影结果，不需要等待 Feature 5 完成 didChange 协调器抽离。

## 0. 范围约束

- Feature 4 只做展示层增强，不改写文本输入主路径，不新增 LSP 写操作，不接入 hover / definition / references。
- Feature 4 不通过修改 `NSTextStorage` 属性来实现当前行高亮或 diagnostics 行级染色，避免和 Feature 3 的语法高亮局部回写互相覆盖。
- Feature 4 不提前实现 diagnostics underline、find matches、selection matches 或 minimap；这些属于 Feature 7 的局部装饰层。
- Feature 4 可以临时复用现有 `ClaudeService.makeWorkspacePanelLSPStatus` 与 `LSPDiagnosticsStore.snapshot`，但不能把 `FileEditorView` 里的裸 LSP 同步逻辑继续扩散到更多 UI 组件里。
- Feature 4 的 UI 真相边界要保持清晰：文件文本仍由 `FileEditorSessionController` 持有，编辑器内部只管理“当前可见状态”和“轻量展示投影”。
- 这个 Xcode 工程使用 `PBXFileSystemSynchronizedRootGroup`；在 `agentGui` 和 `agentGuiTests` 下新增文件通常不需要手动修改工程文件。

## 1. 代码锚点

当前与 Feature 4 直接相关的实现落点如下：

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorView.swift`
  当前只包裹 `CodeEditorTextView` 并同步 `text` / `persistedText`，尚未承载状态栏或额外 chrome。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
  当前已经有 coordinator、选区观测、viewport 观测和高亮调度，是接入 gutter、当前行状态、可见区回传的主入口。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/CodeEditorDocument.swift`
  当前已有 `lineIndex`、版本号、选区与位置映射 API，可直接为行号、列号、当前行和 diagnostics 位置映射服务。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPDiagnosticsStore.swift`
  当前已支持按 `workspaceRoot + uri` 查询文件级 diagnostics snapshot，也支持项目级 summary。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+WorkspaceContext.swift`
  当前已经把工作目录、选中文件、LSP service state 和 diagnostics 汇总成 `WorkspacePanelLSPStatusPresentation`，这正好可复用于状态栏 LSP 状态。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/WorkbenchLSPPanelPresentation.swift`
  当前已经有 diagnostics severity 到颜色 / 文本的稳定映射，可复用其 tone / severity 规则，避免编辑器和工作台面板各自维护一套颜色逻辑。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
  当前文本分支仍直接把 `workspaceState.editorSelection` 与裸 LSP sync 挂在 `CodeEditorView` 回调上；Feature 4 的状态栏数据也应由这里提供工作目录、当前文件和 `ClaudeService` 环境，而不是让底层编辑器直接依赖环境对象。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
  当前覆盖文本变更、选区和高亮基础行为，可继续扩展当前行 / viewport / gutter 配置的集成断言。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`
  当前已覆盖 `CodeEditorView` 和宿主回调链路，是状态栏与 diagnostics 组合行为的自然回归点。

## 2. 方案结论

本 Feature 建议按下面这条路线落地：

1. 新增一个轻量 `CodeEditorViewModel`，只负责把文档位置、选区、语言、缩进风格、LSP 状态和 diagnostics 汇总成 UI 可消费的 presentation state。
2. 在 `CodeEditorTextView` 侧增加两个明确能力：
   - 向上回传当前光标位置、当前行和 visible line range
   - 在 AppKit 层挂接一个专用 gutter 视图，并只在旧/新当前行或可见区变化时局部失效
3. gutter 使用 AppKit 侧车视图而不是 SwiftUI `List`/`VStack` 重建整列，避免滚动时整个 gutter 树频繁刷新。
4. 当前行高亮采用背景绘制，不写入 `NSTextStorage` 属性；diagnostics 行级着色同样走背景 / gutter 图层，而不是文本 attributes。
5. 状态栏放在 `CodeEditorView` 最底部，用纯值状态驱动展示“行列、语言、缩进、LSP 状态、错误/警告计数”，不在这里做交互式 LSP 管理。

这样做的原因：

- gutter 和当前行高亮都与滚动、layoutManager、visible rect 强耦合，落在 AppKit 层最稳妥。
- 状态栏天然是宿主 chrome，放在 SwiftUI 层比塞进 `NSTextView` 子视图更清晰。
- 诊断与 LSP 状态已有现成投影源，可以先把 UI 闭环搭起来；等 Feature 5 再把数据供应方从 `FileEditorView` 裸回调改成专用协调器。

## 3. 设计细节

### 3.1 展示状态模型

建议新增以下轻量类型，集中放在 `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/CodeEditorViewModel.swift`：

```swift
struct CodeEditorCursorStatus: Equatable {
    let line: Int
    let column: Int
    let selectedLineRange: FileLineRange?
}

struct CodeEditorIndentationStatus: Equatable {
    let kind: Kind
    let width: Int

    enum Kind: Equatable {
        case spaces
        case tabs
        case unknown
    }
}

struct CodeEditorLineDiagnosticSummary: Equatable {
    let line: Int
    let highestSeverity: LSPDiagnosticSeverity
    let messageCount: Int
}

struct CodeEditorStatusBarState: Equatable {
    let cursor: CodeEditorCursorStatus
    let languageLabel: String
    let indentation: CodeEditorIndentationStatus
    let lspStateText: String
    let errorCount: Int
    let warningCount: Int
}
```

`CodeEditorViewModel` 只做派生，不持有文件文本真相。建议输入是：

- `CodeEditorDocument`
- 当前 `selectedRange`
- 当前 `visibleLineRange`
- 当前文件 `URL`
- `WorkspacePanelLSPStatusPresentation`
- `LSPDiagnosticsSnapshot?`

输出是状态栏状态和 `diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary]`。不要把 `ClaudeService` 或 `AppSettings` 直接注入这个 view model；这些环境依赖由 `FileEditorView` 先解析成普通值，再传给 `CodeEditorView`。

### 3.2 gutter 结构

建议新增 `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorGutterView.swift`，但实现形式应为 AppKit `NSRulerView` 风格侧车视图，而不是普通 SwiftUI `View`。关键职责：

- 绘制可见区与近场缓冲窗口内的行号。
- 在 diagnostics 命中的行上绘制 severity dot / stripe。
- 对当前行绘制更高对比度的行号与背景强调。
- 只根据 `visibleLineRange`、`currentLine`、`diagnosticsByLine` 局部 `setNeedsDisplay`。

建议 API 形状类似：

```swift
final class CodeEditorGutterView: NSRulerView {
    var document: CodeEditorDocument
    var visibleLineRange: ClosedRange<Int>
    var currentLine: Int?
    var diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary]

    func updateLayoutState(...)
    func invalidateLines(_ lines: ClosedRange<Int>)
}
```

这里不要把每一行预先转成 `NSView`。绘制时直接通过 `layoutManager` 查询可见 line fragment rect，再把 line number 和 diagnostic marker 画到 gutter context，避免滚动时创建大量子视图。

### 3.3 当前行高亮

当前行高亮建议放在 `CodeEditorPlatformTextView` 里完成，通过背景绘制而不是 attributed string：

```swift
final class CodeEditorPlatformTextView: NSTextView {
    var highlightedLineRange: NSRange?
    var highlightedLineColor: NSColor = .selectedTextBackgroundColor.withAlphaComponent(0.08)

    override func drawViewBackground(in rect: NSRect) {
        super.drawViewBackground(in: rect)
        drawHighlightedCurrentLine(in: rect)
    }
}
```

更新规则：

- 选区变化后，把 caret 所在行映射成文本 `NSRange`。
- 只让旧行和新行对应的背景矩形失效，不触发整个文本视图重绘。
- 多选区和非空选区首轮先按“主插入点所在行”处理，不在本 Feature 实现多光标逻辑。

这样可以避免与 Feature 3 的 `CodeEditorHighlightApplicator` 发生属性层冲突，也能把视觉更新控制在线级别。

### 3.4 diagnostics 行级装饰

Feature 4 的 diagnostics 只做两类表现：

- gutter 左侧或行号旁的 severity dot / bar
- 文本区域当前可见行的轻量 background wash

不要在本轮实现 underline、squiggle 或 fix-it bubble。推荐规则：

- 同一行多条 diagnostics 时，只取最高 severity 作为 gutter 主标记。
- 文本区域只对 error / warning 做低透明度整行 wash；information / hint 只在 gutter 上表现。
- diagnostics 更新只重绘受影响的行集合，不因整个 snapshot 刷新而整屏 invalidation。

`CodeEditorViewModel` 负责把 `LSPDiagnosticsSnapshot` 聚合成 `diagnosticsByLine`，gutter 和 text view 只消费聚合结果，不直接解析原始 diagnostics 数组。

### 3.5 状态栏

建议新增 `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorStatusBar.swift`，作为一个纯 SwiftUI 只读状态条。内容只放：

- 行 / 列
- 语言
- 缩进模式，例如 `Spaces: 4`、`Tabs: 1`、`Unknown`
- LSP 状态文本，例如 `运行中`、`未安装`、`当前文件无匹配服务`
- 错误 / 警告数量

建议不要把状态栏直接依赖 `WorkspaceState` 或 `ClaudeService`。`FileEditorView` 负责计算 `WorkspacePanelLSPStatusPresentation`，`CodeEditorView` 负责把光标状态 + 语言 + diagnostics 交给 `CodeEditorStatusBar`。

### 3.6 缩进策略

仓库当前没有现成的源码编辑器缩进状态模型，因此本轮只做只读探测：

- 扫描前 `N` 行非空行的前导空白。
- 若 tab 前导占优，显示 `Tabs: 1`。
- 若 space 前导占优，取最常见缩进宽度，显示 `Spaces: 2` 或 `Spaces: 4`。
- 若样本不足，显示 `Unknown`。

不要在 Feature 4 增加“切换缩进模式”交互，也不要把 Tab 键行为和状态栏耦合在一起。

## 4. 目标文件集

### New files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/CodeEditorViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorGutterView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorStatusBar.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewModelTests.swift`

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/CodeEditorDocument.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`

### Optional modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+WorkspaceContext.swift`
  只有在需要补一个更窄的 editor-specific helper 时才修改；优先复用现有 `makeWorkspacePanelLSPStatus`。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/WorkbenchLSPPanelPresentation.swift`
  只有在需要抽取 diagnostics severity 颜色 helper 供编辑器和工作台共用时才修改；不要无意义重构。

## 5. 任务拆解

### Task 1: 建立状态栏与 diagnostics 聚合模型

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/CodeEditorViewModel.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewModelTests.swift`

**Step 1: Write the failing test**

先锁定两个纯逻辑行为：

- 光标 offset 能稳定映射成状态栏行列
- `LSPDiagnosticsSnapshot` 能按行聚合成最高 severity
- 缩进探测能识别 spaces / tabs

示例：

```swift
@Test
func statusBarUsesDocumentLocationAndLSPSummary() {
    let document = CodeEditorDocument(
        text: "func demo() {\n    return 1\n}\n",
        persistedText: ""
    )
    let status = WorkspacePanelLSPStatusPresentation(
        stateText: "运行中",
        serverID: "swift",
        selectedFileName: "Demo.swift",
        errorCount: 2,
        warningCount: 1,
        projectSummary: nil
    )

    let state = CodeEditorViewModel.makeStatusBarState(
        document: document,
        selectedRange: NSRange(location: 18, length: 0),
        fileURL: URL(fileURLWithPath: "/tmp/Demo.swift"),
        lspStatus: status,
        diagnostics: nil
    )

    #expect(state.cursor.line == 2)
    #expect(state.cursor.column == 5)
    #expect(state.languageLabel == "swift")
    #expect(state.lspStateText == "运行中")
    #expect(state.errorCount == 2)
}
```

再补 diagnostics 聚合测试：

```swift
@Test
func diagnosticsAggregateHighestSeverityPerLine() {
    let snapshot = LSPDiagnosticsSnapshot(
        workspaceRoot: "/tmp",
        uri: URL(fileURLWithPath: "/tmp/Demo.swift").absoluteString,
        diagnostics: [
            .init(message: "unused", severity: .warning, line: 3, character: 1),
            .init(message: "syntax", severity: .error, line: 3, character: 4),
            .init(message: "hint", severity: .hint, line: 5, character: 0)
        ]
    )

    let summaries = CodeEditorViewModel.diagnosticsByLine(snapshot)

    #expect(summaries[4]?.highestSeverity == .error)
    #expect(summaries[4]?.messageCount == 2)
    #expect(summaries[6]?.highestSeverity == .hint)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature4-task1 \
  -only-testing:agentGuiTests/CodeEditorViewModelTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 `CodeEditorViewModel`、`CodeEditorStatusBarState` 和 diagnostics 聚合 helper 还不存在。

**Step 3: Write minimal implementation**

实现一个纯值 `CodeEditorViewModel`，至少提供：

```swift
enum CodeEditorViewModel {
    static func makeStatusBarState(... ) -> CodeEditorStatusBarState { ... }
    static func diagnosticsByLine(_ snapshot: LSPDiagnosticsSnapshot?) -> [Int: CodeEditorLineDiagnosticSummary] { ... }
    static func detectIndentation(in text: String) -> CodeEditorIndentationStatus { ... }
}
```

约束：

- 行号统一 1-based；LSP diagnostics 原始 `line` 是 0-based，转换时只在聚合边界做一次。
- diagnostics 聚合优先级必须是 `error > warning > information > hint`。
- 语言标签优先从 `CodeSyntaxHighlightingService.languageIdentifier(for:)` 取值；拿不到时退回文件扩展名或 `plain text`。

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/CodeEditorViewModel.swift agentGuiTests/CodeEditorViewModelTests.swift
git commit -m "feat: add code editor presentation state"
```

### Task 2: 让文本视图发布当前行与 visible range，并实现当前行高亮

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/CodeEditorDocument.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`

**Step 1: Write the failing test**

补两个集成断言：

- 选区变化后能得到当前行 / 列更新
- 当前行高亮不会因为高亮属性回写被清空

示例：

```swift
@Test
func selectionChangePublishesCurrentCursorLocation() {
    let harness = CodeEditorTextViewHarness(text: "alpha\nbeta\ngamma")

    harness.select(range: NSRange(location: 7, length: 0))

    #expect(harness.lastCursorLocation == CodeEditorTextLocation(line: 2, column: 2))
    #expect(harness.highlightedLine == 2)
}
```

可再加一个回归：程序性高亮回写后当前行高亮仍存在。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature4-task2 \
  -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为当前 harness 还没有 cursor / current line 回调，也没有当前行高亮状态可观察。

**Step 3: Write minimal implementation**

按最小路径扩展 `CodeEditorTextView`：

- 新增 `onCursorLocationChange` 和 `onVisibleLineRangeChange` 回调。
- 在 coordinator 的 `publishSelection(for:)` 中调用 `parent.document.location(ofUTF16Offset:)` 生成当前位置。
- 为 `CodeEditorPlatformTextView` 增加 `highlightedLineRange` 或 `highlightedLineNumber` 状态，并在 `drawViewBackground(in:)` 里画背景。
- 新旧当前行变化时只失效对应 rect，不调用整视图 `setNeedsDisplay(bounds)`。

必要时在 `CodeEditorDocument` 增加帮助方法：

```swift
func utf16LineRange(forLine line: Int) -> NSRange
```

用于把当前行映射成文本范围。

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorTextView.swift agentGui/Models/CodeEditorDocument.swift agentGuiTests/CodeEditorTextViewIntegrationTests.swift agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift
git commit -m "feat: highlight current code editor line"
```

### Task 3: 接入 line-number gutter 与 diagnostics gutter

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorGutterView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`

**Step 1: Write the failing test**

先锁定两个最小集成行为：

- `CodeEditorTextView` 会为 `NSScrollView` 安装垂直 gutter / ruler
- diagnostics 更新后，gutter 能收到按行聚合结果

示例：

```swift
@Test
func textViewInstallsCodeEditorGutter() {
    let harness = CodeEditorTextViewHarness(text: "one\ntwo\nthree")

    #expect(harness.scrollView.hasVerticalRuler)
    #expect(harness.gutterView != nil)
}
```

再补一个纯状态回归：注入 diagnostics by line 后，当前行与告警行可以同时存在。

**Step 2: Run test to verify it fails**

Run 同 Task 2，但先只看新增断言失败。

Expected: FAIL，因为当前 `NSScrollView` 还没有挂 gutter 视图。

**Step 3: Write minimal implementation**

实现 `CodeEditorGutterView` 并在 `makeNSView` / `updateNSView` 时接入：

```swift
let gutter = CodeEditorGutterView(scrollView: scrollView, orientation: .verticalRuler)
gutter.clientView = textView
scrollView.verticalRulerView = gutter
scrollView.hasVerticalRuler = true
scrollView.rulersVisible = true
```

然后给 gutter 一个最小更新入口：

```swift
gutter.updateLayoutState(
    document: parent.document,
    visibleLineRange: visibleLineRange,
    currentLine: currentLine,
    diagnosticsByLine: diagnosticsByLine
)
```

关键约束：

- gutter 内部按 `layoutManager` + `textContainer` 查询 line fragment rect，不能提前为所有行构建视图列表。
- 滚动时只重绘新的可见区；diagnostics 更新时只失效受影响行所在的 gutter rect。
- gutter 宽度按文档总行数动态扩展，例如预留 `digits + marker padding`，但不要在每次滚动时重新测量整个文档。

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorGutterView.swift agentGui/Views/CodeEditor/CodeEditorTextView.swift agentGuiTests/CodeEditorTextViewIntegrationTests.swift agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift
git commit -m "feat: add code editor gutter rendering"
```

### Task 4: 组合状态栏并把 diagnostics / LSP 状态接到 CodeEditorView

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorStatusBar.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`

**Step 1: Write the failing test**

锁定宿主层组合行为：

- `CodeEditorView` 在底部显示状态栏
- 状态栏会随着当前光标更新行列
- 传入 diagnostics / LSP 状态后能显示错误和警告计数

示例：

```swift
@Test
func codeEditorViewShowsStatusBarState() {
    let harness = CodeEditorViewHarness(initialText: "let value = 1", persistedText: "let value = 1")

    harness.select(range: NSRange(location: 4, length: 0))
    harness.injectLSPStatus(
        .init(
            stateText: "运行中",
            serverID: "swift",
            selectedFileName: "Sample.swift",
            errorCount: 1,
            warningCount: 2,
            projectSummary: nil
        )
    )

    #expect(harness.statusBarText.contains("Ln 1"))
    #expect(harness.statusBarText.contains("Col 5"))
    #expect(harness.statusBarText.contains("运行中"))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature4-task4 \
  -only-testing:agentGuiTests/CodeEditorViewIntegrationTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 `CodeEditorView` 目前没有状态栏，也没有 diagnostics / LSP status 输入。

**Step 3: Write minimal implementation**

最小组合方式：

- `FileEditorView` 继续持有环境对象，计算当前文件的 `WorkspacePanelLSPStatusPresentation` 和文件级 diagnostics snapshot。
- `CodeEditorView` 接收这些纯值输入，以及来自 `CodeEditorTextView` 的 `onCursorLocationChange` / `onVisibleLineRangeChange` 结果。
- 底部新增 `CodeEditorStatusBar(state: ...)`，其内容完全由 `CodeEditorViewModel.makeStatusBarState` 生成。

建议新增接口：

```swift
CodeEditorView(
    ...
    diagnostics: LSPDiagnosticsSnapshot?,
    lspStatus: WorkspacePanelLSPStatusPresentation?
)
```

重要边界：

- `CodeEditorView` 不应直接读取 `ClaudeService` 环境；环境解析仍放在 `FileEditorView`。
- 现有 `syncOpenDocumentToLSPIfNeeded` 保持不动，直到 Feature 5 再整体替换。

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorStatusBar.swift agentGui/Views/CodeEditor/CodeEditorView.swift agentGui/Views/FileEditorView.swift agentGuiTests/CodeEditorViewIntegrationTests.swift
git commit -m "feat: add code editor status bar"
```

### Task 5: 回归验证 visible-range 局部失效与手工 smoke

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`

**Step 1: Write the failing test**

补一个 focused regression，至少覆盖：

- 滚动后 visible line range 发生变化，但文本内容和当前行高亮不丢失
- diagnostics 更新只影响当前行 / 受影响行的显示状态，不会重置当前光标位置

如果难以直接断言绘制次数，至少断言“滚动 + diagnostics 更新”这两个事件不会触发文本回写或选区丢失。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature4-task5 \
  -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests \
  -only-testing:agentGuiTests/CodeEditorViewIntegrationTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，新增回归断言未满足。

**Step 3: Write minimal implementation**

修补局部失效路径，确保：

- 当前行切换时只 invalid old/new line rect
- gutter 更新时只 invalid changed line rect 与新增 visible range
- diagnostics 注入不会调用整份 `textView.string = ...`

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGuiTests/CodeEditorTextViewIntegrationTests.swift agentGuiTests/CodeEditorViewIntegrationTests.swift
git commit -m "test: lock code editor chrome regressions"
```

## 6. 手工验证清单

自动化通过后，至少做以下手工 smoke：

1. 打开 2 千行以上文本文件，滚动时观察 gutter 是否只平滑刷新可见区，没有整列闪烁。
2. 上下移动光标，确认当前行高亮只跟随当前行，不会覆盖语法高亮颜色。
3. 制造一条 warning / error，确认 gutter 标记和状态栏计数会更新。
4. 切换不同语言文件，确认状态栏语言标签变化，缩进模式不会出现明显误判。
5. 持续输入期间观察状态栏和 gutter，不应出现输入阻塞或选区跳动。

## 7. 风险与决策点

### 风险 1: gutter 实现如果用 SwiftUI 列表，滚动时容易整列刷新

**应对：** 坚持 AppKit 侧车绘制，不为每一行创建独立 SwiftUI 节点。

### 风险 2: 当前行高亮与 Feature 3 的语法高亮属性互相覆盖

**应对：** 当前行高亮只走背景绘制，不走 `NSTextStorage` attributes。

### 风险 3: diagnostics 和 LSP 状态源在 Feature 5 前仍分散在宿主层

**应对：** 本 Feature 只消费投影结果，不扩散更多裸同步逻辑；Feature 5 再统一抽离协调器。

### 风险 4: 缩进探测误判导致状态栏不稳定

**应对：** 先做只读 heuristic，并在样本不足时明确显示 `Unknown`，不要伪装成高置信度结果。

## 8. 完成定义

满足以下条件后，可以认为 Feature 4 初步完成：

- 代码编辑器左侧有稳定的行号 gutter，滚动和编辑时不会整列抖动。
- 当前行能稳定高亮，且不会破坏语法高亮、选区和 typing attributes。
- diagnostics 能以 gutter 标记和轻量行级着色的形式出现在可见区。
- 底部状态栏能显示当前行列、语言、缩进、LSP 状态和错误 / 警告计数。
- `CodeEditorView` 仍保持纯值输入边界，没有把 `ClaudeService` 和 `AppSettings` 直接下沉进底层 AppKit 组件。

Plan complete and saved to `docs/plans/2026-03-30-code-editor-feature-4-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - 我按 Task 顺序逐个实现、逐个验证

**2. Parallel Session (separate)** - 新开会话按 executing-plans skill 并行执行

**Which approach?**
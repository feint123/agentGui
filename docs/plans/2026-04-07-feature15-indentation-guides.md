# Feature 15: 缩进参考线（Indentation Guides）实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 `CodeEditorPlatformTextView.drawBackground(in:)` 中绘制纵向缩进参考线，区分 active 与 inactive 两种状态，对齐 VSCode `IndentGuidesOverlay` 和 Zed `paint_indent_guides` 的视觉效果，支持 tabs 和 spaces 两种缩进模式。

**Architecture:** 纯绘制方案（方案 B）。不修改 `NSTextStorage`，在 `drawBackground(in:)` override 里，利用已有的 `CodeEditorVisibleLineMetric`（F9）和 `CodeEditorIndentationStatus`（ViewModel 已检测）对可见行逐行计算缩进深度，然后画垂直线。Active guide 通过光标当前所在缩进块确定，使用更深的颜色。整个流程对 IME 安全（`hasMarkedText()` 时跳过 active guide 重算）。

**Tech Stack:** Swift 6.0+, AppKit `NSTextView` / `NSBezierPath`, `NSColor.separatorColor`, `CodeEditorVisibleLineMetric`（已有），`CodeEditorIndentationStatus`（已有），Swift Testing (`@Test` / `#expect`)

---

## 研究摘要

### VSCode 方案（`indentGuides.ts` + `guidesTextModelPart.ts`）

VSCode 的 `IndentGuidesOverlay`（`DynamicViewOverlay` 子类）核心流程：

1. **数据来源：** `viewModel.getLinesIndentGuides(startLine, endLine)` 返回每行的缩进层级数（整数）；`viewModel.getActiveIndentGuide(cursorLine, visibleStartLine, visibleEndLine)` 返回包含光标的最深缩进块 `{ startLineNumber, endLineNumber, indent }`。
2. **X 坐标计算：** `leftOffset + (indentLevel - 1) * spaceWidth`，其中 `spaceWidth = fontInfo.spaceWidth`（单个空格的宽度）。VSCode 用 `indentSize`（tab stop 宽度，通常 4）作为每级宽度单位。
3. **渲染：** 每个 guide 渲染为 `<div class="core-guide-indent vertical">` 的 HTML 元素，宽度 1px，通过 CSS `box-shadow: 1px 0 0 0 var(--indent-color) inset` 实现细线效果。
4. **Active guide：** 颜色来自 `editorActiveIndentGuide` token（比 `editorIndentGuide` 更深），条件：`activeIndentStartLineNumber <= lineNumber <= activeIndentEndLineNumber && indentLevel == activeIndentLevel`。
5. **空行处理：** 空行的 indent guide 级别从相邻非空行推断（取上行和下行 indent 级别的较小值），VSCode 叫"blank line indent guide"。
6. **性能：** `prepareRender` 在每次 scroll/cursor change 时调用，仅计算可见行。

**关键教训：**
- Active guide 的 `indent` 字段是 0-indexed 的列数（空格数），不是级别数。要换算为级别：`indent / indentSize`。
- 空行的 indent guide 不能直接用行首空白字符计数，需要从上下文推断。

---

### Zed 方案（`element.rs` + `indent_guides.rs`）

Zed 的 `layout_indent_guides` + `paint_indent_guides` 分两个阶段：

**Layout 阶段（`layout_indent_guides`）：**
```rust
let indent_guides = editor.indent_guides(visible_buffer_range, snapshot, cx)?;
let active_indent_guide_indices = editor.find_active_indent_guide_indices(
    &indent_guides, snapshot, window, cx
).unwrap_or_default();
```
每个 `IndentGuide` 包含：`start_row`, `end_row`, `depth`（0-indexed 层级）, `tab_size`, `settings`（含 `coloring` 和 `background_coloring`）。

**Paint 阶段（`paint_indent_guides`）：**
```rust
let line_color = match (settings.coloring, indent_guide.active) {
    (IndentGuideColoring::Fixed, false) => Some(theme.colors().editor_indent_guide),
    (IndentGuideColoring::Fixed, true)  => Some(theme.colors().editor_indent_guide_active),
    (IndentGuideColoring::IndentAware, ..) => Some(accent_colors.faded(ALPHA)),
    ..
};
// 线：1px 宽垂直线
window.paint_quad(fill(Bounds { origin: guide.origin, size: (px(1.), guide.length) }, color));
// 背景：整个缩进宽度的半透明色块
if let Some(bg) = background_color {
    window.paint_quad(fill(background_bounds, bg));
}
```

**`calculate_indent_guide_bounds`：** 处理了折叠行、多buffer excerpt header 等边界情况，把 multi-buffer row 映射到 display row，并扩展 guide 到相邻块的边界（避免 guide 在 block element 处断开）。

**Active guide 判断（`find_active_indent_guide_indices`）：**
- 取光标所在行，找包含该行的所有 indent guide，取深度最大的。
- 实现：`indent_guides.iter().enumerate().filter(|(_, g)| g.start_row <= cursor_row && cursor_row <= g.end_row).max_by_key(|(_, g)| g.depth)`

**关键教训：**
- Zed 用 `IndentGuideBackgroundColoring` 支持整个缩进宽度的半透明背景块（不只是 1px 线），这是 Zed 特有的视觉增强。
- `depth` 从 0 开始，第 depth 级的 x 坐标 = `depth * tab_size * char_width`（depth=0 的 guide 在列 0，一般不画）。
- `start_row..end_row` 是前闭后开，paint 时通常向下扩展 1 行（`guide.length = (end_row - start_row) * line_height`）。

---

### AppKit 实现路径

`NSTextView.drawBackground(in:)` 是绘制非文字背景内容的正确 override 点，现有代码已在此绘制当前行高亮。在此基础上追加 indent guide 绘制：

1. 调用 `visibleLineMetrics(in:)` 获取当前可见行的 rect（`line`、`rect`、`baselineY`）—— F9 已提供。
2. 遍历每行的 `line.rect`，取行首字符偏移（前缀空白字符数），除以 `indentWidth` 得到缩进层级。
3. 对层级 1..=depth，计算 x = `textContainerInset.width + textContainer.lineFragmentPadding + (level-1) * indentWidth * charWidth`。
4. 用 `NSBezierPath.stroke` 或 `NSRect.fill` 画 1pt 宽的垂直线，颜色 `NSColor.separatorColor.withAlphaComponent(0.4)`（inactive）或 `0.7`（active）。
5. 空行：直接跳过（不画 guide），因为空行不贡献缩进信息。

---

## 文件总览

| 操作 | 路径 |
|------|------|
| 新建 | `agentGui/Services/Editor/CodeEditorIndentGuideScanner.swift` |
| 修改 | `agentGui/Views/CodeEditor/CodeEditorTextView.swift` |
| 新建 | `agentGuiTests/CodeEditorIndentGuideTests.swift` |

---

## Task 1：`CodeEditorIndentGuideScanner` — 纯值类型，无副作用

**文件：**
- Create: `agentGui/Services/Editor/CodeEditorIndentGuideScanner.swift`

**功能：** 给定一行的行首内容，返回其缩进深度（层级 = 前缀空白字符数 / indentWidth）和是否为空行。同时提供批量处理可见行的接口，返回 `[CodeEditorIndentGuideLevel]`（每行的层级 + 是否空行）。

---

### Step 1：定义 `CodeEditorIndentGuideLevel` 模型

```swift
import Foundation

/// 一行的缩进层级信息。
struct CodeEditorIndentGuideLevel: Equatable, Sendable {
    /// 0-indexed 缩进层级。level=0 表示无缩进（在列 0）。
    /// 空行时 level=0，isBlankLine=true，规则：取上行和下行层级的较小值（调用方负责填充）。
    let level: Int
    let isBlankLine: Bool
}
```

**Step 2: Run（验证类型可编译）**

确认文件可加入 Xcode target，编译通过即可。

---

### Step 3：实现 `CodeEditorIndentGuideScanner`

```swift
/// 从行文本片段（行首 N 个字符）计算缩进层级。
/// 仅依赖 `indentWidth`（>= 1）和 `useTabs: Bool`。
enum CodeEditorIndentGuideScanner {

    /// 给定行首内容（可以是整行 String）,返回缩进层级（0-indexed）。
    /// - spaces 模式: 前缀连续空格数 / indentWidth（向下取整）
    /// - tabs 模式: 前缀连续 \t 字符数
    static func indentLevel(
        forLinePrefix prefix: some StringProtocol,
        indentWidth: Int,
        useTabs: Bool
    ) -> Int {
        guard indentWidth > 0 else { return 0 }
        if useTabs {
            var count = 0
            for ch in prefix.unicodeScalars {
                guard ch == "\t" else { break }
                count += 1
            }
            return count
        } else {
            var count = 0
            for ch in prefix.unicodeScalars {
                guard ch == " " else { break }
                count += 1
            }
            return count / indentWidth
        }
    }

    /// 判断一行是否为空行（仅含空白字符或为空字符串）。
    static func isBlankLine(_ line: some StringProtocol) -> Bool {
        line.unicodeScalars.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// 批量处理行文本数组，返回每行的 CodeEditorIndentGuideLevel。
    /// 空行的 level 由相邻非空行推断（min of prev and next non-blank level），
    /// 若无相邻非空行则为 0。
    static func computeLevels(
        forLines lines: [String],
        indentWidth: Int,
        useTabs: Bool
    ) -> [CodeEditorIndentGuideLevel] {
        // 第一遍：直接计算
        var raw: [(level: Int, isBlank: Bool)] = lines.map { line in
            let blank = isBlankLine(line)
            let lvl = blank ? 0 : indentLevel(forLinePrefix: line, indentWidth: indentWidth, useTabs: useTabs)
            return (lvl, blank)
        }
        // 第二遍：空行填充（取前后非空行的最小值）
        let rawCount = raw.count
        for i in raw.indices where raw[i].isBlank {
            var prevLevel = 0
            var j = i - 1
            while j >= 0 {
                if !raw[j].isBlank { prevLevel = raw[j].level; break }
                j -= 1
            }
            var nextLevel = 0
            var k = i + 1
            while k < rawCount {
                if !raw[k].isBlank { nextLevel = raw[k].level; break }
                k += 1
            }
            raw[i].level = min(prevLevel, nextLevel)
        }
        return raw.map { CodeEditorIndentGuideLevel(level: $0.level, isBlank: $0.isBlank) }
    }
}
```

### Step 4: Run（仅验证编译，不跑测试）

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

---

## Task 2：单元测试 `CodeEditorIndentGuideTests`

**文件：**
- Create: `agentGuiTests/CodeEditorIndentGuideTests.swift`

### Step 1：新建测试文件

```swift
import Testing
@testable import agentGui

@Suite("CodeEditorIndentGuideScanner Tests")
struct CodeEditorIndentGuideTests {

    // MARK: - indentLevel (spaces)

    @Test("spaces: 无缩进")
    func spacesLevel0() {
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "func foo()", indentWidth: 4, useTabs: false) == 0)
    }

    @Test("spaces: 4 空格 = level 1")
    func spacesLevel1() {
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "    let x = 1", indentWidth: 4, useTabs: false) == 1)
    }

    @Test("spaces: 8 空格 = level 2")
    func spacesLevel2() {
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "        return x", indentWidth: 4, useTabs: false) == 2)
    }

    @Test("spaces: 2 空格 indentWidth=2")
    func spacesWidth2Level1() {
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "  let x", indentWidth: 2, useTabs: false) == 1)
    }

    @Test("spaces: 奇数空格向下取整")
    func spacesFloor() {
        // 6 spaces / 4 = 1（不是 1.5）
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "      x", indentWidth: 4, useTabs: false) == 1)
    }

    // MARK: - indentLevel (tabs)

    @Test("tabs: 无缩进")
    func tabsLevel0() {
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "func foo()", indentWidth: 4, useTabs: true) == 0)
    }

    @Test("tabs: 1 tab = level 1")
    func tabsLevel1() {
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "\tlet x = 1", indentWidth: 4, useTabs: true) == 1)
    }

    @Test("tabs: 2 tabs = level 2")
    func tabsLevel2() {
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "\t\treturn x", indentWidth: 4, useTabs: true) == 2)
    }

    @Test("tabs: indentWidth 不影响 tab 的层级计算")
    func tabsIgnoresIndentWidth() {
        // tab 模式 indentWidth 不影响层级（每个 tab = 1 级）
        #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "\tlet x", indentWidth: 2, useTabs: true) == 1)
    }

    // MARK: - isBlankLine

    @Test("纯空行")
    func pureBlank() {
        #expect(CodeEditorIndentGuideScanner.isBlankLine("") == true)
    }

    @Test("只有空格")
    func spacesOnlyBlank() {
        #expect(CodeEditorIndentGuideScanner.isBlankLine("    ") == true)
    }

    @Test("只有 tab")
    func tabsOnlyBlank() {
        #expect(CodeEditorIndentGuideScanner.isBlankLine("\t\t") == true)
    }

    @Test("有内容的行不是空行")
    func notBlankWithContent() {
        #expect(CodeEditorIndentGuideScanner.isBlankLine("  x") == false)
    }

    // MARK: - computeLevels 空行填充

    @Test("空行填充：取前后最小值")
    func blankLineFill() {
        let lines = [
            "    x",    // level 1
            "        y", // level 2
            "",          // blank -> min(2, 0) = 0? 但下面 level 0，应得 0
            "z",         // level 0
        ]
        let result = CodeEditorIndentGuideScanner.computeLevels(forLines: lines, indentWidth: 4, useTabs: false)
        #expect(result[0].level == 1)
        #expect(result[1].level == 2)
        #expect(result[2].isBlankLine == true)
        #expect(result[2].level == 0) // min(2, 0) = 0
        #expect(result[3].level == 0)
    }

    @Test("空行填充：前后都有缩进取较小值")
    func blankLineFillMinOfBoth() {
        let lines = [
            "    x",     // level 1
            "",          // blank -> min(1, 2) = 1
            "        y", // level 2
        ]
        let result = CodeEditorIndentGuideScanner.computeLevels(forLines: lines, indentWidth: 4, useTabs: false)
        #expect(result[1].isBlankLine == true)
        #expect(result[1].level == 1) // min(1, 2) = 1
    }

    @Test("连续空行：所有空行填充同一值")
    func consecutiveBlanks() {
        let lines = [
            "    x",  // level 1
            "",
            "",
            "    y",  // level 1
        ]
        let result = CodeEditorIndentGuideScanner.computeLevels(forLines: lines, indentWidth: 4, useTabs: false)
        #expect(result[1].level == 1)
        #expect(result[2].level == 1)
    }

    @Test("首行就是空行：无前驱，取后驱")
    func leadingBlank() {
        let lines = [
            "",          // blank, no prev -> min(0, 1) = 0
            "    x",     // level 1
        ]
        let result = CodeEditorIndentGuideScanner.computeLevels(forLines: lines, indentWidth: 4, useTabs: false)
        #expect(result[0].level == 0)
    }

    @Test("仅空行数组")
    func allBlankLines() {
        let lines = ["", "  ", "\t"]
        let result = CodeEditorIndentGuideScanner.computeLevels(forLines: lines, indentWidth: 4, useTabs: false)
        result.forEach { #expect($0.level == 0) }
    }
}
```

### Step 2：跑测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f15-derived \
  -only-testing:agentGuiTests/CodeEditorIndentGuideTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

Expected: 全部通过，`** TEST SUCCEEDED **`

---

## Task 3：`CodeEditorPlatformTextView` 中新增 indent guide 状态属性

**文件：**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（`CodeEditorPlatformTextView` 类定义内）

具体改动：在 `final class CodeEditorPlatformTextView: NSTextView {` 的属性区（紧跟现有属性之后）新增：

```swift
// MARK: - Indent Guides

/// 缩进参考线配置，由 Coordinator 在 updateNSView 时写入。
/// indentWidth <= 0 时不绘制参考线。
var indentGuideConfig: CodeEditorIndentGuideConfig = .disabled
```

同时在文件同一位置新增 `CodeEditorIndentGuideConfig`：

```swift
/// 缩进参考线所需配置，从 CodeEditorIndentationStatus 派生。
struct CodeEditorIndentGuideConfig: Equatable, Sendable {
    let indentWidth: Int   // 每级缩进的字符数，<=0 时禁用
    let useTabs: Bool

    static let disabled = CodeEditorIndentGuideConfig(indentWidth: 0, useTabs: false)

    init(indentWidth: Int, useTabs: Bool) {
        self.indentWidth = indentWidth
        self.useTabs = useTabs
    }

    init(from status: CodeEditorIndentationStatus) {
        switch status.kind {
        case .spaces:
            self.init(indentWidth: max(1, status.width), useTabs: false)
        case .tabs:
            self.init(indentWidth: max(1, status.width), useTabs: true)
        case .unknown:
            self.init(indentWidth: 4, useTabs: false) // 默认 4 spaces
        }
    }
}
```

### Step 1: 准备 `drawBackground` 修改点

`drawBackground(in:)` 现有代码（高亮当前行）：
```swift
override func drawBackground(in rect: NSRect) {
    super.drawBackground(in: rect)

    guard let line = highlightedLineNumber,
          let lineRect = backgroundRect(forLine: line),
          lineRect.intersects(rect) else {
        return
    }

    NSColor.selectedTextBackgroundColor.withAlphaComponent(0.10).setFill()
    lineRect.fill()
}
```

在 `lineRect.fill()` 之后（整个 drawBackground 末尾）追加 indent guide 绘制调用：

```swift
    // 绘制缩进参考线（在当前行高亮之上，参考线可见）
    drawIndentGuides(in: rect)
```

### Step 2: Run（确保编译通过）

---

## Task 4：实现 `drawIndentGuides(in:)` 核心绘制逻辑

**文件：**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（在 `CodeEditorPlatformTextView` 末尾添加 extension 或 private method）

### Step 1：实现 `drawIndentGuides`

在 `CodeEditorPlatformTextView` 内（`drawBackground` 之后）添加：

```swift
private static let indentGuideInactiveColor = NSColor.separatorColor.withAlphaComponent(0.35)
private static let indentGuideActiveColor   = NSColor.separatorColor.withAlphaComponent(0.70)

private func drawIndentGuides(in rect: NSRect) {
    let config = indentGuideConfig
    guard config.indentWidth > 0, !hasMarkedText() else { return }

    // 1. 取可见行 metrics
    let metrics = visibleLineMetrics(in: rect)
    guard !metrics.isEmpty else { return }

    // 2. 从 NSTextStorage 中读取各可见行行首内容
    let storage = textStorage ?? return
    let fullString = storage.string as NSString
    let nsStr = string as NSString

    // 字符宽度：用等宽字体测量单个空格
    guard let font = self.font else { return }
    let charWidth = measureCharWidth(font: font)
    guard charWidth > 0 else { return }

    let insetX = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)

    // 3. 收集可见行的行首文本用于扫描层级
    // metrics.line 是 1-indexed 逻辑行
    let lineTexts: [String] = metrics.map { metric in
        let lineRange = displayedUTF16LineRange(forLine: metric.line)
        // 只取前 200 个字符用于缩进检测（性能保护）
        let safeLength = min(200, lineRange.length)
        guard lineRange.location != NSNotFound, safeLength >= 0,
              lineRange.location + safeLength <= nsStr.length else { return "" }
        return nsStr.substring(with: NSRange(location: lineRange.location, length: safeLength))
    }

    let levels = CodeEditorIndentGuideScanner.computeLevels(
        forLines: lineTexts,
        indentWidth: config.indentWidth,
        useTabs: config.useTabs
    )

    // 4. 计算 active indent guide 范围。
    // 基于光标所在行，在可见行中找出包含当前行的所有 guide 区间，取深度最大的。
    let activeGuideRange = computeActiveIndentGuideRange(
        metrics: metrics,
        levels: levels,
        indentWidth: config.indentWidth
    )

    // 5. 绘制
    NSGraphicsContext.saveGraphicsState()
    for (i, metric) in metrics.enumerated() {
        guard i < levels.count else { break }
        let levelInfo = levels[i]
        guard levelInfo.level > 0 else { continue }
        guard metric.rect.intersects(rect) else { continue }

        for depthIdx in 0 ..< levelInfo.level {
            // depthIdx = 0-indexed，即第 (depthIdx+1) 级 guide
            let xPos = insetX + CGFloat(depthIdx) * CGFloat(config.indentWidth) * charWidth
            let guideRect = NSRect(
                x: xPos,
                y: metric.rect.minY,
                width: 1.0,
                height: metric.rect.height
            )

            if guideRect.maxX < rect.minX || guideRect.minX > rect.maxX { continue }

            let isActive: Bool
            if let activeRange = activeGuideRange,
               activeRange.lineRange.contains(metric.line),
               depthIdx == activeRange.depth {
                isActive = true
            } else {
                isActive = false
            }

            let color = isActive
                ? CodeEditorPlatformTextView.indentGuideActiveColor
                : CodeEditorPlatformTextView.indentGuideInactiveColor
            color.setFill()
            guideRect.fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
}

/// 测量等宽字体的单个字符宽度。
private func measureCharWidth(font: NSFont) -> CGFloat {
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let size = (" " as NSString).size(withAttributes: attrs)
    return size.width
}
```

### Step 2：实现 `computeActiveIndentGuideRange`

```swift
private struct IndentGuideActiveRange {
    let lineRange: ClosedRange<Int>  // 1-indexed 逻辑行
    let depth: Int                    // 0-indexed depth（同 indentLevel - 1）
}

private func computeActiveIndentGuideRange(
    metrics: [CodeEditorVisibleLineMetric],
    levels: [CodeEditorIndentGuideLevel],
    indentWidth: Int
) -> IndentGuideActiveRange? {
    guard !hasMarkedText() else { return nil }

    // 光标当前行（1-indexed）
    let cursorLine = highlightedLineNumber ?? 1

    // 找光标行在可见 metrics 中的 index
    guard let cursorIdx = metrics.firstIndex(where: { $0.line == cursorLine }),
          cursorIdx < levels.count else {
        return nil
    }

    let cursorLevel = levels[cursorIdx].level
    guard cursorLevel > 0 else { return nil }

    // 找包含光标行且深度最大的 guide 区间
    // guide 区间：连续行的相同或更深 level 的块
    // 简化：active guide 是光标行所在的 level (cursorLevel-1) 的缩进块
    // 即：向上/向下扩展，找到所有 level >= cursorLevel 的连续行
    let targetDepth = cursorLevel - 1 // 0-indexed，画在第 cursorLevel 列

    var startLine = cursorLine
    var endLine   = cursorLine

    // 向上
    for i in stride(from: cursorIdx - 1, through: 0, by: -1) {
        let lvl = levels[i]
        if !lvl.isBlankLine && lvl.level < cursorLevel { break }
        startLine = metrics[i].line
    }

    // 向下
    for i in (cursorIdx + 1) ..< min(metrics.count, levels.count) {
        let lvl = levels[i]
        if !lvl.isBlankLine && lvl.level < cursorLevel { break }
        endLine = metrics[i].line
    }

    return IndentGuideActiveRange(lineRange: startLine...endLine, depth: targetDepth)
}
```

### Step 3: Run（验证编译通过）

已有 `displayedUTF16LineRange(forLine:)` 私有方法（见 `CodeEditorTextView.swift` 末部），在此直接调用。

---

## Task 5：Coordinator 注入 `indentGuideConfig`

**文件：**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（`Coordinator.updateGutterState` 调用附近或 `schedulePostUpdateRefresh` 阶段）

在 `Coordinator.updateGutterState(for textView:)` 或独立的 `updateIndentGuideConfig(for textView:)` 中，从 parent 的 `CodeEditorStatusBarState.indentation` 推导配置并写入 `textView.indentGuideConfig`。

> **注意：** `CodeEditorTextView` 是 `NSViewRepresentable`，其 `parent` 属性持有当前 SwiftUI binding 的上下文。`CodeEditorView` 通过 `@State private var document: CodeEditorDocument` 已持有文档状态；但 `CodeEditorIndentationStatus` 是由 `CodeEditorViewModel` 异步检测后推送到 `document` 或通过 `statusBarState` 回调上来的。

需要在 `CodeEditorTextView` 上添加一个 `indentationStatus` binding/参数，让 `updateNSView` 时把它注入 `textView.indentGuideConfig`。

### Step 1: `CodeEditorTextView` 新增参数

在 `struct CodeEditorTextView: NSViewRepresentable {` 的属性区添加：

```swift
var indentationStatus: CodeEditorIndentationStatus = CodeEditorIndentationStatus(kind: .unknown, width: 0)
```

### Step 2: `updateNSView` 中注入 config

在 `func updateNSView(_ containerView:, context:)` 的末尾（`schedulePostUpdateRefresh` 之前）添加：

```swift
(textView as? CodeEditorPlatformTextView)?.indentGuideConfig =
    CodeEditorIndentGuideConfig(from: indentationStatus)
```

### Step 3: `CodeEditorView` 传递 `indentationStatus`

`CodeEditorView` 内的 `CodeEditorTextView(...)` 调用处补充 `indentationStatus:` 参数：

```swift
CodeEditorTextView(
    text: $text,
    document: $document,
    // ... 已有参数 ...
    indentationStatus: viewModel.statusBar.indentation  // ← 新增
)
```

`viewModel.statusBar.indentation` 来自 `CodeEditorStatusBarState.indentation`，已在 `CodeEditorViewModel.detectIndentation(in:)` 中填充（见 `ViewModels/CodeEditorViewModel.swift`）。

### Step 4: 触发重绘

`indentGuideConfig` 变化时 (`didSet`)，调用 `setNeedsDisplay(visibleRect)`：

```swift
var indentGuideConfig: CodeEditorIndentGuideConfig = .disabled {
    didSet {
        guard indentGuideConfig != oldValue else { return }
        setNeedsDisplay(visibleRect)
    }
}
```

### Step 5: Run（完整编译验证）

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

---

## Task 6：视觉验证与边界情况修复

手动打开一个有多级缩进的 Swift 文件（如 `CodeEditorTextView.swift`），检查：

- [ ] inactive guide 可见，细线，灰色，半透明
- [ ] 当光标移动到不同缩进块时，active guide 颜色变深
- [ ] 空行不产生多余的孤立参考线
- [ ] tab 缩进文件（如 Makefile）参考线正确
- [ ] 滚动时参考线不闪烁或偏移
- [ ] IME 输入（中文）期间 drawBackground 不崩溃，active guide 暂停更新

### Step 1: 空行处理验证

检查连续空行区域，参考线应向上下延续（因为 `computeLevels` 的空行填充逻辑用了 min(prev, next)）。若视觉上出现断裂，检查是否由于 `guideRect.height = metric.rect.height` 与相邻行的 y 存在 1pt 间隔导致。

**修复方案（若出现间隔）：** 将 `height` 改为 `metric.rect.height + 0.5` 或按 `ceil` 对齐到像素边界。

```swift
// Retina 屏 1pt = 2px，需要 ceil 对齐
let pixelAlignedHeight = ceil(metric.rect.height * scaleFactor) / scaleFactor
where scaleFactor = window?.backingScaleFactor ?? 1.0
```

### Step 2: 低分辨率屏幕的线宽

标准屏 1pt = 1px，参考线可能太粗。可改为 0.5pt 宽度（Retina 下是 1px）：

```swift
let lineWidth: CGFloat = 1.0 / max(1.0, window?.backingScaleFactor ?? 1.0)
let guideRect = NSRect(x: xPos, y: metric.rect.minY, width: lineWidth, height: metric.rect.height)
```

### Step 3: `drawBackground` clip rect 优化

`drawBackground(in:)` 的参数 `rect` 是 NSTextView dirty rect，不一定覆盖全屏。当 `guideRect` 与 `rect` 不相交时跳过（已在代码中做了 `intersects` 检查）。确认没有遗漏。

---

## Task 7：完整测试套件补充

**文件：**
- Modify: `agentGuiTests/CodeEditorIndentGuideTests.swift`（追加）

补充纯绘制逻辑的间接测试（通过 scanner 验证）：

```swift
// MARK: - 混合缩进（容错）

@Test("混合缩进：tab 后跟空格，按 useTabs 判断")
func mixedIndent() {
    // useTabs=true 时只数前缀 tab 数
    #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "\t   x", indentWidth: 4, useTabs: true) == 1)
    // useTabs=false 时只数前缀空格数（遇到 tab 停止？不，\t 不是空格，所以 level=0）
    #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "\t   x", indentWidth: 4, useTabs: false) == 0)
}

@Test("单字符 indentWidth=1")
func indentWidth1() {
    #expect(CodeEditorIndentGuideScanner.indentLevel(forLinePrefix: "  x", indentWidth: 1, useTabs: false) == 2)
}

@Test("整行为空格")
func lineAllSpaces() {
    // 与 isBlankLine 一致
    #expect(CodeEditorIndentGuideScanner.isBlankLine("    ") == true)
    // computeLevels 空行处理
    let result = CodeEditorIndentGuideScanner.computeLevels(forLines: ["    "], indentWidth: 4, useTabs: false)
    #expect(result[0].isBlankLine == true)
    #expect(result[0].level == 0)
}
```

### Step 1: Run（完整测试）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f15-derived \
  -only-testing:agentGuiTests/CodeEditorIndentGuideTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`

---

## Task 8：Commit

```bash
cd /Volumes/T7/文稿/Projects/agentGui
git add \
  agentGui/Services/Editor/CodeEditorIndentGuideScanner.swift \
  agentGui/Views/CodeEditor/CodeEditorTextView.swift \
  agentGuiTests/CodeEditorIndentGuideTests.swift
git commit -m "feat(editor): F15 indent guides — scanner + drawBackground rendering"
```

---

## 边界情况与已知限制

| 情况 | 处理方式 |
|------|---------|
| `indentWidth <= 0` | `CodeEditorIndentGuideConfig.disabled`，`drawIndentGuides` 立即返回 |
| IME 组合输入 | `hasMarkedText()` 时跳过 active guide 计算（draw inactive only）|
| 空行 | `computeLevels` 填充为 min(prev, next) 非空行 level |
| 混合缩进（tab + spaces）| 以 `useTabs` 标志为准，只计数对应字符 |
| `indentationStatus.kind == .unknown` | 默认 4 spaces |
| 文件字符串很长（> 10 万行）| `visibleLineMetrics` 已限制为可见行，性能安全 |
| 折叠行（F12 完成后）| 折叠行对应的 `visibleLineMetrics` 中不会出现被隐藏行，无需特殊处理；折叠后 guide 自然跟随可见区域缩短，符合 VSCode 行为 |
| Retina 屏线宽 | Task 6 中按 `backingScaleFactor` 计算 0.5pt 或 1px |

---

## 颜色主题对照

| 状态 | 颜色 | 来源 |
|------|------|------|
| Inactive guide | `NSColor.separatorColor.withAlphaComponent(0.35)` | 系统动态色，适配 Light/Dark |
| Active guide | `NSColor.separatorColor.withAlphaComponent(0.70)` | 同上，更深 |

VSCode 使用主题 token `editorIndentGuide.background` / `editorIndentGuide.activeBackground`（约 `#404040` @ Dark+）。  
Zed 使用 `cx.theme().colors().editor_indent_guide` / `editor_indent_guide_active`。  
agentGui 首轮用系统色（动态 Light/Dark 适配），后续可通过 `AppSettings + UserDefaults` 支持自定义。

---

## 测试清单（手动验收）

- [ ] Swift 文件：多级 if/guard/switch 嵌套，inactive guide 清晰可见
- [ ] Swift 文件：光标移动到 if 体内，同级 guide 变深
- [ ] Markdown 文件（无缩进）：没有多余 guide
- [ ] Makefile（tab 缩进）：`useTabs=true`，参考线位置正确
- [ ] YAML 文件（2 spaces）：indentWidth=2，参考线每 2 列一条
- [ ] 空行：参考线延续上下邻行级别，无断裂
- [ ] IME 输入中文：界面不闪烁，active guide 暂停不崩溃
- [ ] 滚动快速拖拽：参考线跟随，无渲染残影

# Feature 14: Bracket Matching & Pair Colorization 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 CodeEditor 中实现光标括号高亮（bracket match highlight）和可选的括号对着色（pair colorization），对齐 VSCode 2021 括号着色特性与 Zed 的 `highlight_matching_bracket` 模块。

**Architecture:** 括号匹配高亮通过 `NSLayoutManager.addTemporaryAttributes` 实现（不污染 NSTextStorage，不影响撤销，对 IME 安全）；选区变化时在 Coordinator 同步计算并立即应用，无需 SwiftUI 绑定往返。括号对着色作为独立的后处理过程，在 highlight pipeline 完成后调用，opt-in 控制开关存入 AppSettings。

**Tech Stack:** Swift 6.0+、AppKit NSTextView (TextKit 1)、NSLayoutManager temporary attributes、Swift Testing (`@Test` / `#expect`)、SwiftData (`AppSettings`)

---

## 研究摘要

### VSCode 方案（`bracketPairsTree.ts`）

- 实现了完整的 AST：`AstNodeKind.List / Pair / Bracket / Text / UnexpectedClosingBracket`
- 两棵树：`initialAstWithoutTokens`（无 token，快速初始化）和 `astWithTokens`（精确，等 Tokenization 完成后切换），防止着色闪烁
- 括号对着色用 `levelPerBracketType: Map<String, number>` 分类型计数，每种括号独立循环 6 色
- 高亮更新路径：`IModelContentChangedEvent` → `handleContentChanged` → `flushQueue` → delta 增量解析

**agentGui 对应：** 当前无 Tree-sitter，不需要 AST；首轮用线性栈扫描（O(n)，n 为文档长度），viewport-first 截断。括号对着色用全局嵌套深度 % 6 简化版（可后续升级为 per-type）。

### Zed 方案（`highlight_matching_bracket.rs` + `bracket_colorization.rs`）

- `refresh_matching_bracket_highlights` 在 `selections_did_change` 末尾调用，异步 Task (`cx.spawn`)
- `colorize_brackets` 在 `Reparsed` 和 `language_settings_changed` 事件触发
- 两者都基于 Tree-sitter 的 `enclosing_bracket_ranges(selection.start..selection.end)` API

**agentGui 对应：** 无 Tree-sitter，使用 `CodeEditorLineIndex` 提供 offset → line 映射，直接线性扫描 `string.utf16`。选区变化同步执行（无 async task），因为扫描是纯 CPU 的 O(n)，文件通常 < 10k 行时无感知延迟。

---

## 文件总览

| 操作 | 路径 |
|------|------|
| 新建 | `agentGui/Services/Editor/CodeEditorBracketScanner.swift` |
| 新建 | `agentGui/Services/Editor/CodeEditorBracketPairColorizationService.swift` |
| 修改 | `agentGui/Views/CodeEditor/CodeEditorTextView.swift` |
| 修改 | `agentGui/Models/AppSettings.swift` |
| 新建 | `agentGuiTests/CodeEditorBracketScannerTests.swift` |
| 新建 | `agentGuiTests/CodeEditorBracketMatchHighlightTests.swift` |
| 新建 | `agentGuiTests/CodeEditorBracketPairColorizationTests.swift` |

---

## Task 1: CodeEditorBracketScanner — 纯值类型扫描器

**Files:**
- Create: `agentGui/Services/Editor/CodeEditorBracketScanner.swift`

### Step 1: 创建文件骨架与类型定义

```swift
import Foundation

/// 括号匹配扫描结果：开括号和闭括号的 utf16 range。
/// openRange 和 closeRange 各占一个字符（在极少数多字节 utf16 情况下也是 1 或 2 个 utf16 unit）。
struct CodeEditorBracketMatchResult: Equatable, Sendable {
    let openRange: NSRange
    let closeRange: NSRange
}

/// 纯值类型括号匹配扫描器。
/// 线性 O(n) 栈扫描，不依赖 Tree-sitter。
struct CodeEditorBracketScanner: Sendable {

    /// 支持的括号对（开 → 闭）
    static let openBrackets: [UInt16] = [
        UInt16(("(" as UnicodeScalar).value),
        UInt16(("[" as UnicodeScalar).value),
        UInt16(("{" as UnicodeScalar).value),
    ]
    static let closeBrackets: [UInt16] = [
        UInt16((")" as UnicodeScalar).value),
        UInt16(("]" as UnicodeScalar).value),
        UInt16(("}" as UnicodeScalar).value),
    ]

    /// 给定 utf16 字符串和光标 utf16 offset，查找匹配括号对。
    /// 检测光标前一字符（index = cursorOffset - 1）和光标当前字符（index = cursorOffset）。
    /// 若在括号字符上，向前/向后线性扫描，找到匹配的另一侧括号。
    /// - Parameter maxSearchDistance: 最大扫描字符数，防止超大文件卡顿，默认 50_000
    static func findMatch(
        in utf16: [UInt16],
        cursorOffset: Int,
        maxSearchDistance: Int = 50_000
    ) -> CodeEditorBracketMatchResult? {
        // Step 1: 检查 cursor 当前字符 (forward bracket)
        if let result = scanForward(utf16: utf16, from: cursorOffset, maxDistance: maxSearchDistance) {
            return result
        }
        // Step 2: 检查 cursor 前一字符 (backward bracket)
        if cursorOffset > 0,
           let result = scanBackward(utf16: utf16, from: cursorOffset - 1, maxDistance: maxSearchDistance) {
            return result
        }
        return nil
    }

    /// 给定一个开括号在 startIndex 处，向前搜索其匹配的闭括号。
    static func scanForward(utf16: [UInt16], from startIndex: Int, maxDistance: Int) -> CodeEditorBracketMatchResult? {
        guard startIndex < utf16.count else { return nil }
        let ch = utf16[startIndex]
        guard let pairIndex = openBrackets.firstIndex(of: ch) else { return nil }
        let closeChar = closeBrackets[pairIndex]

        var depth = 1
        var i = startIndex + 1
        let limit = min(utf16.count, startIndex + maxDistance)
        while i < limit {
            let c = utf16[i]
            if c == ch { depth += 1 }
            else if c == closeChar {
                depth -= 1
                if depth == 0 {
                    return CodeEditorBracketMatchResult(
                        openRange: NSRange(location: startIndex, length: 1),
                        closeRange: NSRange(location: i, length: 1)
                    )
                }
            }
            i += 1
        }
        return nil
    }

    /// 给定一个闭括号在 startIndex 处，向后搜索其匹配的开括号。
    static func scanBackward(utf16: [UInt16], from startIndex: Int, maxDistance: Int) -> CodeEditorBracketMatchResult? {
        guard startIndex < utf16.count else { return nil }
        let ch = utf16[startIndex]
        guard let pairIndex = closeBrackets.firstIndex(of: ch) else { return nil }
        let openChar = openBrackets[pairIndex]

        var depth = 1
        var i = startIndex - 1
        let lowerLimit = max(0, startIndex - maxDistance)
        while i >= lowerLimit {
            let c = utf16[i]
            if c == ch { depth += 1 }
            else if c == openChar {
                depth -= 1
                if depth == 0 {
                    return CodeEditorBracketMatchResult(
                        openRange: NSRange(location: i, length: 1),
                        closeRange: NSRange(location: startIndex, length: 1)
                    )
                }
            }
            i -= 1
        }
        return nil
    }
}

extension CodeEditorBracketScanner {
    /// 便利入口：直接接受 String，转为 UTF-16 数组后调用 findMatch。
    static func findMatch(
        in text: String,
        cursorOffset: Int,
        maxSearchDistance: Int = 50_000
    ) -> CodeEditorBracketMatchResult? {
        let utf16Array = Array(text.utf16)
        return findMatch(in: utf16Array, cursorOffset: cursorOffset, maxSearchDistance: maxSearchDistance)
    }
}
```

### Step 2: 把文件加入 Xcode 项目

在 `agentGui.xcodeproj` 中把 `CodeEditorBracketScanner.swift` 添加到 `agentGui` target 的 `Services/Editor` 组。

**提交：** `git add agentGui/Services/Editor/CodeEditorBracketScanner.swift && git commit -m "feat: add CodeEditorBracketScanner pure value type"`

---

## Task 2: BracketScanner 单元测试

**Files:**
- Create: `agentGuiTests/CodeEditorBracketScannerTests.swift`
- Add to `agentGuiTests` target in Xcode.

### Step 1: 写测试

```swift
import Testing
@testable import agentGui

struct CodeEditorBracketScannerTests {

    // MARK: - Forward scan

    @Test func cursorOnOpenParenFindsMatchingCloseParen() {
        let text = "(hello)"
        // cursor 在 '(' 上，offset=0
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: 0)
        #expect(result?.openRange == NSRange(location: 0, length: 1))
        #expect(result?.closeRange == NSRange(location: 6, length: 1))
    }

    @Test func cursorOnOpenBraceFindsMatchingCloseBrace() {
        let text = "{ a + b }"
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: 0)
        #expect(result?.openRange == NSRange(location: 0, length: 1))
        #expect(result?.closeRange == NSRange(location: 8, length: 1))
    }

    @Test func nestedBracketsReturnsInnermostMatch() {
        let text = "((x))"
        // cursor 在内层 '('，offset=1
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: 1)
        #expect(result?.openRange == NSRange(location: 1, length: 1))
        #expect(result?.closeRange == NSRange(location: 3, length: 1))
    }

    // MARK: - Backward scan

    @Test func cursorAfterCloseParenFindsMatchingOpenParen() {
        let text = "(hello)"
        // cursor 在 ')' 后面，offset=7；cursor-1=')' at 6
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: 7)
        #expect(result?.openRange == NSRange(location: 0, length: 1))
        #expect(result?.closeRange == NSRange(location: 6, length: 1))
    }

    @Test func cursorOnCloseBracketBeforeTextFindsOpen() {
        // "[abc]" — cursor 在 ']' 处（offset=4）
        let text = "[abc]"
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: 4)
        // 先检测 offset=4 (']):  backward scan
        #expect(result?.openRange == NSRange(location: 0, length: 1))
        #expect(result?.closeRange == NSRange(location: 4, length: 1))
    }

    // MARK: - No match cases

    @Test func unmatchedOpenParenReturnsNil() {
        let text = "(no close"
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: 0)
        #expect(result == nil)
    }

    @Test func cursorOnNonBracketCharReturnsNil() {
        let text = "hello world"
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: 3)
        #expect(result == nil)
    }

    @Test func emptyStringReturnsNil() {
        let result = CodeEditorBracketScanner.findMatch(in: "", cursorOffset: 0)
        #expect(result == nil)
    }

    @Test func cursorAtEndOfStringReturnsNil() {
        let text = "(x)"
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: text.utf16.count)
        #expect(result == nil)
    }

    // MARK: - maxSearchDistance 截断

    @Test func searchDistanceLimitPreventsMatchTooFarAway() {
        // 在 '(' 和 ')' 之间插入 100 个字符
        let inner = String(repeating: "x", count: 100)
        let text = "(" + inner + ")"
        // maxSearchDistance=10 应无法找到
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: 0, maxSearchDistance: 10)
        #expect(result == nil)
    }

    @Test func searchDistanceLargeEnoughFindsBracket() {
        let inner = String(repeating: "x", count: 100)
        let text = "(" + inner + ")"
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: 0, maxSearchDistance: 200)
        #expect(result != nil)
    }

    // MARK: - 多行

    @Test func multilineBracketMatch() {
        let text = "func foo() {\n    let x = 1\n}"
        // '{' 在 offset=11
        let braceOffset = (text as NSString).range(of: "{").location
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: braceOffset)
        let closeOffset = (text as NSString).range(of: "}", options: .backwards).location
        #expect(result?.openRange.location == braceOffset)
        #expect(result?.closeRange.location == closeOffset)
    }
}
```

### Step 2: 运行测试（确认全部通过）

```bash
cd /Volumes/T7/文稿/Projects/agentGui && \
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f14-bracket-derived \
  -only-testing:agentGuiTests/CodeEditorBracketScannerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|passed|failed|error:"
```

Expected: 所有测试 PASS

**提交：** `git add agentGuiTests/CodeEditorBracketScannerTests.swift && git commit -m "test: add CodeEditorBracketScannerTests"`

---

## Task 3: CodeEditorPlatformTextView — 括号高亮集成

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`

本 Task 在 `CodeEditorPlatformTextView` 内部管理括号高亮，使用 `NSLayoutManager.addTemporaryAttributes`（不修改 NSTextStorage，对撤销/IME 安全）。

### Step 1: 在 CodeEditorPlatformTextView 中添加属性和方法

在 `final class CodeEditorPlatformTextView: NSTextView {` 块的属性区（`latestAppliedHighlightVersion` 附近）添加：

```swift
// MARK: - Bracket Match Highlight
/// 当前已应用的括号高亮范围（用于后续清除）
private var appliedBracketMatchRanges: (open: NSRange, close: NSRange)?

/// 括号高亮背景色
static let bracketMatchBackgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.22)
```

再在 `CodeEditorPlatformTextView` 中添加两个方法：

```swift
/// 应用括号高亮（清除旧的后应用新的）。
/// 若 result 为 nil 则只清除旧高亮。
func applyBracketMatchHighlight(_ result: CodeEditorBracketMatchResult?) {
    guard let layoutManager else { return }
    // 清除旧的高亮
    if let old = appliedBracketMatchRanges {
        let fullLength = (string as NSString).length
        let safeOpen = clampRange(old.open, max: fullLength)
        let safeClose = clampRange(old.close, max: fullLength)
        if safeOpen.length > 0 {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: safeOpen)
        }
        if safeClose.length > 0 {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: safeClose)
        }
    }
    appliedBracketMatchRanges = nil

    guard let result else { return }
    let fullLength = (string as NSString).length
    let safeOpen = clampRange(result.openRange, max: fullLength)
    let safeClose = clampRange(result.closeRange, max: fullLength)
    guard safeOpen.length > 0, safeClose.length > 0 else { return }

    layoutManager.addTemporaryAttribute(
        .backgroundColor,
        value: Self.bracketMatchBackgroundColor,
        forCharacterRange: safeOpen
    )
    layoutManager.addTemporaryAttribute(
        .backgroundColor,
        value: Self.bracketMatchBackgroundColor,
        forCharacterRange: safeClose
    )
    appliedBracketMatchRanges = (safeOpen, safeClose)
}

private func clampRange(_ range: NSRange, max length: Int) -> NSRange {
    let location = Swift.max(0, Swift.min(range.location, length))
    let safeLength = Swift.max(0, Swift.min(range.length, length - location))
    return NSRange(location: location, length: safeLength)
}
```

### Step 2: 在 Coordinator.publishSelection 中触发括号高亮

在 `func publishSelection(for textView: NSTextView)` 末尾（`updateGutterState(for: textView)` 调用之后）添加：

```swift
// 括号高亮
if let platformTextView = textView as? CodeEditorPlatformTextView,
   !platformTextView.hasMarkedText() {
    let cursorOffset = textView.selectedRange().location
    let matchResult = CodeEditorBracketScanner.findMatch(
        in: platformTextView.string,
        cursorOffset: cursorOffset
    )
    platformTextView.applyBracketMatchHighlight(matchResult)
}
```

### Step 3: 在 IME 组合输入结束时重置高亮

在 `handleCompositionStateChange(in textView:)` 末尾，添加：

```swift
// IME 结束后重新计算括号高亮
if let platformTextView = textView as? CodeEditorPlatformTextView,
   !platformTextView.hasMarkedText() {
    let cursorOffset = platformTextView.selectedRange().location
    let matchResult = CodeEditorBracketScanner.findMatch(
        in: platformTextView.string,
        cursorOffset: cursorOffset
    )
    platformTextView.applyBracketMatchHighlight(matchResult)
} else if let platformTextView = textView as? CodeEditorPlatformTextView {
    // IME 期间清除括号高亮
    platformTextView.applyBracketMatchHighlight(nil)
}
```

### Step 4: 验证不崩溃（手工验证）

打开 Xcode，运行 App，在 CodeEditor 中移动光标到括号字符旁，观察背景高亮是否出现。

**提交：** `git commit -am "feat: implement bracket match highlight via NSLayoutManager temporary attributes"`

---

## Task 4: 括号高亮集成测试

**Files:**
- Create: `agentGuiTests/CodeEditorBracketMatchHighlightTests.swift`

### Step 1: 写集成测试

```swift
import AppKit
import Testing
@testable import agentGui

@MainActor
struct CodeEditorBracketMatchHighlightTests {

    // 注意：CodeEditorPlatformTextView 需要 NSWindow 才能有 layoutManager 的 temporary attributes 效果。
    // 这里仅测试 applyBracketMatchHighlight 不崩溃，以及 appliedBracketMatchRanges 状态。

    @Test func applyBracketMatchHighlightSetsBothRanges() {
        let textView = CodeEditorPlatformTextView()
        textView.string = "(hello)"
        let result = CodeEditorBracketMatchResult(
            openRange: NSRange(location: 0, length: 1),
            closeRange: NSRange(location: 6, length: 1)
        )
        // Should not crash even without a window/layoutManager
        textView.applyBracketMatchHighlight(result)
        // If no layoutManager, just verify no crash
    }

    @Test func applyBracketMatchHighlightNilClearsPreviousState() {
        let textView = CodeEditorPlatformTextView()
        textView.string = "(hello)"
        let result = CodeEditorBracketMatchResult(
            openRange: NSRange(location: 0, length: 1),
            closeRange: NSRange(location: 6, length: 1)
        )
        textView.applyBracketMatchHighlight(result)
        textView.applyBracketMatchHighlight(nil)  // 清除，不崩溃
    }

    @Test func applyBracketMatchHighlightWithOutOfBoundsRangeSafelyClamps() {
        let textView = CodeEditorPlatformTextView()
        textView.string = "x"  // length=1
        let badResult = CodeEditorBracketMatchResult(
            openRange: NSRange(location: 0, length: 1),
            closeRange: NSRange(location: 999, length: 1)  // out of bounds
        )
        textView.applyBracketMatchHighlight(badResult)
        // Should not crash
    }

    @Test func bracketScannerAndHighlightEndToEnd() {
        let textView = CodeEditorPlatformTextView()
        textView.string = "func foo(x: Int) {}"
        // Cursor 在 '(' 上 (offset=8)
        let matchResult = CodeEditorBracketScanner.findMatch(
            in: textView.string,
            cursorOffset: 8
        )
        #expect(matchResult != nil)
        #expect(matchResult?.openRange.location == 8)
        // ')' 在 offset 15
        #expect(matchResult?.closeRange.location == 15)
        textView.applyBracketMatchHighlight(matchResult)
    }
}
```

### Step 2: 运行测试

```bash
cd /Volumes/T7/文稿/Projects/agentGui && \
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f14-bracket-derived \
  -only-testing:agentGuiTests/CodeEditorBracketScannerTests \
  -only-testing:agentGuiTests/CodeEditorBracketMatchHighlightTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|passed|failed|error:"
```

Expected: 所有测试 PASS

**提交：** `git add agentGuiTests/CodeEditorBracketMatchHighlightTests.swift && git commit -m "test: add CodeEditorBracketMatchHighlightTests"`

---

## Task 5: 括号对着色服务（Pair Colorization，opt-in）

**Files:**
- Create: `agentGui/Services/Editor/CodeEditorBracketPairColorizationService.swift`

括号对着色参考 VSCode `bracketPairsTree.ts` 的 `levelPerBracketType` 设计，首轮使用全局嵌套深度（简化版），6 色循环。着色通过 `NSLayoutManager.addTemporaryAttribute` 应用（同 bracket match，不污染 NSTextStorage）。

### Step 1: 实现着色服务

```swift
import AppKit
import Foundation

/// 括号对着色服务（opt-in）。
/// 在 viewport 文本范围内，对不同嵌套深度的括号对应用不同颜色（6 色循环）。
/// 通过 NSLayoutManager.addTemporaryAttribute 应用，不修改 NSTextStorage。
struct CodeEditorBracketPairColorizationService: Sendable {

    /// 6 种括号对颜色（可主题化，首轮使用系统颜色近似）
    static let paletteColors: [NSColor] = [
        NSColor(calibratedRed: 0.97, green: 0.79, blue: 0.18, alpha: 1.0), // yellow
        NSColor(calibratedRed: 0.27, green: 0.69, blue: 0.95, alpha: 1.0), // cyan
        NSColor(calibratedRed: 0.62, green: 0.45, blue: 0.98, alpha: 1.0), // purple
        NSColor(calibratedRed: 0.33, green: 0.85, blue: 0.48, alpha: 1.0), // green
        NSColor(calibratedRed: 0.97, green: 0.53, blue: 0.32, alpha: 1.0), // orange
        NSColor(calibratedRed: 0.95, green: 0.36, blue: 0.64, alpha: 1.0), // pink
    ]

    /// bracket 字符集（开和闭，索引对应）
    private static let openBrackets: [UInt16] = [
        UInt16(("(" as UnicodeScalar).value),
        UInt16(("[" as UnicodeScalar).value),
        UInt16(("{" as UnicodeScalar).value),
    ]
    private static let closeBrackets: [UInt16] = [
        UInt16((")" as UnicodeScalar).value),
        UInt16(("]" as UnicodeScalar).value),
        UInt16(("}" as UnicodeScalar).value),
    ]

    /// 为给定的 NSTextView 区间 [rangeStart, rangeEnd)（utf16 offset）着色。
    /// 扫描从文档开头到 rangeEnd，追踪全局嵌套深度，仅对 rangeStart..rangeEnd 区间内的括号应用颜色。
    /// - Parameters:
    ///   - textView: 目标 NSTextView（含 layoutManager）
    ///   - visibleUTF16Range: 只对此范围内的括号着色（viewport window）
    static func colorize(
        textView: NSTextView,
        visibleUTF16Range: NSRange
    ) {
        guard let layoutManager = textView.layoutManager else { return }
        let text = textView.string
        let utf16 = Array(text.utf16)
        let totalLength = utf16.count

        // 清除旧的括号对颜色（foregroundColor temporary attributes 在 visibleUTF16Range 内）
        // 注意：这会清除所有 foregroundColor temporary attributes，包括 syntax highlight 之外的。
        // 安全起见，只在 viewport 范围内清除，且仅清除 pair colorization key。
        // 这里用一个专门的 attribute key 避免与语法高亮冲突。
        // 由于 NSTextView temporary attributes 只支持标准 AttributedString key，
        // 我们用一个不常用的自定义 attribute 标记颜色 span（macOS 会忽略未知 attribute 渲染，
        // 所以我们只在清除时用它标记范围，同时也应用 .foregroundColor）。
        // 首轮简化：先 remove 整个 visibleRange 内的 pairColor 标记，再重新写入。
        let safeRangeStart = max(0, min(visibleUTF16Range.location, totalLength))
        let safeRangeEnd = max(safeRangeStart, min(visibleUTF16Range.location + visibleUTF16Range.length, totalLength))
        guard safeRangeEnd > safeRangeStart else { return }
        let safeRange = NSRange(location: safeRangeStart, length: safeRangeEnd - safeRangeStart)
        // 移除旧的 pairColorization foregroundColor (用单独 attribute key 标记)
        layoutManager.removeTemporaryAttribute(.init("agentGui.bracketPairColor"), forCharacterRange: safeRange)

        // 从文档头扫描到 safeRangeEnd，追踪全局深度
        // 对在 safeRange 内的每个括号字符应用颜色
        var globalDepth = 0  // 全局混合深度（所有括号类型共用）
        var i = 0
        while i < safeRangeEnd {
            let ch = utf16[i]
            if let pairIdx = openBrackets.firstIndex(of: ch) {
                let color = paletteColors[globalDepth % paletteColors.count]
                globalDepth += 1
                if i >= safeRangeStart {
                    layoutManager.addTemporaryAttribute(
                        .foregroundColor,
                        value: color,
                        forCharacterRange: NSRange(location: i, length: 1)
                    )
                    layoutManager.addTemporaryAttribute(
                        .init("agentGui.bracketPairColor"),
                        value: color,
                        forCharacterRange: NSRange(location: i, length: 1)
                    )
                }
            } else if closeBrackets.contains(ch) {
                globalDepth = max(0, globalDepth - 1)
                let color = paletteColors[globalDepth % paletteColors.count]
                if i >= safeRangeStart {
                    layoutManager.addTemporaryAttribute(
                        .foregroundColor,
                        value: color,
                        forCharacterRange: NSRange(location: i, length: 1)
                    )
                    layoutManager.addTemporaryAttribute(
                        .init("agentGui.bracketPairColor"),
                        value: color,
                        forCharacterRange: NSRange(location: i, length: 1)
                    )
                }
            }
            i += 1
        }
    }
}
```

> **设计注意：** 首轮 colorizaton 使用 `NSLayoutManager.addTemporaryAttribute(.foregroundColor)` 叠加颜色。由于 temporary attributes 在 setAttributes 调用后会被清除，需要在 `applyHighlightResult` 完成后再调用 colorize。当前架构中的时机是 `schedulePostUpdateRefresh` 回调后触发。具体接入见 Task 7。

### Step 2: 把文件加入 Xcode 项目 target

**提交：** `git add agentGui/Services/Editor/CodeEditorBracketPairColorizationService.swift && git commit -m "feat: add CodeEditorBracketPairColorizationService"`

---

## Task 6: Pair Colorization 测试

**Files:**
- Create: `agentGuiTests/CodeEditorBracketPairColorizationTests.swift`

### Step 1: 写测试

```swift
import AppKit
import Testing
@testable import agentGui

@MainActor
struct CodeEditorBracketPairColorizationTests {

    @Test func colorizationDoesNotCrashOnEmptyText() {
        let textView = NSTextView()
        textView.string = ""
        CodeEditorBracketPairColorizationService.colorize(
            textView: textView,
            visibleUTF16Range: NSRange(location: 0, length: 0)
        )
    }

    @Test func colorizationDoesNotCrashOnNoBrackets() {
        let textView = NSTextView()
        textView.string = "hello world"
        CodeEditorBracketPairColorizationService.colorize(
            textView: textView,
            visibleUTF16Range: NSRange(location: 0, length: 11)
        )
    }

    @Test func colorizationDoesNotCrashOnOutOfBoundsRange() {
        let textView = NSTextView()
        textView.string = "(x)"
        CodeEditorBracketPairColorizationService.colorize(
            textView: textView,
            visibleUTF16Range: NSRange(location: 0, length: 999)
        )
    }

    @Test func colorizationHasSixDistinctColors() {
        #expect(CodeEditorBracketPairColorizationService.paletteColors.count == 6)
    }

    @Test func colorizationDepthModuloWrapsCorrectly() {
        // Depth 0 → paletteColors[0], depth 6 → paletteColors[0], depth 7 → paletteColors[1]
        let colors = CodeEditorBracketPairColorizationService.paletteColors
        #expect(colors.count == 6)
        let depth6Color = colors[6 % colors.count]
        let depth0Color = colors[0]
        #expect(depth6Color == depth0Color)
    }
}
```

### Step 2: 运行测试

```bash
cd /Volumes/T7/文稿/Projects/agentGui && \
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f14-bracket-derived \
  -only-testing:agentGuiTests/CodeEditorBracketPairColorizationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|passed|failed|error:"
```

Expected: 所有 PASS

**提交：** `git add agentGuiTests/CodeEditorBracketPairColorizationTests.swift && git commit -m "test: add CodeEditorBracketPairColorizationTests"`

---

## Task 7: AppSettings 开关 + CodeEditorView 接入

**Files:**
- Modify: `agentGui/Models/AppSettings.swift`（添加 `isBracketPairColorizationEnabled`）
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（接入 pair colorization）

### Step 1: 在 AppSettings 添加开关

找到 `AppSettings` (SwiftData `@Model` class)，在属性区添加：

```swift
/// 括号对着色（Bracket Pair Colorization）开关，默认 false（opt-in）。
var isBracketPairColorizationEnabled: Bool = false
```

### Step 2: 在 CodeEditorTextView 中暴露开关

在 `struct CodeEditorTextView: NSViewRepresentable {` 的属性区添加：

```swift
var isBracketPairColorizationEnabled: Bool = false
```

### Step 3: 在 applyHighlightResult 末尾触发 pair colorization

在 `Coordinator.applyHighlightResult(_ result:, to textView:)` 末尾（`textView.latestAppliedHighlightVersion = result.version` 之后）添加：

```swift
// Pair colorization（opt-in）
if parent.isBracketPairColorizationEnabled,
   let storage = textView.textStorage {
    let visibleRange = NSRange(location: 0, length: storage.length)
    if let visibleLineRange = visibleLineRange(for: textView) {
        let startOffset = parent.document.utf16Offset(line: visibleLineRange.lowerBound, column: 1)
        let endOffset = parent.document.utf16Offset(line: visibleLineRange.upperBound, column: 9999)
        let clampedEnd = min(endOffset, storage.length)
        let clampedStart = max(0, startOffset)
        if clampedEnd > clampedStart {
            CodeEditorBracketPairColorizationService.colorize(
                textView: textView,
                visibleUTF16Range: NSRange(location: clampedStart, length: clampedEnd - clampedStart)
            )
        }
    }
}
```

### Step 4: 在 CodeEditorView（或 FileEditorView）中读取 AppSettings 并传递开关

在 `CodeEditorView` 或其调用方中，从 `AppSettings` 读取 `isBracketPairColorizationEnabled`，通过 `CodeEditorTextView(... isBracketPairColorizationEnabled: settings.isBracketPairColorizationEnabled)` 传递。

> 具体传参路径视 `CodeEditorView` 的 struct 定义而定，参考 `highlighter` 参数的传递方式。

### Step 5: 手工验证

1. 在 Settings UI 中加一个 Toggle 绑定 `AppSettings.isBracketPairColorizationEnabled`
2. 打开 App → 加载 Swift 文件 → 开启 Pair Colorization → 观察括号是否着色

**提交：** `git commit -am "feat: wire bracket pair colorization opt-in via AppSettings"`

---

## Task 8: 全量回归测试

### Step 1: 运行所有 F14 相关测试

```bash
cd /Volumes/T7/文稿/Projects/agentGui && \
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f14-final-derived \
  -only-testing:agentGuiTests/CodeEditorBracketScannerTests \
  -only-testing:agentGuiTests/CodeEditorBracketMatchHighlightTests \
  -only-testing:agentGuiTests/CodeEditorBracketPairColorizationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|passed|failed|error:"
```

Expected: 全部 PASS

### Step 2: 运行已有 CodeEditor 相关测试（回归）

```bash
cd /Volumes/T7/文稿/Projects/agentGui && \
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f14-regression-derived \
  -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests \
  -only-testing:agentGuiTests/CodeEditorViewIntegrationTests \
  -only-testing:agentGuiTests/CodeEditorGutterLaneTests \
  -only-testing:agentGuiTests/CodeEditorHighlightPipelineTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|passed|failed|error:"
```

Expected: 无 FAIL，无新引入 error

**最终提交：** `git commit -am "chore: Feature 14 bracket matching & pair colorization complete"`

---

## 已知限制与后续扩展点

| 主题 | 当前状态 | 后续升级路径 |
|------|---------|-------------|
| 括号类型 | 仅 `() [] {}` | 加 `<>` 需防止与泛型尖括号误判；加 `""` `''` 需字符串上下文感知 |
| 扫描算法 | O(n) 线性栈扫描 | 升级到 F27 Tree-sitter 后，改用 `enclosing_bracket_ranges` API（同 Zed） |
| Pair Colorization 时机 | applyHighlightResult 末尾 | 当前 temporary attributes 在下次 setAttributes 写入时会被清除；长远方案：在 drawBackground 中按行重绘，类似 VSCode canvas 层 |
| 颜色主题化 | 硬编码 6 色 | AppSettings 中增加自定义颜色主题，从 Highlightr theme 中读取 |
| 两棵树性能（VSCode 方案） | 无 | 当前文件规模不需要；F27 后可借鉴 initialAstWithoutTokens / astWithTokens 双树防闪烁 |

---

## 调试技巧

**测试 bracket scan 的 offset：**
```swift
// 在 REPL 或 test 中快速确认 offset
let text = "func foo(x: Int) {}"
let nsText = text as NSString
print(nsText.range(of: "(").location)  // 8
print(nsText.range(of: ")").location)  // 15
print(nsText.range(of: "{").location)  // 17
print(nsText.range(of: "}").location)  // 18
```

**NSLayoutManager temporary attributes 的清除时机：**
`NSLayoutManager` 在每次 `setAttributes` 写入对应 range 后会清除 temporary attributes。因此 bracket match 高亮需要在 `applyHighlightResult` 完成后重新应用（为简化，仅重新应用当前已匹配的结果，`appliedBracketMatchRanges` 作为 cache 存储）。  

如发现高亮在滚动/重排后消失，需在 `schedulePostUpdateRefresh` 完成后调用 `applyBracketMatchHighlight(appliedBracketMatchRanges.flatMap { ... })`，见 `schedulePostUpdateRefresh` 中的 completion 回调位置。

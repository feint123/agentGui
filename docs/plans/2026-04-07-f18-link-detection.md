# Feature 18: URL 链接检测（Link Detection）实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 自动识别代码注释/字符串里的 URL，显示下划线，⌘+Click 在默认浏览器打开，与 VSCode / Zed link detection 行为对齐。

**Architecture:** 纯视口局部实现，不通过父视图装饰管线。`CodeEditorLinkDetector` 同步扫描可见文本（`NSDataDetector`），结果存入 `CodeEditorPlatformTextView.currentViewportLinkSpans`；高亮管线完成后通过 `NSLayoutManager.addTemporaryAttributes` 渲染下划线；`mouseDown` 在 ⌘+Click 时优先命中链接范围打开 URL。

**Tech Stack:** Swift 6.0+, AppKit, `NSDataDetector`, `NSLayoutManager.addTemporaryAttributes`, `NSWorkspace`

---

## 参考调研

### VSCode 链接检测（`src/vs/editor/contrib/links/`）

VSCode 的 link provider（`DefaultLinkProvider`）走异步 model decoration 管线：

- **触发时机**：Model 版本变化或 viewport scroll（防抖 250ms）
- **实现**：在 web worker 线程把 model text 切片，每行用正则 `LinkDetector.linkify` 扫描（匹配 `https?://`、`file://`、mailto 等模式）
- **渲染**：把扫描结果注册到 `IModelDecorationOptions.inlineClassName: 'detected-link'`，CSS 给 `detected-link` class 设 underline  
- **交互**：监听 `mousedown` 事件，检测 `ctrlKey`（Windows/Linux）或 `metaKey`（macOS），命中 decoration range 则 `openerService.open(url)`
- **光标**：`EditorMouseEventFactory` 在 hover 时检测是否 ctrl/meta pressed + link range，若是则改 cursor 为 `pointer`

关键点：VSCode 把这个视为"presentation-only" decoration，不修改 text model 本身。

### Zed 链接检测（`crates/editor/src/link_go_to_definition.rs` + `crates/ui/src/tooltip.rs`）

Zed 走更轻量的路径：

- **触发**：在 `Editor::mouse_moved` 里（即 hover 时，不在 paint 路径上），检查光标下字符是否是 URL 的一部分（使用 `linkify` crate 实现的 URI 状态机）
- **时机差异**：Zed 的链接高亮是 **hover-driven**，不是 viewport-change driven；只在鼠标移动时扫描光标附近的 token
- **渲染**：通过 GPUI 的 `Highlight::underline` 在鼠标悬停的 URL 上即时绘制下划线  
- **交互**：`cmd_down` 时在当前 hover URL 上调用平台 `open_url`，并传入 URL 字符串；若检测到 URL 则优先 open URL，否则走 go-to-definition

**Zed 与 VSCode 的核心差异**：Zed 不预扫描整个 viewport，而是在 hover 时按需检测；VSCode 会把 viewport 内所有 link 都标记好等待点击。

### agentGui 设计选择

agentGui 采用**类 VSCode 的 viewport-driven 预扫描**，理由：

1. `NSDataDetector` 的 `NSTextCheckingResult.CheckingType.link` 支持主流 URL 格式（http/https/file/mailto），字符集覆盖比自写正则更全且鲁棒
2. 预扫描一次后存入 `currentViewportLinkSpans`，`mouseDown` 命中检测只需 O(n) 遍历，不需要每次点击都运行 `NSDataDetector`  
3. Viewport-driven 与现有 `applyHighlightResult` 触发点天然对齐，无需新的调度链路

---

## 受影响文件一览

| 动作 | 文件路径 |
|------|---------|
| 新增 | `agentGui/Services/Editor/CodeEditorLinkDetector.swift` |
| 新增 | `agentGuiTests/CodeEditorLinkDetectionTests.swift` |
| 修改 | `agentGui/Models/CodeEditorDecorationModels.swift`（新增 `.link(URL)` kind） |
| 修改 | `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（`CodeEditorPlatformTextView` 存储、mouseMoved cursor、mouseDown ⌘+Click 分支、`applyLinkDecorations`；`Coordinator.applyHighlightResult` 触发링크探测） |

---

## Tasks

---

### Task 1：扩展 `CodeEditorDecorationKind` 支持 `.link(URL)`

**Files:**
- Modify: `agentGui/Models/CodeEditorDecorationModels.swift`

**概述：**  
`CodeEditorDecorationKind` 目前是 `Equatable & Sendable` enum，四个 case。新增 `.link(url: URL)` case。`URL` 是 `Sendable`，`Equatable` 需要手写。

**Step 1: 阅读现有 enum**

阅读 `CodeEditorDecorationModels.swift` 顶部，确认 `CodeEditorDecorationKind` 的四个现有 case 和 `Equatable` 的 auto-synthesis 或手写情况（目前自动合成即可，因为 URL 不自动合成）。

**Step 2: 添加 `.link` case**

在 `CodeEditorDecorationKind` 中追加：

```swift
case link(url: URL)
```

因为 `URL` 不被 `Equatable` 自动合成（属于 struct，其实可以自动合成，但 enum 有关联值时 Swift 会自动合成 `Equatable` 只要所有 associated value 都 `Equatable`），需要验证编译是否无误。`URL` 符合 `Equatable` 和 `Hashable`，所以自动合成可行。

同时在 `kindIdentifier` 辅助静态方法中（用于生成 `DecorationSpan.id`）添加匹配分支：

```swift
case let .link(url):
    return "link-\(url.absoluteString)"
```

**Step 3: 在 `CodeEditorHighlightApplicator.decorationAttributes` 中添加渲染逻辑**

在 `decorationAttributes(for:)` switch 新增：

```swift
case let .link(url: _):
    return [
        .underlineStyle: NSUnderlineStyle.single.rawValue,
        .underlineColor: NSColor.linkColor,
        .foregroundColor: NSColor.linkColor
    ]
```

> 注意：`.link` 装饰由 `NSLayoutManager.addTemporaryAttributes` 应用（Task 4），**不**走 `NSTextStorage`，所以这个 `decorationAttributes` 分支目前保留作备用/文档，实际渲染在 Task 4 中通过 `temporaryAttributes` 实现。  
> 但仍需保持 switch exhaustive，否则编译报错。

**Step 4: 编译验证**

确认：
- 无 exhaustive switch 警告
- `CodeEditorDecorationKind` 的 existing case 无改变

---

### Task 2：创建 `CodeEditorLinkDetector`

**Files:**
- Create: `agentGui/Services/Editor/CodeEditorLinkDetector.swift`

**Step 1: 写失败测试**

在 `agentGuiTests/CodeEditorLinkDetectionTests.swift` 先写（Task 3 中创建文件，这里只规划测试意图）：

```swift
let spans = CodeEditorLinkDetector.detect(in: "// see https://example.com for info", utf16Range: NSRange(location: 0, length: 36))
#expect(spans.count == 1)
#expect(spans.first?.url.absoluteString == "https://example.com")
```

**Step 2: 创建文件骨架**

```swift
import Foundation

/// 纯函数命名空间：在给定 utf16 文本片段中检测所有 URL。
/// 使用 NSDataDetector（Foundation 内置），不依赖外部正则，覆盖
/// http/https/ftp/file/mailto 等主流 scheme。
/// 
/// 注意：
/// - 调用是同步的，调用方需确保在非主线程或运算量可控的场景下使用。
/// - 参考 VSCode DefaultLinkProvider 和 Zed linkify 均采用 deterministic scan，
///   无网络请求/副作用，此处保持相同设计。
enum CodeEditorLinkDetector {
    // 复用单例 Detector，避免每次 viewport 刷新都重新创建
    private static let detector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    struct LinkSpan: Equatable, Sendable {
        let utf16Range: NSRange
        let url: URL
    }

    /// 在 `text` 的 `utf16Range` 子区间中检测所有链接，
    /// 返回相对于整个 `text` 的 utf16 offset 的 `LinkSpan` 数组。
    /// - Parameters:
    ///   - text:       完整文本（NSString-compatible）
    ///   - utf16Range: 要扫描的子区间，通常为 viewport visible range
    /// - Returns:      命中的链接列表，按 location 升序排列
    static func detect(in text: String, utf16Range: NSRange) -> [LinkSpan] {
        guard let detector else { return [] }
        guard utf16Range.length > 0 else { return [] }
        let nsText = text as NSString
        guard utf16Range.location >= 0,
              utf16Range.upperBound <= nsText.length else { return [] }

        var results: [LinkSpan] = []
        detector.enumerateMatches(
            in: text,
            options: [],
            range: utf16Range
        ) { result, _, _ in
            guard let result,
                  let url = result.url else { return }
            results.append(LinkSpan(utf16Range: result.range, url: url))
        }
        return results
    }
}
```

**Step 3: 运行测试（先确保文件创建后 xcodebuild 能编译通过）**

（此步骤在 Task 3 的测试编写 + 运行阶段验证）

**注意 NSDataDetector 线程安全：**  
`NSDataDetector` 继承自 `NSRegularExpression`，Apple 文档说单个实例的 `-enumerateMatches` 不是线程安全的（不可并发调用），但串行使用没问题。由于此处只在 `MainActor`（高亮回调完成后）调用，没有并发风险。

---

### Task 3：编写链接检测单元测试

**Files:**
- Create: `agentGuiTests/CodeEditorLinkDetectionTests.swift`

**Step 1: 创建测试文件**

```swift
import Foundation
import Testing
@testable import agentGui

struct CodeEditorLinkDetectionTests {

    // MARK: - 基础链接检测

    @Test func detectHttpsURL() {
        let text = "// see https://example.com for info"
        let range = NSRange(location: 0, length: (text as NSString).length)
        let spans = CodeEditorLinkDetector.detect(in: text, utf16Range: range)
        #expect(spans.count == 1)
        #expect(spans.first?.url.absoluteString == "https://example.com")
    }

    @Test func detectHttpURL() {
        let text = "visit http://example.org/path?q=1"
        let range = NSRange(location: 0, length: (text as NSString).length)
        let spans = CodeEditorLinkDetector.detect(in: text, utf16Range: range)
        #expect(spans.count == 1)
        #expect(spans.first?.url.host == "example.org")
    }

    @Test func detectMultipleURLsInText() {
        let text = "a: https://foo.com and b: https://bar.org"
        let range = NSRange(location: 0, length: (text as NSString).length)
        let spans = CodeEditorLinkDetector.detect(in: text, utf16Range: range)
        #expect(spans.count == 2)
    }

    @Test func noLinksInPlainText() {
        let text = "let x = 42"
        let range = NSRange(location: 0, length: (text as NSString).length)
        let spans = CodeEditorLinkDetector.detect(in: text, utf16Range: range)
        #expect(spans.isEmpty)
    }

    @Test func emptyRangeReturnsNoSpans() {
        let text = "https://example.com"
        let spans = CodeEditorLinkDetector.detect(in: text, utf16Range: NSRange(location: 0, length: 0))
        #expect(spans.isEmpty)
    }

    @Test func outOfBoundsRangeReturnsNoSpans() {
        let text = "hello"
        let spans = CodeEditorLinkDetector.detect(in: text, utf16Range: NSRange(location: 999, length: 10))
        #expect(spans.isEmpty)
    }

    // MARK: - 子区间扫描（模拟 viewport slice）

    @Test func detectURLInSubrangeOnly() {
        // 文字：前半段有 URL，后半段有 URL；只扫描后半段
        let text = "https://first.com some text https://second.com"
        let nsText = text as NSString
        // 找到 "https://second.com" 的位置
        let secondStart = nsText.range(of: "https://second.com")
        let spans = CodeEditorLinkDetector.detect(in: text, utf16Range: secondStart)
        #expect(spans.count == 1)
        #expect(spans.first?.url.host == "second.com")
    }

    // MARK: - utf16Range 的绝对偏移

    @Test func spanRangeIsRelativeToFullText() {
        let text = "  https://example.com  "
        let range = NSRange(location: 0, length: (text as NSString).length)
        let spans = CodeEditorLinkDetector.detect(in: text, utf16Range: range)
        #expect(spans.count == 1)
        // 偏移应当是相对于整个 text 的 utf16 偏移（location = 2 for "  "）
        #expect(spans.first?.utf16Range.location == 2)
    }

    // MARK: - 特殊格式（NSDataDetector 覆盖范围）

    @Test func detectMailtoURL() {
        let text = "email: someone@example.com for questions"
        let range = NSRange(location: 0, length: (text as NSString).length)
        let spans = CodeEditorLinkDetector.detect(in: text, utf16Range: range)
        // NSDataDetector 会把 email 地址识别为 mailto link 或自定义 scheme
        // 只验证不崩溃，结果可能随平台版本变化
        _ = spans
    }

    @Test func detectURLWithPath() {
        let text = "// Ref: https://developer.apple.com/documentation/appkit/nstextview"
        let range = NSRange(location: 0, length: (text as NSString).length)
        let spans = CodeEditorLinkDetector.detect(in: text, utf16Range: range)
        #expect(spans.count == 1)
        #expect(spans.first?.url.path.contains("nstextview") == true)
    }
}
```

**Step 2: 运行（确认通过）**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f18-link-derived \
  -only-testing:agentGuiTests/CodeEditorLinkDetectionTests \
  CODE_SIGNING_ALLOWED=NO
```

预期：全部 pass。`detectMailtoURL` 是 non-asserting（只验证不崩溃），不会因平台行为差异失败。

---

### Task 4：在 `CodeEditorPlatformTextView` 中存储并渲染链接装饰

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`

涉及 `CodeEditorPlatformTextView` 类（文件底部 `final class CodeEditorPlatformTextView: NSTextView`）。

**Step 1: 添加 `currentViewportLinkSpans` 属性**

在 `CodeEditorPlatformTextView` 类内，`var latestHighlightResult` 声明附近添加：

```swift
/// 当前 viewport 中检测到的链接 span，由 Coordinator 在高亮完成后更新。
var currentViewportLinkSpans: [CodeEditorLinkDetector.LinkSpan] = []
```

**Step 2: 添加 `applyLinkDecorations(spans:)` 方法**

在 `CodeEditorPlatformTextView` 类内新增：

```swift
/// 把传入的链接 span 用 NSLayoutManager.addTemporaryAttributes 渲染为下划线蓝色。
/// 调用前先清除旧链接的 temporary attributes，避免 viewport 外的旧 span 残留。
/// 不修改 NSTextStorage，不影响撤销栈。
func applyLinkDecorations(_ spans: [CodeEditorLinkDetector.LinkSpan]) {
    guard let layoutManager, let textStorage else { return }

    // 1. 清除整个文档的旧链接 temporary attributes
    //    （只清除已知的旧 span 范围，避免影响 bracket match 等其他 temporary attributes）
    for oldSpan in currentViewportLinkSpans {
        let safeRange = clampedRange(oldSpan.utf16Range, length: textStorage.length)
        guard safeRange.length > 0 else { continue }
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: safeRange)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: safeRange)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: safeRange)
    }

    currentViewportLinkSpans = spans

    // 2. 应用新 span 的 temporary attributes
    let attrs: [NSAttributedString.Key: Any] = [
        .underlineStyle: NSUnderlineStyle.single.rawValue,
        .underlineColor: NSColor.linkColor,
        .foregroundColor: NSColor.linkColor
    ]
    for span in spans {
        let safeRange = clampedRange(span.utf16Range, length: textStorage.length)
        guard safeRange.length > 0 else { continue }
        layoutManager.addTemporaryAttributes(attrs, forCharacterRange: safeRange)
    }
}

private func clampedRange(_ range: NSRange, length: Int) -> NSRange {
    let location = max(0, min(range.location, length))
    let safeLen = max(0, min(range.length, length - location))
    return NSRange(location: location, length: safeLen)
}
```

> **注意 `clampedRange` 命名冲突：** 检查文件中是否已有同名私有辅助方法（Coordinator 有一个同名的 private free function），如有冲突，命名为 `clampedLinkRange` 即可。

**Step 3: 验证编译**  
此时 `applyLinkDecorations` 已可调用，但还没有调用方——Next task 接入。

---

### Task 5：在 Coordinator 的 `applyHighlightResult` 后触发链接检测

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（`Coordinator` section）

**目标调用位置：**  
`Coordinator.applyHighlightResult(_:to:)` 末尾（bracket pair colorization 之后）。

**Step 1: 找到函数末尾**

函数位于 `private func applyHighlightResult(_ result: CodeEditorHighlightResult, to textView: CodeEditorPlatformTextView)`。末尾在 bracket pair colorization 的 `if parent.isBracketPairColorizationEnabled` block 之后。

**Step 2: 追加链接检测调用**

在 `applyHighlightResult` 末尾添加：

```swift
// 链接检测：扫描当前 viewport 文本中的 URL，应用下划线渲染
applyViewportLinkDetection(result: result, to: textView)
```

**Step 3: 在 Coordinator 中实现 `applyViewportLinkDetection`**

在 `Coordinator` extension 中添加私有辅助方法：

```swift
private func applyViewportLinkDetection(
    result: CodeEditorHighlightResult,
    to textView: CodeEditorPlatformTextView
) {
    // 只扫描实际高亮结果覆盖的 utf16 范围
    let lineRange = result.lineRange
    let document = parent.document
    let startOffset = document.lineIndex.lineStartOffset(forLine: lineRange.lowerBound)
    let endOffset: Int
    if lineRange.upperBound < document.lineCount {
        endOffset = max(startOffset,
                        document.lineIndex.lineStartOffset(forLine: lineRange.upperBound + 1) - 1)
    } else {
        endOffset = document.text.utf16.count
    }
    let scanRange = NSRange(location: startOffset, length: max(0, endOffset - startOffset))
    let spans = CodeEditorLinkDetector.detect(in: document.text, utf16Range: scanRange)
    textView.applyLinkDecorations(spans)
}
```

**Step 4: 验证** — `applyHighlightResult` 结束后链接下划线在编辑器中可见（将在 Task 7 的 smoke test 验证）。

---

### Task 6：⌘+Click 优先命中链接

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（`CodeEditorPlatformTextView.mouseDown`）

**当前逻辑：**

```swift
override func mouseDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let localPt = convert(event.locationInWindow, from: nil)

    // ⌘+Click → Go to Definition
    if modifiers.contains(.command), !modifiers.contains(.option),
       let position = semanticPosition(at: localPt) {
        emitSemanticIntent(.requestDefinition(position))
        return
    }
    // Option+Click → 多光标 toggle ...
    super.mouseDown(with: event)
}
```

**目标逻辑：** ⌘+Click 时，先检查是否命中链接 span；若命中，打开 URL，不走 go-to-definition；否则仍发 `requestDefinition`。

**Step 1: 添加 hit-test 辅助方法**

在 `CodeEditorPlatformTextView` 中添加：

```swift
/// 返回点击点下方的链接 URL（若有）。
/// - Parameter point: text view 本地坐标系
private func linkURL(at point: NSPoint) -> URL? {
    guard let layoutManager, let textContainer else { return nil }
    let containerPt = NSPoint(
        x: point.x - textContainerInset.width,
        y: point.y - textContainerInset.height
    )
    let glyphIndex = layoutManager.glyphIndex(
        for: containerPt,
        in: textContainer,
        fractionOfDistanceThroughGlyph: nil
    )
    let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
    return currentViewportLinkSpans.first { span in
        span.utf16Range.contains(charIndex) ||
        charIndex == span.utf16Range.location  // 边界也算命中
    }?.url
}
```

**Step 2: 修改 `mouseDown` 中 ⌘+Click 分支**

将原来：

```swift
if modifiers.contains(.command), !modifiers.contains(.option),
   let position = semanticPosition(at: localPt) {
    emitSemanticIntent(.requestDefinition(position))
    return
}
```

改为：

```swift
if modifiers.contains(.command), !modifiers.contains(.option) {
    // ⌘+Click：先检查是否命中链接，否则走 Go to Definition
    if let url = linkURL(at: localPt) {
        NSWorkspace.shared.open(url)
        return
    }
    if let position = semanticPosition(at: localPt) {
        emitSemanticIntent(.requestDefinition(position))
        return
    }
}
```

**Step 3: 验证编译通过**

---

### Task 7：mouseMoved 时链接光标指针变化（cmd held）

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（`CodeEditorPlatformTextView.mouseMoved` + `resetCursorRects`）

**目标行为：** 按住 ⌘ 时，鼠标移动到链接上方，光标变为 `pointingHand`；移开或松开 ⌘ 则恢复 `IBeam`。这与 VSCode 的 "hover on link changes cursor" 行为一致。

**Step 1: 覆盖 `resetCursorRects` 并记录链接命中状态**

给 `CodeEditorPlatformTextView` 添加属性：

```swift
private var isCursorOverLink = false
```

**Step 2: 修改 `mouseMoved`**

在现有的 `mouseMoved` 函数里，  semantic hover 之前/之后，追加光标状态更新：

```swift
override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)

    let localPt = convert(event.locationInWindow, from: nil)
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let cmdHeld = modifiers.contains(.command)

    // 链接光标：cmd 按住时悬停在链接上方显示 pointingHand
    let overLink = cmdHeld && linkURL(at: localPt) != nil
    if overLink != isCursorOverLink {
        isCursorOverLink = overLink
        // 触发 resetCursorRects 以刷新光标形状
        window?.invalidateCursorRects(for: self)
    }

    guard let position = semanticPosition(at: localPt) else { return }
    emitSemanticIntent(.requestHover(position))
}
```

**Step 3: 覆盖 `resetCursorRects`**

```swift
override func resetCursorRects() {
    super.resetCursorRects()
    if isCursorOverLink {
        addCursorRect(visibleRect, cursor: .pointingHand)
    }
}
```

同时在 `mouseExited` 中重置 `isCursorOverLink`：

```swift
override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    emitSemanticIntent(.cancelHover)
    if isCursorOverLink {
        isCursorOverLink = false
        window?.invalidateCursorRects(for: self)
    }
}
```

**Step 4: 验证编译**

---

### Task 8：集成测试——`CodeEditorPlatformTextView` 链接高亮不崩溃

**Files:**
- Modify: `agentGuiTests/CodeEditorLinkDetectionTests.swift`（追加 integration block）

**Step 1: 追加测试 block**

```swift
// MARK: - Integration: PlatformTextView link decoration

@MainActor
@Test func applyLinkDecorationsDoesNotCrashWithoutWindow() {
    let textView = CodeEditorPlatformTextView()
    textView.string = "// see https://example.com"
    let spans = [
        CodeEditorLinkDetector.LinkSpan(
            utf16Range: NSRange(location: 7, length: 19),
            url: URL(string: "https://example.com")!
        )
    ]
    // 无 window/layoutManager 时应不崩溃（graceful skip）
    textView.applyLinkDecorations(spans)
    #expect(textView.currentViewportLinkSpans.count == 1)
}

@MainActor
@Test func applyEmptySpansClearsPreviousLinks() {
    let textView = CodeEditorPlatformTextView()
    textView.string = "https://example.com"
    let span = CodeEditorLinkDetector.LinkSpan(
        utf16Range: NSRange(location: 0, length: 19),
        url: URL(string: "https://example.com")!
    )
    textView.applyLinkDecorations([span])
    #expect(textView.currentViewportLinkSpans.count == 1)
    textView.applyLinkDecorations([])
    #expect(textView.currentViewportLinkSpans.isEmpty)
}

@MainActor
@Test func outOfBoundsSpanIsSkippedSafely() {
    let textView = CodeEditorPlatformTextView()
    textView.string = "hi"  // length = 2
    let badSpan = CodeEditorLinkDetector.LinkSpan(
        utf16Range: NSRange(location: 999, length: 10),
        url: URL(string: "https://example.com")!
    )
    textView.applyLinkDecorations([badSpan])
    // Should not crash
}
```

**Step 2: 运行测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f18-link-derived \
  -only-testing:agentGuiTests/CodeEditorLinkDetectionTests \
  CODE_SIGNING_ALLOWED=NO
```

预期：全部 pass。

---

### Task 9：加入 `.tasks.json` 测试任务（可选）

**Files:**
- Modify: `.vscode/tasks.json`（若已有）or `agentGui.xcodeproj/xcshareddata/`

在 `tasks.json` 中添加：

```json
{
    "label": "F18 Link Detection Tests",
    "type": "shell",
    "command": "xcodebuild",
    "args": [
        "test",
        "-project", "agentGui.xcodeproj",
        "-scheme", "agentGui",
        "-destination", "platform=macOS",
        "-parallel-testing-enabled", "NO",
        "-derivedDataPath", "/tmp/agentGui-f18-link-derived",
        "-only-testing:agentGuiTests/CodeEditorLinkDetectionTests",
        "CODE_SIGNING_ALLOWED=NO"
    ],
    "group": "test"
}
```

---

## 精华约束（来自设计文档 §6）

| 约束 | F18 适用细节 |
|------|------------|
| **IME 安全** | `applyViewportLinkDetection` 在 `applyHighlightResult` 内调用，该函数开头已有 `guard !textView.hasMarkedText()` 检查，无需额外处理 |
| **NSTextStorage 修改** | 不修改 NSTextStorage，只用 `NSLayoutManager.addTemporaryAttributes`；不影响撤销栈 |
| **代际取消** | 无需：链接检测是同步操作，在高亮回调主线程执行，无异步代际问题 |
| **Viewport-First** | `applyViewportLinkDetection` 只扫描 `result.lineRange`（=高亮管线的 retainedLineRange），视口外代码不扫描 |
| **Coordinator 隔离** | `applyViewportLinkDetection` 在 Coordinator 内，`CodeEditorView` 不需要任何新 binding/参数 |
| **测试先行** | Task 3 写单元测试，Task 8 写集成测试，先于渲染/交互代码 |

---

## 设计限制与未作决策

1. **不做 URL 安全确认弹窗**：macOS 原生沙盒 + `NSWorkspace.open` 会走系统安全层，行为等同浏览器地址栏点击，不额外弹 "这将打开外部链接" 确认。与设计文档对齐。

2. **不检测 `file://` 路径**：`NSDataDetector` 会匹配 file:// URL，但考虑到 agentGui 的使用场景（代码注释中的 http/https 链接），首轮不对 file:// 做特殊处理；`NSWorkspace.open(url)` 对 file:// 也能正确打开 Finder。

3. **链接颜色跟随系统 linkColor**：`NSColor.linkColor` 在 dark/light mode 自适应，不需要额外主题处理。

4. **TemporaryAttributes 与 bracket match highlight 的共存**：两者均使用 `addTemporaryAttributes`，互不干扰（作用的字符范围不重叠——链接在URL所在位置，括号高亮在括号位置）。

5. **后续升级方向（不在 F18 范围内）**：
   - 鼠标悬停在 URL 上方时显示 tooltip 预览（参考 Zed `link_tooltip`）
   - `file://` 相对路径解析（相对于 workspace root）
   - 自定义 link scheme（如 `rdar://` 内部链接）

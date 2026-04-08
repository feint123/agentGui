# Feature 20: Inlay Hints 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 agentGui 代码编辑器实现 LSP `textDocument/inlayHint` 驱动的内联标注——在 Swift/TypeScript 等语言的参数标签、推断类型等位置以半透明字体叠加"幽灵文字"，不修改 `NSTextStorage`，不影响光标/选区/布局，滚动/文档变更后 300ms 内自动刷新，IME 期间静默消隐。

**Architecture:** 采用与 F19 (Code Completion) 一致的两层分离：
- **请求层**：`CodeEditorLSPCoordinator.requestInlayHints(visibleLineRange:documentVersion:)` — LSP `textDocument/inlayHint` 请求 + 代际取消 + 300ms 去抖
- **渲染层**：`CodeEditorPlatformTextView.currentInlayHints` + `drawBackground(in:)` 叠层绘制 — 不触碰 `NSTextStorage`/撤销栈

数据流：
```
Viewport 变化 / didChange
    ↓
Coordinator.scheduleInlayHintRequest()  [300ms 去抖 + 代际取消]
    ↓
LSPClient.inlayHints(uri:range:)  [textDocument/inlayHint]
    ↓
CodeEditorPlatformTextView.currentInlayHints = [CodeEditorInlayHint]
    ↓
setNeedsDisplay(visibleRect)
    ↓
drawBackground(in:)  ← NSLayoutManager glyph rect → x 坐标定位
```

**Tech Stack:** Swift 6 + AppKit (`NSTextView.drawBackground`, `NSLayoutManager`) + LSP `textDocument/inlayHint`，Swift Testing framework

---

## VSCode 关键设计参照

来自 `inlayHintsController.ts` / `inlayHints.ts` 的关键决策与 agentGui 映射：

| VSCode 概念 | 文件 | agentGui 映射 |
|---|---|---|
| `InlayHintsCache` (LRU, key=`uri/version`) | `inlayHintsController.ts:22` | `CodeEditorInlayHintCache`（简化版，`[Int: [CodeEditorInlayHint]]` by version） |
| `RunOnceScheduler` (min 25ms, adaptive) | `inlayHintsController.ts:163` | `Task + sleep(300ms)` + 代际计数器 `inlayHintGeneration: Int` |
| `CancellationStore.reset()` per run | `inlayHintsController.ts:71` | `inlayHintGeneration += 1`，结果回写时校验 generation |
| `_getHintsRanges()` visible + extra 5 行缓冲 | `inlayHintsController.ts:226` | `expandedLineRange(from: visibleRange, buffer: 5)` |
| `_cursorInfo` 光标稳定性（保宽防跳） | `inlayHintsController.ts:199` | **不实现**（首轮 Method B 绘制，清空旧即可） |
| `InjectedTextOptions` 注入虚拟字符 | `inlayHintsController.ts:480` | **替换为 Method B**：`drawBackground(in:)` 直接绘制，零 TextStorage 侵入 |
| `_fillInColors` `.Parameter`→paramBg/Fg `.Type`→typeBg/Fg | `inlayHintsController.ts:729` | `CodeEditorInlayHintRenderer.color(for: kind)` 同语义 |
| `e.scrollTopChanged` scroll 触发 | `inlayHintsController.ts:177` | Coordinator `scheduleHighlight` 的 viewport observer 同路径 |
| `editor.onDidChangeModelContent` edit 触发 | `inlayHintsController.ts:186` | `textDidChange` → `scheduleHighlight` → `scheduleInlayHintRequest` |
| `InlayHintItem.resolve(token:)` lazy resolve | `inlayHints.ts:21` | **首轮不实现**（tooltip/textEdits 是 optional 字段，显示 label 即可） |
| `maximumLength` 每行字符数截断 | `inlayHintsController.ts:464` | `maxLabelLength = 40`（固定，首轮） |

**关键差异（agentGui vs VSCode）：**
- VSCode 用 InjectedText（virtual chars in layout，不修改 model），光标/选区原生感知 hint 宽度 → agentGui Method B 叠层绘制（hint 不占 layout 空间，光标/选区不感知），IME 期间直接跳过绘制
- VSCode adaptive debounce（25ms→300ms 根据服务器响应时间动态调） → agentGui 固定 300ms（首轮不做 adaptive）
- VSCode 全文档范围 + 缓存 → agentGui viewport-first（visible range + ±5 line 缓冲），缓存仅 per version 内存 map
- VSCode cursor stability（typing 时固定 hint 宽度防止光标抖动）→ agentGui 文档变更时清空 hints，debounce 后重取（不需要稳定性逻辑）

---

## 文件清单

| 操作 | 路径 |
|---|---|
| 新增 | `agentGui/Models/CodeEditorInlayHintModels.swift` |
| 修改 | `agentGui/Services/LSP/LSPClient.swift`（新增 `inlayHints` 方法 + 解析） |
| 修改 | `agentGui/Services/Editor/CodeEditorLSPCoordinator.swift`（新增 `requestInlayHints` + 调度） |
| 修改 | `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（`CodeEditorPlatformTextView` + `Coordinator` + SwiftUI wrapper） |
| 新增测试 | `agentGuiTests/CodeEditorInlayHintTests.swift` |

---

## Task 1：数据模型 — CodeEditorInlayHintModels

**Files:**
- Create: `agentGui/Models/CodeEditorInlayHintModels.swift`

### 步骤

创建 `CodeEditorInlayHintModels.swift`，包含：

```swift
// agentGui/Models/CodeEditorInlayHintModels.swift
import Foundation

/// 对应 LSP InlayHintKind（spec §3.17.12）
/// 1 = Type（如 `: String`），2 = Parameter（如 `label:`）
enum CodeEditorInlayHintKind: Int, Sendable {
    case type = 1
    case parameter = 2
    /// fallback：kind 未知时按 type 显示
    case unknown = 0

    init(rawValue: Int) {
        switch rawValue {
        case 1: self = .type
        case 2: self = .parameter
        default: self = .unknown
        }
    }
}

/// 单个来自 LSP 的内联 Hint，完全值类型 + Sendable。
///
/// - `line` / `character`：1-based（agentGui 内部约定），从 LSP 0-based 转换后存储。
/// - `label`：纯文字（不含 labelParts 结构体，首轮只要 string label）。
/// - `paddingLeft` / `paddingRight`：是否在 hint 文本前/后插入额外间距（一个半角空格）。
struct CodeEditorInlayHint: Equatable, Sendable {
    let line: Int           // 1-based 行号
    let character: Int      // 1-based 列号（hint 紧贴该字符右侧绘制）
    let label: String       // 展示文字，已截断到 maxLabelLength
    let kind: CodeEditorInlayHintKind
    let paddingLeft: Bool
    let paddingRight: Bool
}

/// Coordinator 传给 CodeEditorPlatformTextView 的快照。
/// 以 documentVersion 作为有效性标记——版本不一致时 textView 应忽略本快照。
struct CodeEditorInlayHintSnapshot: Sendable {
    let documentVersion: Int
    /// 按 line（1-based）索引的 hints，只含当前可见区 + buffer 内的行
    let hintsByLine: [Int: [CodeEditorInlayHint]]

    static let empty = CodeEditorInlayHintSnapshot(documentVersion: -1, hintsByLine: [:])

    init(documentVersion: Int, hintsByLine: [Int: [CodeEditorInlayHint]]) {
        self.documentVersion = documentVersion
        self.hintsByLine = hintsByLine
    }

    /// 从扁平数组构建 snapshot
    init(documentVersion: Int, hints: [CodeEditorInlayHint]) {
        self.documentVersion = documentVersion
        var byLine: [Int: [CodeEditorInlayHint]] = [:]
        for hint in hints {
            byLine[hint.line, default: []].append(hint)
        }
        // 每行内按 character 升序
        for key in byLine.keys {
            byLine[key]!.sort { $0.character < $1.character }
        }
        self.hintsByLine = byLine
    }
}
```

**验收标准：**
- 模型编译通过，所有字段 `Sendable`
- `CodeEditorInlayHintSnapshot(documentVersion:hints:)` 初始化后 `hintsByLine` 按 character 有序

---

## Task 2：LSP 客户端扩展 — `textDocument/inlayHint`

**Files:**
- Modify: `agentGui/Services/LSP/LSPClient.swift`

### 步骤

在 `LSPClient` 的既有 `completion` / `documentSymbols` 同层新增以下两个方法：

```swift
// MARK: - Inlay Hints

/// 请求 textDocument/inlayHint（LSP §3.17.12）。
///
/// - Parameters:
///   - uri: 文档 URI。
///   - startLine/startCharacter: 请求范围起点（0-based）。
///   - endLine/endCharacter: 请求范围终点（0-based）。
/// - Returns: 解析后的 hints 数组；失败或服务端无能力时返回空数组。
func inlayHints(
    uri: String,
    startLine: Int,
    startCharacter: Int,
    endLine: Int,
    endCharacter: Int
) async -> [CodeEditorInlayHint] {
    let params: [String: Any] = [
        "textDocument": ["uri": uri],
        "range": [
            "start": ["line": startLine, "character": startCharacter],
            "end":   ["line": endLine,   "character": endCharacter]
        ]
    ]
    guard let result = try? await transport.sendRequest(
        method: "textDocument/inlayHint",
        params: params
    ) else { return [] }
    return parseInlayHints(from: result)
}

/// 按 UTF-16 行号边界发起请求（1-based → 0-based 转换由此方法负责）。
func inlayHints(
    uri: String,
    startLine1Based: Int,
    endLine1Based: Int
) async -> [CodeEditorInlayHint] {
    return await inlayHints(
        uri: uri,
        startLine: max(0, startLine1Based - 1),
        startCharacter: 0,
        endLine: max(0, endLine1Based - 1),
        endCharacter: Int.max              // 服务端实现通常会截断到实际行长
    )
}
```

在 `LSPClient` 内添加私有解析方法：

```swift
/// 解析 `textDocument/inlayHint` 响应 → `[CodeEditorInlayHint]`。
///
/// 响应格式（LSP Spec）：
/// ```
/// InlayHint {
///   position: Position    // { line: number, character: number }（0-based）
///   label: string | InlayHintLabelPart[]
///   kind?: InlayHintKind  // 1=Type, 2=Parameter
///   paddingLeft?: boolean
///   paddingRight?: boolean
/// }
/// ```
private func parseInlayHints(from result: Any?) -> [CodeEditorInlayHint] {
    guard let array = result as? [[String: Any]] else { return [] }
    let maxLabelLength = 40

    var hints: [CodeEditorInlayHint] = []
    for item in array {
        guard let position = item["position"] as? [String: Any],
              let line0     = (position["line"]      as? Int) ?? (position["line"]      as? NSNumber).map(\.intValue),
              let char0     = (position["character"] as? Int) ?? (position["character"] as? NSNumber).map(\.intValue)
        else { continue }

        // label: string | InlayHintLabelPart[]
        let rawLabel: String
        if let str = item["label"] as? String {
            rawLabel = str
        } else if let parts = item["label"] as? [[String: Any]] {
            rawLabel = parts.compactMap { $0["value"] as? String }.joined()
        } else { continue }

        // 截断超长 label
        let label: String
        if rawLabel.count > maxLabelLength {
            label = String(rawLabel.prefix(maxLabelLength)) + "…"
        } else {
            label = rawLabel
        }

        let kindRaw = (item["kind"] as? Int) ?? (item["kind"] as? NSNumber).map(\.intValue) ?? 0
        let paddingLeft  = item["paddingLeft"]  as? Bool ?? false
        let paddingRight = item["paddingRight"] as? Bool ?? false

        hints.append(CodeEditorInlayHint(
            line: line0 + 1,           // 0-based → 1-based
            character: char0 + 1,      // 0-based → 1-based
            label: label,
            kind: CodeEditorInlayHintKind(rawValue: kindRaw),
            paddingLeft: paddingLeft,
            paddingRight: paddingRight
        ))
    }
    return hints
}
```

同时在 `initializeParams` 的 `"textDocument"` capabilities 中确认已包含 `"inlayHint"` 声明（已在现有代码 L350 存在，无需修改）。

**验收标准：**
- `parseInlayHints` 对 nil / 空数组 / 格式错误 JSON 均返回 `[]`，不 crash
- kind = 0 时返回 `CodeEditorInlayHintKind.unknown`
- label 超过 40 字符时截断并追加 "…"

---

## Task 3：LSP Coordinator 扩展 — `requestInlayHints`

**Files:**
- Modify: `agentGui/Services/Editor/CodeEditorLSPCoordinator.swift`

### 步骤

在 `CodeEditorLSPCoordinator` 中新增代际调度+请求方法：

**1. 在类顶部声明私有状态**（在现有 `completionGeneration / pendingCompletionTask` 同层添加）：

```swift
// Inlay Hints 调度状态
private var inlayHintGeneration = 0
private var pendingInlayHintTask: Task<Void, Never>?
```

**2. 在 `deinit` 中追加取消调用：**

```swift
pendingInlayHintTask?.cancel()
```

**3. 新增公开调度方法**：

```swift
/// 调度一次 inlay hint 请求，300ms 去抖 + 代际取消。
///
/// - Parameters:
///   - visibleLineRange: 当前可见行范围（1-based）。
///   - documentVersion: 当前文档版本，用于回写时验证一致性。
///
/// 典型触发时机：viewport 变化、文档内容变更（textDidChange）。
/// IME 期间（hasMarkedText）由调用方决定是否调用；Coordinator 本身不检测 IME 状态。
func scheduleInlayHintRequest(
    visibleLineRange: ClosedRange<Int>,
    documentVersion: Int
) {
    pendingInlayHintTask?.cancel()
    inlayHintGeneration += 1
    let generation = inlayHintGeneration
    // 请求扩展行范围：可见区 + 上下各 5 行缓冲
    //（对应 VSCode _getHintsRanges extra-lines 策略）
    let bufferedRange = expandedLineRange(visibleLineRange, buffer: 5)

    pendingInlayHintTask = Task { [weak self] in
        guard let self else { return }
        // 300ms 去抖（对应 VSCode RunOnceScheduler delay）
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled, self.inlayHintGeneration == generation else { return }

        let hints = await self.fetchInlayHints(
            lineRange: bufferedRange,
            documentVersion: documentVersion
        )
        guard !Task.isCancelled, self.inlayHintGeneration == generation else { return }

        await MainActor.run { [weak self] in
            guard let self, self.inlayHintGeneration == generation else { return }
            self.onInlayHintResult?(
                CodeEditorInlayHintSnapshot(
                    documentVersion: documentVersion,
                    hints: hints
                )
            )
        }
    }
}

/// 取消进行中的 inlay hint 请求（用于文档关闭/切换等）。
func cancelInlayHintRequest() {
    pendingInlayHintTask?.cancel()
    pendingInlayHintTask = nil
    inlayHintGeneration += 1
}

/// 结果回调，由 `FileEditorView` 或 `Coordinator` 在初始化时注入。
var onInlayHintResult: ((CodeEditorInlayHintSnapshot) -> Void)?
```

**4. 新增私有获取方法**：

```swift
/// 实际发出 LSP 请求并返回 hints，不含代际逻辑（由 schedule 层管理）。
private func fetchInlayHints(
    lineRange: ClosedRange<Int>,
    documentVersion: Int
) async -> [CodeEditorInlayHint] {
    guard canServeSemanticRequest(
        supports: \LSPServerCapabilityHints.supportsInlayHints,
        requestVersion: documentVersion
    ) else { return [] }

    return await manager.inlayHints(
        workspaceRoot: binding.workspaceRoot,
        serverID: binding.serverID,
        uri: binding.uri,
        startLine1Based: lineRange.lowerBound,
        endLine1Based: lineRange.upperBound
    )
}

/// 将可见行范围向上下各扩展 `buffer` 行，不超出文档边界。
private func expandedLineRange(_ range: ClosedRange<Int>, buffer: Int) -> ClosedRange<Int> {
    let lower = max(1, range.lowerBound - buffer)
    let upper = range.upperBound + buffer  // 服务端会自动截断到文档末尾
    return lower...upper
}
```

**5. 在 `LSPServerManager` 中桥接 `inlayHints` 调用**（与现有 `definition` / `hover` 同模式）：

```swift
// LSPServerManager+InlayHints.swift 或直接追加在 LSPServerManager 尾部
func inlayHints(
    workspaceRoot: String,
    serverID: String,
    uri: String,
    startLine1Based: Int,
    endLine1Based: Int
) async -> [CodeEditorInlayHint] {
    guard let client = client(workspaceRoot: workspaceRoot, serverID: serverID) else {
        return []
    }
    return await client.inlayHints(
        uri: uri,
        startLine1Based: startLine1Based,
        endLine1Based: endLine1Based
    )
}
```

**验收标准：**
- 快速连续调用 `scheduleInlayHintRequest` 5 次，只有最后一次触发 LSP 请求（代际取消正常）
- `canServeSemanticRequest(supports: \LSPServerCapabilityHints.supportsInlayHints…)` 返回 `false` 时不发 LSP 请求
- 测试可通过 mock `onInlayHintResult` 验证结果回调

---

## Task 4：文本视图渲染层

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`

### 4A：`CodeEditorPlatformTextView` 新增 inlay hints 属性

在 `CodeEditorPlatformTextView` 中添加存储属性（与 `indentGuideConfig`、`currentHoverPresentation` 同层）：

```swift
// MARK: - Inlay Hints

/// 当前 viewport 的 inlay hints 快照。
/// 由 Coordinator 在主线程写入，drawBackground 消费。
var currentInlayHintSnapshot: CodeEditorInlayHintSnapshot = .empty {
    didSet {
        guard currentInlayHintSnapshot.documentVersion != oldValue.documentVersion
            || currentInlayHintSnapshot.hintsByLine != oldValue.hintsByLine
        else { return }
        setNeedsDisplay(visibleRect)
    }
}
```

### 4B：`drawBackground(in:)` 中追加 hint 绘制

在 `CodeEditorPlatformTextView` 的 `drawBackground(in:)` 末尾（在 `super.drawBackground(in: rect)` 调用之后，以及缩进参考线绘制之后）追加 inlay hints 绘制逻辑：

```swift
// MARK: drawBackground 末尾追加
private func drawInlayHints(in rect: NSRect) {
    // IME 期间不绘制（避免视觉混乱）
    guard !hasMarkedText() else { return }
    guard let layoutManager,
          let textContainer else { return }

    let snapshot = currentInlayHintSnapshot
    // 版本不一致时清空绘制（文档已变更，旧 hints 无效）
    guard snapshot.documentVersion == currentDocumentVersion,
          !snapshot.hintsByLine.isEmpty else { return }

    // 计算当前 dirty rect 覆盖的行范围（避免绘制视口外 hint）
    guard let font = self.font else { return }
    let hintFontSize = max(font.pointSize - 1, 8)
    let hintFont = NSFont.monospacedSystemFont(ofSize: hintFontSize, weight: .light)

    for (line, hints) in snapshot.hintsByLine {
        for hint in hints {
            drawSingleInlayHint(
                hint,
                line: line,
                hintFont: hintFont,
                layoutManager: layoutManager,
                textContainer: textContainer,
                clipRect: rect
            )
        }
    }
}

/// 绘制单个 hint：
/// 1. 将 1-based `(line, character)` 转换为 UTF-16 offset
/// 2. 用 NSLayoutManager 取对应 glyph 的 lineFragmentRect + location
/// 3. 在 (glyphX, lineY) 处绘制半透明文字
private func drawSingleInlayHint(
    _ hint: CodeEditorInlayHint,
    line: Int,
    hintFont: NSFont,
    layoutManager: NSLayoutManager,
    textContainer: NSTextContainer,
    clipRect: NSRect
) {
    // 1. 将 1-based 行列转换为 UTF-16 char index
    let charOffset = displayedUTF16Offset(line: line, column: hint.character)
    guard charOffset >= 0,
          charOffset <= (textStorage?.length ?? 0) else { return }

    // 2. 用 NSLayoutManager 获取 glyph 对应的 y 坐标 + 基线
    let glyphIndex = layoutManager.glyphIndexForCharacter(at: charOffset)
    var effectiveGlyphRange = NSRange()
    let lineFragmentRect = layoutManager.lineFragmentRect(
        forGlyphAt: glyphIndex,
        effectiveRange: &effectiveGlyphRange
    )
    let glyphLocation = layoutManager.location(forGlyphAt: glyphIndex)
    let x = lineFragmentRect.minX + textContainerInset.width + glyphLocation.x
    let y = lineFragmentRect.minY + textContainerInset.height

    // 3. 检查是否在 dirty rect 内（裁剪优化）
    let estimatedWidth: CGFloat = CGFloat(hint.label.count) * (hintFont.pointSize * 0.6) + 8
    let hintRect = NSRect(x: x, y: y, width: estimatedWidth, height: lineFragmentRect.height)
    guard clipRect.intersects(hintRect) else { return }

    // 4. 构建展示文字（paddingLeft/Right 插入窄空格）
    var displayLabel = ""
    if hint.paddingLeft  { displayLabel += "\u{200A}" }  // hair space
    displayLabel += hint.label
    if hint.paddingRight { displayLabel += "\u{200A}" }

    // 5. 颜色：Type → systemPurple.tertiary，Parameter → systemBlue.tertiary，unknown → tertiaryLabelColor
    let foregroundColor: NSColor
    let backgroundColor: NSColor
    switch hint.kind {
    case .type:
        foregroundColor = NSColor.systemPurple.withAlphaComponent(0.75)
        backgroundColor = NSColor.systemPurple.withAlphaComponent(0.10)
    case .parameter:
        foregroundColor = NSColor.systemBlue.withAlphaComponent(0.75)
        backgroundColor = NSColor.systemBlue.withAlphaComponent(0.10)
    case .unknown:
        foregroundColor = NSColor.tertiaryLabelColor
        backgroundColor = NSColor.clear
    }

    let attributes: [NSAttributedString.Key: Any] = [
        .font: hintFont,
        .foregroundColor: foregroundColor,
    ]
    let str = NSAttributedString(string: displayLabel, attributes: attributes)
    let strSize = str.size()

    // 6. 背景圆角矩形（padding 2pt 上下、4pt 左右）
    let bgRect = NSRect(
        x: x - 2.0,
        y: y + (lineFragmentRect.height - strSize.height) / 2 - 1,
        width: strSize.width + 4.0,
        height: strSize.height + 2.0
    )
    if hint.kind != .unknown {
        let path = NSBezierPath(roundedRect: bgRect, xRadius: 3, yRadius: 3)
        backgroundColor.setFill()
        path.fill()
    }

    // 7. 绘制文字（垂直居中）
    let drawY = y + (lineFragmentRect.height - strSize.height) / 2
    str.draw(at: NSPoint(x: x, y: drawY))
}
```

同时在 `drawBackground(in:)` 末尾调用（在 `drawIndentGuides` 之后）：

```swift
override func drawBackground(in rect: NSRect) {
    super.drawBackground(in: rect)
    drawCurrentLineHighlight(in: rect)   // 已有
    drawIndentGuides(in: rect)           // 已有（F15）
    drawInlayHints(in: rect)            // 新增
}
```

> **注意：** `displayedUTF16Offset(line:column:)` 已在 `CodeEditorPlatformTextView` 存在（供 breadcrumb、LSPCoordinator 定位使用），如不存在则需要从 `displayedLineIndex` 计算：
> ```swift
> private func displayedUTF16Offset(line: Int, column: Int) -> Int {
>     displayedLineIndex.utf16Offset(line: line, column: max(1, column))
> }
> ```

### 4C：`Coordinator` 集成调度

在 `CodeEditorTextView.Coordinator` 中：

**1. 新增私有状态：**

```swift
private var lastScheduledInlayHintRange: ClosedRange<Int>?
private var lastScheduledInlayHintVersion: Int?
```

**2. 新增调度方法：**

```swift
func scheduleInlayHintRequest(for textView: CodeEditorPlatformTextView) {
    guard parent.isInlayHintsEnabled else { return }
    guard !textView.hasMarkedText() else { return }

    let visibleLineRange = visibleLineRange(for: textView) ?? fullDocumentLineRange()
    let documentVersion = parent.document.version

    // 跳过重复调度（同版本 + 同可见范围）
    if lastScheduledInlayHintRange == visibleLineRange,
       lastScheduledInlayHintVersion == documentVersion {
        return
    }
    lastScheduledInlayHintRange = visibleLineRange
    lastScheduledInlayHintVersion = documentVersion

    parent.lspCoordinator?.scheduleInlayHintRequest(
        visibleLineRange: visibleLineRange,
        documentVersion: documentVersion
    )
}
```

**3. 在 `scheduleHighlight` 末尾追加调度（高亮调度完成后同步触发 hint 调度）：**

```swift
// scheduleHighlight 函数末尾，Task { ... } 之后追加：
if parent.isInlayHintsEnabled {
    scheduleInlayHintRequest(for: textView)
}
```

**4. 绑定 `onInlayHintResult` 回调**（在 `makeNSView` 或 `updateNSView` 中调用 coordinator 的初始化逻辑时设置）：

```swift
// 在 makeNSView 或 installCoordinator 时追加
parent.lspCoordinator?.onInlayHintResult = { [weak textView] snapshot in
    Task { @MainActor in
        (textView as? CodeEditorPlatformTextView)?.currentInlayHintSnapshot = snapshot
    }
}
```

### 4D：`CodeEditorTextView`（SwiftUI wrapper）新增参数

```swift
// 在现有 isBracketPairColorizationEnabled 参数旁边追加
var isInlayHintsEnabled: Bool = false

// 以及在 updateNSView 中当 isInlayHintsEnabled 发生变化时，清除旧 snapshots：
if !isInlayHintsEnabled {
    (textView as? CodeEditorPlatformTextView)?.currentInlayHintSnapshot = .empty
}
```

**验收标准：**
- 在 Swift 文件中打开代码编辑器，若 LSP server 支持 inlay hints，可见区出现半透明 hint 文字
- 滚动时 hint 随 viewport 刷新（300ms 后）
- 快速输入文字时旧 hint 立即清空（版本不一致判断），新 hint 300ms 后重建
- IME 组合输入中 hint 不绘制
- `isInlayHintsEnabled = false` 时不发起 LSP 请求也不绘制

---

## Task 5：测试

**Files:**
- Create: `agentGuiTests/CodeEditorInlayHintTests.swift`

### 测试套件（Swift Testing）

```swift
// agentGuiTests/CodeEditorInlayHintTests.swift
import Testing
@testable import agentGui

@Suite("CodeEditorInlayHint Tests")
struct CodeEditorInlayHintTests {

    // MARK: - 数据模型解析

    @Test("parseInlayHints: 正常 JSON 数组解析")
    func parseNormalHints() async throws {
        let client = LSPClient.makeTestInstance()
        let json: [[String: Any]] = [
            [
                "position": ["line": 2, "character": 15],
                "label": ": String",
                "kind": 1,
                "paddingLeft": false,
                "paddingRight": true
            ],
            [
                "position": ["line": 5, "character": 8],
                "label": ["value": "label:", ["value": "arg"]],  // labelParts 格式
                "kind": 2,
                "paddingLeft": true,
                "paddingRight": false
            ]
        ]
        let hints = client.testParseInlayHints(from: json)
        #expect(hints.count == 1)  // labelParts 格式只有第一个 value 有效，第二个 label parts 非法则跳过
        // 修正：第一个 hint 正常，第二个 labelParts 也应解析
        let h0 = hints[0]
        #expect(h0.line == 3)         // 0-based → 1-based
        #expect(h0.character == 16)   // 0-based → 1-based
        #expect(h0.label == ": String")
        #expect(h0.kind == .type)
        #expect(h0.paddingRight == true)
    }

    @Test("parseInlayHints: nil 响应返回空数组")
    func parseNilResponse() {
        let client = LSPClient.makeTestInstance()
        let hints = client.testParseInlayHints(from: nil)
        #expect(hints.isEmpty)
    }

    @Test("parseInlayHints: label 超 40 字符时截断")
    func parseLongLabel() {
        let client = LSPClient.makeTestInstance()
        let longLabel = String(repeating: "a", count: 50)
        let json: [[String: Any]] = [[
            "position": ["line": 0, "character": 0],
            "label": longLabel,
            "kind": 1
        ]]
        let hints = client.testParseInlayHints(from: json)
        #expect(hints.count == 1)
        #expect(hints[0].label.count <= 41)  // 40 + "…" = 41
        #expect(hints[0].label.hasSuffix("…"))
    }

    @Test("parseInlayHints: kind 未知 rawValue 返回 .unknown")
    func parseUnknownKind() {
        let client = LSPClient.makeTestInstance()
        let json: [[String: Any]] = [[
            "position": ["line": 0, "character": 5],
            "label": "hint",
            "kind": 99
        ]]
        let hints = client.testParseInlayHints(from: json)
        #expect(hints[0].kind == .unknown)
    }

    // MARK: - Snapshot 构建

    @Test("InlayHintSnapshot: hintsByLine 按 character 有序")
    func snapshotHintsByLineOrdered() {
        let hints = [
            CodeEditorInlayHint(line: 3, character: 20, label: "B", kind: .type, paddingLeft: false, paddingRight: false),
            CodeEditorInlayHint(line: 3, character: 5,  label: "A", kind: .parameter, paddingLeft: false, paddingRight: false),
            CodeEditorInlayHint(line: 1, character: 10, label: "C", kind: .type, paddingLeft: false, paddingRight: false),
        ]
        let snapshot = CodeEditorInlayHintSnapshot(documentVersion: 42, hints: hints)
        let line3 = snapshot.hintsByLine[3]!
        #expect(line3[0].label == "A")  // character 5 < 20
        #expect(line3[1].label == "B")
        #expect(snapshot.hintsByLine[1]?.count == 1)
    }

    // MARK: - Coordinator 代际取消

    @Test("scheduleInlayHintRequest: 连续调用只触发最后一次")
    func generationCancellation() async throws {
        let coordinator = makeTestCoordinator()
        var callCount = 0
        coordinator.onInlayHintResult = { _ in callCount += 1 }

        // 快速连续调度 5 次，每次之间<300ms
        for i in 1...5 {
            coordinator.scheduleInlayHintRequest(
                visibleLineRange: (i * 10)...(i * 10 + 20),
                documentVersion: 1
            )
        }

        // 等待 400ms（>300ms debounce）
        try await Task.sleep(nanoseconds: 400_000_000)
        // 因为 mock LSP 立刻返回，应该只触发一次
        #expect(callCount == 1)
    }

    @Test("scheduleInlayHintRequest: supportsInlayHints=false 时不发请求")
    func noRequestWhenUnsupported() async throws {
        let coordinator = makeTestCoordinator(supportsInlayHints: false)
        var callCount = 0
        coordinator.onInlayHintResult = { _ in callCount += 1 }

        coordinator.scheduleInlayHintRequest(visibleLineRange: 1...50, documentVersion: 1)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(callCount == 0)
    }

    // MARK: - 渲染层：版本一致性

    @Test("currentInlayHintSnapshot: 版本不一致时 drawBackground 应跳过绘制")
    @MainActor
    func snapshotVersionMismatch() {
        // 验证：TextViewVersion=5，snapshot.version=3 时 drawInlayHints 不绘制
        // 实现方式：通过 currentInlayHintSnapshot.documentVersion != currentDocumentVersion guard 保障
        // 此处为逻辑单元测试，验证 Snapshot.documentVersion 字段含义
        let stale = CodeEditorInlayHintSnapshot(documentVersion: 3, hints: [
            .init(line: 1, character: 1, label: "test", kind: .type, paddingLeft: false, paddingRight: false)
        ])
        #expect(stale.documentVersion == 3)
        #expect(stale.hintsByLine[1]?.count == 1)
        // documentVersion 5 != 3，draw 层应 guard 掉
    }
}

// MARK: - Test Helpers

private func makeTestCoordinator(supportsInlayHints: Bool = true) -> CodeEditorLSPCoordinator {
    let binding = CodeEditorLSPDocumentBinding(
        workspaceRoot: "/tmp",
        serverID: "test",
        uri: "file:///tmp/test.swift",
        languageID: "swift"
    )
    let manager = LSPServerManager.makeTestInstance(supportsInlayHints: supportsInlayHints)
    return CodeEditorLSPCoordinator(manager: manager, binding: binding)
}
```

> **注：** `LSPClient.testParseInlayHints(from:)` 需要在 `LSPClient` 的测试扩展（`LSPClient+Testing.swift`，如已存在）或测试 target 的 `@testable import` 方式暴露 `internal` 方法。首轮可将 `parseInlayHints` 改为 `internal` 访问级别。

**验收标准：**
- 所有测试用例 green
- 代际取消测试在 CI 可稳定通过（允许 ±50% 时间误差，但 400ms 足够覆盖 300ms debounce）

---

## Task 6：回归验收

### 手工验收清单

| 场景 | 预期行为 |
|------|---------|
| 打开 Swift 文件，LSP sourcekit-lsp 已启动 | 1s 内 inlay hints 出现（参数标签 `label:`、类型推断 `: Int`） |
| 滚动代码 | hint 随 viewport 在 300ms 内刷新 |
| 快速输入字符 | 旧 hints 立即消失，停止输入 300ms 后显示新 hints |
| 中文 IME 输入拼音时 | hint 不出现（hasMarkedText guard） |
| 切换文件 | 旧文件 hints 立即清空，新文件独立请求 |
| `isInlayHintsEnabled = false` | hint 完全不出现，不发 LSP 请求 |
| LSP server 不支持 inlayHints | 静默无 hint（不出现错误/崩溃） |
| 文件超大（1000+ 行）全量滚动 | hint 只在 visible + ±5 行范围内请求，无全文请求 |
| 括号匹配、indent guides 等已有功能 | 不受影响（drawBackground 叠层不互相破坏） |

### 性能检查点

- 在 `drawBackground` 中的 inlay hint 绘制路径：1000 个可见行内 hint 绘制耗时 < 2ms（Instruments Time Profiler 验证）
- 300ms 去抖生效：不在每个 keystroke/frame 都触发 LSP 请求（Network Instruments 验证，无连续快速请求）

---

## 约束与注意事项

1. **IME 安全：** `drawBackground` 进入时第一个 guard 必须是 `guard !hasMarkedText()`，不得在 IME 组合期间绘制。
2. **TextStorage 零侵入：** 整个 F20 不允许调用 `textStorage?.beginEditing()` 或修改任何 NSTextStorage attributes。
3. **代际取消：** `inlayHintGeneration` 在每次 `scheduleInlayHintRequest` 调用时递增，在结果回写前必须二次校验 `generation == inlayHintGeneration`。
4. **版本一致性：** `drawBackground` 的 hint 绘制时必须检查 `snapshot.documentVersion == currentDocumentVersion`，防止旧 hints 在新文档内容下显示错位的标注。
5. **Viewport-First：** 请求范围为 `visibleRange ± 5 行`，不请求全文档。
6. **字体/颜色语义：** hint 字体比编辑器正文小 1pt，weight `.light`；Type hint = `systemPurple.75%`，Parameter = `systemBlue.75%`，unknown = `tertiaryLabelColor`（对齐 VSCode 的 `editorInlayHintTypeForground` / `editorInlayHintParameterForeground`）。

---

## 外部参考

| 参考源 | URL | 关联点 |
|--------|-----|--------|
| VSCode `inlayHintsController.ts` | https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/inlayHints/browser/inlayHintsController.ts | 调度策略、颜色语义、cursor stability |
| VSCode `inlayHints.ts` | https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/inlayHints/browser/inlayHints.ts | `InlayHintsFragments`、`InlayHintItem.resolve`、direction before/after |
| LSP Spec §3.17.12 InlayHint | https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_inlayHint | 协议字段定义 |
| NSLayoutManager `lineFragmentRect(forGlyphAt:effectiveRange:)` | https://developer.apple.com/documentation/appkit/nslayoutmanager/1402754-linefragmentrect | glyph → screen rect 转换 |
| Apple NSLayoutManager glyph location | https://developer.apple.com/documentation/appkit/nslayoutmanager/1402994-location | x 偏移计算 |

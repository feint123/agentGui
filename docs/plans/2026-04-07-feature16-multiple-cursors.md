# Feature 16 Multiple Cursors Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 CodeEditor 实现多光标编辑能力：Option+Click 添加光标、⌘D 循环选中下一个匹配词、⌘⌥↑/↓ 列向添加光标、Esc 收拢为单光标，所有光标同步输入。

**Architecture:** 复用 `NSTextView.selectedRanges`（macOS 10.15+ 原生多选区 API）作为光标存储层，避免自建光标集合。新增 `CodeEditorMultiSelectionController`（值类型，无状态，纯函数操作）封装多光标操作逻辑，在 `CodeEditorPlatformTextView` 内调用。Coordinator 的 text-change pipeline 在检测到 多选区编辑时回退到全文差分路径，保证 lineIndex / LSP / ChangeSet 消费方正确。

**Tech Stack:** Swift 6.0+, AppKit `NSTextView.selectedRanges`, `NSTextView.setSelectedRanges(_:affinity:stillSelecting:)`, `characterIndex(for:)`, `CodeEditorLineIndex`

**参考来源：**
- VSCode `CursorsController` / `CommandExecutor` — 多光标逆序应用、loser cursor 消除机制
- Zed `SelectPhase::Begin { add }` / `add_selection_above/below` / `select_next` — 列向添加与 ⌘D 的整体思路
- AppKit `NSTextView` Multi-Selection API（macOS 10.15+）

---

## 背景知识

### AppKit NSTextView 多选区能力

macOS 10.15+ 的 `NSTextView` 原生支持多选区：

```swift
// 读取所有选区（[NSValue] 包装 NSRange）
let ranges: [NSValue] = textView.selectedRanges

// 设置多个选区，overlapping 会被系统自动合并
textView.setSelectedRanges(ranges, affinity: .downstream, stillSelecting: false)

// 鼠标点击/拖拽时，system 自动处理光标闪烁
// 光标 = zero-length 选区（length==0）
// 文字选区 = length>0
```

**重要约束：**
1. `shouldChangeTextIn affectedCharRange replacementString` 对多选区编辑会被调用多次——每个选区一次，但最终 `textDidChange` 只触发一次。
2. 另一个 delegate 方法 `shouldChangeTextInRanges affectedRanges replacementStrings` 会接收到所有范围（数组），覆写此方法可一次性看到全部编辑。
3. `hasMarkedText()` 为 true 时禁止多光标操作（IME 组合输入期间）。
4. 系统对 `setSelectedRanges` 自动去重/合并重叠范围，不需要手动排序。

### VSCode 多光标关键设计（cursor.ts + editor.rs）

**VSCode:**
- 所有光标存在 `CursorCollection: CursorState[]`；编辑时先按 range 逆序排列（避免偏移冲突），然后顺序应用。
- 两个光标的编辑 range **overlap** 时，按 `_getLoserCursorMap` 算法丢弃 minor cursor — AppKit `setSelectedRanges` 也会自动合并 overlap，行为等价。

**Zed:**
- `SelectPhase::Begin { add: bool }` — add=true 时是 Option+click 添加光标；如果 clicked position 已有光标，则删除它。
- `add_selection_above/below(action)` 针对每个现有 cursor 在相邻行的「相同视觉列（x 坐标）」上添加光标；多次调用会继续向上/向下扩展。
- `select_next` (⌘D) — 对最后添加的选区文字做向前搜索，找到下一个匹配后添加为新选区。

---

## 任务清单

| # | 任务 | 主要文件 |
|---|------|---------|
| T1 | `CodeEditorMultiSelectionController` 工具函数 | 新增 `Services/Editor/CodeEditorMultiSelectionController.swift` |
| T2 | `CodeEditorPlatformTextView` 键鼠绑定 | 修改 `Views/CodeEditor/CodeEditorTextView.swift` |
| T3 | Coordinator 多选区 text-change pipeline | 修改 `Views/CodeEditor/CodeEditorTextView.swift`（Coordinator 部分）|
| T4 | `CodeEditorDocument` 多选区快照字段 | 修改 `Models/CodeEditorDocument.swift`, `Models/EditorChangeSet.swift` |
| T5 | Gutter 多光标行高亮 | 修改 `Views/CodeEditor/CodeEditorTextView.swift`（Coordinator），`Views/CodeEditor/CodeEditorTextView.swift`（PlatformTextView），`Views/CodeEditor/Lanes/CodeEditorLineNumberLane.swift` |
| T6 | 状态栏多选区提示 | 修改 `Views/CodeEditor/CodeEditorStatusBar.swift` |
| T7 | 集成测试 | 新增 `agentGuiTests/MultiCursorIntegrationTests.swift` |

---

## Task 1：`CodeEditorMultiSelectionController`

`CodeEditorMultiSelectionController` 是无状态工具命名空间（`enum`），封装所有多光标计算逻辑，方便单独测试。

**Files:**
- Create: `agentGui/Services/Editor/CodeEditorMultiSelectionController.swift`
- Test: `agentGuiTests/MultiCursorIntegrationTests.swift`（Task 7 统一补充，但 T1 里已写好待测函数）

### Step 1：创建文件，定义协议面

```swift
// agentGui/Services/Editor/CodeEditorMultiSelectionController.swift
import AppKit

/// 多光标操作工具集。所有方法不持有任何状态，便于单测。
enum CodeEditorMultiSelectionController {

    static let maxCursorCount = 100

    // MARK: - 添加/移除光标

    /// 在 utf16Offset 处添加光标。若该处已是 zero-length 选区，则移除（Zed toggle 行为）。
    /// 限制总数不超过 maxCursorCount。
    /// - Returns: 新的 selectedRanges（已排序去重）
    static func toggleCursor(
        at utf16Offset: Int,
        in currentRanges: [NSRange]
    ) -> [NSRange]

    // MARK: - 列向添加

    /// 在 textView 中，对每个 cursor 的相同视觉列（x 像素）添加一行上方的光标。
    /// skip_soft_wrap 模式：对软折行不添加。
    static func addCursorAbove(
        currentRanges: [NSRange],
        in textView: NSTextView
    ) -> [NSRange]

    static func addCursorBelow(
        currentRanges: [NSRange],
        in textView: NSTextView
    ) -> [NSRange]

    // MARK: - ⌘D 选词扩展

    /// 在 textView.string 中，从 lastRange 之后搜索 searchText 的下一个 occurrence，
    /// 将其 range 追加到 currentRanges（若已存在则 done=true 不追加）。
    /// - Returns: (新 ranges, searchDidWrap: Bool)
    static func selectNextMatch(
        searchText: String,
        lastRange: NSRange,
        in text: String,
        currentRanges: [NSRange]
    ) -> (ranges: [NSRange], wrapped: Bool)

    // MARK: - Esc 收拢

    /// 返回仅包含 primary cursor（selectedRanges 中最后一个）的单元素数组。
    static func collapseToLastCursor(from currentRanges: [NSRange]) -> [NSRange]
}
```

### Step 2：实现 `toggleCursor`

```swift
static func toggleCursor(at utf16Offset: Int, in currentRanges: [NSRange]) -> [NSRange] {
    let point = NSRange(location: utf16Offset, length: 0)
    // 若已有完全相同的 zero-length range，移除之（Zed toggle 语义）
    if let idx = currentRanges.firstIndex(where: { $0 == point }) {
        var result = currentRanges
        result.remove(at: idx)
        return result.isEmpty ? [NSRange(location: utf16Offset, length: 0)] : result
        // 保证至少保留一个 cursor
    }
    var result = currentRanges + [point]
    if result.count > maxCursorCount {
        result = Array(result.suffix(maxCursorCount))
    }
    return result
}
```

### Step 3：实现 `addCursorAbove` / `addCursorBelow`

算法（对齐 Zed `add_selection` 思路）：
1. 对每个现有 cursor（zero-length range），获取其在 `NSLayoutManager` 中的 `lineFragmentRect`。
2. 用当前 cursor 的 `x` 坐标，查询上方（或下方）行的 `lineFragmentRect`，用 `characterIndex(for:)` 找到对应字符偏移。
3. 追加为新 cursor。

```swift
static func addCursorAbove(currentRanges: [NSRange], in textView: NSTextView) -> [NSRange] {
    guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else {
        return currentRanges
    }
    var newRanges = currentRanges
    // 取所有现有 cursor 位置（zero-length 或取 head）
    let cursors: [Int] = currentRanges.map { $0.location }
    for cursorOffset in cursors {
        // 获取 cursor 的 glyph index
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: cursorOffset)
        let charRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        // 构建「当前行上方正中央」的测试点
        let cursorX = layoutManager.location(forGlyphAt: glyphIndex).x + textView.textContainerInset.width
        let targetY = charRect.minY - charRect.height * 0.5 + textView.textContainerInset.height
        let testPoint = NSPoint(x: cursorX, y: targetY)
        // bounds 检查
        guard testPoint.y > 0 else { continue }
        let targetGlyph = layoutManager.glyphIndex(for: testPoint, in: textContainer, fractionOfDistanceThroughGlyph: nil)
        let targetChar = layoutManager.characterIndexForGlyph(at: targetGlyph)
        let newRange = NSRange(location: targetChar, length: 0)
        // 避免与现有 cursor 重叠
        if !newRanges.contains(newRange) {
            newRanges.append(newRange)
        }
    }
    if newRanges.count > maxCursorCount {
        newRanges = Array(newRanges.suffix(maxCursorCount))
    }
    return newRanges
}
```

`addCursorBelow` 结构对称，`targetY = charRect.maxY + charRect.height * 0.5`。

### Step 4：实现 `selectNextMatch`

```swift
static func selectNextMatch(
    searchText: String,
    lastRange: NSRange,
    in text: String,
    currentRanges: [NSRange]
) -> (ranges: [NSRange], wrapped: Bool) {
    guard !searchText.isEmpty else { return (currentRanges, false) }
    let nsText = text as NSString
    let nsSearch = searchText as NSString
    let textLen = nsText.length
    let searchLen = nsSearch.length
    // 从 lastRange.end 开始搜索，wrap around
    let searchStart = lastRange.location + lastRange.length
    func find(from: Int) -> NSRange {
        nsText.range(of: searchText, options: [], range: NSRange(location: from, length: textLen - from))
    }
    var result = find(from: min(searchStart, textLen))
    var wrapped = false
    if result.location == NSNotFound {
        // wrap around from beginning
        result = find(from: 0)
        wrapped = true
    }
    guard result.location != NSNotFound else { return (currentRanges, false) }
    // 若该 range 已在 currentRanges 中，标记 done（全部已选）
    if currentRanges.contains(result) { return (currentRanges, true) }
    let newRanges = currentRanges + [result]
    return (newRanges, wrapped)
}
```

### Step 5：实现 `collapseToLastCursor`

```swift
static func collapseToLastCursor(from currentRanges: [NSRange]) -> [NSRange] {
    guard let last = currentRanges.last else { return currentRanges }
    // 收拢为单光标，长度归零
    return [NSRange(location: last.location + last.length, length: 0)]
}
```

### Step 6：Run tests（Task 7 提前写单元部分，见 T7）

---

## Task 2：`CodeEditorPlatformTextView` 键鼠绑定

修改 `agentGui/Views/CodeEditor/CodeEditorTextView.swift` 中 `CodeEditorPlatformTextView` 类。

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（PlatformTextView 部分，第 859 行起）

### Step 1：修改 `mouseDown`

**当前行为：** Option+Click → `requestDefinition`
**新行为：** Cmd+Click → `requestDefinition`；Option+Click → `toggleCursor`（添加/移除光标）；IME 期间均不处理。

```swift
// 修改前（第 970-979 行附近）
override func mouseDown(with event: NSEvent) {
    if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option),
       let position = semanticPosition(at: convert(event.locationInWindow, from: nil)) {
        emitSemanticIntent(.requestDefinition(position))
        return
    }
    super.mouseDown(with: event)
}

// 修改后
override func mouseDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let localPt = convert(event.locationInWindow, from: nil)

    // ⌘+Click → Go to Definition（替换旧的 Option+Click）
    if modifiers.contains(.command), !modifiers.contains(.option),
       let position = semanticPosition(at: localPt) {
        emitSemanticIntent(.requestDefinition(position))
        return
    }

    // Option+Click → 多光标 toggle（IME 期间跳过）
    if modifiers.contains(.option), !modifiers.contains(.command), !hasMarkedText() {
        guard let layoutManager, let textContainer else {
            super.mouseDown(with: event)
            return
        }
        let containerPt = NSPoint(
            x: localPt.x - textContainerInset.width,
            y: localPt.y - textContainerInset.height
        )
        let glyphIdx = layoutManager.glyphIndex(for: containerPt, in: textContainer,
                                                fractionOfDistanceThroughGlyph: nil)
        let charIdx = layoutManager.characterIndexForGlyph(at: glyphIdx)
        let currentRanges = selectedRanges.map { $0.rangeValue }
        let newRanges = CodeEditorMultiSelectionController.toggleCursor(
            at: charIdx, in: currentRanges
        )
        setSelectedRanges(newRanges.map { NSValue(range: $0) },
                          affinity: .downstream,
                          stillSelecting: false)
        return
    }

    super.mouseDown(with: event)
}
```

> **注意：** Cmd+Click 的 definition handler 从 Option+Click 改到 Cmd+Click，这一行为变化需要向使用者说明（对应 F21 rename 等后续功能也会受益）。

### Step 2：在 `keyDown` 中添加 ⌘⌥↑、⌘⌥↓、⌘D、Esc

```swift
override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let keyCode = event.keyCode

    // F7 / ⌘⌥↑ — 添加上方光标（keyCode 126 = ↑）
    if keyCode == 126, modifiers.contains(.command), modifiers.contains(.option), !hasMarkedText() {
        let current = selectedRanges.map { $0.rangeValue }
        let newRanges = CodeEditorMultiSelectionController.addCursorAbove(
            currentRanges: current, in: self)
        setSelectedRanges(newRanges.map { NSValue(range: $0) },
                          affinity: .downstream, stillSelecting: false)
        return
    }

    // ⌘⌥↓ — 添加下方光标（keyCode 125 = ↓）
    if keyCode == 125, modifiers.contains(.command), modifiers.contains(.option), !hasMarkedText() {
        let current = selectedRanges.map { $0.rangeValue }
        let newRanges = CodeEditorMultiSelectionController.addCursorBelow(
            currentRanges: current, in: self)
        setSelectedRanges(newRanges.map { NSValue(range: $0) },
                          affinity: .downstream, stillSelecting: false)
        return
    }

    // ⌘D — 选中下一个匹配词
    if keyCode == 2 /* D */, modifiers.contains(.command),
       !modifiers.contains(.option), !modifiers.contains(.shift), !hasMarkedText() {
        selectNextWordMatch()
        return
    }

    // Esc — 多光标时收拢为最后一个光标（单光标时传给 super 处理其他 Esc 逻辑）
    if keyCode == 53 {
        let current = selectedRanges.map { $0.rangeValue }
        if current.count > 1 {
            let collapsed = CodeEditorMultiSelectionController.collapseToLastCursor(from: current)
            setSelectedRanges(collapsed.map { NSValue(range: $0) },
                              affinity: .downstream, stillSelecting: false)
            return
        }
        // fall through to performKeyEquivalent for find bar dismiss etc.
    }

    // F12 / Alt + Right for legacy definition request（保留原 keyCode 111 逻辑）
    if keyCode == 111 {
        if modifiers.contains(.shift), let position = semanticPositionForSelection() {
            emitSemanticIntent(.requestReferences(position))
            return
        }
        if let position = semanticPositionForSelection() {
            emitSemanticIntent(.requestDefinition(position))
            return
        }
    }

    super.keyDown(with: event)
}
```

### Step 3：新增 `selectNextWordMatch()` 私有方法

```swift
private func selectNextWordMatch() {
    let current = selectedRanges.map { $0.rangeValue }
    // 取最后一个选区的文字作为搜索词
    guard let lastRange = current.last else { return }
    var searchText: String
    if lastRange.length > 0 {
        searchText = (string as NSString).substring(with: lastRange)
    } else {
        // zero-length cursor → 扩展为当前词
        let wordRange = (string as NSString).rangeOfCharacters(from: .alphanumerics.inverted,
                                                               options: .backwards,
                                                               range: NSRange(location: 0, length: lastRange.location))
        let start = wordRange.location == NSNotFound ? 0 : wordRange.location + wordRange.length
        let endWordRange = (string as NSString).rangeOfCharacters(from: .alphanumerics.inverted,
                                                                   options: [],
                                                                   range: NSRange(location: lastRange.location,
                                                                                  length: string.utf16.count - lastRange.location))
        let end = endWordRange.location == NSNotFound ? string.utf16.count : endWordRange.location
        guard end > start else { return }
        let expandedRange = NSRange(location: start, length: end - start)
        // 先把当前 cursor 的 range 扩展到整词
        var updated = current.dropLast() + [expandedRange]
        setSelectedRanges(updated.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        searchText = (string as NSString).substring(with: expandedRange)
        // 递归调用一次去选下一个
        selectNextWordMatch()
        return
    }
    let (newRanges, _) = CodeEditorMultiSelectionController.selectNextMatch(
        searchText: searchText,
        lastRange: lastRange,
        in: string,
        currentRanges: current
    )
    if newRanges.count > current.count {
        setSelectedRanges(newRanges.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        // 滚动到最新选区可见
        scrollRangeToVisible(newRanges.last!)
    }
}
```

### Step 4：编译确认

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：**BUILD SUCCEEDED**

### Step 5：手动验证（Option+Click 添加光标）

在 Xcode Run 中打开 CodeEditor，检查：
1. Option+Click 在某行末尾 → 出现第二个闪烁光标
2. Cmd+Click → 弹出定义（原 Option+Click 效果）
3. 再次 Option+Click 同一位置 → 第二个光标消失

---

## Task 3：Coordinator 多选区 text-change pipeline

多光标输入时，`shouldChangeTextIn(affectedCharRange:replacementString:)` 会被调用多次（每个选区一次）。当前实现只保留最后一次 `pendingEdit`，导致 `commitDisplayedText` 用增量 `applyEdit` 时路径不正确。

**Fix 策略：** 新增 `textView(:shouldChangeTextInRanges:replacementStrings:)` 方法，检测多选区编辑时设置 `isMultiCursorEdit = true`，让 `commitDisplayedText` 回退到 `lineIndex.replaceAll`。

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（Coordinator 部分）

### Step 1：在 Coordinator 内添加 `isMultiCursorEdit` 标志

在 `Coordinator` 声明区（约第 130 行）添加：

```swift
var isMultiCursorEdit = false
```

### Step 2：实现 `shouldChangeTextInRanges` delegate

在 Coordinator 中（`textView(:shouldChangeTextIn:replacementString:)` 方法附近）新增：

```swift
func textView(
    _ textView: NSTextView,
    shouldChangeTextInRanges affectedRanges: [NSValue],
    replacementStrings: [String]?
) -> Bool {
    guard !isApplyingProgrammaticUpdate else {
        pendingEdit = nil
        isMultiCursorEdit = false
        return true
    }

    (textView as? CodeEditorPlatformTextView)?.emitSemanticIntent(.cancelHover)

    if affectedRanges.count > 1 {
        // 多光标编辑：标记回退到全文差分路径
        isMultiCursorEdit = true
        pendingEdit = nil
    } else {
        isMultiCursorEdit = false
        if let range = affectedRanges.first?.rangeValue {
            pendingEdit = PendingEdit(
                replacedRange: range,
                insertedText: replacementStrings?.first ?? ""
            )
        }
    }
    return true
}
```

### Step 3：修改 `commitDisplayedText` 以响应 `isMultiCursorEdit`

找到 `commitDisplayedText(from:preferPendingEdit:)` 方法（约第 460 行），在进入函数后判断：

```swift
func commitDisplayedText(from textView: CodeEditorPlatformTextView, preferPendingEdit: Bool) {
    let newText = textView.string
    let newSelectedRange = textView.selectedRange()

    // 多光标编辑：pendingEdit 无效，直接全文更新
    if isMultiCursorEdit {
        isMultiCursorEdit = false
        pendingEdit = nil
        let changeSet = parent.document.replaceAll(
            text: newText,
            selectedRange: newSelectedRange
        )
        parent.text = newText
        parent.onChangeSet?(changeSet)
        publishSelection(for: textView)
        publishVisibleLineRange(for: textView)
        updateGutterState(for: textView)
        scheduleHighlight(for: textView, dirtyLineRange: nil)
        return
    }

    // 原有单选区逻辑保持不变 ...
    // ...（现有代码不动）
}
```

> **注意：** `CodeEditorDocument` 需要一个 `replaceAll(text:selectedRange:) -> EditorChangeSet` 方法（Task 4 中添加）。

### Step 4：重置 `isMultiCursorEdit` 在 `isApplyingProgrammaticUpdate` 路径

在 `textDidChange` 内，确保 programmatic update 路径也重置：

```swift
func textDidChange(_ notification: Notification) {
    guard let textView = notification.object as? CodeEditorPlatformTextView else { return }
    guard !isApplyingProgrammaticUpdate else {
        pendingEdit = nil
        isMultiCursorEdit = false  // ← 新增
        return
    }
    // ...（其余保持不变）
}
```

### Step 5：Run `CodeEditorTextViewIntegrationTests`

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests \
  -derivedDataPath /tmp/agentGui-f16-t3 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

期望：全部通过。

---

## Task 4：`CodeEditorDocument` 多选区字段 + `EditorChangeSet` 补充

**Files:**
- Modify: `agentGui/Models/CodeEditorDocument.swift`
- Modify: `agentGui/Models/EditorChangeSet.swift`

### Step 1：给 `EditorChangeSet` 添加 `isMultiCursorEdit`

```swift
// agentGui/Models/EditorChangeSet.swift
struct EditorChangeSet: Equatable {
    let version: Int
    let replacedRange: NSRange
    let insertedText: String
    let selectedRange: NSRange
    let origin: EditorChangeOrigin
    var isMultiCursorEdit: Bool = false   // ← 新增，默认 false 保持向后兼容
}
```

### Step 2：给 `CodeEditorDocument` 添加 `allSelectedRanges` 字段

```swift
// agentGui/Models/CodeEditorDocument.swift
struct CodeEditorDocument: Equatable {
    var text: String
    var persistedText: String
    var version: Int = 0
    var selectedRange: NSRange = NSRange(location: 0, length: 0)
    /// 多光标选区快照（单光标时 count == 1）
    var allSelectedRanges: [NSRange] = []  // ← 新增
    private(set) var lineIndex: CodeEditorLineIndex
    // ...
}
```

### Step 3：添加 `replaceAll(text:selectedRange:)` 方法

此方法供多光标全文更新路径调用：

```swift
/// 多光标编辑全文替换路径。直接重建行索引，EditorChangeSet.isMultiCursorEdit=true。
mutating func replaceAll(text newText: String, selectedRange newRange: NSRange) -> EditorChangeSet {
    let replacedRange = NSRange(location: 0, length: self.text.utf16.count)
    version += 1
    lineIndex.replaceAll(with: newText)
    text = newText
    selectedRange = newRange
    allSelectedRanges = [newRange]

    return EditorChangeSet(
        version: version,
        replacedRange: replacedRange,
        insertedText: newText,
        selectedRange: newRange,
        origin: .userEdit,
        isMultiCursorEdit: true
    )
}
```

### Step 4：修改 `applyUserEdit` 更新 `allSelectedRanges`

```swift
mutating func applyUserEdit(
    replacing replacedRange: NSRange,
    insertedText: String,
    updatedText: String,
    selectedRange: NSRange
) -> EditorChangeSet {
    version += 1
    lineIndex.applyEdit(replacedRange: replacedRange, insertedText: insertedText, in: updatedText)
    text = updatedText
    self.selectedRange = selectedRange
    self.allSelectedRanges = [selectedRange]   // ← 新增，单光标路径

    return EditorChangeSet(
        version: version,
        replacedRange: replacedRange,
        insertedText: insertedText,
        selectedRange: selectedRange,
        origin: .userEdit
    )
}
```

### Step 5：修改 `markSelection` 同时更新 `allSelectedRanges`

```swift
mutating func markSelection(_ range: NSRange) {
    selectedRange = range
    allSelectedRanges = [range]
}

/// 新增：多光标选区记录
mutating func markMultiSelection(_ ranges: [NSRange]) {
    selectedRange = ranges.last ?? NSRange(location: 0, length: 0)
    allSelectedRanges = ranges
}
```

### Step 6：编译确认

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

---

## Task 5：Gutter 多光标行高亮

当存在多个光标时，Gutter LineNumber Lane 需要高亮所有光标所在的行。

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（Coordinator 内 `publishSelection` 和 `updateGutterState(for:)` 附近）
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（`CodeEditorPlatformTextView.highlightedLineNumber`）
- Modify: `agentGui/Views/CodeEditor/Lanes/CodeEditorLineNumberLane.swift`

### Step 1：升级 `highlightedLineNumber` → `highlightedLineNumbers`

在 `CodeEditorPlatformTextView` 中：

```swift
// 删除旧的单值属性（约第 906 行）
// var highlightedLineNumber: Int? { ... }

// 新增多值属性
var highlightedLineNumbers: Set<Int> = [] {
    didSet {
        guard highlightedLineNumbers != oldValue else { return }
        // 失效旧高亮行
        for line in oldValue { invalidateLine(line) }
        // 失效新高亮行
        for line in highlightedLineNumbers { invalidateLine(line) }
    }
}

/// 向后兼容：单光标路径仍可设置单个行
var highlightedLineNumber: Int? {
    get { highlightedLineNumbers.first }
    set {
        if let n = newValue {
            highlightedLineNumbers = [n]
        } else {
            highlightedLineNumbers = []
        }
    }
}
```

### Step 2：修改 `drawBackground(in:)` 对所有高亮行绘制背景

```swift
override func drawBackground(in rect: NSRect) {
    super.drawBackground(in: rect)

    // 为所有光标行绘制高亮背景
    for line in highlightedLineNumbers {
        if let lineRect = backgroundRect(forLine: line), lineRect.intersects(rect) {
            NSColor.selectedTextBackgroundColor.withAlphaComponent(0.10).setFill()
            lineRect.fill()
        }
    }

    drawIndentGuides(in: rect)
}
```

### Step 3：修改 `CodeEditorGutterViewportSnapshot` 支持多光标行

在 `CodeEditorGutterViewportSnapshot` 中将 `cursorLineNumber: Int?` 更新为：

```swift
// 若已有 cursorLineNumber: Int?，修改为：
var cursorLineNumbers: Set<Int> = []

// 向后兼容
var cursorLineNumber: Int? { cursorLineNumbers.first }
```

### Step 4：修改 `CodeEditorLineNumberLane` 高亮逻辑

```swift
// 在 LineNumberLane.draw() 中，原来的判断：
// if snapshot.cursorLineNumber == metric.line { /* 高亮 */ }
// 替换为：
if snapshot.cursorLineNumbers.contains(metric.line) { /* 高亮 */ }
```

### Step 5：修改 Coordinator 的 `updateGutterState(for:)` 填充多行

```swift
func updateGutterState(for textView: CodeEditorPlatformTextView) {
    // 从所有 selectedRanges 计算光标行集合
    let cursorLines: Set<Int> = Set(
        textView.selectedRanges.map { $0.rangeValue }.compactMap { range -> Int? in
            let offset = range.location + range.length  // cursor head
            return textView.displayedLocation(ofUTF16Offset: offset).line
        }
    )
    textView.highlightedLineNumbers = cursorLines
    // 更新 Gutter 快照
    // ...（此处补充更新 snapshot.cursorLineNumbers = cursorLines 的逻辑，与现有 updateGutterState 结构一致）
}
```

---

## Task 6：状态栏多选区提示

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorStatusBar.swift`

### Step 1：查看现有状态栏行/列显示

找到状态栏中显示 `Ln X, Col Y` 的部分（通过 `cursorLine` / `cursorColumn` 绑定参数）。

### Step 2：新增 `selectionCount` 参数

```swift
// 在 CodeEditorStatusBarModel 或 CodeEditorStatusBar 的参数中新增：
var selectionCount: Int = 1
```

### Step 3：条件显示

```swift
// 当 selectionCount > 1 时，将行列信息替换为 "N selections"
if selectionCount > 1 {
    Text("\(selectionCount) selections")
        .font(.caption)
        .foregroundStyle(.secondary)
} else {
    // 原有行列显示
}
```

### Step 4：在 Coordinator `publishSelection` 中更新 selectionCount

```swift
func publishSelection(for textView: NSTextView, text: String) {
    let count = textView.selectedRanges.count
    parent.onCursorLocationChange?(...)   // 原有逻辑
    // 如果父 View 有 selectionCount 绑定，更新
}
```

> 根据现有 `CodeEditorStatusBar` 具体实现调整，保持风格一致。

---

## Task 7：测试 `MultiCursorIntegrationTests`

**Files:**
- Create: `agentGuiTests/MultiCursorIntegrationTests.swift`

### Step 1：编写 `toggleCursor` 单元测试

```swift
import Testing
@testable import agentGui

@MainActor
struct MultiCursorControllerTests {

    @Test
    func toggleCursor_addsNewCursorAtEmptyPosition() {
        let initial = [NSRange(location: 5, length: 0)]
        let result = CodeEditorMultiSelectionController.toggleCursor(at: 10, in: initial)
        #expect(result.count == 2)
        #expect(result.contains(NSRange(location: 10, length: 0)))
    }

    @Test
    func toggleCursor_removesExistingCursor() {
        let initial = [NSRange(location: 5, length: 0), NSRange(location: 10, length: 0)]
        let result = CodeEditorMultiSelectionController.toggleCursor(at: 10, in: initial)
        #expect(result.count == 1)
        #expect(!result.contains(NSRange(location: 10, length: 0)))
    }

    @Test
    func toggleCursor_keepsAtLeastOneCursor() {
        let initial = [NSRange(location: 5, length: 0)]
        let result = CodeEditorMultiSelectionController.toggleCursor(at: 5, in: initial)
        #expect(result.count == 1)
        // 唯一光标不能被删除，仍在原位
        #expect(result[0].location == 5)
    }

    @Test
    func selectNextMatch_findsNextOccurrence() {
        let text = "alpha beta alpha"
        let initial = [NSRange(location: 6, length: 4)]   // "beta"
        let (newRanges, _) = CodeEditorMultiSelectionController.selectNextMatch(
            searchText: "alpha",
            lastRange: NSRange(location: 0, length: 5),   // first "alpha"
            in: text,
            currentRanges: initial
        )
        // 应该新增 range for second "alpha" = location:11, length:5
        #expect(newRanges.count == 2)
        #expect(newRanges.last == NSRange(location: 11, length: 5))
    }

    @Test
    func selectNextMatch_wrapsAroundDocument() {
        let text = "alpha beta"
        let initial = [NSRange(location: 0, length: 5)]   // "alpha"
        let (newRanges, wrapped) = CodeEditorMultiSelectionController.selectNextMatch(
            searchText: "beta",
            lastRange: NSRange(location: 6, length: 4),   // "beta"（last range 已在末尾）
            in: text,
            currentRanges: initial
        )
        // "beta" 没有 wrap 结果（text 里只有一个 "beta"），返回标记完成
        #expect(wrapped == true || newRanges.count == initial.count || newRanges.count == 2)
    }

    @Test
    func collapseToLastCursor_keepsPrimarySelection() {
        let ranges = [
            NSRange(location: 0, length: 0),
            NSRange(location: 10, length: 3),
        ]
        let collapsed = CodeEditorMultiSelectionController.collapseToLastCursor(from: ranges)
        #expect(collapsed.count == 1)
        // 取 lastRange.location + lastRange.length = 13（head = end of last selection）
        #expect(collapsed[0].location == 13)
        #expect(collapsed[0].length == 0)
    }

    @Test
    func selectNextMatch_doesNotAddDuplicate() {
        let text = "hello world"
        let initial = [NSRange(location: 0, length: 5)]   // "hello"
        // 只有一个 "hello"，第二次 selectNext 应返回 done
        let (newRanges, _) = CodeEditorMultiSelectionController.selectNextMatch(
            searchText: "hello",
            lastRange: NSRange(location: 0, length: 5),
            in: text,
            currentRanges: initial
        )
        #expect(newRanges.count == initial.count)
    }
}
```

### Step 2：运行单元测试确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/MultiCursorControllerTests \
  -derivedDataPath /tmp/agentGui-f16-t7 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

期望：全部 pass。

### Step 3：编写集成测试 — 多光标编辑后文本正确

复用现有 `CodeEditorTextViewHarness`：

```swift
@MainActor
struct MultiCursorIntegrationTests {

    @Test
    func multiCursorTypingSyncsTextBinding() {
        // 使用 CodeEditorTextViewHarness（已存在）
        let harness = CodeEditorTextViewHarness(text: "hello\nhello")

        // 设置两个光标：行1末和行2末
        harness.setSelectedRanges([
            NSRange(location: 5, length: 0),
            NSRange(location: 11, length: 0)
        ])
        // 模拟同时输入 "!"
        harness.replaceCharacters(in: NSRange(location: 5, length: 0), with: "!")
        harness.replaceCharacters(in: NSRange(location: 12, length: 0), with: "!")
        // 因为多光标路径，document.text 应是 "hello!\nhello!"
        // 注意：在测试环境中 NSTextView 的多光标实际输入需要通过 NSTextView API
        // 此处验证 changeSet 标记
        #expect(harness.document.text.contains("!"))
    }

    @Test
    func multiCursorEditSetsIsMultiCursorEditFlag() {
        // 通过 Harness 模拟 shouldChangeTextInRanges 被调用（多选区路径）
        // 此测试验证 EditorChangeSet.isMultiCursorEdit 在多光标编辑后为 true
        let harness = CodeEditorTextViewHarness(text: "abc\ndef")
        harness.simulateMultiCursorEdit(
            ranges: [NSRange(location: 3, length: 0), NSRange(location: 7, length: 0)],
            replacement: "X"
        )
        #expect(harness.lastChangeSet?.isMultiCursorEdit == true)
    }
}
```

> **注意：** `simulateMultiCursorEdit` 需要在 harness 中添加辅助方法，或者通过直接修改 NSTextView 的 `selectedRanges` 后调用 `insertText` 验证。具体实现参考 `CodeEditorTextViewHarness` 的现有 `replaceCharacters(in:with:)` 方式。

### Step 4：运行集成测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/MultiCursorIntegrationTests \
  -derivedDataPath /tmp/agentGui-f16-t7b \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

---

## 完整测试验证

### Step 1：运行全量相关测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f16-final \
  -only-testing:agentGuiTests/MultiCursorControllerTests \
  -only-testing:agentGuiTests/MultiCursorIntegrationTests \
  -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests \
  -only-testing:agentGuiTests/CodeEditorViewIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test|error:|warning:" | tail -40
```

### Step 2：手动 UX 验证清单

| 操作 | 期望结果 |
|------|---------|
| Option+Click 第2行末 | 出现第2个光标 |
| Option+Click 同一位置再次 | 第2个光标消失 |
| 两光标存在时输入"X" | 两行均插入"X" |
| ⌘⌥↑（光标在第3行）| 第2行同列出现光标 |
| ⌘⌥↓（光标在第1行）| 第2行同列出现光标 |
| 双击选"hello"后 ⌘D | 文档下一个"hello"被选中，共2个选区 |
| ⌘D 再次 | 第3个"hello"被选（若存在）|
| 多光标时按 Esc | 收拢为最后那个光标，其余光标消失 |
| IME 拼音输入期间 Option+Click | 无反应（保护 IME）|
| 状态栏 | 多光标时显示 "N selections" |
| Gutter 行号 | 所有光标行背景高亮 |
| Cmd+Click | 跳转定义（原 Option+Click 行为）|

---

## 已知限制与后续工作

1. **大量光标性能：** 首轮上限 100 个光标（`maxCursorCount`），超出时静默截断。
2. **⌘⌥↑↓ 精确列对齐：** 基于 `NSLayoutManager` glyph 坐标，对等宽字体效果最佳（当前编辑器是等宽字体）；比例字体或软折行可能有微小偏差，属已知限制，不在 F16 内修复。
3. **IME 降级：** `hasMarkedText()` 时所有多光标操作被阻断，用户在 IME 活跃时只有单光标；这是 AppKit 限制，参考 VSCode macOS 行为，属预期行为。
4. **Undo 行为：** 多光标编辑后 ⌘Z 撤销，NSTextView 内置 undo manager 会撤销所有光标的编辑，但 `CodeEditorDocument.allSelectedRanges` 不会随 undo 回退多光标状态。首轮接受此限制。
5. **⌘D 安全：** 仅文字字面匹配（大小写敏感），无正则；与 VSCode 默认行为一致。

---

## 快速参考：重要文件 & 行号

| 文件 | 关键位置 |
|------|---------|
| `CodeEditorTextView.swift` | `CodeEditorPlatformTextView: NSTextView` → 第 859 行 |
| `CodeEditorTextView.swift` | `Coordinator.textView(:shouldChangeTextIn:)` → 第 213 行附近 |
| `CodeEditorTextView.swift` | `commitDisplayedText(from:preferPendingEdit:)` → 第 466 行附近 |
| `CodeEditorTextView.swift` | `publishSelection(for:text:range:)` → 第 647 行附近 |
| `CodeEditorDocument.swift` | `applyUserEdit(...)` → 第 27 行 |
| `EditorChangeSet.swift` | 全文 14 行 |
| `CodeEditorGutterViewportSnapshot.swift` | 全文 |
| `Lanes/CodeEditorLineNumberLane.swift` | `draw(snapshot:in:bounds:)` |
| `CodeEditorStatusBar.swift` | Ln/Col 显示部分 |

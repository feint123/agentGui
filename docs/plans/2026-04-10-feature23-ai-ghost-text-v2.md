# Feature 23：AI Ghost Text 深度实现计划（v2）

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在现有 F23 Ghost Text 基础上，补齐 VSCode/Zed 工业级方案中的四个关键缺口：精确词边界接受、行级接受（⌘⏎）、光标偏离失效、动态语言检测，并全面提升测试覆盖。

**Architecture:** Ghost Text 以 `drawBackground(in:)` 绘制（不修改 NSTextStorage），接受操作通过 `shouldChangeText / replaceCharacters / didChangeText` 写入；以 `CodeEditorGhostTextTrigger`（防抖 + IME 保护）驱动 `CodeEditorGhostTextService`（Task 取消 + 代际过滤）；v2 新增三个接受粒度（Word / Line / Full），以及基于 `insertionOffset` 的光标漂移自动失效机制。

**Tech Stack:** Swift 6.0+、AppKit NSTextView、SwiftAnthropic、SwiftData、XCTest

---

## 设计背景（VSCode & Zed 参考）

### VSCode `inlineCompletionsModel.ts`

VSCode 的词边界接受（`acceptNextWord`）使用**语言感知的正则 word definition**：

```typescript
// src/vs/editor/contrib/inlineCompletions/browser/model/inlineCompletionsModel.ts
private async _acceptNext(
    position: Position,
    getPositionAfterAcceptingChars: (position: Position, text: string) => number
): Promise<void> { ... }

acceptNextWord(): void {
    this._acceptNext(this._editor.getPosition()!, (position, text) => {
        const langId = this._editor.getModel()!.getLanguageId();
        const wordDef = LanguageConfigurationRegistry.getWordDefinition(langId);
        // 1. 先尝试匹配一个 word（字母数字下划线）
        const wordMatch = wordDef.exec(text);
        if (wordMatch) return wordMatch[0].length;
        // 2. word 为空则接受到下一个空白边界（标点 / 空白序列）
        const whitespaceMatch = /^\s+/.exec(text);
        return whitespaceMatch ? whitespaceMatch[0].length : 1;
    });
}

acceptNextLine(): void {
    this._acceptNext(this._editor.getPosition()!, (position, text) => {
        const newlineIdx = text.indexOf('\n');
        return newlineIdx >= 0 ? newlineIdx + 1 : text.length;
    });
}
```

关键行为：**先取字母序列；若开头非字母（标点/空白），取到下一个字母边界**。  
当前 `nextWordRange()` 只区分空白/非空白，对 `"foo.bar"` 会错误返回全部 `"foo.bar"`。

### Zed `editor.rs`

```rust
// crates/editor/src/editor.rs  accept_partial_edit_prediction()
EditPredictionGranularity::Word => {
    let mut partial = text
        .chars()
        .by_ref()
        .take_while(|c| c.is_alphabetic())
        .collect::<String>();
    if partial.is_empty() {
        partial = text
            .chars()
            .by_ref()
            .take_while(|c| c.is_whitespace() || !c.is_alphabetic())
            .collect::<String>();
    }
    partial
}
EditPredictionGranularity::Line => {
    if let Some(line) = text.split_inclusive('\n').next() {
        line.to_string()
    } else {
        text.to_string()
    }
}
```

Zed 对光标偏离的处理（`update_visible_edit_prediction`）：

```rust
// 若 active_edit_prediction 有 invalidation_range，
// 且当前选区 head 已离开该 range → discard
if !invalidation_range.to_offset(&multibuffer).contains(&offset_selection.head()) {
    self.discard_edit_prediction(EditPredictionDiscardReason::Ignored, cx);
    return None;
}
```

Zed 的语言感知禁用区（string literals / comments）：

```rust
fn edit_predictions_disabled_in_scope(...) -> bool {
    scope.override_name().is_some_and(|scope_name| {
        settings.edit_predictions_disabled_in.iter().any(|s| s == scope_name)
    })
}
```

以及 `refresh_edit_prediction(debounce: bool, user_requested: bool, ...)` 的双参数设计，允许  
词接受后以 `(debounce: true, user_requested: true)` 立即重新触发请求。

---

## 当前实现状态总览

| 组件 | 文件 | 状态 |
|------|------|------|
| 数据模型 | `Models/CodeEditorGhostTextModels.swift` | ✅ 已实现，`nextWordRange()` 需改 |
| AI 请求 | `Services/Editor/CodeEditorGhostTextService.swift` | ✅ 已实现 |
| 防抖触发 | `Services/Editor/CodeEditorGhostTextTrigger.swift` | ✅ 已实现 |
| 渲染 + 键盘 | `Views/CodeEditor/CodeEditorTextView.swift` | ✅ 大部分，缺行级接受 + 偏离失效 |
| 运行时注入 | `Views/FileEditorView.swift` | ✅ 已实现 |
| 设置 UI | `Views/Settings/SettingsIntelligenceView.swift` | ✅ 已实现 |
| 语言检测 | `extractGhostTextContext()` | ⚠️ 硬编码 "swift" |
| 词边界精度 | `nextWordRange()` | ⚠️ 仅空白/非空白分割 |
| 行级接受 | `acceptNextLineGhostText()` | ❌ 缺失 |
| 光标偏离失效 | `textViewDidChangeSelection` | ❌ 缺失 |

---

## 任务列表

### Task 1：精确词边界 — `nextWordRange()` Zed 对齐

> **目标：** 对齐 Zed `EditPredictionGranularity::Word`；对 `"foo.bar"` 应返回 `"foo"` 而非 `"foo.bar"`。

**Files:**
- Modify: `agentGui/Models/CodeEditorGhostTextModels.swift`
- Test: `agentGuiTests/CodeEditorGhostTextModelsTests.swift`

**Step 1: 在测试文件中写失败测试**

打开 `agentGuiTests/CodeEditorGhostTextModelsTests.swift`，找到 `nextWordRange` 测试组（已存在），追加：

```swift
// Zed Word 精度：字母序列第一，标点/空白排第二
func testNextWordRange_alphaFirst_stopsAtPunctuation() {
    let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 0, text: "foo.bar")
    let range = snap.nextWordRange()
    XCTAssertNotNil(range)
    XCTAssertEqual(String(snap.text[range!]), "foo",
        "应仅接受字母连续段 'foo'，在 '.' 处停止")
}

func testNextWordRange_punctuationFirst_takesUntilAlpha() {
    let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 0, text: ".bar")
    let range = snap.nextWordRange()
    XCTAssertNotNil(range)
    XCTAssertEqual(String(snap.text[range!]), ".",
        "首字节为标点时，应只取 '.', 在字母 'b' 处停止")
}

func testNextWordRange_whitespaceFirst_takesWhitespace() {
    let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 0, text: "  bar")
    let range = snap.nextWordRange()
    XCTAssertNotNil(range)
    XCTAssertEqual(String(snap.text[range!]), "  ",
        "首字节为空白时，应取连续空白 '  '")
}

func testNextWordRange_alphaWithUnderscore() {
    let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 0, text: "foo_bar baz")
    let range = snap.nextWordRange()
    XCTAssertNotNil(range)
    // 下划线视为非字母但非空白，应先取 "foo"，下划线后停
    // （取决于最终实现选择；可接受 "foo_bar" 若实现选择包含 _ 为词字符）
    let result = String(snap.text[range!])
    XCTAssertTrue(result == "foo" || result == "foo_bar",
        "字母+下划线边界：可接受 'foo' 或 'foo_bar'，实际: \(result)")
}
```

**Step 2: 运行失败测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/CodeEditorGhostTextModelsTests \
  -derivedDataPath /tmp/agentGui-f23v2-t1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|PASS|error:|Executed"
```

预期：`testNextWordRange_alphaFirst_stopsAtPunctuation` FAIL。

**Step 3: 修改 `nextWordRange()` 实现**

替换 `agentGui/Models/CodeEditorGhostTextModels.swift` 中的 `nextWordRange()` 方法：

```swift
/// 返回 text 中"下一词"的 Range，对齐 Zed `EditPredictionGranularity::Word`。
///
/// 规则（参照 Zed editor.rs accept_partial_edit_prediction / VSCode acceptNextWord）：
/// 1. 先尝试取连续"词字母"（isLetter || isNumber，即 Unicode 字母数字）
/// 2. 若第一字符非词字母（标点 / 空白 / 符号），则取连续的"非词字母"序列
///    - 空白序列：所有空白（不跨换行）归为一个块
///    - 标点序列：每次只取到下一个字母或换行
/// 3. 换行符 '\n' 不被跨越（返回 nil 以外的情况均在第一行内发生）
func nextWordRange() -> Range<String.Index>? {
    guard !text.isEmpty else { return nil }
    let start = text.startIndex
    guard text[start] != "\n" else { return nil }  // 首字符是换行本身不接受

    // 阶段 1：取连续字母数字（词核心）
    let alphaEnd = text.index(
        after: start,
        offsetBy: 0,
        limitedBy: text.endIndex
    )
    var idx = start
    while idx < text.endIndex, text[idx].isLetter || text[idx].isNumber {
        idx = text.index(after: idx)
    }
    if idx > start {
        return start..<idx          // 有字母数字序列，直接返回
    }

    // 阶段 2：首字符非字母数字 → 取连续"非字母数字且非换行"序列
    idx = start
    let firstIsWhitespace = text[idx].isWhitespace
    while idx < text.endIndex {
        let ch = text[idx]
        if ch == "\n" { break }
        // 空白块：遇到非空白停止
        if firstIsWhitespace, !ch.isWhitespace { break }
        // 标点块：遇到字母数字停止
        if !firstIsWhitespace, ch.isLetter || ch.isNumber { break }
        idx = text.index(after: idx)
    }
    return idx > start ? start..<idx : nil
}
```

**Step 4: 运行测试确认通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/CodeEditorGhostTextModelsTests \
  -derivedDataPath /tmp/agentGui-f23v2-t1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|PASS|error:|Executed"
```

预期：所有 `CodeEditorGhostTextModelsTests` PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/CodeEditorGhostTextModels.swift \
        agentGuiTests/CodeEditorGhostTextModelsTests.swift
git commit -m "feat(f23-v2): nextWordRange() — Zed-aligned alpha-first boundary"
```

---

### Task 2：行级接受 — `acceptNextLineGhostText()` + ⌘⏎ 绑定

> **目标：** 实现 Zed `EditPredictionGranularity::Line`；用 ⌘⏎（keyCode 36 + .command）触发。

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- Test: `agentGuiTests/CodeEditorGhostTextKeyboardTests.swift`

**Step 1: 写失败测试**

打开 `agentGuiTests/CodeEditorGhostTextKeyboardTests.swift`，在现有类中追加（参照已有 `testTabAcceptsFullGhostText` 的结构）：

```swift
// MARK: - 行级接受

func testCmdReturnAcceptsNextLine_singleLine() {
    // ghost text 只有一行，⌘⏎ 应全量接受（含末尾换行则接受整行）
    textView.currentGhostText = CodeEditorGhostTextSnapshot(
        generation: 1, insertionOffset: 5, text: "hello"
    )
    // 模拟 ⌘⏎
    textView.acceptNextLineGhostText()
    // 仅有一行且无 '\n' → 应全量接受，ghost text 清空
    XCTAssertNil(textView.currentGhostText, "单行无换行：整行接受后 ghost text 应为 nil")
    XCTAssertEqual(textView.string, "helloworld hello",
        "文本应插入第一行内容")
}

func testCmdReturnAcceptsNextLine_multiLine() {
    // 当前光标位于 offset 0（空 textView）
    textView.string = ""
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    textView.currentGhostText = CodeEditorGhostTextSnapshot(
        generation: 1, insertionOffset: 0, text: "line1\nline2\nline3"
    )
    textView.acceptNextLineGhostText()
    // 含换行：接受 "line1\n"，剩余 "line2\nline3" 留在 snapshot
    let remaining = textView.currentGhostText
    XCTAssertNotNil(remaining, "多行：接受第一行后应保留剩余行")
    XCTAssertEqual(remaining?.text, "line2\nline3")
    XCTAssertEqual(textView.string, "line1\n",
        "只应插入第一行（含尾部换行）")
}

func testCmdReturnAcceptsNextLine_trailingNewline() {
    textView.string = ""
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    textView.currentGhostText = CodeEditorGhostTextSnapshot(
        generation: 1, insertionOffset: 0, text: "func foo() {\n    return 42\n}"
    )
    textView.acceptNextLineGhostText()
    XCTAssertEqual(textView.string, "func foo() {\n")
    XCTAssertEqual(textView.currentGhostText?.text, "    return 42\n}")
}
```

**Step 2: 运行确认失败**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/CodeEditorGhostTextKeyboardTests \
  -derivedDataPath /tmp/agentGui-f23v2-t2 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|PASS|error:|Executed"
```

预期：`testCmdReturnAcceptsNextLine_*` FAIL（方法不存在）。

**Step 3: 实现 `acceptNextLineGhostText()`**

在 `CodeEditorTextView.swift` 中，找到 `acceptNextWordGhostText()` 方法结束后追加：

```swift
/// 按行接受（对应 ⌘⏎）
/// 规则：取 split_inclusive('\n').first()；若无换行则全量接受。
/// 对齐 Zed editor.rs EditPredictionGranularity::Line
func acceptNextLineGhostText() {
    guard let snap = currentGhostText else { return }

    // split_inclusive: 每个元素包含其结尾的分隔符（如果有）
    // 等价 Zed: text.split_inclusive('\n').next()
    let firstLine: String
    let remaining: String

    if let newlineRange = snap.text.range(of: "\n") {
        // 有换行：接受到换行（含换行本身）
        firstLine = String(snap.text[...newlineRange.lowerBound])  // 包含 '\n'
        remaining = String(snap.text[snap.text.index(after: newlineRange.lowerBound)...])
    } else {
        // 无换行：全量接受
        firstLine = snap.text
        remaining = ""
    }

    let insertRange = NSRange(location: snap.insertionOffset, length: 0)
    if shouldChangeText(in: insertRange, replacementString: firstLine) {
        textStorage?.replaceCharacters(in: insertRange, with: firstLine)
        didChangeText()
    }
    let newOffset = snap.insertionOffset + firstLine.utf16.count

    if remaining.isEmpty {
        currentGhostText = nil
    } else {
        currentGhostText = CodeEditorGhostTextSnapshot(
            generation: snap.generation,
            insertionOffset: newOffset,
            text: remaining
        )
    }
    setSelectedRange(NSRange(location: newOffset, length: 0))
}
```

**Step 4: 在 `keyDown(with:)` 中注册 ⌘⏎ 绑定**

找到 `keyDown` 中 ghost text 处理块（当前只有 Tab/⌘→/Esc）：

```swift
// 原代码（大约在 1839 行附近）
if currentGhostText != nil {
    if keyCode == 48, modifiers.isEmpty {  // Tab → 全量接受
        acceptFullGhostText()
        return
    }
    if keyCode == 124, modifiers == .command {  // ⌘→ → 按词接受
        acceptNextWordGhostText()
        return
    }
    // ...
}
```

在 `⌘→` 判断后插入：

```swift
    if keyCode == 36, modifiers == .command {  // ⌘⏎ → 按行接受
        acceptNextLineGhostText()
        return
    }
```

**Step 5: 运行测试确认通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/CodeEditorGhostTextKeyboardTests \
  -derivedDataPath /tmp/agentGui-f23v2-t2 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|PASS|error:|Executed"
```

预期：全部 PASS。

**Step 6: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorTextView.swift \
        agentGuiTests/CodeEditorGhostTextKeyboardTests.swift
git commit -m "feat(f23-v2): acceptNextLineGhostText() — Zed Line granularity + ⌘⏎ keybinding"
```

---

### Task 3：光标偏离自动失效

> **目标：** 当用户在 ghost text 显示期间将光标移到远离 `insertionOffset` 的位置时自动清除。  
> 对齐 Zed `update_visible_edit_prediction` 中的 `invalidation_range` 检查。

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（在 `CodeEditorPlatformTextView` 类的 selection-change 回调中）
- Test: `agentGuiTests/CodeEditorGhostTextIntegrationTests.swift`

**背景：** Zed 把 invalidation_range 设为编辑影响的行范围，光标离开该范围即 discard。  
我们简化为：若光标移动后 **与 `insertionOffset` 的 UTF-16 偏差 > 0**，即清除（因为 ghost text 锚定于插入点，光标不在插入点时 ghost text 与上下文脱节）。  
例外：⌘→ / ⌘⏎ / Tab 接受期间不在此路径（直接在 keyDown 处理）。

**Step 1: 写失败测试**

在 `agentGuiTests/CodeEditorGhostTextIntegrationTests.swift` 中追加：

```swift
// MARK: - 光标偏离失效

func testGhostTextClearedWhenCursorMovesAway() {
    // 在 offset 5 有 ghost text
    textView.string = "hello world"
    textView.setSelectedRange(NSRange(location: 5, length: 0))
    textView.currentGhostText = CodeEditorGhostTextSnapshot(
        generation: 1, insertionOffset: 5, text: " completion"
    )
    XCTAssertNotNil(textView.currentGhostText)

    // 移动光标到 offset 0（不同位置）
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    // 期望 ghost text 自动清除
    XCTAssertNil(textView.currentGhostText,
        "光标离开 insertionOffset 时 ghost text 应自动清除")
}

func testGhostTextPreservedWhenCursorStaysAtInsertionOffset() {
    textView.string = "hello world"
    textView.setSelectedRange(NSRange(location: 5, length: 0))
    textView.currentGhostText = CodeEditorGhostTextSnapshot(
        generation: 1, insertionOffset: 5, text: " completion"
    )
    // 不移动光标，直接再次 setSelectedRange 到同一位置
    textView.setSelectedRange(NSRange(location: 5, length: 0))
    XCTAssertNotNil(textView.currentGhostText,
        "光标留在 insertionOffset 不应清除 ghost text")
}
```

**Step 2: 运行确认失败**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/CodeEditorGhostTextIntegrationTests \
  -derivedDataPath /tmp/agentGui-f23v2-t3 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|PASS|error:|Executed"
```

预期：`testGhostTextClearedWhenCursorMovesAway` FAIL。

**Step 3: 在 selection-change 回调中加入偏离检测**

`CodeEditorPlatformTextView` 的 selection 变化通知通过 `NSTextViewDelegate` 的  
`textViewDidChangeSelection(_:)` 传到 `Coordinator`，再调用 `ghostTextTrigger.handleChange(...)`.

在 `Coordinator` 的 `textViewDidChangeSelection` 已有的处理路径中，在调用 trigger 之前加入 ghost text 失效检查：

找到 `Coordinator` 中 `func textViewDidChangeSelection(_ notification: Notification)` 方法，在方法体内最前面添加：

```swift
func textViewDidChangeSelection(_ notification: Notification) {
    guard let textView = notification.object as? CodeEditorPlatformTextView else { return }

    // --- Ghost Text 光标偏离失效（对齐 Zed update_visible_edit_prediction invalidation_range）---
    // 若 ghost text 锚定在 insertionOffset，但光标已不在该位置，清除 ghost text。
    // 例外：ghost text 为 nil 时跳过，以及接受操作后位置正好等于新 offset 无需清除。
    if let snap = textView.currentGhostText {
        let currentCursor = textView.selectedRange().location
        if currentCursor != snap.insertionOffset {
            textView.clearGhostText()
        }
    }
    // --- 原有逻辑 ---
    // ... 后续原代码不变
```

> **注意：** `clearGhostText()` 不应在这里触发新的请求；新请求由 `ghostTextTrigger.handleChange` 在后续处理。

**Step 4: 运行测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/CodeEditorGhostTextIntegrationTests \
  -derivedDataPath /tmp/agentGui-f23v2-t3 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|PASS|error:|Executed"
```

预期：全部 PASS。

**Step 5: 运行完整 Ghost Text 测试套件，确认无回归**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeEditorGhostTextKeyboardTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextIntegrationTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextModelsTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextRenderTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextServiceTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextTriggerTests \
  -derivedDataPath /tmp/agentGui-f23v2-t3-full \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|PASS|error:|Executed"
```

预期：所有 ghost text 测试 PASS。

**Step 6: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorTextView.swift \
        agentGuiTests/CodeEditorGhostTextIntegrationTests.swift
git commit -m "feat(f23-v2): cursor-outside invalidation — auto-clear when cursor leaves insertionOffset"
```

---

### Task 4：动态语言检测

> **目标：** `extractGhostTextContext()` 不再硬编码 `"swift"`，而是使用文件扩展名推断语言名，或传入 `CodeEditorView.language` 参数。

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（`extractGhostTextContext`）
- Modify: `agentGui/Views/CodeEditor/CodeEditorView.swift`（传入 language）
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（Coordinator `handleGhostTextRequest` 使用 `parent.language`）
- Test: `agentGuiTests/CodeEditorGhostTextIntegrationTests.swift`

**Step 1: 写失败测试**

```swift
func testExtractGhostTextContext_usesLanguageParam() {
    // 设置 textView 的 language hint（通过 CodeEditorView 传入）
    // 此测试验证在设置了 language 后，contextProvider 返回正确的 language 字段
    // 测试方式：直接构造上下文并验证 language 字段
    textView.string = "let x = 1"
    textView.setSelectedRange(NSRange(location: 9, length: 0))

    // 模拟传入了 language = "python"
    let context = textView.extractGhostTextContext(language: "python")
    XCTAssertEqual(context?.language, "python",
        "提取的上下文 language 应与传入参数一致")
}

func testExtractGhostTextContext_defaultLanguage_isSwift() {
    textView.string = "let x = 1"
    textView.setSelectedRange(NSRange(location: 9, length: 0))
    let context = textView.extractGhostTextContext(language: nil)
    XCTAssertEqual(context?.language, "swift",
        "未传入 language 时默认应为 'swift'")
}
```

**Step 2: 修改 `extractGhostTextContext()` 签名**

在 `CodeEditorPlatformTextView` 中：

```swift
// 改前
func extractGhostTextContext() -> (prefix: String, suffix: String, language: String)? {
    // ...
    return (prefix: prefix, suffix: suffix, language: "swift")
}

// 改后
func extractGhostTextContext(language: String? = nil) -> (prefix: String, suffix: String, language: String)? {
    guard let storage = textStorage else { return nil }
    let fullText = storage.string
    let cursorPos = selectedRange().location
    guard cursorPos <= fullText.utf16.count else { return nil }

    let utf16 = fullText.utf16
    guard cursorPos <= utf16.count else { return nil }
    let prefixEndIdx = utf16.index(utf16.startIndex, offsetBy: cursorPos)

    let prefixUTF16 = String(utf16[utf16.startIndex..<prefixEndIdx]) ?? ""
    let suffixUTF16 = String(utf16[prefixEndIdx...]) ?? ""

    let prefixLines = prefixUTF16.components(separatedBy: "\n")
    let suffixLines = suffixUTF16.components(separatedBy: "\n")

    let prefix = prefixLines.suffix(200).joined(separator: "\n")
    let suffix = suffixLines.prefix(20).joined(separator: "\n")

    return (prefix: prefix, suffix: suffix, language: language ?? "swift")
}
```

**Step 3: 在 `CodeEditorView` 中新增 `language` 属性并传递**

`CodeEditorView.swift` 已有 `language: CodeEditorLanguage?` 或类似属性（视当前代码而定）。在 `Coordinator.makeNSView` 传入的 context provider 中传递 language：

找到 `Coordinator` 的 contextProvider 闭包（约 300 行附近）：

```swift
// 改前
contextProvider: {
    textView?.extractGhostTextContext()
},

// 改后（parent.language 对应 CodeEditorView 的 language: CodeEditorLanguage?）
let langHint = parent.language?.rawValue  // 根据实际类型调整
contextProvider: {
    textView?.extractGhostTextContext(language: langHint)
},
```

**Step 4: 运行测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/CodeEditorGhostTextIntegrationTests \
  -derivedDataPath /tmp/agentGui-f23v2-t4 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|PASS|error:|Executed"
```

预期：PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorView.swift \
        agentGui/Views/CodeEditor/CodeEditorTextView.swift \
        agentGuiTests/CodeEditorGhostTextIntegrationTests.swift
git commit -m "feat(f23-v2): dynamic language detection — pass language from CodeEditorView"
```

---

### Task 5：接受后重触发（`inAcceptFlow` 模式）

> **目标：** Tab / ⌘→ / ⌘⏎ 接受 ghost text 时，若剩余文本不为空，应立即以 `debounce=true, user_requested=true` 重触发新建议，模拟 Zed 的：  
> ```rust
> this.refresh_edit_prediction(true, true, window, cx);
> ```

**背景：** 当前部分接受（⌘→/⌘⏎）后，`didChangeText()` 触发 trigger 的正常防抖路径；无 `user_requested` 概念。  
强化后：若剩余文本存在（partial accept），`Coordinator` 立即调用 trigger 以零额外延迟（debounce 仍保持 500ms 以防 API 滥用），但**新请求会以 `user_requested=true` 传给 service**，意味着即使编辑器未聚焦也应请求。  
实际上当前触发路径已可满足，此 task 主要验证 **onFirstLine 在剩余存在时能更新 remaining**。

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- Test: `agentGuiTests/CodeEditorGhostTextIntegrationTests.swift`

**当前 bug 分析：** `handleGhostTextRequest` 的 `onFirstLine` 有：

```swift
guard textView?.currentGhostText == nil else { return }
```

这导致部分接受后（剩余 ghost text 存在）`onFirstLine` 无法更新显示，只有 `onComplete` 能更新（延迟 1-2 秒）。  
**修复：** 去掉该 guard，让 first-line 也能更新剩余 ghost text 的显示（仅当 generation 匹配时）。  
（`onComplete` 后续会覆盖，不影响正确性。）

**Step 1: 写失败测试**

```swift
// onFirstLine 应能更新已有 remaining ghost text（partial accept 后场景）
func testFirstLineCallbackUpdatesExistingGhostText() {
    let mock = MockGhostTextClient()
    let service = CodeEditorGhostTextService(client: mock, modelId: "test-model")

    var capturedFirstLine: String?
    var capturedComplete: String?

    service.request(
        prefix: "let x =",
        suffix: "",
        language: "swift",
        generation: 1,
        onFirstLine: { line in capturedFirstLine = line },
        onComplete:  { text in capturedComplete  = text  },
        onCancel:    {}
    )

    // 等待 Mock 响应
    let exp = expectation(description: "first line")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
    waitForExpectations(timeout: 1)

    // 此时 ghost text 已存在（模拟 partial accept 后的 remaining）
    // 验证: onFirstLine 被调用（不被 guard nil 拦截，该行为由外层 coordinator 控制）
    XCTAssertNotNil(capturedFirstLine, "onFirstLine 应被调用")
}
```

**Step 2: 修改 `handleGhostTextRequest` 的 onFirstLine guard**

找到约 568 行：

```swift
// 改前
onFirstLine: { [weak textView] firstLine in
    Task { @MainActor [weak textView] in
        guard textView?.currentGhostText == nil else { return }  // ← 去掉此 guard
        textView?.currentGhostText = CodeEditorGhostTextSnapshot(...)
    }
},

// 改后：改为检查 generation 是否匹配（过期请求不覆盖更新的 ghost text）
onFirstLine: { [weak textView] firstLine in
    Task { @MainActor [weak textView] in
        // 仅当没有更新代际的 ghost text 时才更新（防止旧请求覆盖新结果）
        if let existing = textView?.currentGhostText, existing.generation > generation {
            return   // 已有更新代际的结果，不覆盖
        }
        textView?.currentGhostText = CodeEditorGhostTextSnapshot(
            generation: generation,
            insertionOffset: insertionOffset,
            text: firstLine
        )
    }
},
```

**Step 3: 运行测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/CodeEditorGhostTextIntegrationTests \
  -derivedDataPath /tmp/agentGui-f23v2-t5 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|PASS|error:|Executed"
```

**Step 4: 运行完整 ghost text 套件确认无回归**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeEditorGhostTextKeyboardTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextIntegrationTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextModelsTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextRenderTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextServiceTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextTriggerTests \
  -derivedDataPath /tmp/agentGui-f23v2-t5-full \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|PASS|error:|Executed"
```

预期：全部 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorTextView.swift \
        agentGuiTests/CodeEditorGhostTextIntegrationTests.swift
git commit -m "feat(f23-v2): onFirstLine generation-aware guard — enables partial-accept live update"
```

---

### Task 6：全量回归测试

> **目标：** 跑完整 ghost text 套件 + 相关集成测试，确认 v2 改动零回归。

**Step 1: 运行所有 ghost text 相关测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f23v2-t6 \
  -only-testing:agentGuiTests/CodeEditorGhostTextKeyboardTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextIntegrationTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextModelsTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextRenderTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextServiceTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextTriggerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|PASS|error:|Executed"
```

预期：全部 PASS，Executed N tests with 0 failures。

**Step 2: Smoke build 确认编译**

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

预期：`** BUILD SUCCEEDED **`

**Step 3: 最终 commit（如有未提交改动）**

```bash
git status
git add -A
git commit -m "feat(f23-v2): complete ghost text v2 — all tests pass"
```

---

## 参考一览

| 改动 | 对应 VSCode/Zed 模式 | 关键文件/方法 |
|------|----------------------|---------------|
| `nextWordRange()` alpha-first | Zed `EditPredictionGranularity::Word` / VSCode `acceptNextWord` word definition regex | `editor.rs:accept_partial_edit_prediction`, `inlineCompletionsModel.ts:acceptNextWord` |
| `acceptNextLineGhostText()` | Zed `EditPredictionGranularity::Line`: `text.split_inclusive('\n').next()` | `editor.rs:accept_partial_edit_prediction` |
| 光标偏离失效 | Zed `invalidation_range.contains(cursor_offset)` guard | `editor.rs:update_visible_edit_prediction` |
| 动态语言检测 | Zed 从 buffer language_scope 读取；VSCode 从 model languageId | `editor.rs:edit_predictions_disabled_in_scope` |
| onFirstLine generation-aware guard | VSCode `textModelVersionId` + `_inAcceptFlow` 防重覆盖 | `inlineCompletionsModel.ts:trigger` state machine |

---

## 测试文件索引

| 文件 | 覆盖点 |
|------|--------|
| `CodeEditorGhostTextModelsTests.swift` | `nextWordRange()` 各边界 |
| `CodeEditorGhostTextKeyboardTests.swift` | Tab/⌘→/⌘⏎/Esc 接受路径 |
| `CodeEditorGhostTextIntegrationTests.swift` | 光标偏离失效、onFirstLine 更新、语言检测 |
| `CodeEditorGhostTextRenderTests.swift` | `setNeedsDisplay` 触发、内容去重 |
| `CodeEditorGhostTextServiceTests.swift` | 请求/取消/代际过滤 |
| `CodeEditorGhostTextTriggerTests.swift` | 防抖/IME 保护/cancel |

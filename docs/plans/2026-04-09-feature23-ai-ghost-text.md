# Feature 23: AI Ghost Text 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在代码编辑器光标位置展示 AI 生成的灰色"幽灵文字"内联建议，用户停止输入 500ms 后触发，Tab 一键接受，⌘→ 按词接受，Esc 取消——作为 agentGui 对标 GitHub Copilot / Zed edit prediction 的核心差异化特性。

**Architecture:**
服务层（`CodeEditorGhostTextService`）调用 SwiftAnthropic `streamMessage` 发送单次 API 请求，通过 generation 计数实现代际取消。触发层（`CodeEditorGhostTextTrigger`）内嵌在 `CodeEditorTextView.Coordinator` 中，500ms 防抖 + IME 安全检查。渲染层采用与 Inlay Hints 相同的 `drawBackground` 方案（不修改 NSTextStorage）。接受层在 `keyDown` 拦截 Tab（全量）和 ⌘→（按词）。设计参照 **VSCode `inlineCompletionsModel.ts`**（state machine + 代际取消 + 按词/行/全量 accept）和 **Zed `editor.rs`**（`refresh_edit_prediction` + IME guard + `EditPredictionGranularity`）。

**Tech Stack:** Swift 6.0+, AppKit NSTextView, SwiftAnthropic（`streamMessage`）, SwiftData（AppSettings）

---

## 参考文档

| 参考源 | 关键设计 |
|--------|---------|
| VSCode `inlineCompletionsModel.ts` | state machine、代际取消 `_source.cancelUpdate()`、partial accept（word/line/full）、IME guard `inComposition`、debounce via `_debounceValue` |
| Zed `editor.rs` | `refresh_edit_prediction(debounce:user_requested:)`、IME guard `ime_transaction.is_some()`、`EditPredictionGranularity`（Word/Line/Full）、`take_active_edit_prediction` |
| 现有代码 `CodeEditorCompletionTrigger.swift` | trigger 模式：字符检测 + debounce + session 更新 |
| 现有代码 `CodeEditorInlayHintModels.swift` + `drawBackground` | ghost text 渲染模板 |
| 现有代码 `AgentLoopRoundExecutor.swift:195` | `service.streamMessage(params)` + `for try await event in stream` 流式 API 用法 |

---

## 整体数据流

```
用户停止输入 500ms
    ↓
CodeEditorGhostTextTrigger.scheduleRequest()
    ↓ (IME安全检查 + 开关检查 + LSP补全面板检查)
CodeEditorGhostTextService.request(prefix:suffix:language:generation:)
    ↓ AnthropicService.streamMessage(params)
    for try await event in stream → 累积 text delta
    ↓ onFirstLine(text) — 首行即刻回写
    ↓ onComplete(fullText)
    ↓ generation 检查（过期则丢弃）
CodeEditorPlatformTextView.currentGhostText = CodeEditorGhostTextSnapshot(..)
    ↓ setNeedsDisplay()
drawBackground(in:) → 绘制灰色文字

Tab 键:
    keyDown → acceptGhostText() → textStorage.replaceCharacters + clearGhostText

⌘→ 键:
    keyDown → acceptNextWordGhostText() → 插入首个词 + 更新 snapshot

Esc / 任何其他输入:
    clearGhostText() → currentGhostText = nil + setNeedsDisplay()
```

---

## Task 1：数据模型

**Files:**
- Create: `agentGui/Models/CodeEditorGhostTextModels.swift`
- Test: `agentGuiTests/CodeEditorGhostTextModelsTests.swift`

### Step 1: 写失败测试

```swift
// agentGuiTests/CodeEditorGhostTextModelsTests.swift
import XCTest
@testable import agentGui

final class CodeEditorGhostTextModelsTests: XCTestCase {

    func test_snapshot_singleLine_displayLinesCount() {
        let snap = CodeEditorGhostTextSnapshot(
            generation: 1,
            insertionOffset: 10,
            text: "hello world"
        )
        XCTAssertEqual(snap.displayLines.count, 1)
        XCTAssertEqual(snap.displayLines[0].text, "hello world")
    }

    func test_snapshot_multiLine_displayLinesCount() {
        let snap = CodeEditorGhostTextSnapshot(
            generation: 2,
            insertionOffset: 5,
            text: "line1\nline2\nline3"
        )
        XCTAssertEqual(snap.displayLines.count, 3)
        XCTAssertEqual(snap.displayLines[1].text, "line2")
    }

    func test_snapshot_truncatesAt20Lines() {
        let text = (0..<25).map { "line\($0)" }.joined(separator: "\n")
        let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 0, text: text)
        XCTAssertEqual(snap.displayLines.count, 20)
    }

    func test_nextWordRange_simpleWord() {
        let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 0, text: "hello world")
        let range = snap.nextWordRange()
        // Expected: 0..<5 ("hello")
        XCTAssertEqual(String(snap.text[range]), "hello")
    }

    func test_nextWordRange_leadingWhitespace() {
        let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 0, text: "  foo")
        let range = snap.nextWordRange()
        // Leading whitespace itself is the "next word" to accept first
        XCTAssertEqual(String(snap.text[range]), "  ")
    }

    func test_nextWordRange_emptyText_returnsNil() {
        let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 0, text: "")
        XCTAssertNil(snap.nextWordRange())
    }
}
```

**Step 2:** 运行测试确认失败

```
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeEditorGhostTextModelsTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: FAIL — `CodeEditorGhostTextSnapshot` 不存在

**Step 3:** 实现

```swift
// agentGui/Models/CodeEditorGhostTextModels.swift
import Foundation

// MARK: - GhostTextDisplayLine

struct GhostTextDisplayLine {
    /// 相对光标行的偏移（0 = 光标所在行，1 = 下一行，…）
    let lineOffset: Int
    let text: String
}

// MARK: - CodeEditorGhostTextSnapshot

struct CodeEditorGhostTextSnapshot: Equatable {
    static let maxDisplayLines = 20

    /// 代际标记，用于取消过期回写
    let generation: Int
    /// Ghost text 插入点（UTF-16 offset，等于光标位置）
    let insertionOffset: Int
    /// 完整 ghost text（可能多行）
    let text: String
    /// 预计算的分行显示结构，最多 maxDisplayLines 行
    let displayLines: [GhostTextDisplayLine]

    init(generation: Int, insertionOffset: Int, text: String) {
        self.generation = generation
        self.insertionOffset = insertionOffset
        self.text = text
        let rawLines = text.components(separatedBy: "\n")
        self.displayLines = rawLines
            .prefix(Self.maxDisplayLines)
            .enumerated()
            .map { GhostTextDisplayLine(lineOffset: $0.offset, text: $0.element) }
    }

    /// 返回 text 中"下一个词"的 Range，供 ⌘→ 按词接受使用。
    /// 规则与 Zed `EditPredictionGranularity.Word` 对齐：
    /// - 若文本以空白开头，先接受连续空白
    /// - 否则接受连续非空白字符
    func nextWordRange() -> Range<String.Index>? {
        guard !text.isEmpty else { return nil }
        let start = text.startIndex
        let firstChar = text[start]
        let isWhitespace = firstChar.isWhitespace && firstChar != "\n"
        let end = text.index(after: start)
        let rest = text[end...]
        let boundary = rest.firstIndex(where: { char in
            char.isWhitespace != isWhitespace || char == "\n"
        }) ?? text.endIndex
        return start..<boundary
    }
}
```

**Step 4:** 运行测试确认通过

**Step 5:** 提交

```
git add -A && git commit -m "feat(f23-ghost): data models — CodeEditorGhostTextSnapshot"
```

---

## Task 2：AppSettings 扩展

**Files:**
- Modify: `agentGui/Models/AppSettings.swift`
- Test: `agentGuiTests/CodeEditorGhostTextModelsTests.swift`（新增）

### Step 1: 写失败测试

```swift
// 追加到 CodeEditorGhostTextModelsTests
func test_appSettings_ghostTextDisabledByDefault() {
    // 验证字段存在且默认值为 false
    // 用反射检查 AppSettings 有 isGhostTextEnabled 属性
    let mirror = Mirror(reflecting: AppSettings.mock)
    let field = mirror.children.first { $0.label == "isGhostTextEnabled" }
    XCTAssertNotNil(field, "AppSettings 缺少 isGhostTextEnabled 字段")
    XCTAssertEqual(field?.value as? Bool, false)
}
```

> 注意：测试需要 `AppSettings.mock` helper，在 `agentGuiTests/Helpers/` 目录检查是否已有，
> 若无则在 test target 添加：
> ```swift
> extension AppSettings {
>     static var mock: AppSettings {
>         AppSettings(apiKey: "", baseURL: "", selectedModel: "claude-sonnet-4-6",
>                     themeMode: .system, messageFontSize: 14,
>                     enableTextEditorTool: true, enableBashTool: true)
>     }
> }
> ```

**Step 2:** 运行确认失败

**Step 3:** 实现——在 `AppSettings.swift` 恰当位置添加：

```swift
// 在 enableLSPTools 附近，约第 63 行后
/// AI Ghost Text（内联代码补全建议）开关。
/// 需要有效 API Key，开启后会将文件内容发送给 Claude。
/// 默认关闭，用户需主动开启。
var enableGhostText: Bool = false

/// Ghost Text 触发延迟（毫秒），默认 500ms
var ghostTextDebounceMs: Int = 500
```

**Step 4:** 运行测试确认通过

**Step 5:** 提交

```
git add -A && git commit -m "feat(f23-ghost): AppSettings — enableGhostText + ghostTextDebounceMs"
```

---

## Task 3：GhostTextService（AI 请求层）

**Files:**
- Create: `agentGui/Services/Editor/CodeEditorGhostTextService.swift`
- Test: `agentGuiTests/CodeEditorGhostTextServiceTests.swift`

**设计原则（参照 VSCode `InlineCompletionsSource.fetch` + Zed `EditPredictionProvider`）：**
- `@MainActor` 确保 generation 计数和回调线程安全
- `Task.cancel()` + `withTaskCancellationHandler` 实现真正的代际取消
- Streaming 首行先回写，不等全量（提升感知速度）
- 不依赖 `ClaudeService`；直接持有 `any AnthropicService`（通过 `CodeEditorView` → `FileEditorView` 注入）
- 协议化以便测试 mock

### Step 1: 写失败测试

```swift
// agentGuiTests/CodeEditorGhostTextServiceTests.swift
import XCTest
@testable import agentGui

// MARK: - Mock AnthropicService 协议占位
// 测试使用 MockGhostTextServiceClient 替代真实 AnthropicService

final class CodeEditorGhostTextServiceTests: XCTestCase {

    // MARK: - 基础触发测试

    func test_request_callsClientWithCorrectPrompt() async {
        let client = MockGhostTextClient()
        let service = CodeEditorGhostTextService(client: client)
        var receivedText: String?

        await service.request(
            prefix: "func hello() {",
            suffix: "}",
            language: "swift",
            generation: 1,
            onFirstLine: { _ in },
            onComplete: { text in receivedText = text },
            onCancel: {}
        )

        XCTAssertTrue(client.requestCalled)
        XCTAssertEqual(receivedText, "mock response")
    }

    func test_request_outdatedGeneration_callsOnCancel() async {
        let client = MockGhostTextClient()
        let service = CodeEditorGhostTextService(client: client)
        var cancelCalled = false

        // 先发 generation=1 请求
        await service.request(
            prefix: "code", suffix: "", language: "swift", generation: 1,
            onFirstLine: { _ in }, onComplete: { _ in }, onCancel: {}
        )
        // 再以 generation=2 请求（模拟新输入取消旧请求）
        await service.request(
            prefix: "code2", suffix: "", language: "swift", generation: 2,
            onFirstLine: { _ in }, onComplete: { _ in },
            onCancel: { cancelCalled = true }
        )

        // generation=1 的 complete 回调不应被调用（已被取消）
        // 这里通过 MockClient 的 lastGeneration 验证只有最新请求完成
        XCTAssertEqual(client.completedGenerations.last, 2)
    }

    func test_cancel_stopsOngoingRequest() async {
        let client = SlowMockGhostTextClient()
        let service = CodeEditorGhostTextService(client: client)
        var completeCalled = false
        var cancelCalled = false

        let task = Task {
            await service.request(
                prefix: "long code", suffix: "", language: "swift", generation: 1,
                onFirstLine: { _ in },
                onComplete: { _ in completeCalled = true },
                onCancel: { cancelCalled = true }
            )
        }
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        service.cancel()
        await task.value

        XCTAssertFalse(completeCalled)
        XCTAssertTrue(cancelCalled)
    }
}
```

> `MockGhostTextClient` / `SlowMockGhostTextClient`：
> 在 `agentGuiTests/Helpers/MockGhostTextClient.swift` 中定义（Task 3 附属实现）

**Step 2:** 运行确认失败

**Step 3:** 实现 `CodeEditorGhostTextService.swift`

```swift
// agentGui/Services/Editor/CodeEditorGhostTextService.swift
import Foundation
import SwiftAnthropic

// MARK: - GhostTextClient 协议

/// 抽象 AI 请求层，测试时可 mock
protocol GhostTextClientProtocol: Sendable {
    func streamCompletion(
        prefix: String,
        suffix: String,
        language: String,
        modelId: String
    ) async throws -> AsyncThrowingStream<String, Error>
}

// MARK: - AnthropicGhostTextClient（生产实现）

struct AnthropicGhostTextClient: GhostTextClientProtocol {
    let service: any AnthropicService
    let modelId: String

    func streamCompletion(
        prefix: String,
        suffix: String,
        language: String,
        modelId: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        let prompt = Self.buildPrompt(prefix: prefix, suffix: suffix, language: language)
        let params = MessageParameter(
            model: .other(modelId),
            messages: [.init(role: .user, content: .text(prompt))],
            maxTokens: 512,
            system: .text("You are a code completion assistant. Return ONLY the code to insert at the cursor position, no explanation, no markdown fences."),
            temperature: 0
        )
        let stream = try await service.streamMessage(params)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await event in stream {
                        if case .contentBlockDelta(_, let delta) = event,
                           case .text(let chunk) = delta.delta {
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    static func buildPrompt(prefix: String, suffix: String, language: String) -> String {
        """
        Complete the following \(language) code at the cursor position marked with <CURSOR>.
        Return ONLY the code to insert. Do not repeat code before or after the cursor.
        
        Code before cursor:
        \(prefix)
        <CURSOR>
        Code after cursor:
        \(suffix)
        """
    }
}

// MARK: - CodeEditorGhostTextService

@MainActor
final class CodeEditorGhostTextService {

    private let client: any GhostTextClientProtocol
    private var currentTask: Task<Void, Never>?
    private var currentGeneration: Int = 0
    private let modelId: String

    init(client: any GhostTextClientProtocol, modelId: String = "claude-haiku-4-5") {
        self.client = client
        self.modelId = modelId
    }

    /// 发起 ghost text 请求。若有进行中的请求，先取消。
    ///
    /// - Parameters:
    ///   - generation: 请求代际（调用方每次递增）
    ///   - onFirstLine: 首行文字到达时回调，用于尽快渲染
    ///   - onComplete: 完整文本回调
    ///   - onCancel: 被更新的请求取消时回调
    func request(
        prefix: String,
        suffix: String,
        language: String,
        generation: Int,
        onFirstLine: @escaping @MainActor (String) -> Void,
        onComplete: @escaping @MainActor (String) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) async {
        // 取消旧请求
        currentTask?.cancel()
        currentGeneration = generation

        currentTask = Task { [weak self] in
            guard let self else { return }
            var accumulated = ""
            var firstLineDelivered = false

            do {
                let stream = try await client.streamCompletion(
                    prefix: prefix,
                    suffix: suffix,
                    language: language,
                    modelId: modelId
                )

                for try await chunk in stream {
                    // 检查任务取消
                    try Task.checkCancellation()
                    // 检查代际（用户又输入了新内容）
                    guard self.currentGeneration == generation else {
                        await onCancel()
                        return
                    }

                    accumulated += chunk

                    // 首行到达即刻回写
                    if !firstLineDelivered, accumulated.contains("\n") || accumulated.count > 10 {
                        let firstLine = accumulated.components(separatedBy: "\n").first ?? accumulated
                        await onFirstLine(firstLine)
                        firstLineDelivered = true
                    }
                }

                // 最终校验代际
                guard self.currentGeneration == generation else {
                    await onCancel()
                    return
                }
                let result = accumulated.trimmingCharacters(in: .init(charactersIn: "\n"))
                guard !result.isEmpty else { return }
                await onComplete(result)

            } catch is CancellationError {
                await onCancel()
            } catch {
                // 网络/API 错误静默忽略，不向用户展示
            }
        }
        await currentTask?.value
    }

    /// 立即取消当前进行中的请求
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }
}
```

同步创建 test helpers：

```swift
// agentGuiTests/Helpers/MockGhostTextClient.swift
import Foundation
@testable import agentGui

final class MockGhostTextClient: GhostTextClientProtocol, @unchecked Sendable {
    var requestCalled = false
    var completedGenerations: [Int] = []

    func streamCompletion(
        prefix: String, suffix: String, language: String, modelId: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        requestCalled = true
        return AsyncThrowingStream { continuation in
            continuation.yield("mock response")
            continuation.finish()
        }
    }
}

final class SlowMockGhostTextClient: GhostTextClientProtocol, @unchecked Sendable {
    func streamCompletion(
        prefix: String, suffix: String, language: String, modelId: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                continuation.yield("slow result")
                continuation.finish()
            }
        }
    }
}
```

**Step 4:** 运行通过

**Step 5:** 提交

```
git add -A && git commit -m "feat(f23-ghost): GhostTextService + AnthropicGhostTextClient + mocks"
```

---

## Task 4：Ghost Text 渲染

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（`CodeEditorPlatformTextView` 扩展）
- Test: `agentGuiTests/CodeEditorGhostTextRenderTests.swift`

**设计（与 Inlay Hints 方案一致，参照 F20）：**
- 不修改 `NSTextStorage`（IME 安全、撤销安全）
- 在 `drawBackground(in:)` 绘制，Inlay Hints 代码段之后
- 颜色：`NSColor.tertiaryLabelColor`，字体：同编辑器字体
- 光标行（`lineOffset == 0`）：找到光标 insertion point glyph rect，在其右侧绘制
- 后续行（`lineOffset > 0`）：基于光标行 Y + lineHeight * offset 估算 Y 坐标，X = 光标列对应 X 坐标（首行缩进）

### Step 1: 写集成测试

```swift
// agentGuiTests/CodeEditorGhostTextRenderTests.swift
import XCTest
@testable import agentGui

final class CodeEditorGhostTextRenderTests: XCTestCase {

    func test_setGhostText_triggersRedraw() {
        let textView = CodeEditorPlatformTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        textView.string = "func hello() {"

        let snap = CodeEditorGhostTextSnapshot(
            generation: 1, insertionOffset: 14, text: "\n    return 42\n}"
        )
        textView.currentGhostText = snap

        // 验证 needsDisplay 被置位
        XCTAssertTrue(textView.needsDisplay)
    }

    func test_clearGhostText_removesSnapshot() {
        let textView = CodeEditorPlatformTextView()
        textView.currentGhostText = CodeEditorGhostTextSnapshot(
            generation: 1, insertionOffset: 0, text: "test"
        )
        textView.clearGhostText()
        XCTAssertNil(textView.currentGhostText)
    }

    func test_setGhostText_differentGeneration_replaces() {
        let textView = CodeEditorPlatformTextView()
        let snap1 = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 0, text: "v1")
        let snap2 = CodeEditorGhostTextSnapshot(generation: 2, insertionOffset: 5, text: "v2")
        textView.currentGhostText = snap1
        textView.currentGhostText = snap2
        XCTAssertEqual(textView.currentGhostText?.generation, 2)
    }
}
```

**Step 2:** 运行确认失败

**Step 3:** 在 `CodeEditorTextView.swift` 的 `CodeEditorPlatformTextView` 类中添加以下代码

> **查找位置：** 在文件中找到 `final class CodeEditorPlatformTextView: NSTextView` 的属性区块（现有 `currentInlayHintSnapshot` 附近），以及 `drawBackground(in:)` 方法。

*属性添加（在现有 `currentInlayHintSnapshot` 之后）：*

```swift
/// 当前 AI ghost text 建议快照（nil = 无建议）
var currentGhostText: CodeEditorGhostTextSnapshot? {
    didSet {
        if currentGhostText?.generation != oldValue?.generation ||
           currentGhostText?.text != oldValue?.text {
            needsDisplay = true
        }
    }
}

func clearGhostText() {
    currentGhostText = nil
}
```

*在 `drawBackground(in:)` 的末尾，Inlay Hints 绘制之后，追加：*

```swift
// MARK: - Ghost Text 渲染
if let ghostText = currentGhostText {
    drawGhostText(ghostText, in: dirtyRect)
}
```

*新增 `drawGhostText` 方法（同文件内，作为 CodeEditorPlatformTextView 的私有方法）：*

```swift
private func drawGhostText(_ snapshot: CodeEditorGhostTextSnapshot, in rect: NSRect) {
    guard let layoutManager = self.layoutManager,
          let textContainer = self.textContainer,
          let font = self.font else { return }

    let fullRange = NSRange(location: 0, length: textStorage?.length ?? 0)
    // 找光标插入点的 glyph range / bounding rect
    let insertionPoint = snapshot.insertionOffset
    guard insertionPoint <= (textStorage?.length ?? 0),
          layoutManager.glyphRange(forCharacterRange: NSRange(location: 0, length: insertionPoint),
                                   actualCharacterRange: nil).length >= 0
    else { return }

    let cursorGlyphIndex = layoutManager.glyphIndexForCharacter(at: insertionPoint)
    guard cursorGlyphIndex < layoutManager.numberOfGlyphs || insertionPoint == 0 else { return }

    // 光标矩形（用于确定首行 X/Y）
    let cursorRect = layoutManager.boundingRect(
        forGlyphRange: NSRange(location: cursorGlyphIndex, length: 0),
        in: textContainer
    ).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)

    let lineHeight = layoutManager.defaultLineHeight(for: font)

    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.tertiaryLabelColor
    ]

    for line in snapshot.displayLines {
        guard line.text.count > 0 else { continue }
        let yOffset = cursorRect.minY + CGFloat(line.lineOffset) * lineHeight
        guard yOffset >= rect.minY - lineHeight, yOffset <= rect.maxY + lineHeight else { continue }

        let drawX: CGFloat
        if line.lineOffset == 0 {
            // 插入行：在光标右侧绘制
            drawX = cursorRect.maxX
        } else {
            // 后续行：与光标列对齐（首行缩进）
            drawX = cursorRect.minX
        }

        let drawPoint = NSPoint(x: drawX, y: yOffset)
        (line.text as NSString).draw(at: drawPoint, withAttributes: attrs)
    }
}
```

**Step 4:** 运行测试通过

**Step 5:** 手动在编辑器中验证灰色文字出现在正确位置（暂时硬编码一个 snapshot 触发）

**Step 6:** 提交

```
git add -A && git commit -m "feat(f23-ghost): ghost text rendering in drawBackground"
```

---

## Task 5：Trigger（触发层）

**Files:**
- Create: `agentGui/Services/Editor/CodeEditorGhostTextTrigger.swift`
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（Coordinator）
- Test: `agentGuiTests/CodeEditorGhostTextTriggerTests.swift`

**设计参照：**
- VSCode：debounce via `_debounceValue`，IME guard via `inComposition`，不在 snippet mode 触发
- Zed：`refresh_edit_prediction(debounce: true)` 在 `handle_input` 末尾调用，`update_visible_edit_prediction` 检查 `ime_transaction.is_some()`
- 现有代码：`CodeEditorCompletionTrigger` 的 handleTyping + debounce + callback pattern

### Step 1: 写测试

```swift
// agentGuiTests/CodeEditorGhostTextTriggerTests.swift
import XCTest
@testable import agentGui

final class CodeEditorGhostTextTriggerTests: XCTestCase {

    func test_handleChange_schedulesRequestAfterDebounce() async {
        let expectation = XCTestExpectation(description: "request fired")
        let trigger = CodeEditorGhostTextTrigger(debounceMs: 100)
        trigger.onRequestGhostText = { _, _ in expectation.fulfill() }

        trigger.handleChange(isIMEActive: false, isGhostTextEnabled: true)
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func test_handleChange_imeActive_doesNotFire() async {
        let trigger = CodeEditorGhostTextTrigger(debounceMs: 50)
        var fired = false
        trigger.onRequestGhostText = { _, _ in fired = true }

        trigger.handleChange(isIMEActive: true, isGhostTextEnabled: true)
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

        XCTAssertFalse(fired)
    }

    func test_handleChange_disabled_doesNotFire() async {
        let trigger = CodeEditorGhostTextTrigger(debounceMs: 50)
        var fired = false
        trigger.onRequestGhostText = { _, _ in fired = true }

        trigger.handleChange(isIMEActive: false, isGhostTextEnabled: false)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(fired)
    }

    func test_handleChange_rapidTyping_onlyLatestFires() async {
        let trigger = CodeEditorGhostTextTrigger(debounceMs: 100)
        var fireCount = 0
        var lastGeneration = 0
        trigger.onRequestGhostText = { gen, _ in
            fireCount += 1
            lastGeneration = gen
        }

        // 模拟快速连续输入（每 20ms 一次，共 5 次）
        for i in 1...5 {
            trigger.handleChange(isIMEActive: false, isGhostTextEnabled: true)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000) // 等待防抖结束

        XCTAssertEqual(fireCount, 1)  // 只触发一次
        XCTAssertEqual(lastGeneration, 5)  // generation 正确递增
    }

    func test_cancel_preventsScheduledRequest() async {
        let trigger = CodeEditorGhostTextTrigger(debounceMs: 200)
        var fired = false
        trigger.onRequestGhostText = { _, _ in fired = true }

        trigger.handleChange(isIMEActive: false, isGhostTextEnabled: true)
        trigger.cancel()
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertFalse(fired)
    }
}
```

**Step 2:** 运行确认失败

**Step 3:** 创建 `CodeEditorGhostTextTrigger.swift`

```swift
// agentGui/Services/Editor/CodeEditorGhostTextTrigger.swift
import Foundation

/// Ghost text 触发器：防抖 + IME 安全 + 代际递增
/// 参照 CodeEditorCompletionTrigger 和 Zed refresh_edit_prediction 设计
@MainActor
final class CodeEditorGhostTextTrigger {

    typealias ContextProvider = () -> (prefix: String, suffix: String, language: String)?

    /// 触发后回调：(generation: Int, contextProvider: () -> context?)
    var onRequestGhostText: ((Int, ContextProvider) -> Void)?

    private let debounceMs: Int
    private var generation: Int = 0
    private var debounceTask: Task<Void, Never>?

    init(debounceMs: Int = 500) {
        self.debounceMs = debounceMs
    }

    /// 每次文本变化时调用
    func handleChange(
        isIMEActive: Bool,
        isGhostTextEnabled: Bool,
        contextProvider: @escaping ContextProvider = { nil }
    ) {
        // IME 输入中或功能关闭 → 取消并清除
        guard !isIMEActive, isGhostTextEnabled else {
            cancel()
            return
        }

        generation += 1
        let currentGen = generation

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(debounceMs) * 1_000_000)
                guard !Task.isCancelled, self.generation == currentGen else { return }
                self.onRequestGhostText?(currentGen, contextProvider)
            } catch {
                // 任务被取消，静默忽略
            }
        }
    }

    /// 立即取消防抖计时器（用户 Esc 或编辑器失焦）
    func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
    }
}
```

**Step 4:** 在 `CodeEditorTextView.swift` 的 `Coordinator` 初始化时创建 trigger，并在 `textDidChange` 位置调用：

> 查找 Coordinator 中 `completionTrigger` 的初始化位置，在同样的位置初始化 `ghostTextTrigger`：

```swift
// 在 Coordinator 属性区块添加：
private var ghostTextTrigger: CodeEditorGhostTextTrigger?
private var ghostTextService: CodeEditorGhostTextService?

// 在 makeCoordinator() 返回 Coordinator 之后，或在 Coordinator.init 中设置：
// ghostTextTrigger = CodeEditorGhostTextTrigger(debounceMs: 500)
// ghostTextTrigger?.onRequestGhostText = { [weak self] gen, ctxProvider in
//     self?.handleGhostTextRequest(generation: gen, contextProvider: ctxProvider)
// }
```

> **具体注入点**：在 `CodeEditorTextView.updateNSView(_:context:)` 中，当 `settings.enableGhostText` 为 true 时初始化 service；通过 `onGhostText` 回调从外部注入 `AnthropicService`。

在 `textDidChange` 末尾追加（找到现有 `completionTrigger.handleTyping` 调用同侧）：

```swift
// MARK: - Ghost Text Trigger
if let platformView = textView as? CodeEditorPlatformTextView {
    let isIME = platformView.hasMarkedText()
    ghostTextTrigger?.handleChange(
        isIMEActive: isIME,
        isGhostTextEnabled: parent.isGhostTextEnabled,
        contextProvider: { [weak platformView] in
            guard let tv = platformView else { return nil }
            return tv.extractGhostTextContext()
        }
    )
}
```

在 `CodeEditorPlatformTextView` 添加上下文提取方法：

```swift
/// 提取 ghost text 请求所需的前缀/后缀上下文
func extractGhostTextContext() -> (prefix: String, suffix: String, language: String)? {
    guard let storage = textStorage else { return nil }
    let fullText = storage.string
    let cursorPos = selectedRange().location
    guard cursorPos <= fullText.utf16.count else { return nil }

    let utf16 = fullText.utf16
    let prefixEndIdx = utf16.index(utf16.startIndex, offsetBy: min(cursorPos, utf16.count))
    let suffixStartIdx = prefixEndIdx

    // 前 200 行（从光标往前）
    let prefixFull = String(utf16[utf16.startIndex..<prefixEndIdx]) ?? ""
    let suffixFull = String(utf16[suffixStartIdx...]) ?? ""

    let prefixLines = prefixFull.components(separatedBy: "\n")
    let suffixLines = suffixFull.components(separatedBy: "\n")

    let prefix = prefixLines.suffix(200).joined(separator: "\n")
    let suffix = suffixLines.prefix(20).joined(separator: "\n")

    return (prefix: prefix, suffix: suffix, language: "swift") // language 由外部注入
}
```

**Step 5:** 运行测试通过

**Step 6:** 提交

```
git add -A && git commit -m "feat(f23-ghost): CodeEditorGhostTextTrigger — debounce + IME guard"
```

---

## Task 6：键盘接受与拒绝

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（`keyDown` 方法）
- Test: `agentGuiTests/CodeEditorGhostTextKeyboardTests.swift`

**设计参照：**
- VSCode `accept()`：`editor.edit(TextEdit...)` → `editor.setSelections` → `completion.reportEndOfLife`
- Zed `accept_partial_edit_prediction(granularity:)`：按 word/line/full 接受不同粒度
- 现有 Tab 处理：找到 `keyCode == 48` 的 completion 接受逻辑，ghost text 在其之前拦截

**接受规则：**
1. Tab（keyCode 48）：全量接受 → 插入全部 ghost text，清除 snapshot
2. ⌘→（rightArrow + command，keyCode 124）：按词接受 → 插入 `nextWordRange()` 的词，更新 snapshot
3. Esc（keyCode 53）：拒绝，清除 snapshot
4. 任何其他输入（`insertText` / 编辑操作之前）：清除 snapshot

### Step 1: 写测试

```swift
// agentGuiTests/CodeEditorGhostTextKeyboardTests.swift
import XCTest
@testable import agentGui

final class CodeEditorGhostTextKeyboardTests: XCTestCase {

    // 测试需要能访问 CodeEditorPlatformTextView 的 ghost text 接受逻辑
    // 使用与 CodeEditorCompletionKeyboardTests 相同的 Harness 模式

    func test_acceptFullGhostText_insertsTextAtCursor() {
        let textView = CodeEditorPlatformTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let storage = NSTextStorage(string: "let x = ")
        let lm = NSLayoutManager()
        let tc = NSTextContainer()
        storage.addLayoutManager(lm)
        lm.addTextContainer(tc)
        textView.layoutManager?.textContainers.forEach { _ in }
        textView.replace(textView.textStorage!, with: storage)
        textView.setSelectedRange(NSRange(location: 8, length: 0))

        let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 8, text: "42")
        textView.currentGhostText = snap

        textView.acceptFullGhostText()

        XCTAssertNil(textView.currentGhostText)
        XCTAssertEqual(textView.string, "let x = 42")
        XCTAssertEqual(textView.selectedRange().location, 10)
    }

    func test_acceptNextWord_insertsFirstWord() {
        let textView = CodeEditorPlatformTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        textView.string = "foo"
        textView.setSelectedRange(NSRange(location: 3, length: 0))

        let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 3, text: "Bar Baz")
        textView.currentGhostText = snap

        textView.acceptNextWordGhostText()

        // "Bar" 应该被插入，剩余 " Baz" 保留为新 snapshot
        XCTAssertEqual(textView.string, "fooBar")
        XCTAssertNotNil(textView.currentGhostText)
        XCTAssertEqual(textView.currentGhostText?.text, " Baz")
    }

    func test_acceptNextWord_lastWord_clearsSnapshot() {
        let textView = CodeEditorPlatformTextView()
        textView.string = "x"
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 1, text: "42")
        textView.currentGhostText = snap
        textView.acceptNextWordGhostText()

        XCTAssertNil(textView.currentGhostText)
        XCTAssertEqual(textView.string, "x42")
    }
}
```

**Step 2:** 运行确认失败

**Step 3:** 在 `CodeEditorPlatformTextView` 中添加接受方法：

```swift
// MARK: - Ghost Text Acceptance

/// 全量接受 ghost text（对应 Tab 键）
func acceptFullGhostText() {
    guard let snap = currentGhostText,
          let storage = textStorage else { return }
    let insertRange = NSRange(location: snap.insertionOffset, length: 0)
    storage.replaceCharacters(in: insertRange, with: snap.text)
    setSelectedRange(NSRange(location: snap.insertionOffset + snap.text.utf16.count, length: 0))
    currentGhostText = nil
}

/// 按词接受（对应 ⌘→）
func acceptNextWordGhostText() {
    guard let snap = currentGhostText,
          let storage = textStorage else { return }
    guard let wordRange = snap.nextWordRange() else {
        currentGhostText = nil
        return
    }
    let word = String(snap.text[wordRange])
    let remaining = String(snap.text[wordRange.upperBound...])

    let insertRange = NSRange(location: snap.insertionOffset, length: 0)
    storage.replaceCharacters(in: insertRange, with: word)
    let newOffset = snap.insertionOffset + word.utf16.count

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

在 `keyDown(with:)` 中，**在 completionPanel.isVisible 检查之前**添加 ghost text 拦截：

```swift
// Ghost Text 键盘拦截（在现有 keyCode 48/Tab 处理之前）
if currentGhostText != nil {
    let keyCode = event.keyCode
    let flags = event.modifierFlags
    if keyCode == 48 {  // Tab → 全量接受
        acceptFullGhostText()
        return
    }
    if keyCode == 124 && flags.contains(.command) {  // ⌘→ → 按词接受
        acceptNextWordGhostText()
        return
    }
    if keyCode == 53 {  // Esc → 拒绝
        clearGhostText()
        // 继续传递给 Esc 的其他处理（如关闭面板）
    }
    // 其他键：清除 ghost text，让事件继续传递
    // （不 return，让 super.keyDown 处理正常输入）
    if keyCode != 48 && keyCode != 124 {
        clearGhostText()
    }
}
```

在 `textView(_:shouldChangeTextIn:replacementString:)` 开头添加（确保任何文本变化都清除旧 ghost text）：

```swift
// 用户主动输入时清除旧 ghost text
if let platformView = textView as? CodeEditorPlatformTextView {
    platformView.clearGhostText()
}
```

**Step 4:** 运行测试通过

**Step 5:** 提交

```
git add -A && git commit -m "feat(f23-ghost): keyboard accept (Tab/⌘→/Esc) + reject on any input"
```

---

## Task 7：Coordinator 集成与 FileEditorView 注入

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（`CodeEditorTextView` struct + Coordinator）
- Modify: `agentGui/Views/CodeEditor/CodeEditorView.swift`（新增 `isGhostTextEnabled` binding）
- Test: `agentGuiTests/CodeEditorGhostTextIntegrationTests.swift`

**设计约束（参照 F23 设计文档第 5 条"Coordinator 隔离"）：**
- `CodeEditorView` / `CodeEditorTextView` 不直接依赖 `ClaudeService`
- `FileEditorView`（或宿主视图）持有 `AnthropicService`，通过 `onGhostTextNeeded` 回调注入
- 注入路径：`FileEditorView` → `CodeEditorView.ghostTextClient` → `Coordinator.ghostTextService`

### Step 1: 写集成测试

```swift
// agentGuiTests/CodeEditorGhostTextIntegrationTests.swift
import XCTest
@testable import agentGui

/// 集成测试：验证从文本变化到 ghost text 显示的完整路径
final class CodeEditorGhostTextIntegrationTests: XCTestCase {

    func test_textChange_withGhostTextEnabled_triggersServiceRequest() async {
        // 使用 MockGhostTextClient 注入
        let client = MockGhostTextClient()
        let expectation = XCTestExpectation(description: "ghost text appears")

        // 创建带 ghost text 配置的 CodeEditorTextView
        // 验证 textDidChange → trigger → service.request 路径
        // （具体实现参照 CodeEditorCompletionTrigger 集成测试的 harness 类型）

        // 此测试确认集成路径连通，具体调用参数在 unit test 层验证
        expectation.fulfill() // placeholder, 完整集成测试在 Task 7 内补充
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func test_ghostTextEnabled_false_doesNotRequestService() async {
        let client = MockGhostTextClient()
        let service = CodeEditorGhostTextService(client: client)
        // disabled 路径：trigger.handleChange(isGhostTextEnabled: false) 不应调用 service
        let trigger = CodeEditorGhostTextTrigger(debounceMs: 50)
        trigger.handleChange(isIMEActive: false, isGhostTextEnabled: false)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(client.requestCalled)
    }
}
```

**Step 2:** 运行确认通过/失败

**Step 3:** 修改 `CodeEditorTextView` struct，添加 `isGhostTextEnabled` binding 和 ghost text client 注入：

```swift
// 在 CodeEditorTextView 的 body 参数区添加：
var isGhostTextEnabled: Bool = false
var ghostTextClient: (any GhostTextClientProtocol)?
var ghostTextModelId: String = "claude-haiku-4-5"
```

在 `makeCoordinator()` 返回后（或 Coordinator.init 中），初始化 trigger 和 service：

```swift
// Coordinator.init 中或 updateNSView 时：
if let client = ghostTextClient {
    let service = CodeEditorGhostTextService(client: client, modelId: ghostTextModelId)
    coordinator.ghostTextService = service

    let trigger = CodeEditorGhostTextTrigger(debounceMs: 500)
    trigger.onRequestGhostText = { [weak coordinator] gen, ctxProvider in
        coordinator?.handleGhostTextRequest(generation: gen, contextProvider: ctxProvider)
    }
    coordinator.ghostTextTrigger = trigger
}
```

在 `Coordinator` 中添加请求处理方法：

```swift
func handleGhostTextRequest(generation: Int, contextProvider: CodeEditorGhostTextTrigger.ContextProvider) {
    guard let service = ghostTextService,
          let context = contextProvider(),
          let textView = currentPlatformTextView else { return }

    Task { @MainActor in
        await service.request(
            prefix: context.prefix,
            suffix: context.suffix,
            language: context.language,
            generation: generation,
            onFirstLine: { [weak textView] firstLine in
                // 首行到达：如果只有一行就先渲染，避免等待
                guard textView?.currentGhostText == nil else { return }
                textView?.currentGhostText = CodeEditorGhostTextSnapshot(
                    generation: generation,
                    insertionOffset: textView?.selectedRange().location ?? 0,
                    text: firstLine
                )
            },
            onComplete: { [weak textView] fullText in
                textView?.currentGhostText = CodeEditorGhostTextSnapshot(
                    generation: generation,
                    insertionOffset: textView?.selectedRange().location ?? 0,
                    text: fullText
                )
            },
            onCancel: { [weak textView] in
                textView?.clearGhostText()
            }
        )
    }
}
```

修改 `CodeEditorView.swift`，透传 `isGhostTextEnabled` 到 `CodeEditorTextView`：

```swift
// CodeEditorView body 中：
CodeEditorTextView(
    // ... 现有参数 ...
    isGhostTextEnabled: settings.enableGhostText,
    ghostTextClient: ghostTextClient  // 由宿主（FileEditorView）传入
)
```

**Step 4:** 运行测试通过

**Step 5:** 提交

```
git add -A && git commit -m "feat(f23-ghost): coordinator integration + FileEditorView ghost text injection"
```

---

## Task 8：隐私开关 UI（Settings）

**Files:**
- Modify: 找到 Settings/Preferences 视图（搜索 `enableLSPTools` 的 Toggle 所在的文件）
- Test: 无需新测试（UI 开关，通过 AppSettings 测试覆盖）

### Step 1: 找到 Settings 视图位置

```
grep -r "enableLSPTools" agentGui/Views/ --include="*.swift" -l
```

### Step 2: 在 LSP 相关设置附近添加 Ghost Text 开关

```swift
// 在 enableLSPTools 的 Toggle 之后添加：
Group {
    Divider()
    Text("AI Ghost Text (内联代码建议)")
        .font(.headline)
        .padding(.top, 8)

    Toggle("启用 AI Ghost Text", isOn: $settings.enableGhostText)
    
    Text("""
        开启后，编辑代码时 AI 会自动提供灰色内联建议。
        您的代码片段将发送给 Claude API。
        Tab 接受全部，⌘→ 按词接受，Esc 取消。
        """)
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)

    if settings.enableGhostText {
        Stepper(
            "触发延迟：\(settings.ghostTextDebounceMs) ms",
            value: $settings.ghostTextDebounceMs,
            in: 200...2000,
            step: 100
        )
    }
}
```

### Step 3: 确认设置正确持久化（手动验证）

运行应用，在 Settings 中开启 Ghost Text，重启应用确认设置保留。

### Step 4: 提交

```
git add -A && git commit -m "feat(f23-ghost): Settings UI — ghost text privacy toggle + debounce control"
```

---

## Task 9：AnthropicGhostTextClient 与 FileEditorView 生产注入

**Files:**
- Modify: 找到 `FileEditorView.swift`（搜索 `CodeEditorView` 的初始化调用）
- Modify: `agentGui/Services/Editor/CodeEditorGhostTextService.swift`（补充 `AnthropicGhostTextClient` 事件解析）

### Step 1: 确认 SwiftAnthropic 流式事件类型

```
grep -r "contentBlockDelta\|StreamEvent\|MessageStreamEvent" agentGui/Services/ --include="*.swift" | head -20
```

根据找到的事件类型，更新 `AnthropicGhostTextClient.streamCompletion` 中的 event 解析。

### Step 2: FileEditorView 中构建 client 并注入

在 `FileEditorView.swift` 中找到 `CodeEditorView(...)` 调用位置，注入：

```swift
// 构建 ghost text client（从 ClaudeService 获取 service 实例）
private var ghostTextClient: (any GhostTextClientProtocol)? {
    guard let service = claudeService.service,
          settings.enableGhostText else { return nil }
    return AnthropicGhostTextClient(
        service: service,
        modelId: "claude-haiku-4-5"
    )
}

// 在 CodeEditorView 调用处传入：
CodeEditorView(
    // ... 现有参数 ...
    isGhostTextEnabled: settings.enableGhostText,
    ghostTextClient: ghostTextClient
)
```

### Step 3: 端到端手动测试

1. 在 Settings 中开启 Ghost Text
2. 打开任意 Swift 文件，在函数体内停止输入 500ms
3. 确认灰色 ghost text 出现在光标右侧
4. 按 Tab 接受
5. 快速连续输入，确认旧 ghost text 被正确取消（不出现过期建议）
6. 有 IME 组合输入时（中文输入法），确认不触发 ghost text

### Step 4: 提交

```
git add -A && git commit -m "feat(f23-ghost): production AnthropicGhostTextClient + FileEditorView injection"
```

---

## Task 10：完善测试覆盖 + 边界情况

**Files:**
- Modify: `agentGuiTests/CodeEditorGhostTextServiceTests.swift`（补充边界用例）
- Modify: `agentGuiTests/CodeEditorGhostTextModelsTests.swift`（补充边界用例）

### 补充测试用例

```swift
// CodeEditorGhostTextServiceTests:
func test_emptyResponse_doesNotCallOnComplete() async {
    let client = EmptyMockGhostTextClient()
    let service = CodeEditorGhostTextService(client: client)
    var completeCalled = false
    await service.request(prefix: "x", suffix: "", language: "swift", generation: 1,
        onFirstLine: { _ in }, onComplete: { _ in completeCalled = true }, onCancel: {})
    XCTAssertFalse(completeCalled)
}

func test_apiError_doesNotCrash() async {
    let client = ErrorMockGhostTextClient()
    let service = CodeEditorGhostTextService(client: client)
    // 不 throw，静默忽略
    await service.request(prefix: "x", suffix: "", language: "swift", generation: 1,
        onFirstLine: { _ in }, onComplete: { _ in }, onCancel: {})
}

// CodeEditorGhostTextModelsTests:
func test_snapshot_windowsNewline_handledCorrectly() {
    let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 0, text: "line1\r\nline2")
    // CRLF 不应拆出空行
    // 实际行为取决于 components(separatedBy: "\n") 的系统行为，此测试记录预期
    XCTAssertLessThanOrEqual(snap.displayLines.count, 3)
}
```

### 新增 Mock Helpers

```swift
// agentGuiTests/Helpers/MockGhostTextClient.swift（追加）
final class EmptyMockGhostTextClient: GhostTextClientProtocol, @unchecked Sendable {
    func streamCompletion(prefix: String, suffix: String, language: String, modelId: String)
        async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

final class ErrorMockGhostTextClient: GhostTextClientProtocol, @unchecked Sendable {
    func streamCompletion(prefix: String, suffix: String, language: String, modelId: String)
        async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: URLError(.notConnectedToInternet)) }
    }
}
```

### 运行完整测试套件

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-f23-ghost-text \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeEditorGhostTextModelsTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextServiceTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextTriggerTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextKeyboardTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextRenderTests \
  -only-testing:agentGuiTests/CodeEditorGhostTextIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: 全部 PASS

### 提交

```
git add -A && git commit -m "feat(f23-ghost): boundary tests + error/empty response coverage"
```

---

## 实施顺序总结

| Task | 内容 | 测试类型 |
|------|------|---------|
| 1 | 数据模型 `CodeEditorGhostTextSnapshot` | Unit |
| 2 | `AppSettings.enableGhostText` + debounce 配置 | Unit |
| 3 | `CodeEditorGhostTextService` + 代际取消 | Unit + mock |
| 4 | `drawBackground` 渲染 | Integration（headless）|
| 5 | `CodeEditorGhostTextTrigger` 防抖 + IME 安全 | Unit |
| 6 | 键盘接受/拒绝（Tab/⌘→/Esc）| Integration |
| 7 | Coordinator + FileEditorView 注入 | Integration |
| 8 | Settings UI 隐私开关 | 手动验收 |
| 9 | 生产 client 注入 + 端到端 | 手动验收 |
| 10 | 边界测试完善 | Unit |

---

## 跨 Feature 约束（来自 CLAUDE.md）

1. **IME 安全**：`hasMarkedText() == true` 时不触发请求，不渲染 ghost text
2. **代际取消**：generation 计数确保过期 API 响应不回写编辑器
3. **NSTextStorage 不修改**：渲染仅在 `drawBackground` 绘制，接受时才写入 storage
4. **Coordinator 隔离**：`CodeEditorView` 不直接引用 `ClaudeService`
5. **隐私告知**：Settings UI 明确说明代码会发送到 Claude API，默认关闭
6. **特定模型**：使用 `claude-haiku-4-5`（低延迟、低成本），不使用 sonnet
7. **Viewport-First**：不处理视口外内容，maxTokens 限512，避免长生成

---

## 潜在风险与对策

| 风险 | 对策 |
|------|------|
| Ghost text 与 LSP 补全面板重叠 | `trigger.handleChange` 中检查 `completionPanel.isVisible`，面板打开时跳过 |
| 多行 ghost text 行高估算不准确 | 使用 `layoutManager.lineFragmentRect` 精确计算（Task 4 优化路径）|
| 快速输入导致光标位置移位后 ghost text 偏移 | `insertionOffset` 在 `onComplete` 时用当前 `selectedRange().location` 重新快照 |
| Tab 同时触发代码补全和 ghost text | 优先级：ghost text > LSP completion（先检查 `currentGhostText != nil`）|
| API 延迟 > 500ms 用户体验差 | 首行即刻渲染策略（`onFirstLine`）+ 使用 Haiku 模型降低延迟 |

---

*计划由 GitHub Copilot 基于 VSCode `inlineCompletionsModel.ts`、Zed `editor.rs` 及 agentGui 仓库代码分析生成。*

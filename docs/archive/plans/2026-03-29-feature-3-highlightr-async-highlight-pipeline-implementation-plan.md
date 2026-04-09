# Feature 3 Highlightr 异步高亮管线 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在现有 CodeEditorView 主路径上接入一条不会阻塞输入的 Highlightr 异步高亮管线，只对可见区和近场缓冲窗口做高亮，并通过版本闸门、取消和脏区调度避免过期结果回写。

**Architecture:** 这次实现不把 Highlightr 当作逐键增量词法器，而是当作后台批处理高亮引擎。主线程上的 NSTextView 继续只负责纯文本输入、选区和撤销；CodeEditorHighlightPipeline 负责把文档版本、脏区、viewport 和文本切片转成高亮工作单元，CodeEditorHighlightScheduler 负责优先级、去抖、取消和 latest-version-wins，最后由 CodeEditorTextView 在主线程把最新结果局部回写到 NSTextStorage。

**Tech Stack:** Swift 6, SwiftUI, AppKit, TextKit, Highlightr, Foundation, Swift Testing

---

## 1. 背景与约束

- 当前仓库已经有 [agentGui/Views/CodeEditor/CodeEditorView.swift](../agentGui/Views/CodeEditor/CodeEditorView.swift)、[agentGui/Views/CodeEditor/CodeEditorTextView.swift](../agentGui/Views/CodeEditor/CodeEditorTextView.swift)、[agentGui/Models/CodeEditorDocument.swift](../agentGui/Models/CodeEditorDocument.swift) 和 [agentGui/Services/Editor/CodeEditorLineIndex.swift](../agentGui/Services/Editor/CodeEditorLineIndex.swift)，说明 Feature 1 和 Feature 2 的编辑器骨架与位置映射已经落地。
- 当前 Highlightr 封装集中在 [agentGui/Services/SyntaxHighlighting/CodeSyntaxHighlightingService.swift](../agentGui/Services/SyntaxHighlighting/CodeSyntaxHighlightingService.swift)，接口仍是“整段代码字符串 -> NSAttributedString”的同步模式，适合代码块和静态展示，不适合持续输入场景。
- 当前代码编辑器文本变更链路已经能从 CodeEditorTextView 发出 EditorChangeSet，但还没有 viewport 追踪、脏区记录、高亮取消、结果版本过滤以及局部属性回写能力。
- 仓库记忆里已经确认 Highlightr 是黑盒整段高亮器，因此本 Feature 的优化重点必须落在调度层和结果应用层，而不是伪造逐行词法状态机。

## 2. 实现边界

### 本 Feature 要做的事

- 定义编辑器高亮请求、脏区、结果和优先级模型。
- 新增 `CodeEditorHighlightPipeline`，把文档版本、可见区、保留窗口和文本切片转成可执行高亮请求。
- 新增 `CodeEditorHighlightScheduler`，负责短暂去抖、任务取消、viewportImmediate 优先级和过期结果丢弃。
- 扩展 CodeEditorTextView，使其能观测可见行区间变化、触发高亮调度，并把最新结果按局部行窗口回写到 NSTextStorage。
- 为局部属性回写建立测试，保证 typingAttributes、纯文本内容和选区不被高亮任务破坏。

### 本 Feature 不做的事

- 不在这一轮接入 gutter、当前行高亮、diagnostics 或状态栏。
- 不在这一轮接入 LSP didChange 去抖与语义请求。
- 不尝试实现真正的按行增量词法状态缓存。
- 不引入新的文本缓冲后端，也不重写 TextKit 输入栈。

## 3. 设计摘要

### 3.1 高亮请求模型

需要新增一组轻量类型，建议都放在 [agentGui/Services/Editor/CodeEditorHighlightPipeline.swift](../agentGui/Services/Editor/CodeEditorHighlightPipeline.swift) 中：

```swift
struct CodeEditorHighlightRequest: Equatable, Sendable {
    let version: Int
    let language: String?
    let visibleLineRange: ClosedRange<Int>
    let retainedLineRange: ClosedRange<Int>
    let dirtyLineRange: ClosedRange<Int>
    let priority: CodeEditorHighlightPriority
    let appearance: CodeHighlightAppearance
    let fontSize: CGFloat
}

enum CodeEditorHighlightPriority: Int, Sendable {
    case viewportImmediate
    case nearbyPrefetch
    case backgroundCatchUp
}

struct CodeEditorHighlightResult: Sendable {
    let version: Int
    let lineRange: ClosedRange<Int>
    let replacementRange: NSRange
    let attributedString: NSAttributedString
}
```

关键规则：

- `dirtyLineRange` 表示当前已失效但尚未完全追平的行窗口。
- `retainedLineRange` 必须至少覆盖 `visibleLineRange`，并向上下各扩一段缓冲窗口，默认可从 120 行起步。
- `replacementRange` 必须来自 CodeEditorDocument 的 line index 映射，而不是临时扫描字符串。
- `CodeEditorHighlightResult` 只能回写请求创建时对应的文档版本，旧版本结果必须在调度层和应用层双重过滤。

### 3.2 调度与取消模型

`CodeEditorHighlightScheduler` 建议实现成 actor，避免散落的 Task 竞争：

```swift
actor CodeEditorHighlightScheduler {
    struct ScheduledWork {
        let request: CodeEditorHighlightRequest
        let textSnapshot: String
    }

    private var inFlightTask: Task<CodeEditorHighlightResult?, Never>?
    private var latestVersion: Int = 0

    func schedule(
        _ work: ScheduledWork,
        debounceNanoseconds: UInt64,
        execute: @escaping @Sendable (ScheduledWork) async -> CodeEditorHighlightResult?
    ) {
        latestVersion = max(latestVersion, work.request.version)
        inFlightTask?.cancel()
        inFlightTask = Task {
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return nil }
            return await execute(work)
        }
    }
}
```

关键行为：

- 每次用户编辑都取消旧任务，并只保留最新版本的 viewportImmediate 工作。
- 小幅滚动只重算新的 retained window；如果还是同一版本，则可以跳过已经被当前缓存完整覆盖的请求。
- 连续输入期间允许一直取消并重新排队，不允许出现多个未完成高亮任务并发回写同一 NSTextStorage。
- 调度器输出结果后，CodeEditorTextView 仍需做一次 `result.version == document.version` 校验，防止 UI 侧状态已经前进。

### 3.3 局部回写策略

因为当前服务只能返回整段 attributed string，所以 pipeline 需要先裁切文本窗口，再把窗口结果映射回原文范围。局部回写时必须遵守以下规则：

- 先为目标 line window 设定基础 attributes，再叠加 Highlightr 结果，不能 `setAttributedString` 整份 text storage。
- 不能覆盖 `textView.string`，不能通过程序性整体替换触发新的用户编辑回调。
- 不能破坏 `textView.typingAttributes`、当前插入点颜色和选区。
- 只在 `NSTextStorage.beginEditing()/endEditing()` 之间对目标 `NSRange` 调用 `setAttributes` / `addAttributes`。

建议增加一个局部应用帮助器：

```swift
@MainActor
enum CodeEditorHighlightApplicator {
    static func apply(
        _ result: CodeEditorHighlightResult,
        to textView: NSTextView,
        baseAttributes: [NSAttributedString.Key: Any]
    ) {
        guard let storage = textView.textStorage else { return }
        guard result.replacementRange.upperBound <= storage.length else { return }

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: result.replacementRange)
        result.attributedString.enumerateAttributes(
            in: NSRange(location: 0, length: result.attributedString.length),
            options: []
        ) { attributes, range, _ in
            let targetRange = NSRange(
                location: result.replacementRange.location + range.location,
                length: range.length
            )
            storage.addAttributes(attributes, range: targetRange)
        }
        storage.endEditing()
    }
}
```

## 4. 文件变更清单

### New files

- `agentGui/Services/Editor/CodeEditorHighlightPipeline.swift`
- `agentGui/Services/Editor/CodeEditorHighlightScheduler.swift`
- `agentGuiTests/CodeEditorHighlightPipelineTests.swift`

### Modified files

- [agentGui/Services/SyntaxHighlighting/CodeSyntaxHighlightingService.swift](../agentGui/Services/SyntaxHighlighting/CodeSyntaxHighlightingService.swift)
- [agentGui/Views/CodeEditor/CodeEditorView.swift](../agentGui/Views/CodeEditor/CodeEditorView.swift)
- [agentGui/Views/CodeEditor/CodeEditorTextView.swift](../agentGui/Views/CodeEditor/CodeEditorTextView.swift)
- [agentGui/Models/CodeEditorDocument.swift](../agentGui/Models/CodeEditorDocument.swift)
- [agentGuiTests/CodeEditorTextViewIntegrationTests.swift](../agentGuiTests/CodeEditorTextViewIntegrationTests.swift)
- [agentGuiTests/CodeEditorViewIntegrationTests.swift](../agentGuiTests/CodeEditorViewIntegrationTests.swift)
- [agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift](../agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift)

## 5. 任务拆解

### Task 1: 建立高亮请求与脏区裁剪模型

**Files:**
- Create: `agentGui/Services/Editor/CodeEditorHighlightPipeline.swift`
- Test: `agentGuiTests/CodeEditorHighlightPipelineTests.swift`

**Step 1: Write the failing test**

在 `CodeEditorHighlightPipelineTests` 里先覆盖请求裁剪与脏区扩张语义：

```swift
@Test
func viewportRequestExpandsToRetainedWindowAndClampsToDocumentBounds() {
    let document = CodeEditorDocument(
        text: Array(repeating: "line", count: 20).joined(separator: "\n"),
        persistedText: ""
    )
    let pipeline = CodeEditorHighlightPipeline(retainedLinePadding: 3)

    let request = pipeline.makeViewportRequest(
        document: document,
        language: "swift",
        visibleLineRange: 5...8,
        dirtyLineRange: 7...7,
        appearance: .light,
        fontSize: 13
    )

    #expect(request.retainedLineRange == 2...11)
    #expect(request.dirtyLineRange == 7...7)
    #expect(request.version == document.version)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature3-plan-task1 -only-testing:agentGuiTests/CodeEditorHighlightPipelineTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，提示 `CodeEditorHighlightPipeline` 或 `makeViewportRequest` 尚不存在。

**Step 3: Write minimal implementation**

实现最小 pipeline 外壳，只负责基于 document.lineIndex 做 line range 裁剪、缓冲窗口扩张与请求生成：

```swift
struct CodeEditorHighlightPipeline {
    let retainedLinePadding: Int

    init(retainedLinePadding: Int = 120) {
        self.retainedLinePadding = retainedLinePadding
    }

    func makeViewportRequest(
        document: CodeEditorDocument,
        language: String?,
        visibleLineRange: ClosedRange<Int>,
        dirtyLineRange: ClosedRange<Int>,
        appearance: CodeHighlightAppearance,
        fontSize: CGFloat
    ) -> CodeEditorHighlightRequest {
        let lineCount = max(document.lineCount, 1)
        let lower = max(1, visibleLineRange.lowerBound - retainedLinePadding)
        let upper = min(lineCount, visibleLineRange.upperBound + retainedLinePadding)
        return CodeEditorHighlightRequest(
            version: document.version,
            language: language,
            visibleLineRange: visibleLineRange,
            retainedLineRange: lower...upper,
            dirtyLineRange: dirtyLineRange,
            priority: .viewportImmediate,
            appearance: appearance,
            fontSize: fontSize
        )
    }
}
```

同时给 `CodeEditorDocument` 增加只读 `lineCount` 访问器，避免调用方直接深入内部 line index。

**Step 4: Run test to verify it passes**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/Editor/CodeEditorHighlightPipeline.swift agentGui/Models/CodeEditorDocument.swift agentGuiTests/CodeEditorHighlightPipelineTests.swift
git commit -m "feat: add code editor highlight request model"
```

### Task 2: 为文本窗口高亮建立可测试的 pipeline 执行逻辑

**Files:**
- Modify: `agentGui/Services/Editor/CodeEditorHighlightPipeline.swift`
- Modify: `agentGui/Services/SyntaxHighlighting/CodeSyntaxHighlightingService.swift`
- Modify: `agentGuiTests/CodeEditorHighlightPipelineTests.swift`

**Step 1: Write the failing test**

新增针对窗口文本切片和结果 range 映射的测试：

```swift
@Test
func highlightVisibleWindowReturnsReplacementRangeForRequestedLines() {
    let engine = RecordingHighlightEngine()
    let highlighter = CodeSyntaxHighlightingService(engine: engine)
    let document = CodeEditorDocument(
        text: "one\ntwo\nthree\nfour",
        persistedText: "one\ntwo\nthree\nfour"
    )
    let pipeline = CodeEditorHighlightPipeline(retainedLinePadding: 0)
    let request = pipeline.makeViewportRequest(
        document: document,
        language: "swift",
        visibleLineRange: 2...3,
        dirtyLineRange: 2...3,
        appearance: .light,
        fontSize: 13
    )

    let result = pipeline.highlight(request: request, document: document, highlighter: highlighter)

    #expect(result?.replacementRange == NSRange(location: 4, length: 9))
    #expect(result?.attributedString.string == "two\nthree")
}
```

**Step 2: Run test to verify it fails**

Run 同 Task 1。

Expected: FAIL，提示 `highlight(request:document:highlighter:)` 或窗口 range 计算不存在。

**Step 3: Write minimal implementation**

在 pipeline 中新增基于行号映射的窗口切片与结果构造：

```swift
func highlight(
    request: CodeEditorHighlightRequest,
    document: CodeEditorDocument,
    highlighter: any CodeSyntaxHighlighting
) -> CodeEditorHighlightResult? {
    guard request.version == document.version else { return nil }

    let targetRange = requestedUTF16Range(for: request.retainedLineRange, document: document)
    let source = document.text as NSString
    let slice = source.substring(with: targetRange)
    let highlighted = highlighter.highlightedString(
        code: slice,
        language: request.language,
        appearance: request.appearance,
        fontSize: request.fontSize
    )

    guard highlighted.length == targetRange.length else { return nil }
    return CodeEditorHighlightResult(
        version: request.version,
        lineRange: request.retainedLineRange,
        replacementRange: targetRange,
        attributedString: highlighted
    )
}
```

如果 [agentGui/Services/SyntaxHighlighting/CodeSyntaxHighlightingService.swift](../agentGui/Services/SyntaxHighlighting/CodeSyntaxHighlightingService.swift) 当前接口里没有足够的测试注入点，就补充 `engine` 注入构造器的可见性或新增最小 helper，但不要让视图层直接知道 Highlightr。

**Step 4: Run test to verify it passes**

Run 同 Task 1。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/Editor/CodeEditorHighlightPipeline.swift agentGui/Services/SyntaxHighlighting/CodeSyntaxHighlightingService.swift agentGuiTests/CodeEditorHighlightPipelineTests.swift
git commit -m "feat: add code editor highlight window execution"
```

### Task 3: 引入高亮调度器并验证取消与 latest-version-wins

**Files:**
- Create: `agentGui/Services/Editor/CodeEditorHighlightScheduler.swift`
- Modify: `agentGuiTests/CodeEditorHighlightPipelineTests.swift`

**Step 1: Write the failing test**

新增调度层测试，至少覆盖“新请求取消旧请求”和“旧版本结果被丢弃”：

```swift
@Test
func schedulerOnlyPublishesNewestVersionResult() async {
    let scheduler = CodeEditorHighlightScheduler()
    let published = LockIsolated<[Int]>([])

    await scheduler.schedule(
        .init(request: request(version: 1), textSnapshot: "old"),
        debounceNanoseconds: 50_000_000
    ) { work in
        try? await Task.sleep(nanoseconds: 80_000_000)
        return CodeEditorHighlightResult.stub(version: work.request.version)
    } onResult: { result in
        published.withValue { $0.append(result.version) }
    }

    await scheduler.schedule(
        .init(request: request(version: 2), textSnapshot: "new"),
        debounceNanoseconds: 0
    ) { work in
        CodeEditorHighlightResult.stub(version: work.request.version)
    } onResult: { result in
        published.withValue { $0.append(result.version) }
    }

    #expect(published.value == [2])
}
```

**Step 2: Run test to verify it fails**

Run 同 Task 1。

Expected: FAIL，提示 `CodeEditorHighlightScheduler` 或结果发布机制不存在。

**Step 3: Write minimal implementation**

把调度器实现成 actor，并显式暴露 `schedule` 与 `cancel`：

```swift
actor CodeEditorHighlightScheduler {
    typealias WorkExecutor = @Sendable (ScheduledWork) async -> CodeEditorHighlightResult?
    typealias ResultHandler = @MainActor @Sendable (CodeEditorHighlightResult) -> Void

    private var inFlightTask: Task<Void, Never>?
    private var newestVersion: Int = 0

    func schedule(
        _ work: ScheduledWork,
        debounceNanoseconds: UInt64,
        execute: @escaping WorkExecutor,
        onResult: @escaping ResultHandler
    ) {
        newestVersion = max(newestVersion, work.request.version)
        inFlightTask?.cancel()
        inFlightTask = Task {
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            guard let result = await execute(work) else { return }
            guard !Task.isCancelled else { return }
            guard result.version >= newestVersion else { return }
            await onResult(result)
        }
    }

    func cancel() {
        inFlightTask?.cancel()
        inFlightTask = nil
    }
}
```

如果测试里没有现成的线程安全收集器，就在测试文件内部加一个最小 helper，避免把生产代码为了测试而复杂化。

**Step 4: Run test to verify it passes**

Run 同 Task 1。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/Editor/CodeEditorHighlightScheduler.swift agentGuiTests/CodeEditorHighlightPipelineTests.swift
git commit -m "feat: add code editor highlight scheduler"
```

### Task 4: 把高亮调度接入 CodeEditorTextView 的可见区和编辑事件

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- Modify: `agentGui/Views/CodeEditor/CodeEditorView.swift`
- Modify: `agentGui/Models/CodeEditorDocument.swift`
- Modify: `agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`
- Modify: `agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
- Modify: `agentGuiTests/CodeEditorViewIntegrationTests.swift`

**Step 1: Write the failing test**

先写两个集成测试：

```swift
@Test
func userEditSchedulesHighlightWithoutReplacingPlainTextContent() {
    let harness = CodeEditorTextViewHarness(text: "let value = 1", language: "swift")

    harness.replaceCharacters(in: NSRange(location: 13, length: 0), with: "\nprint(value)")
    harness.waitForHighlightPass()

    #expect(harness.textView.string == "let value = 1\nprint(value)")
    #expect(harness.textView.selectedRange() == NSRange(location: 26, length: 0))
}

@Test
func staleHighlightResultDoesNotOverwriteNewerVersionAttributes() {
    let harness = CodeEditorTextViewHarness(text: "let a = 1", language: "swift", highlightDelay: .milliseconds(120))

    harness.replaceCharacters(in: NSRange(location: 8, length: 1), with: "b")
    harness.replaceCharacters(in: NSRange(location: 8, length: 1), with: "c")
    harness.waitForHighlightPass()

    #expect(harness.latestAppliedHighlightVersion == harness.document.version)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature3-plan-task4 -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests -only-testing:agentGuiTests/CodeEditorViewIntegrationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，提示高亮调度、可见区追踪或测试 harness 能力缺失。

**Step 3: Write minimal implementation**

接入点建议如下：

- 在 `CodeEditorTextView.Coordinator` 中维护 `highlightScheduler`、`highlightPipeline`、当前语言、当前 appearance、最近一次可见行范围和最近一次应用的高亮版本。
- 在 `textDidChange` 之后根据新的 `EditorChangeSet` 把受影响行标成 dirty，并立即 schedule viewportImmediate 请求。
- 通过 `NSView.boundsDidChangeNotification` 监听 scrollView contentView 的滚动，重新计算 visible line range；若 retained window 发生变化，则 schedule nearbyPrefetch。
- 把属性回写封装到一个单独 helper，明确包住 `beginEditing/endEditing`，并在回写前后保存 `selectedRange` 与 `typingAttributes`。

最小接入骨架可以是：

```swift
private func scheduleHighlight(for textView: NSTextView) {
    guard let visibleLineRange = visibleLineRange(for: textView) else { return }
    let request = highlightPipeline.makeViewportRequest(
        document: parent.document,
        language: parent.language,
        visibleLineRange: visibleLineRange,
        dirtyLineRange: dirtyLineRange(for: parent.document.selectedRange),
        appearance: currentAppearance(for: textView),
        fontSize: currentFontSize(for: textView)
    )

    Task {
        await highlightScheduler.schedule(
            .init(request: request, textSnapshot: parent.document.text),
            debounceNanoseconds: 75_000_000,
            execute: { [pipeline = highlightPipeline, document = parent.document, highlighter] work in
                pipeline.highlight(request: work.request, document: document, highlighter: highlighter)
            },
            onResult: { [weak self, weak textView] result in
                guard let self, let textView else { return }
                self.applyHighlightResult(result, to: textView)
            }
        )
    }
}
```

如需在 `CodeEditorView` 上传语言信息，可先从 `fileURL.pathExtension` 做最小语言推断，后续再替换成更正式的语言解析服务。

**Step 4: Run test to verify it passes**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorTextView.swift agentGui/Views/CodeEditor/CodeEditorView.swift agentGui/Models/CodeEditorDocument.swift agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift agentGuiTests/CodeEditorTextViewIntegrationTests.swift agentGuiTests/CodeEditorViewIntegrationTests.swift
git commit -m "feat: connect async highlighting to code editor text view"
```

### Task 5: 补齐回写保护与降级开关

**Files:**
- Modify: `agentGui/Services/Editor/CodeEditorHighlightPipeline.swift`
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- Modify: `agentGuiTests/CodeEditorHighlightPipelineTests.swift`
- Modify: `agentGuiTests/CodeEditorTextViewIntegrationTests.swift`

**Step 1: Write the failing test**

新增两类保护测试：

```swift
@Test
func pipelineSkipsHighlightWhenRequestedWindowExceedsLargeFileThreshold() {
    let pipeline = CodeEditorHighlightPipeline(retainedLinePadding: 120, realtimeHighlightLineLimit: 2000)
    let document = CodeEditorDocument(
        text: Array(repeating: "x", count: 5000).joined(separator: "\n"),
        persistedText: ""
    )

    let request = pipeline.makeViewportRequest(
        document: document,
        language: "swift",
        visibleLineRange: 100...120,
        dirtyLineRange: 100...120,
        appearance: .light,
        fontSize: 13
    )

    #expect(pipeline.shouldSkipRealtimeHighlight(for: request, document: document))
}

@Test
func applyingHighlightPreservesTypingAttributes() {
    let harness = CodeEditorTextViewHarness(text: "let value = 1", language: "swift")
    let before = harness.textView.typingAttributes

    harness.forceApplyHighlightResult()

    #expect(NSDictionary(dictionary: harness.textView.typingAttributes).isEqual(to: before))
}
```

**Step 2: Run test to verify it fails**

Run 同 Task 4。

Expected: FAIL，提示降级判断或 typingAttributes 保护缺失。

**Step 3: Write minimal implementation**

加入最低限度的保护逻辑：

- 在 pipeline 内增加 `realtimeHighlightLineLimit` 或 `realtimeHighlightUTF16Limit`，超限时直接跳过实时高亮。
- 在回写 helper 中先抓取并恢复 `typingAttributes`、`selectedRange`、`usesFontPanel` 这类容易受影响的显示状态。
- 如果高亮结果长度与 replacementRange 不匹配，直接丢弃，不做任何修复性猜测。

最小接口：

```swift
func shouldSkipRealtimeHighlight(
    for request: CodeEditorHighlightRequest,
    document: CodeEditorDocument
) -> Bool {
    request.retainedLineRange.count > realtimeHighlightLineLimit
}
```

**Step 4: Run test to verify it passes**

Run 同 Task 4。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/Editor/CodeEditorHighlightPipeline.swift agentGui/Views/CodeEditor/CodeEditorTextView.swift agentGuiTests/CodeEditorHighlightPipelineTests.swift agentGuiTests/CodeEditorTextViewIntegrationTests.swift
git commit -m "feat: guard code editor highlighting for large files"
```

## 6. 测试门禁

实现完成后至少跑下面三组：

1. 高亮核心单测

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature3-tests-core -only-testing:agentGuiTests/CodeEditorHighlightPipelineTests CODE_SIGNING_ALLOWED=NO
```

2. 编辑器集成测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature3-tests-integration -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests -only-testing:agentGuiTests/CodeEditorViewIntegrationTests CODE_SIGNING_ALLOWED=NO
```

3. 代码编辑器基线回归

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature3-tests-regression -only-testing:agentGuiTests/CodeEditorDocumentTests -only-testing:agentGuiTests/CodeEditorLineIndexTests -only-testing:agentGuiTests/CodeSyntaxHighlightingServiceTests CODE_SIGNING_ALLOWED=NO
```

如果本机签名环境导致 `xcodebuild test` 在 UI target 构建阶段提前失败，先补跑：

```bash
xcodebuild build-for-testing -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -derivedDataPath /tmp/agentGui-feature3-build-for-testing CODE_SIGNING_ALLOWED=NO
```

## 7. 完成定义

满足以下条件即可认为 Feature 3 完成：

- 连续输入时，CodeEditorTextView 不等待 Highlightr，同步路径只处理纯文本编辑与 document 版本前进。
- 用户停顿后，可见区与缓冲窗口能够获得正确高亮，且滚动小范围移动时不会触发整文档全量重算。
- 旧版本高亮结果不会覆盖新版本文本或属性。
- 高亮局部回写不会破坏 `typingAttributes`、选区、first responder 和文本内容。
- 大窗口或超大文件场景存在明确跳过策略，不会在持续输入时堆积后台高亮任务。

Plan complete and saved to `docs/plans/2026-03-29-feature-3-highlightr-async-highlight-pipeline-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - 我按任务逐步实现、逐步验证 Feature 3

**2. Parallel Session (separate)** - 新开会话按 executing-plans skill 执行这份计划

**Which approach?**
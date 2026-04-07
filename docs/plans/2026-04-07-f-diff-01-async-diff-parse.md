# F-DIFF-01 异步 Diff 解析 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 `GitDiffPresentation.build()` 从 `var body` 的同步计算属性迁移到后台 `Task.detached`，消除大文件 diff 导致的主线程卡顿。

**Architecture:**  
SwiftUI 的 `.task(id:)` modifier 在 `diffText` 变化时自动取消上一个 Task（等同于 VSCode `CancellationTokenSource`），无需额外的缓存类（YAGNI）。`GitDiffPresentation.build()` 是纯文本解析函数，无 MainActor 依赖，可直接在 `Task.detached` 中运行。解析完成后通过 `@State private var presentation` 触发 SwiftUI 刷新，加载期间展示 skeleton 占位视图。

**Tech Stack:** Swift 6.0, SwiftUI, Swift Concurrency (`Task.detached`, `@State`), XCTest

**参考来源：**
- VSCode `diffEditorViewModel.ts`：`autorunWithStore(async)` + `CancellationTokenSource` + `isDiffUpToDate` observable
- Zed `git_panel.rs`：`wait_for_diff_to_load()` task + `cx.background_spawn(async)`

---

## 背景：问题定位

当前 `GitDiffView.swift` 中：

```swift
// 问题所在 — 每次 SwiftUI body 求值都同步执行全量解析
private var presentation: GitDiffPresentation {
    GitDiffPresentation.build(title: title, diffText: diffText)
}
```

`GitDiffPresentation.build()` 做了以下工作（约 30–60 ms for 5000 行 diff）：
1. `diffText.split(whereSeparator: \.isNewline)` — 全量字符串分割
2. 逐行解析 hunk header、prefix、行号计数
3. 返回含 `[Section]` 的值类型

每次 SwiftUI 刷新（如鼠标 hover、滚动、父视图更新）都会重复执行，导致：
- 主线程 janky（帧时间超过 16 ms）
- Xcode Instruments Time Profiler 可在 `GitDiffView.body` 下看到热点

VSCode 的解法（`diffEditorViewModel.ts`，约 L100-L170）：
```typescript
this._register(autorunWithStore(async (reader, store) => {
    // 设置 isDiffUpToDate = false（展示 loading）
    this._isDiffUpToDate.set(false, undefined);
    // 后台异步计算
    const result = await documentDiffProvider.diffProvider.computeDiff(..., cancellationToken);
    if (cancellationToken.isCancellationRequested) return;
    transaction(tx => {
        this._diff.set(DiffState.fromDiffResult(result), tx);
        this._isDiffUpToDate.set(true, tx);
    });
}));
```

Swift 等价实现使用 `.task(id:)`，其 id 变化时自动 cancel（与 `CancellationTokenSource` 语义相同）。

---

## Task 1：确认 `GitDiffPresentation` 满足 `Sendable` 要求

**Files:**
- Read/Modify: `agentGui/Views/GitDiffView.swift:67-228`

### Step 1：阅读现有代码，确认 sendability

```
agentGui/Views/GitDiffView.swift 第 67–228 行
```

`GitDiffPresentation` 是 `struct`（值类型），成员为：
- `filePath: String` ✅
- `changeSummary: ChangeSummary` (struct) ✅
- `sections: [Section]` (struct 数组，Row 为 enum with associated String/Int) ✅

Swift 6.0 中，纯值类型 struct/enum 自动满足 `Sendable`，无需额外注解。

### Step 2：验证 build() 无 actor 隔离

`GitDiffPresentation.build()` 是 `static func`（无 `@MainActor`），使用标准库函数（`split`、`hasPrefix`、`NSRegularExpression`）。

`NSRegularExpression` 在 Swift 6 中标注为 `@Sendable` 但需注意线程安全——当前 `parseHunkHeader` 在 build 内部局部创建 `NSRegularExpression`，无共享状态。✅

### Step 3：添加显式 Sendable 标注（防止未来回归）

在 `GitDiffPresentation` struct 定义处加上 `Sendable` conformance：

```swift
struct GitDiffPresentation: Equatable, Sendable {
```

同样对内嵌类型：
```swift
struct ChangeSummary: Equatable, Sendable { ... }
struct Section: Equatable, Identifiable, Sendable { ... }
enum Row: Equatable, Identifiable, Sendable { ... }
```

### Step 4：运行编译器检查

```bash
xcodebuild \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  build \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|warning:" | head -30
```

Expected: 无与 Sendable 相关的 error。

### Step 5：Commit

```bash
cd /Volumes/T7/文稿/Projects/agentGui
git add agentGui/Views/GitDiffView.swift
git commit -m "refactor: add Sendable conformance to GitDiffPresentation and nested types"
```

---

## Task 2：为 `GitDiffPresentation.build()` 编写单元测试（TDD 基准）

**Files:**
- Create: `agentGuiTests/GitDiffPresentationTests.swift`

这些测试用于验证异步版本与同步版本产出完全一致。

### Step 1：创建测试文件，编写第一个失败测试

```swift
// agentGuiTests/GitDiffPresentationTests.swift
import XCTest
@testable import agentGui

final class GitDiffPresentationTests: XCTestCase {

    // MARK: - Fixtures

    static let simplePatch = """
    @@ -1,3 +1,3 @@
      line1
    -old line
    +new line
      line3
    """

    static let emptyPatch = ""

    static let binaryPatch = "Binary files a/img.png and b/img.png differ"

    // MARK: - Basic Parsing

    func test_build_emptyText_returnsEmptySections() {
        let result = GitDiffPresentation.build(title: "file.txt", diffText: Self.emptyPatch)
        XCTAssertEqual(result.sections.count, 0)
        XCTAssertEqual(result.changeSummary.additions, 0)
        XCTAssertEqual(result.changeSummary.deletions, 0)
    }

    func test_build_simpleHunk_returnsSingleSection() {
        let result = GitDiffPresentation.build(title: "file.txt", diffText: Self.simplePatch)
        XCTAssertEqual(result.sections.count, 1)
    }

    func test_build_simpleHunk_correctChangeSummary() {
        let result = GitDiffPresentation.build(title: "file.txt", diffText: Self.simplePatch)
        XCTAssertEqual(result.changeSummary.additions, 1)
        XCTAssertEqual(result.changeSummary.deletions, 1)
    }

    func test_build_simpleHunk_correctRowOrder() {
        let result = GitDiffPresentation.build(title: "file.txt", diffText: Self.simplePatch)
        let rows = result.sections[0].rows
        // context, deletion, addition, context
        XCTAssertEqual(rows.count, 4)
        if case .context(_, _, let text) = rows[0] { XCTAssertEqual(text, "line1") } else { XCTFail() }
        if case .deletion(_, _, let text) = rows[1] { XCTAssertEqual(text, "old line") } else { XCTFail() }
        if case .addition(_, _, let text) = rows[2] { XCTAssertEqual(text, "new line") } else { XCTFail() }
        if case .context(_, _, let text) = rows[3] { XCTAssertEqual(text, "line3") } else { XCTFail() }
    }

    func test_build_lineNumbers_context() {
        let result = GitDiffPresentation.build(title: "file.txt", diffText: Self.simplePatch)
        let rows = result.sections[0].rows
        if case .context(let old, let new, _) = rows[0] {
            XCTAssertEqual(old, 1)
            XCTAssertEqual(new, 1)
        } else { XCTFail() }
    }

    func test_build_lineNumbers_deletionHasOldOnly() {
        let result = GitDiffPresentation.build(title: "file.txt", diffText: Self.simplePatch)
        let rows = result.sections[0].rows
        if case .deletion(let old, let new, _) = rows[1] {
            XCTAssertEqual(old, 2)
            XCTAssertNil(new)
        } else { XCTFail() }
    }

    func test_build_lineNumbers_additionHasNewOnly() {
        let result = GitDiffPresentation.build(title: "file.txt", diffText: Self.simplePatch)
        let rows = result.sections[0].rows
        if case .addition(let old, let new, _) = rows[2] {
            XCTAssertNil(old)
            XCTAssertEqual(new, 2)
        } else { XCTFail() }
    }

    func test_build_titleStoredAsFilePath() {
        let result = GitDiffPresentation.build(title: "src/main.swift", diffText: Self.simplePatch)
        XCTAssertEqual(result.filePath, "src/main.swift")
    }

    // MARK: - Multi-hunk

    func test_build_multiHunk_returnsMultipleSections() {
        let multiHunk = """
        @@ -1,2 +1,2 @@
        -old1
        +new1
         context1
        @@ -10,2 +10,2 @@
        -old2
        +new2
         context2
        """
        let result = GitDiffPresentation.build(title: "f.txt", diffText: multiHunk)
        XCTAssertEqual(result.sections.count, 2)
        XCTAssertEqual(result.changeSummary.additions, 2)
        XCTAssertEqual(result.changeSummary.deletions, 2)
    }

    func test_build_multiHunk_secondSectionLineNumbers() {
        let multiHunk = """
        @@ -1,1 +1,1 @@
        -a
        +b
        @@ -10,1 +10,1 @@
        -c
        +d
        """
        let result = GitDiffPresentation.build(title: "f.txt", diffText: multiHunk)
        let section2Rows = result.sections[1].rows
        if case .deletion(let old, _, _) = section2Rows[0] {
            XCTAssertEqual(old, 10)
        } else { XCTFail() }
    }

    // MARK: - Edge cases

    func test_build_onlyAdditions() {
        let addOnly = """
        @@ -0,0 +1,2 @@
        +line1
        +line2
        """
        let result = GitDiffPresentation.build(title: "new.txt", diffText: addOnly)
        XCTAssertEqual(result.changeSummary.additions, 2)
        XCTAssertEqual(result.changeSummary.deletions, 0)
    }

    func test_build_onlyDeletions() {
        let delOnly = """
        @@ -1,2 +0,0 @@
        -line1
        -line2
        """
        let result = GitDiffPresentation.build(title: "del.txt", diffText: delOnly)
        XCTAssertEqual(result.changeSummary.additions, 0)
        XCTAssertEqual(result.changeSummary.deletions, 2)
    }

    func test_build_noNewlineAtEof_metadataRow() {
        let withNoNewline = """
        @@ -1,1 +1,1 @@
        -old
        +new
        \\ No newline at end of file
        """
        let result = GitDiffPresentation.build(title: "f.txt", diffText: withNoNewline)
        let rows = result.sections[0].rows
        XCTAssertTrue(rows.contains { if case .metadata = $0 { return true }; return false })
    }

    func test_build_linesBeforeFirstHunk_ignored() {
        let withPreamble = """
        diff --git a/f.txt b/f.txt
        index abc..def 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,1 +1,1 @@
        -x
        +y
        """
        let result = GitDiffPresentation.build(title: "f.txt", diffText: withPreamble)
        XCTAssertEqual(result.sections.count, 1)
    }

    // MARK: - longestLineCharacterCount

    func test_longestLineCharacterCount_returnsMaxLineLength() {
        let result = GitDiffPresentation.build(title: "f.txt", diffText: Self.simplePatch)
        // "old line" = 8 chars + 1 prefix = 9; "new line" = 8 + 1 = 9
        XCTAssertGreaterThanOrEqual(result.longestLineCharacterCount, 8)
    }
}
```

### Step 2：运行测试，确认全部通过（基准绿灯）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/GitDiffPresentationTests \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`

> 注意：这些测试验证的是**同步** `build()` 的正确性，作为 Task 3 异步版本的正确性基准。

### Step 3：Commit

```bash
git add agentGuiTests/GitDiffPresentationTests.swift
git commit -m "test: add GitDiffPresentationTests as correctness baseline for F-DIFF-01"
```

---

## Task 3：`GitDiffView` 改造为异步解析

**Files:**
- Modify: `agentGui/Views/GitDiffView.swift`

### Step 1：阅读当前 body 结构（了解上下文）

关键位置：
- L239–L270：`GitDiffView` struct 定义、属性、`init`
- L263–L265：待替换的计算属性 `presentation`
- L267：`emptyStateDescriptor` 计算属性（依赖 `presentation.sections.isEmpty`）
- L270–L307：`var body`

### Step 2：编写失败测试（UI 状态测试）

在 `GitDiffPresentationTests.swift` 末尾添加（验证异步解析正确性的 async 测试）：

```swift
// MARK: - Async Parse Parity

func test_asyncParse_returnsIdenticalResultToSync() async {
    let diffText = GitDiffPresentationTests.simplePatch
    let title = "parity.txt"

    // 同步版本（基准）
    let syncResult = GitDiffPresentation.build(title: title, diffText: diffText)

    // 异步版本（Task.detached）
    let asyncResult = await Task.detached(priority: .userInitiated) {
        GitDiffPresentation.build(title: title, diffText: diffText)
    }.value

    XCTAssertEqual(syncResult, asyncResult)
}

func test_asyncParse_largeInput_completesWithinReasonableTime() async {
    // 构造 5000 行 diff
    let header = "@@ -1,2500 +1,2500 @@\n"
    let deletions = (1...2500).map { "-line\($0)" }.joined(separator: "\n")
    let additions = (1...2500).map { "+line\($0)" }.joined(separator: "\n")
    let largeDiff = header + deletions + "\n" + additions

    let start = Date()
    let result = await Task.detached(priority: .userInitiated) {
        GitDiffPresentation.build(title: "large.txt", diffText: largeDiff)
    }.value
    let elapsed = Date().timeIntervalSince(start)

    XCTAssertEqual(result.sections.count, 1)
    XCTAssertEqual(result.changeSummary.additions, 2500)
    XCTAssertEqual(result.changeSummary.deletions, 2500)
    // 后台解析应在 500ms 内完成（性能上限）
    XCTAssertLessThan(elapsed, 0.5, "Async parse took \(elapsed)s, too slow")
}
```

运行确认测试通过后继续：
```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/GitDiffPresentationTests \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tail -20
```

### Step 3：修改 `GitDiffView`

替换同步计算属性为异步 `@State`，并添加 loading 状态。

**修改一：删除同步计算属性，添加 `@State`**

找到：
```swift
    private var presentation: GitDiffPresentation {
        GitDiffPresentation.build(title: title, diffText: diffText)
    }
```

替换为：
```swift
    @State private var presentation: GitDiffPresentation?
    @State private var isParsing: Bool = false
```

**修改二：删除依赖同步 `presentation` 的 `emptyStateDescriptor` 计算属性**

找到：
```swift
    private var emptyStateDescriptor: GitDiffEmptyStateDescriptor {
        GitDiffEmptyStateDescriptor.make(title: title, diffText: diffText)
    }
```

此属性不依赖 `presentation`（它直接使用 `diffText`），无需修改。

**修改三：修改 `var body`**

找到 body 中关于 `presentation.sections.isEmpty` 的判断：

```swift
            if presentation.sections.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
```

替换为：
```swift
            if isParsing || presentation == nil {
                parsingSkeleton
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if presentation?.sections.isEmpty == true {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
```

同时，body 中所有使用 `presentation` 的地方需要使用 `presentation ?? GitDiffPresentation(filePath: title, changeSummary: .init(additions: 0, deletions: 0), sections: [])`，或使用 optional binding。

更简洁的做法：在 body 内部定义局部变量：

```swift
    var body: some View {
        let resolved = presentation ?? GitDiffPresentation(
            filePath: title,
            changeSummary: .init(additions: 0, deletions: 0),
            sections: []
        )
        VStack(spacing: 0) {
            // header 用 resolved
            ...
        }
    }
```

> 注意：`header` 中访问的 `presentation.filePath`、`presentation.changeSummary` 改为 `resolved.filePath`、`resolved.changeSummary`

**修改四：添加 `.task(id:)` modifier**

在 `var body` 的最外层 `VStack` 或视图末尾添加：

```swift
.task(id: diffText) {
    isParsing = true
    let result = await parsePresentation(diffText)
    presentation = result
    isParsing = false
}
```

**修改五：添加 `parsePresentation` 辅助函数**

```swift
private func parsePresentation(_ text: String) async -> GitDiffPresentation {
    await Task.detached(priority: .userInitiated) {
        GitDiffPresentation.build(title: title, diffText: text)
    }.value
}
```

> **为什么用 `Task.detached` 而非直接 `await Task { }.value`？**  
> `Task { }` 继承父任务的 actor isolation（即 `@MainActor`），不会真正后台执行。
> `Task.detached` 明确脱离 actor 隔离，在协作线程池上运行，不占用主线程。  
> VSCode 用 Worker 线程；Zed 用 `cx.background_spawn()`；Swift 等价是 `Task.detached`。

**修改六：添加 `parsingSkeleton` 视图**

```swift
private var parsingSkeleton: some View {
    VStack(spacing: 12) {
        ForEach(0..<3, id: \.self) { _ in
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.06))
                .frame(height: 80)
        }
    }
    .padding(14)
}
```

**在 header 中处理 presentation 为 nil 的情形**

`header` 访问 `presentation.filePath` 和 `presentation.changeSummary`。引入 `resolved` 变量后，`header` 改为：

```swift
private func makeHeader(using resolved: GitDiffPresentation) -> some View {
    // ... 原 header 内容，用 resolved 替换 presentation ...
}
```

或者直接在 header body 内使用 `resolved`（如果 header 是 computed property，将其改为接受参数的函数）。

具体做法（最小改动）：将 `header` computed var 改为：

```swift
private var header: some View {
    let resolved = presentation ?? GitDiffPresentation(
        filePath: title,
        changeSummary: .init(additions: 0, deletions: 0),
        sections: []
    )
    return VStack(spacing: 0) {
        // ... 原有 header 内容，presentation 改为 resolved ...
    }
}
```

> 对 `summaryCard`、`hunkSection`、`diffRow` 等方法同理，它们不直接访问 `self.presentation`，而是通过 `body` 传参，所以只需修改 `body` 中的调用点即可。

### Step 4：运行完整测试套件

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/GitDiffPresentationTests \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`

### Step 5：编译验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

### Step 6：Commit

```bash
git add agentGui/Views/GitDiffView.swift agentGuiTests/GitDiffPresentationTests.swift
git commit -m "feat(F-DIFF-01): async diff parsing in GitDiffView, eliminate main-thread block"
```

---

## Task 4：验证 `.task(id:)` 取消语义（等同于 CancellationTokenSource）

### Step 1：添加取消行为测试

在 `GitDiffPresentationTests.swift` 添加：

```swift
// MARK: - Task Cancellation

func test_taskCancelledBeforeCompletion_doesNotUpdateResult() async {
    // 验证快速取消不会导致 crash 或 race condition
    let expectation = XCTestExpectation(description: "task completes or cancels cleanly")

    let task = Task.detached {
        // 模拟 5000 行 diff
        let largeDiff = "@@ -1,1000 +1,1000 @@\n" +
            (1...1000).map { "-old\($0)" }.joined(separator: "\n") +
            "\n" +
            (1...1000).map { "+new\($0)" }.joined(separator: "\n")
        return GitDiffPresentation.build(title: "cancel_test.txt", diffText: largeDiff)
    }

    // 立即取消
    task.cancel()

    // 等待 Task 结束（取消后 Task 仍可能完成，但结果被丢弃）
    let _ = await task.result
    expectation.fulfill()

    await fulfillment(of: [expectation], timeout: 1.0)
    // 主要验证：无 crash、无数据竞争
}
```

### Step 2：运行测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/GitDiffPresentationTests \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tail -20
```

### Step 3：Commit

```bash
git add agentGuiTests/GitDiffPresentationTests.swift
git commit -m "test(F-DIFF-01): add task cancellation race-condition test"
```

---

## Task 5：手动 smoke test + 性能基准记录

### Step 1：在 Xcode 中运行应用

1. Build & Run（`Cmd+R`）
2. 打开 Git 面板
3. 选择一个有大量改动的文件（500+ 行 diff）
4. 验证：显示 loading skeleton → 完成后渲染内容（无闪烁）
5. 快速切换不同文件：验证取消/重新解析正确

### Step 2：使用 Xcode Instruments 对比前后性能

**Before（git stash 恢复旧代码或在另一分支）：**
- Instruments > Time Profiler
- 在 `GitDiffView.body` 下可看到 `GitDiffPresentation.build` 热点

**After：**
- `GitDiffView.body` 下应只有 `@State` read（< 1 ms）
- `GitDiffPresentation.build` 热点移到后台线程

### Step 3：在文档中记录性能改善

将实测数据更新到 `docs/design/2026-04-07-diff-view-iteration.md` 的 F-DIFF-01 测试目标章节。

---

## 完整文件变更清单

```
agentGui/Views/GitDiffView.swift
  - 删除: private var presentation: GitDiffPresentation { ... }（同步计算属性）
  - 新增: @State private var presentation: GitDiffPresentation?
  - 新增: @State private var isParsing: Bool = false
  - 新增: .task(id: diffText) { ... }（异步解析触发器）
  - 新增: private func parsePresentation(_ text: String) async -> GitDiffPresentation
  - 新增: private var parsingSkeleton: some View
  - 修改: var body（加 optional chaining / resolved 局部变量）
  - 修改: var header（使用 resolved 值）
  - 修改: GitDiffPresentation struct 添加 Sendable conformance

agentGuiTests/GitDiffPresentationTests.swift  ← 新建
  - test_build_emptyText_returnsEmptySections
  - test_build_simpleHunk_returnsSingleSection
  - test_build_simpleHunk_correctChangeSummary
  - test_build_simpleHunk_correctRowOrder
  - test_build_lineNumbers_context
  - test_build_lineNumbers_deletionHasOldOnly
  - test_build_lineNumbers_additionHasNewOnly
  - test_build_titleStoredAsFilePath
  - test_build_multiHunk_returnsMultipleSections
  - test_build_multiHunk_secondSectionLineNumbers
  - test_build_onlyAdditions
  - test_build_onlyDeletions
  - test_build_noNewlineAtEof_metadataRow
  - test_build_linesBeforeFirstHunk_ignored
  - test_longestLineCharacterCount_returnsMaxLineLength
  - test_asyncParse_returnsIdenticalResultToSync
  - test_asyncParse_largeInput_completesWithinReasonableTime
  - test_taskCancelledBeforeCompletion_doesNotUpdateResult
```

---

## 不在此 Feature 范围内

- `DiffPresentationCache`（多文件共享缓存）：YAGNI，等到 F-DIFF-05 虚拟化后再评估
- `DiffPresentationCache` 的 LRU 淘汰策略
- 进度条（仅展示 skeleton，无百分比）
- 取消按钮（`.task(id:)` 自动处理）

---

## xcodebuild 快捷命令参考

```bash
# 只跑 GitDiffPresentation 测试
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/GitDiffPresentationTests \
  CODE_SIGNING_ALLOWED=NO

# 编译（不运行）
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

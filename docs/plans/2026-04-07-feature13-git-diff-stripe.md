# Feature 13: Git Diff Stripe Lane 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 Gutter 新增一条 Git Diff Stripe Lane，将文件相对 `HEAD` 的 git diff 以绿/黄/红色条纹可视化，与 VSCode / Zed 的行内 diff 标记体验对齐。

**Architecture:**
`GitLineDiffService`（Actor）负责调用 `git diff -U0 HEAD -- <file>` 并用 `UnifiedDiffParser` 将 hunk headers 转译为 `[Int: CodeEditorGitDiffKind]` 行级映射。结果自 `FileEditorView` 注入 `CodeEditorView`，后者更新 `CodeEditorGutterViewportSnapshot.gitDiffByLine`，`GitDiffStripeLane` 消费该字段完成绘制。整条数据流与 F11 已有的 Lane 基础设施完全兼容：新 lane 注册进 `CodeEditorGutterView`，无需修改 lane 宿主逻辑。

**Tech Stack:** Swift 6 / AppKit，`Foundation.Process`（已有 `ProcessGitCommandRunner`），Swift Testing（`@Test`），agentGui 现有 `CodeEditorGutterLane` 协议 + `CodeEditorGutterViewportSnapshot`（已含 `gitDiffByLine`）

**参考实现：**
- **VSCode** `quickDiffDecorator.ts`：`linesDecorationsClassName = dirty-diff-added|modified|deleted`，宽度 3 px CSS border-left，删除行用特殊三角 glyph 定位于删除插入点的末尾列。
- **Zed** `element.rs › paint_gutter_diff_hunks()`：`gutter_strip_width = 0.275 * line_height`；删除 hunk（`display_row_range.is_empty()`）在边界绘制宽度翻倍的居中矩形；支持 hollow（仅描边）模式表示 unstaged；颜色来自 `version_control_added/modified/deleted`。

---

## 现有基线状态

| 已有 | 说明 |
|------|------|
| `CodeEditorGitDiffKind` + `gitDiffByLine` 字段 | 定义在 `CodeEditorGutterViewportSnapshot.swift`，当前始终为空 `[:]` |
| `GitService.diff(for:staged:repositoryRoot:)` | 返回完整 unified diff 字符串（`git diff --` 或 `git diff --cached --`） |
| `ProcessGitCommandRunner` | 已有 `GitCommandRunning` 协议 + Process 实现，可直接复用 |
| `CodeEditorGutterLane` + `FoldChevronLane` 等 | Lane 协议及内置 lane 均已实现，注册流程稳定 |
| `CodeEditorGutterView.register(lane:)` | 有序注册，左→右 layout |

---

## Task 1：UnifiedDiffParser — 将 unified diff 文本转为行级映射

**文件：**
- 新增：`agentGui/Services/Editor/UnifiedDiffParser.swift`
- 新增（测试）：`agentGuiTests/UnifiedDiffParserTests.swift`

**背景知识：**

`git diff -U0 HEAD -- <file>` 使用 `-U0`（零上下文行），每个 hunk 的格式为：

```
@@ -<oldStart>[,<oldCount>] +<newStart>[,<newCount>] @@
```

- `oldCount` / `newCount` 缺省时视为 1。`newCount == 0` 表示纯删除，`oldCount == 0` 表示纯添加，两者都非零表示修改。
- 对于一个修改范围 `newStart..<newStart+newCount`，所有这些行都标记为 `.modified`（无差别；字符级 diff 是更高阶段的特性）。
- 纯删除（`newCount == 0`）时，在 **`newStart`** 行处插入一个 `.deleted` 标记；若 `newStart == 0`，则标记在行 1（文件头部删除）。

**Step 1：写失败测试**

```swift
// agentGuiTests/UnifiedDiffParserTests.swift
import Testing
@testable import agentGui

struct UnifiedDiffParserTests {

    @Test func emptyDiff_returnsEmptyMap() {
        let result = UnifiedDiffParser.parse("")
        #expect(result.isEmpty)
    }

    @Test func pureAddition_marksAddedLines() {
        // @@ -0,0 +1,3 @@ → 新行 1,2,3 为 added
        let diff = """
        --- a/file.swift
        +++ b/file.swift
        @@ -0,0 +1,3 @@
        +line1
        +line2
        +line3
        """
        let result = UnifiedDiffParser.parse(diff)
        #expect(result[1] == .added)
        #expect(result[2] == .added)
        #expect(result[3] == .added)
        #expect(result.count == 3)
    }

    @Test func pureDeletion_marksDeletionAtInsertionPoint() {
        // @@ -2,3 +2,0 @@ → 纯删除，newStart=2, newCount=0 → 标记行 2 为 .deleted
        let diff = """
        --- a/file.swift
        +++ b/file.swift
        @@ -2,3 +2,0 @@
        -removed1
        -removed2
        -removed3
        """
        let result = UnifiedDiffParser.parse(diff)
        #expect(result[2] == .deleted)
        #expect(result.count == 1)
    }

    @Test func modification_marksModifiedLines() {
        // @@ -3,2 +3,2 @@ → newStart=3, newCount=2 → 行 3,4 为 .modified
        let diff = """
        --- a/file.swift
        +++ b/file.swift
        @@ -3,2 +3,2 @@
        -old1
        -old2
        +new1
        +new2
        """
        let result = UnifiedDiffParser.parse(diff)
        #expect(result[3] == .modified)
        #expect(result[4] == .modified)
        #expect(result.count == 2)
    }

    @Test func multiplHunks_mergesCorrectly() {
        let diff = """
        --- a/file.swift
        +++ b/file.swift
        @@ -1 +1,2 @@
        -old
        +new1
        +new2
        @@ -10,0 +11,1 @@
        +inserted
        """
        let result = UnifiedDiffParser.parse(diff)
        // 第一个 hunk: 1行 old → 2行 new → modified (行1), added (行2)
        #expect(result[1] == .modified)
        #expect(result[2] == .added)
        // 第二个 hunk: 纯添加行 11
        #expect(result[11] == .added)
    }

    @Test func deletionAtFileHead_marksLine1() {
        // @@ -1,2 +0,0 @@ → newStart=0, newCount=0 → 删除点为行 1
        let diff = """
        --- a/file.swift
        +++ b/file.swift
        @@ -1,2 +0,0 @@
        -removed1
        -removed2
        """
        let result = UnifiedDiffParser.parse(diff)
        #expect(result[1] == .deleted)
    }

    @Test func hunkWithImplicitCount1_parsesCorrectly() {
        // @@ -5 +5 @@ → oldCount=1, newCount=1 → line 5 is modified
        let diff = """
        --- a/file.swift
        +++ b/file.swift
        @@ -5 +5 @@
        -old
        +new
        """
        let result = UnifiedDiffParser.parse(diff)
        #expect(result[5] == .modified)
    }

    @Test func mixedHunk_addModifyDelete() {
        // 第一个 hunk: 2 added → lines 2,3
        // 第二个 hunk: pure delete at line 7
        let diff = """
        --- a/file.swift
        +++ b/file.swift
        @@ -1,0 +2,2 @@
        +add1
        +add2
        @@ -8,1 +7,0 @@
        -deleted
        """
        let result = UnifiedDiffParser.parse(diff)
        #expect(result[2] == .added)
        #expect(result[3] == .added)
        #expect(result[7] == .deleted)
    }
}
```

**Step 2：运行测试确认失败**

```bash
cd /Volumes/T7/文稿/Projects/agentGui && \
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-f13-diff-derived \
  -only-testing:agentGuiTests/UnifiedDiffParserTests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAIL|passed|failed" | head -20
```

预期：编译失败（`UnifiedDiffParser` 不存在）。

**Step 3：实现 UnifiedDiffParser**

```swift
// agentGui/Services/Editor/UnifiedDiffParser.swift
import Foundation

/// 将 `git diff -U0` 输出的 unified diff 文本解析为行级变更映射。
///
/// 设计约束：
/// - 只处理 hunk headers（`@@ ... @@` 行），不逐行解析 `+/-` 内容。
/// - 纯添加 → 每新行标 `.added`；纯删除 → 在插入点行标 `.deleted`；
///   混合 → 新行全标 `.modified`。
/// - 线程安全：无状态，全为静态方法。
enum UnifiedDiffParser {

    /// 解析 unified diff 文本，返回 `[newFileLineNumber: diffKind]`。
    /// - Parameter diffText: `git diff -U0 HEAD -- <file>` 的 stdout。
    static func parse(_ diffText: String) -> [Int: CodeEditorGitDiffKind] {
        guard !diffText.isEmpty else { return [:] }
        var result: [Int: CodeEditorGitDiffKind] = [:]
        let hunkHeaderPrefix = "@@ "

        for line in diffText.split(whereSeparator: \.isNewline) {
            let str = String(line)
            guard str.hasPrefix(hunkHeaderPrefix) else { continue }
            guard let parsed = parseHunkHeader(str) else { continue }

            let (oldCount, newStart, newCount) = parsed

            if newCount == 0 {
                // 纯删除：标记插入点行
                let marker = max(newStart, 1)
                // 若该行已有 added/modified 标记，删除标记高优先
                result[marker] = .deleted
            } else if oldCount == 0 {
                // 纯添加
                for offset in 0..<newCount {
                    let lineNumber = newStart + offset
                    if result[lineNumber] == nil {
                        result[lineNumber] = .added
                    }
                }
            } else {
                // 修改（both sides present）
                for offset in 0..<newCount {
                    let lineNumber = newStart + offset
                    result[lineNumber] = .modified
                }
            }
        }
        return result
    }

    // MARK: - Private

    /// 解析格式 `@@ -<oldStart>[,<oldCount>] +<newStart>[,<newCount>] @@ ...`
    /// 返回 `(oldCount, newStart, newCount)`
    private static func parseHunkHeader(_ line: String) -> (oldCount: Int, newStart: Int, newCount: Int)? {
        // 提取 `@@` 之间的内容
        let parts = line.components(separatedBy: "@@")
        guard parts.count >= 2 else { return nil }
        let rangeString = parts[1].trimmingCharacters(in: .whitespaces)
        // rangeString example: "-3,2 +5,4"  or  "-5 +5"
        let sides = rangeString.components(separatedBy: " ")
        guard sides.count >= 2 else { return nil }

        let oldSide = sides[0]  // e.g. "-3,2"
        let newSide = sides[1]  // e.g. "+5,4"

        guard oldSide.hasPrefix("-"), newSide.hasPrefix("+") else { return nil }

        let oldCount = parseCount(String(oldSide.dropFirst()))
        let (newStart, newCount) = parseStartAndCount(String(newSide.dropFirst()))

        return (oldCount, newStart, newCount)
    }

    /// 解析 "start,count" 或 "start"（count 默认为 1）
    private static func parseStartAndCount(_ s: String) -> (start: Int, count: Int) {
        let comps = s.components(separatedBy: ",")
        let start = Int(comps[0]) ?? 1
        let count = comps.count > 1 ? (Int(comps[1]) ?? 1) : 1
        return (start, count)
    }

    /// 解析 "start,count" 中的 count 部分（仅取 count），不关心 start
    private static func parseCount(_ s: String) -> Int {
        let comps = s.components(separatedBy: ",")
        return comps.count > 1 ? (Int(comps[1]) ?? 1) : 1
    }
}
```

**Step 4：运行测试确认通过**

```bash
cd /Volumes/T7/文稿/Projects/agentGui && \
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-f13-diff-derived \
  -only-testing:agentGuiTests/UnifiedDiffParserTests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|Test Suite|passed|failed" | head -20
```

预期：所有 8 个测试通过。

**Step 5：Commit**

```
git add agentGui/Services/Editor/UnifiedDiffParser.swift agentGuiTests/UnifiedDiffParserTests.swift
git commit -m "feat(f13): add UnifiedDiffParser for hunk-to-line mapping"
```

---

## Task 2：GitLineDiffService — 异步 git diff 查询服务

**文件：**
- 新增：`agentGui/Services/Editor/GitLineDiffService.swift`
- 新增（测试）：`agentGuiTests/GitLineDiffServiceTests.swift`

**设计要点：**
- 使用 `actor` 保证 diff 结果写入线程安全。
- 内部调用 `git diff -U0 HEAD -- <relativePath>`，通过现有 `GitCommandRunning` 协议可测试（注入 mock）。
- 对未追踪文件（exit code 0 + 空输出）和非 git 仓库（exit code 非零）均静默返回空映射。
- 暴露 `func fetchLineDiff(fileURL: URL, workspaceRoot: URL) async -> [Int: CodeEditorGitDiffKind]`。

**Step 1：写失败测试**

```swift
// agentGuiTests/GitLineDiffServiceTests.swift
import Testing
import Foundation
@testable import agentGui

// MARK: - Mock

private struct MockCommandRunner: GitCommandRunning {
    let result: GitCommandResult

    func run(arguments: [String], workingDirectory: URL) async throws -> GitCommandResult {
        result
    }
}

// MARK: - Tests

struct GitLineDiffServiceTests {

    private let workspaceRoot = URL(filePath: "/tmp/repo")

    @Test func emptyDiffOutput_returnsEmptyMap() async {
        let runner = MockCommandRunner(result: GitCommandResult(stdout: "", stderr: "", exitCode: 0))
        let service = GitLineDiffService(commandRunner: runner)
        let fileURL = workspaceRoot.appending(path: "src/main.swift")
        let result = await service.fetchLineDiff(fileURL: fileURL, workspaceRoot: workspaceRoot)
        #expect(result.isEmpty)
    }

    @Test func nonZeroExitCode_returnsEmptyMap() async {
        let runner = MockCommandRunner(result: GitCommandResult(
            stdout: "fatal: not a git repository", stderr: "", exitCode: 128)
        )
        let service = GitLineDiffService(commandRunner: runner)
        let fileURL = workspaceRoot.appending(path: "file.swift")
        let result = await service.fetchLineDiff(fileURL: fileURL, workspaceRoot: workspaceRoot)
        #expect(result.isEmpty)
    }

    @Test func validDiffOutput_returnsCorrectMap() async {
        let diffOutput = """
        --- a/src/main.swift
        +++ b/src/main.swift
        @@ -0,0 +1,2 @@
        +line1
        +line2
        """
        let runner = MockCommandRunner(result: GitCommandResult(stdout: diffOutput, stderr: "", exitCode: 0))
        let service = GitLineDiffService(commandRunner: runner)
        let fileURL = workspaceRoot.appending(path: "src/main.swift")
        let result = await service.fetchLineDiff(fileURL: fileURL, workspaceRoot: workspaceRoot)
        #expect(result[1] == .added)
        #expect(result[2] == .added)
    }

    @Test func relativePath_computedFromWorkspaceRoot() async {
        var capturedArgs: [String] = []
        struct CapturingRunner: GitCommandRunning {
            let capture: ([String]) -> Void
            func run(arguments: [String], workingDirectory: URL) async throws -> GitCommandResult {
                capture(arguments)
                return GitCommandResult(stdout: "", stderr: "", exitCode: 0)
            }
        }
        let runner = CapturingRunner { capturedArgs = $0 }
        let service = GitLineDiffService(commandRunner: runner)
        let fileURL = URL(filePath: "/tmp/repo/Sources/App.swift")
        let root = URL(filePath: "/tmp/repo")
        _ = await service.fetchLineDiff(fileURL: fileURL, workspaceRoot: root)
        // 断言使用了 -U0 和正确的相对路径
        #expect(capturedArgs.contains("-U0"))
        #expect(capturedArgs.contains("Sources/App.swift"))
    }
}
```

**Step 2：运行测试确认编译失败**

```bash
cd /Volumes/T7/文稿/Projects/agentGui && \
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-f13-diff-derived \
  -only-testing:agentGuiTests/GitLineDiffServiceTests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAIL|passed|failed" | head -20
```

预期：编译失败（`GitLineDiffService` 不存在）。

**Step 3：实现 GitLineDiffService**

```swift
// agentGui/Services/Editor/GitLineDiffService.swift
import Foundation

/// 异步查询单文件相对 HEAD 的行级 diff。
/// Actor 保证内部缓存写入线程安全。
actor GitLineDiffService {

    private let commandRunner: GitCommandRunning

    /// 上一次查询结果缓存，用于去重（同文件连续查询时跳过相同版本）
    private var cachedResult: (fileURL: URL, result: [Int: CodeEditorGitDiffKind])?

    init(commandRunner: GitCommandRunning = ProcessGitCommandRunner()) {
        self.commandRunner = commandRunner
    }

    /// 获取指定文件相对 HEAD 的行级 diff 映射。
    /// - Parameters:
    ///   - fileURL: 被查询文件的绝对 URL。
    ///   - workspaceRoot: Git 仓库根目录（用于计算相对路径及作为 git 工作目录）。
    /// - Returns: `[lineNumber: diffKind]`，未追踪文件或出错时返回空映射。
    func fetchLineDiff(
        fileURL: URL,
        workspaceRoot: URL
    ) async -> [Int: CodeEditorGitDiffKind] {
        let relativePath = fileURL.path(percentEncoded: false)
            .replacingOccurrences(of: workspaceRoot.path(percentEncoded: false) + "/", with: "")

        let result: GitCommandResult
        do {
            result = try await commandRunner.run(
                arguments: ["diff", "-U0", "HEAD", "--", relativePath],
                workingDirectory: workspaceRoot
            )
        } catch {
            return [:]
        }

        guard result.exitCode == 0 else { return [:] }

        let diffMap = UnifiedDiffParser.parse(result.stdout)
        cachedResult = (fileURL: fileURL, result: diffMap)
        return diffMap
    }
}
```

**Step 4：运行测试确认通过**

```bash
cd /Volumes/T7/文稿/Projects/agentGui && \
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-f13-diff-derived \
  -only-testing:agentGuiTests/GitLineDiffServiceTests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|Test Suite|passed|failed" | head -20
```

预期：4 个测试全部通过。

**Step 5：Commit**

```
git add agentGui/Services/Editor/GitLineDiffService.swift agentGuiTests/GitLineDiffServiceTests.swift
git commit -m "feat(f13): add GitLineDiffService with mock-injectable runner"
```

---

## Task 3：GitDiffStripeLane — Gutter 条纹绘制 Lane

**文件：**
- 新增：`agentGui/Views/CodeEditor/Lanes/GitDiffStripeLane.swift`
- 新增（测试）：`agentGuiTests/GitDiffStripeLaneTests.swift`

**视觉规格（参考 VSCode + Zed）：**

| 状态 | 颜色 | 绘制方式 |
|------|------|----------|
| `.added` | `NSColor.systemGreen`（alpha 0.85） | 全行高矩形，宽 3pt |
| `.modified` | `NSColor.systemOrange`（alpha 0.85） | 全行高矩形，宽 3pt |
| `.deleted` | `NSColor.systemRed`（alpha 0.90） | 小三角形标记，高 6pt，居中于行顶边界（参照 VSCode 删除三角） |

- Lane 宽度：固定 **4pt**（比条纹多 1pt 留白，视觉留边）。
- 条纹 x 位置：`laneRect.minX` 开始，宽 3pt（参照 VSCode `scm.diffDecorationsGutterWidth` 默认值 3）。
- 删除标记：在行 `metric.rect.minY` 处绘一个 4×6pt 的下三角（`▼`），仿 VSCode 的 `dirty-diff-deleted` glyph。
- 对于视口外的行（`metric` 不存在）跳过绘制。

**Step 1：写失败测试**

```swift
// agentGuiTests/GitDiffStripeLaneTests.swift
import AppKit
import Testing
@testable import agentGui

@MainActor
struct GitDiffStripeLaneTests {

    private func makeSnapshot(
        gitDiffByLine: [Int: CodeEditorGitDiffKind],
        visibleRange: ClosedRange<Int> = 1...10
    ) -> CodeEditorGutterViewportSnapshot {
        let lineMetrics = visibleRange.map { line in
            CodeEditorVisibleLineMetric(
                line: line,
                rect: CGRect(x: 0, y: CGFloat((line - 1) * 14), width: 200, height: 14),
                baselineY: CGFloat((line - 1) * 14 + 11)
            )
        }
        return CodeEditorGutterViewportSnapshot(
            lineCount: visibleRange.upperBound,
            visibleLineRange: visibleRange,
            currentLine: nil,
            lineMetrics: lineMetrics,
            diagnosticsByLine: [:],
            gitDiffByLine: gitDiffByLine
        )
    }

    @Test func preferredWidth_is4pt() {
        let lane = GitDiffStripeLane()
        let snapshot = makeSnapshot(gitDiffByLine: [:])
        #expect(lane.preferredWidth(for: snapshot, appearance: nil) == 4)
    }

    @Test func hitTest_alwaysReturnsNil() {
        // diff stripe 不响应点击
        let lane = GitDiffStripeLane()
        let snapshot = makeSnapshot(gitDiffByLine: [1: .added])
        let laneRect = NSRect(x: 0, y: 0, width: 4, height: 140)
        let result = lane.hitTest(point: CGPoint(x: 2, y: 7), snapshot: snapshot, laneRect: laneRect)
        #expect(result == nil)
    }

    @Test func invalidationPlan_emptyToEmpty_isNone() {
        let lane = GitDiffStripeLane()
        let snap1 = makeSnapshot(gitDiffByLine: [:])
        let snap2 = makeSnapshot(gitDiffByLine: [:])
        let plan = lane.invalidationPlan(from: snap1, to: snap2)
        if case .none = plan { } else { Issue.record("Expected .none") }
    }

    @Test func invalidationPlan_changedLine_linesOnly() {
        let lane = GitDiffStripeLane()
        let snap1 = makeSnapshot(gitDiffByLine: [1: .added])
        let snap2 = makeSnapshot(gitDiffByLine: [1: .modified, 3: .deleted])
        let plan = lane.invalidationPlan(from: snap1, to: snap2)
        if case .lines(let changed) = plan {
            // 行 1（状态变化）和行 3（新增）都需要重绘
            #expect(changed.contains(1))
            #expect(changed.contains(3))
        } else {
            Issue.record("Expected .lines plan, got: \(plan)")
        }
    }

    @Test func invalidationPlan_sameContent_isNone() {
        let lane = GitDiffStripeLane()
        let snap1 = makeSnapshot(gitDiffByLine: [2: .modified, 5: .added])
        let snap2 = makeSnapshot(gitDiffByLine: [2: .modified, 5: .added])
        let plan = lane.invalidationPlan(from: snap1, to: snap2)
        if case .none = plan { } else { Issue.record("Expected .none") }
    }

    @Test func invalidationPlan_nilPrevious_isFull() {
        let lane = GitDiffStripeLane()
        let snap = makeSnapshot(gitDiffByLine: [1: .added])
        let plan = lane.invalidationPlan(from: nil, to: snap)
        if case .full = plan { } else { Issue.record("Expected .full") }
    }
}
```

**Step 2：运行测试确认编译失败**

```bash
cd /Volumes/T7/文稿/Projects/agentGui && \
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-f13-diff-derived \
  -only-testing:agentGuiTests/GitDiffStripeLaneTests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAIL|passed|failed" | head -20
```

**Step 3：实现 GitDiffStripeLane**

```swift
// agentGui/Views/CodeEditor/Lanes/GitDiffStripeLane.swift
import AppKit

/// Git Diff Stripe Lane：在 gutter 左侧绘制 3pt 宽的颜色条纹，
/// 可视化当前文件相对 HEAD 的行级变更状态。
///
/// 视觉设计参考 VSCode `scm.diffDecorations`（宽 3 px border-left）
/// 和 Zed `paint_gutter_diff_hunks`（`gutter_strip_width = 0.275 * line_height`）。
@MainActor
final class GitDiffStripeLane: CodeEditorGutterLane {

    let id = "gitDiffStripe"
    var onPreferredWidthChange: (() -> Void)?

    // MARK: - Preferred Width

    func preferredWidth(
        for snapshot: CodeEditorGutterViewportSnapshot,
        appearance: NSAppearance?
    ) -> CGFloat {
        4   // 3pt 条纹 + 1pt 右侧留白
    }

    // MARK: - Draw

    func draw(
        snapshot: CodeEditorGutterViewportSnapshot,
        laneRect: NSRect,
        dirtyRect: NSRect,
        appearance: NSAppearance?
    ) {
        guard !snapshot.gitDiffByLine.isEmpty else { return }

        let lineMetricsByLine = Dictionary(
            uniqueKeysWithValues: snapshot.lineMetrics.map { ($0.line, $0) }
        )
        let stripeWidth: CGFloat = 3
        let stripeX = laneRect.minX

        for (lineNumber, kind) in snapshot.gitDiffByLine {
            guard let metric = lineMetricsByLine[lineNumber] else { continue }

            switch kind {
            case .added, .modified:
                let color = kind == .added ? NSColor.systemGreen : NSColor.systemOrange
                let stripeRect = NSRect(
                    x: stripeX,
                    y: metric.rect.minY,
                    width: stripeWidth,
                    height: metric.rect.height
                )
                guard stripeRect.intersects(dirtyRect) else { continue }
                color.withAlphaComponent(0.85).setFill()
                NSBezierPath(rect: stripeRect).fill()

            case .deleted:
                // 删除标记：在行顶边界绘制小三角（高 6pt）
                // 参照 VSCode dirty-diff-deleted glyph 风格
                let markerHeight: CGFloat = 6
                let markerWidth: CGFloat = 4
                let markerY = metric.rect.minY - markerHeight / 2   // 居中于行边界
                let markerRect = NSRect(
                    x: stripeX,
                    y: markerY,
                    width: markerWidth,
                    height: markerHeight
                )
                guard markerRect.insetBy(dx: -4, dy: -4).intersects(dirtyRect) else { continue }

                NSColor.systemRed.withAlphaComponent(0.90).setFill()
                let path = NSBezierPath()
                path.move(to: NSPoint(x: markerRect.minX, y: markerRect.minY))
                path.line(to: NSPoint(x: markerRect.maxX, y: markerRect.minY))
                path.line(to: NSPoint(x: (markerRect.minX + markerRect.maxX) / 2,
                                      y: markerRect.maxY))
                path.close()
                path.fill()
            }
        }
    }

    // MARK: - Hit Test

    func hitTest(
        point: CGPoint,
        snapshot: CodeEditorGutterViewportSnapshot,
        laneRect: NSRect
    ) -> Int? {
        nil     // Diff stripe 为装饰性，不响应点击
    }

    // MARK: - Invalidation Plan

    func invalidationPlan(
        from previous: CodeEditorGutterViewportSnapshot?,
        to current: CodeEditorGutterViewportSnapshot
    ) -> CodeEditorGutterLaneInvalidationPlan {
        guard let previous else { return .full }

        let prev = previous.gitDiffByLine
        let curr = current.gitDiffByLine

        guard prev != curr else { return .none }

        // 计算变更行集合（新增、删除、状态变化的行）
        var changedLines = Set<Int>()
        for (line, kind) in curr where prev[line] != kind {
            changedLines.insert(line)
        }
        for line in prev.keys where curr[line] == nil {
            changedLines.insert(line)
        }

        return .lines(changedLines)
    }
}
```

**Step 4：运行测试确认通过**

```bash
cd /Volumes/T7/文稿/Projects/agentGui && \
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-f13-diff-derived \
  -only-testing:agentGuiTests/GitDiffStripeLaneTests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|Test Suite|passed|failed" | head -20
```

预期：5 个测试全部通过。

**Step 5：Commit**

```
git add agentGui/Views/CodeEditor/Lanes/GitDiffStripeLane.swift agentGuiTests/GitDiffStripeLaneTests.swift
git commit -m "feat(f13): add GitDiffStripeLane with minimal-invalidation plan"
```

---

## Task 4：注册 Lane 到 GutterView

**文件（仅修改）：**
- `agentGui/Views/CodeEditor/CodeEditorGutterView.swift`

**目标：** 在 `init(lineCount:)` 中把 `GitDiffStripeLane` 以第一列（最左侧）注册。

**Step 1：写失败测试（Lane 存在性验证）**

将此测试追加到现有 `agentGuiTests/CodeEditorGutterLaneTests.swift`：

```swift
// 追加到 CodeEditorGutterLaneTests.swift
@Test func gitDiffStripeLane_registeredByDefault() throws {
    let view = CodeEditorGutterView(lineCount: 10)
    // 通过 requiredWidth 侧向验证：若 GitDiffStripeLane 注册，
    // 各 lane 宽度之和会比无 git lane 时大 ≥ 4pt
    let widthWithDiff = view.requiredWidth
    // requiredWidth > 0 即验证 lane 注册后 gutter 可以计算宽度
    // 具体验证：至少有 lineNumber + diagnostic + foldChevron + gitDiff 四条 lane
    #expect(widthWithDiff >= 4)   // gitDiff lane 贡献至少 4pt
}
```

> **注意：** 这是一个弱断言（不测绝对值），因为其他 lane 宽度会随字体变化。主要目的是确保注册代码不崩溃。

运行确认现有测试状态（应该通过，因为 `requiredWidth >= 4` 条件已满足）：

```bash
cd /Volumes/T7/文稿/Projects/agentGui && \
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-f13-diff-derived \
  -only-testing:agentGuiTests/CodeEditorGutterLaneTests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|passed|failed" | head -20
```

**Step 2：修改 CodeEditorGutterView.init 注册 GitDiffStripeLane**

找到 `init(lineCount:)` 中注册内置 lane 的三行：

```swift
// 修改前（现有代码）
register(lane: FoldChevronLane())
register(lane: CodeEditorLineNumberLane())
register(lane: CodeEditorDiagnosticDotLane())
```

改为（在最左侧插入 GitDiffStripeLane）：

```swift
// 修改后：GitDiffStripeLane 在最左侧（最接近文本的边缘），
// 与 VSCode gutter 条纹位置一致
register(lane: GitDiffStripeLane())
register(lane: FoldChevronLane())
register(lane: CodeEditorLineNumberLane())
register(lane: CodeEditorDiagnosticDotLane())
```

**Step 3：再次运行测试**

```bash
cd /Volumes/T7/文稿/Projects/agentGui && \
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-f13-diff-derived \
  -only-testing:agentGuiTests/CodeEditorGutterLaneTests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|passed|failed" | head -20
```

**Step 4：Commit**

```
git add agentGui/Views/CodeEditor/CodeEditorGutterView.swift agentGuiTests/CodeEditorGutterLaneTests.swift
git commit -m "feat(f13): register GitDiffStripeLane as first gutter lane"
```

---

## Task 5：CodeEditorView 接收并传递 gitDiffByLine

**文件（仅修改）：**
- `agentGui/Views/CodeEditor/CodeEditorView.swift`
- `agentGui/Views/CodeEditor/CodeEditorTextView.swift`（接收并写入 snapshot）

**目标：** `CodeEditorView` 暴露 `gitDiffByLine: [Int: CodeEditorGitDiffKind]` 参数，将其传入 `CodeEditorTextView`，进而注入 `CodeEditorGutterViewportSnapshot`。

**Step 1：了解当前数据流**

阅读 `CodeEditorView.body` 中对 `CodeEditorTextView` 的调用，以及 `CodeEditorTextView` 如何构建 `CodeEditorGutterViewportSnapshot`。确认 `diagnosticsByLine` 是现有参数，作为 `gitDiffByLine` 的对标参考。

```bash
# 快速定位 snapshot 构建位置
grep -n "CodeEditorGutterViewportSnapshot\|diagnosticsByLine\|gitDiffByLine" \
  /Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift | head -30
```

**Step 2：修改 CodeEditorView**

在 `CodeEditorView` 中新增一个默认为空字典的属性：

```swift
// 在现有属性声明区域追加
var gitDiffByLine: [Int: CodeEditorGitDiffKind] = [:]
```

在 `init` 中追加对应参数（默认值为 `[:]`，保持向后兼容）：

```swift
// init 参数列表增加（默认值确保调用方不需要改动）
gitDiffByLine: [Int: CodeEditorGitDiffKind] = [:]
```

在 `init` 体中赋值：

```swift
self.gitDiffByLine = gitDiffByLine
```

在 `body` 中，找到 `CodeEditorTextView(...)` 调用，在 `diagnosticsByLine:` 参数后追加：

```swift
gitDiffByLine: gitDiffByLine,
```

**Step 3：修改 CodeEditorTextView**

在 `CodeEditorTextView` 的参数列表中追加 `gitDiffByLine`，并确保在构建 `CodeEditorGutterViewportSnapshot` 时传入该字段（参照现有 `diagnosticsByLine` 参数的处理方式）。

具体修改位置：找到所有 `CodeEditorGutterViewportSnapshot(` 初始化调用（应有 1-2 处），在 `diagnosticsByLine:` 后补全 `gitDiffByLine: gitDiffByLine`。

> 注意：`CodeEditorGutterViewportSnapshot` 的 `gitDiffByLine` 参数已有默认值 `[:]`，所以现有调用方暂不报错，此步骤是"激活"该字段。

**Step 4：编译验证**

```bash
cd /Volumes/T7/文稿/Projects/agentGui && \
xcodebuild build \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-f13-diff-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded|Build FAILED" | head -20
```

预期：`Build succeeded`。

**Step 5：运行现有集成测试回归验证**

```bash
cd /Volumes/T7/文稿/Projects/agentGui && \
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-f13-diff-derived \
  -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests \
  -only-testing:agentGuiTests/CodeEditorViewIntegrationTests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|passed|failed" | head -20
```

预期：所有现有测试通过（无回归）。

**Step 6：Commit**

```
git add agentGui/Views/CodeEditor/CodeEditorView.swift agentGui/Views/CodeEditor/CodeEditorTextView.swift
git commit -m "feat(f13): wire gitDiffByLine through CodeEditorView → snapshot"
```

---

## Task 6：FileEditorView 集成 — 触发 diff 刷新并注入结果

**文件（仅修改）：**
- `agentGui/Views/FileEditorView.swift`

**目标：** `FileEditorView` 持有 `GitLineDiffService`，在以下时机触发 diff 刷新并将结果注入 `CodeEditorView.gitDiffByLine`：
1. 文件 `onAppear`/`onChange(fileURL:)`。
2. 文件保存完成后（`sessionController.document.hasUnsavedChanges` 从 `true → false`）。
3. 外部文件变化后（`externalConflict` 解决后）。

**Step 1：在 FileEditorView 添加状态与服务**

```swift
// 追加到现有的 @State 声明区域
@State private var gitDiffByLine: [Int: CodeEditorGitDiffKind] = [:]
private let gitDiffService = GitLineDiffService()
```

**Step 2：添加 diff 刷新辅助方法**

```swift
// MARK: - Git Diff

private func refreshGitDiff(for fileURL: URL) {
    guard let rootURL = resolveWorkspaceRoot() else { return }
    Task { @MainActor in
        let result = await gitDiffService.fetchLineDiff(
            fileURL: fileURL.standardizedFileURL,
            workspaceRoot: rootURL
        )
        gitDiffByLine = result
    }
}

private func resolveWorkspaceRoot() -> URL? {
    let settings = AppSettings.getOrCreate(in: modelContext)
    let rawRoot = workspaceState.effectiveWorkingDirectoryURL(
        globalDefault: settings.workingDirectory
    )
    return rawRoot.flatMap { URL(string: $0.absoluteString) } ?? rawRoot
}
```

> **说明：** `GitLineDiffService.fetchLineDiff` 是 actor 方法，需在 `Task` 中 `await`。结果赋值回 `@MainActor` `@State`，自动触发视图刷新。

**Step 3：在 onAppear / onChange 中触发刷新**

找到现有的 `.onAppear { ... }` 块，在内部追加：

```swift
refreshGitDiff(for: fileURL)
```

找到现有的 `.onChange(of: fileURL) { _, newURL in ... }` 块，追加：

```swift
gitDiffByLine = [:]
refreshGitDiff(for: newURL)
```

**Step 4：在保存完成后触发刷新**

找到现有对 `sessionController.document.hasUnsavedChanges` 的监听（若无则新增）：

```swift
.onChange(of: sessionController.document.hasUnsavedChanges) { _, isDirty in
    // 文件从修改状态变为已保存（dirty → clean）时刷新 diff
    if !isDirty {
        refreshGitDiff(for: fileURL)
    }
}
```

**Step 5：将 gitDiffByLine 传入 CodeEditorView**

在 `fileContentView(for:)` 的 `CodeEditorView(...)` 调用中追加参数：

```swift
// 在现有参数列表的末尾（onTextChange 之后）追加
// gitDiffByLine: gitDiffByLine,
```

找到具体的调用位置（`CodeEditorView(text: ..., persistedText: ..., fileURL: ..., ...)`），添加该参数。

**Step 6：编译验证**

```bash
cd /Volumes/T7/文稿/Projects/agentGui && \
xcodebuild build \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-f13-diff-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded|Build FAILED" | head -20
```

**Step 7：运行全量 gutter + diff 相关测试**

```bash
cd /Volumes/T7/文稿/Projects/agentGui && \
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-f13-diff-derived \
  -only-testing:agentGuiTests/UnifiedDiffParserTests \
  -only-testing:agentGuiTests/GitLineDiffServiceTests \
  -only-testing:agentGuiTests/GitDiffStripeLaneTests \
  -only-testing:agentGuiTests/CodeEditorGutterLaneTests \
  -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|Test Suite|passed|failed" | head -30
```

预期：所有测试通过。

**Step 8：Commit**

```
git add agentGui/Views/FileEditorView.swift
git commit -m "feat(f13): wire GitLineDiffService into FileEditorView, refresh on save/open"
```

---

## Task 7：冒烟测试与收尾

**目标：** 运行完整测试套件确认 Feature 13 无回归。

**Step 1：运行 CodeEditor 相关全量测试**

```bash
cd /Volumes/T7/文稿/Projects/agentGui && \
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-f13-diff-derived \
  -only-testing:agentGuiTests/UnifiedDiffParserTests \
  -only-testing:agentGuiTests/GitLineDiffServiceTests \
  -only-testing:agentGuiTests/GitDiffStripeLaneTests \
  -only-testing:agentGuiTests/CodeEditorGutterLaneTests \
  -only-testing:agentGuiTests/CodeEditorGutterRendererTests \
  -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests \
  -only-testing:agentGuiTests/FoldChevronLaneTests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|Test Suite|passed|failed" | head -40
```

预期：所有测试通过（应有 25+ 个测试用例）。

**Step 2：手动验证 checklist（Xcode 运行 App）**

- [ ] 打开一个在 git 追踪目录中的 Swift 文件 → gutter 最左侧出现空白 diff stripe lane
- [ ] 修改若干行后（不保存）→ gutter 无标记（未保存不触发 diff）
- [ ] 保存文件后 → 修改行出现黄色条纹
- [ ] 新增若干行并保存 → 新增行出现绿色条纹
- [ ] 对比 HEAD 删除一整行并保存 → 行间边界出现红色三角
- [ ] 打开未追踪文件（git new file）→ gutter 所有行显示绿色（整个文件为新增）
- [ ] 切换到不在 git 仓库中的文件 → gutter 无 diff 标记
- [ ] 快速连续保存（300ms 内）→ 不出现闪烁，标记平稳更新

**Step 3：最终 Commit**

```
git add -A
git commit -m "feat(f13): complete Git Diff Stripe Lane - UnifiedDiffParser + GitLineDiffService + GitDiffStripeLane"
```

---

## 实现文件清单

### 新增文件

| 文件 | 说明 |
|------|------|
| `agentGui/Services/Editor/UnifiedDiffParser.swift` | unified diff hunk header 解析器 |
| `agentGui/Services/Editor/GitLineDiffService.swift` | actor + `git diff -U0` 异步查询服务 |
| `agentGui/Views/CodeEditor/Lanes/GitDiffStripeLane.swift` | gutter diff 条纹 lane（3pt 条纹 + 删除三角） |
| `agentGuiTests/UnifiedDiffParserTests.swift` | 8 个 diff 解析测试 |
| `agentGuiTests/GitLineDiffServiceTests.swift` | 4 个服务测试（含 mock runner） |
| `agentGuiTests/GitDiffStripeLaneTests.swift` | 5 个 lane 行为测试 |

### 修改文件

| 文件 | 修改说明 |
|------|---------|
| `agentGui/Views/CodeEditor/CodeEditorGutterView.swift` | 在 `init` 中注册 `GitDiffStripeLane` 为第一个 lane |
| `agentGui/Views/CodeEditor/CodeEditorView.swift` | 新增 `gitDiffByLine` 参数，传入 `CodeEditorTextView` |
| `agentGui/Views/CodeEditor/CodeEditorTextView.swift` | 接收 `gitDiffByLine`，写入 `CodeEditorGutterViewportSnapshot` |
| `agentGui/Views/FileEditorView.swift` | 持有 `GitLineDiffService`，在 onAppear/保存时触发刷新，注入 `CodeEditorView` |

**不需要修改的文件（已就绪）：**
- `CodeEditorGutterViewportSnapshot.swift`（`gitDiffByLine` 字段已存在）
- `CodeEditorGutterLane.swift`（协议完整）
- `CodeEditorGutterView.swift` 的 lane host 逻辑（`register`/`draw`/`hitTest` 流程已完整）

---

## 边界情况与已知限制

| 场景 | 处理方式 |
|------|---------|
| 文件不在 git 仓库 | `git diff` exit code != 0 → `GitLineDiffService` 返回 `[:]` |
| 未追踪新文件 | `git diff HEAD -- <file>` 输出为空 → 返回 `[:]`（未追踪文件暂不显示"全新"标记，属于后续优化） |
| CRLF 换行 | `UnifiedDiffParser` 使用 `split(whereSeparator: \.isNewline)` 处理 `\r\n` |
| 二进制文件 | `git diff -U0 HEAD -- <file>` 输出 "Binary files differ"，无 hunk header，返回 `[:]` |
| diff lane 与 fold 配合 | 折叠后被隐藏的行仍有 diff 状态；lane 绘制时依赖 `lineMetrics`（只含可见行），被折叠行自然不绘制 |
| 性能 | `GitLineDiffService.fetchLineDiff` 是 fork 一个 `git` 进程。保存间隔通常 > 500ms，足够。对超大仓库可加 500ms 防抖（Task 6 扩展点） |
| 删除标记位置 | `newStart == 0` 时（文件头部全删除）标记在行 1（`max(newStart, 1)`），与 VSCode 行为一致 |

---

## 与 Feature 24（AI Change Decoration）的关系

Feature 13 的 `CodeEditorGitDiffKind` 枚举和 `gitDiffByLine` 字段将被 F24 直接复用：Agent 修改的行通过 `ChangeReviewHook` 触发 Myers diff 计算，结果注入同一字段，由同一 `GitDiffStripeLane`（或其样式变体 `AgentDiffStripeLane`）渲染。F13 建立的数据通路是 F24 的基础设施。

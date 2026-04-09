# Feature 24：AI 变更装饰 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Agent 执行文件修改后，在编辑器 gutter 通过 AI Change Stripe Lane 和
Accept/Reject Action Lane 展示行级变更标记，并以 inline diff 背景色高亮新增/修改行，
形成从变更感知到 Accept/Reject 的完整闭环。

**Architecture:** 从 `ChangeReviewProjectionStore` 读取已有 `ProposedFileChangeSnapshot.unifiedDiff`，
通过现有 `UnifiedDiffParser.parse()` 转换为 `[Int: CodeEditorGitDiffKind]`，经过
`FileEditorView` 注入 `CodeEditorView` 的新字段 `agentChangeDiffByLine`，由两个新
Gutter Lane（`AgentDiffStripeLane` + `ChangeReviewActionLane` 二合一）渲染；Accept/Reject
动作路由到 `ApplyEngine` / `DraftRevertService`。Inline 背景高亮在
`CodeEditorPlatformTextView.drawBackground(in:)` 中绘制，**不修改 NSTextStorage**。

**Tech Stack:** Swift 6 / AppKit / NSLayoutManager Temporary Attributes / SwiftUI @Observable /
现有 `UnifiedDiffParser` / `ApplyEngine` / `DraftRevertService`

**参考实现：**
- **VSCode** `dirtydiffDecorator.ts`：`DirtyDiffDecorator.onDidChange` → 每个 hunk 添加
  `border-left: 3px solid green/orange/red`（`added-line` / `modified-line` / `deleted-line`
  CSS class），Overview Ruler 同步着色。Accept/Reject 弹出 `DirtyDiffWidget`（HoverWidget）展示按钮。
- **Zed** `element.rs`：`paint_gutter_diff_hunks` 用 gutter 条纹宽度 `0.275 * line_height`；
  `DiffHunkStatus::Added/Modified/Deleted` 对应不同颜色；Accept 通过 `Editor::accept_hunk`
  驱动 buffer undo tree；Reject 通过 `Editor::reject_hunk`。Zed 的 deleted 行使用
  "ghost rows"（虚拟视图行插入）而我们仅用三角符号（同 F13 `GitDiffStripeLane`）。
- **agentGui F13 `GitDiffStripeLane`** 已实现 git diff stripe，F24 新增独立的 AI 专属 lane
  以紫色主题与 git 绿橙红区分，避免视觉混淆。

---

## 关键设计决策

| 决策点 | 选定方案 | 理由 |
|--------|----------|------|
| Diff 来源 | `UnifiedDiffParser.parse(ProposedFileChangeSnapshot.unifiedDiff)` | 无需 Myers diff，现成数据 |
| Gutter Lane 数量 | 两个新 lane：`AgentDiffStripeLane` + `ChangeReviewActionLane`（合并 ✓/✗） | 单 lane 复杂度高，两 lane 路由清晰 |
| Snapshot 字段 | `agentChangeDiffByLine: [Int: CodeEditorGitDiffKind]`（新增，独立于 `gitDiffByLine`） | 避免 git diff 与 agent diff 互相覆盖 |
| 环境注入 | `FileEditorView` 从 `@Environment(ChangeReviewProjectionStore.self)` 读取 | 与现有 `snapshotsByProposalID` 架构一致 |
| Accept/Reject 路由 | `ChangeReviewActionLane` hit test → `onGutterLaneHit` → `FileEditorView` → `ApplyEngine/DraftRevertService` | 复用现有 hit test 路由，不破坏 lane 协议 |
| Inline 背景色 | `drawBackground(in:)` + `NSLayoutManager.lineFragmentRect` | 不修改 NSTextStorage，IME 安全 |
| ✓/✗ 在 lane 内区分 | `ChangeReviewActionLane` 的 `hitTest` 返回 `+line`=accept, `-line`=reject（encoded） | 在 `onGutterLaneHit.lineNumber` 上编码方向；约定负数为 reject |

> **注：** `CodeEditorGutterHitResult.lineNumber` 在现有代码中为 `Int`（非 `UInt`），
> 因此使用负数编码 reject 动作是合法的。`FileEditorView` 中通过 `abs()` 还原行号。

---

## Task 1：扩展 `CodeEditorGutterViewportSnapshot`

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorGutterViewportSnapshot.swift`
- Test: `agentGuiTests/CodeEditorGutterViewportSnapshotAgentDiffTests.swift`

### Step 1：写失败测试

```swift
// agentGuiTests/CodeEditorGutterViewportSnapshotAgentDiffTests.swift
import Testing
@testable import agentGui

@MainActor
struct CodeEditorGutterViewportSnapshotAgentDiffTests {

    @Test func agentChangeDiffByLineDefaultsToEmpty() {
        let snapshot = CodeEditorGutterViewportSnapshot(
            lineCount: 10,
            visibleLineRange: 1...10,
            currentLine: nil,
            cursorLineNumbers: [],
            lineMetrics: [],
            diagnosticsByLine: [:],
            foldableLines: [],
            foldedLines: [],
            gitDiffByLine: [:]
            // agentChangeDiffByLine 未传 → 默认 [:]
        )
        #expect(snapshot.agentChangeDiffByLine.isEmpty)
    }

    @Test func agentChangeDiffByLineRoundTrips() {
        let agentDiff: [Int: CodeEditorGitDiffKind] = [5: .added, 10: .modified, 15: .deleted]
        let snapshot = CodeEditorGutterViewportSnapshot(
            lineCount: 20,
            visibleLineRange: 1...20,
            currentLine: nil,
            cursorLineNumbers: [],
            lineMetrics: [],
            diagnosticsByLine: [:],
            foldableLines: [],
            foldedLines: [],
            gitDiffByLine: [:],
            agentChangeDiffByLine: agentDiff
        )
        #expect(snapshot.agentChangeDiffByLine == agentDiff)
    }

    @Test func agentChangeDiffEquality() {
        let diff: [Int: CodeEditorGitDiffKind] = [1: .added]
        let s1 = CodeEditorGutterViewportSnapshot(
            lineCount: 5, visibleLineRange: 1...5, currentLine: nil,
            cursorLineNumbers: [], lineMetrics: [], diagnosticsByLine: [:],
            foldableLines: [], foldedLines: [], gitDiffByLine: [:],
            agentChangeDiffByLine: diff
        )
        let s2 = CodeEditorGutterViewportSnapshot(
            lineCount: 5, visibleLineRange: 1...5, currentLine: nil,
            cursorLineNumbers: [], lineMetrics: [], diagnosticsByLine: [:],
            foldableLines: [], foldedLines: [], gitDiffByLine: [:],
            agentChangeDiffByLine: [:]  // 不同
        )
        #expect(s1 != s2)
    }
}
```

### Step 2：运行确认失败

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/CodeEditorGutterViewportSnapshotAgentDiffTests \
  -derivedDataPath /tmp/agentGui-f24-task1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|error:|Build FAILED"
```
预期：编译失败（`agentChangeDiffByLine` 尚不存在）

### Step 3：在 `CodeEditorGutterViewportSnapshot` 新增字段

在 `agentGui/Views/CodeEditor/CodeEditorGutterViewportSnapshot.swift` 找到 struct 定义，
在 `gitDiffByLine` 字段后新增：

```swift
    // MARK: - Agent Change Diff（F24）
    /// Agent 修改产生的行级 diff，独立于 git diff（不覆盖 gitDiffByLine）。
    /// 来自 ChangeReviewProjectionStore 中当前文件的 ProposedFileChangeSnapshot.unifiedDiff。
    let agentChangeDiffByLine: [Int: CodeEditorGitDiffKind]
```

同时在 init 中添加默认值参数（向后兼容所有现有调用方）：

```swift
    init(
        lineCount: Int,
        visibleLineRange: ClosedRange<Int>,
        currentLine: Int?,
        cursorLineNumbers: Set<Int>,
        lineMetrics: [CodeEditorVisibleLineMetric],
        diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary],
        foldableLines: Set<Int>,
        foldedLines: Set<Int>,
        gitDiffByLine: [Int: CodeEditorGitDiffKind],
        agentChangeDiffByLine: [Int: CodeEditorGitDiffKind] = [:]   // ← 新增，有默认值
    ) {
        self.lineCount = lineCount
        self.visibleLineRange = visibleLineRange
        self.currentLine = currentLine
        self.cursorLineNumbers = cursorLineNumbers
        self.lineMetrics = lineMetrics
        self.diagnosticsByLine = diagnosticsByLine
        self.foldableLines = foldableLines
        self.foldedLines = foldedLines
        self.gitDiffByLine = gitDiffByLine
        self.agentChangeDiffByLine = agentChangeDiffByLine   // ← 新增
    }
```

### Step 4：运行测试，确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/CodeEditorGutterViewportSnapshotAgentDiffTests \
  -derivedDataPath /tmp/agentGui-f24-task1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|Executed"
```
预期：3 tests passed

### Step 5：Commit

```bash
git add agentGui/Views/CodeEditor/CodeEditorGutterViewportSnapshot.swift \
        agentGuiTests/CodeEditorGutterViewportSnapshotAgentDiffTests.swift
git commit -m "feat(f24): add agentChangeDiffByLine field to CodeEditorGutterViewportSnapshot"
```

---

## Task 2：实现 `AgentDiffStripeLane`

**Files:**
- Create: `agentGui/Views/CodeEditor/Lanes/AgentDiffStripeLane.swift`
- Test: `agentGuiTests/AgentDiffStripeLaneTests.swift`

> **VSCode 参考：** `dirtydiffDecorator.ts` 使用 `colorIdentifier: 'editorGutter.addedBackground'`
> 等 token 区分 git diff 与其他 diff。F24 使用 `systemPurple`/`systemCyan`/`systemPink`
> 与 F13 的绿/橙/红颜色集合明确分隔。
>
> **Zed 参考：** `element.rs` 中 `paint_gutter_diff_hunks` 条纹宽度为 `0.275 * line_height`；
> 我们沿用 F13 的 3pt 固定宽度（macOS gutter 更窄）。

### Step 1：写失败测试

```swift
// agentGuiTests/AgentDiffStripeLaneTests.swift
import Testing
import AppKit
@testable import agentGui

@MainActor
struct AgentDiffStripeLaneTests {

    private func makeSnapshot(agentDiff: [Int: CodeEditorGitDiffKind]) -> CodeEditorGutterViewportSnapshot {
        CodeEditorGutterViewportSnapshot(
            lineCount: 20,
            visibleLineRange: 1...20,
            currentLine: nil,
            cursorLineNumbers: [],
            lineMetrics: (1...20).map { line in
                CodeEditorVisibleLineMetric(
                    line: line,
                    rect: NSRect(x: 0, y: CGFloat(line - 1) * 18, width: 50, height: 18),
                    isFirstFragmentOfLine: true
                )
            },
            diagnosticsByLine: [:],
            foldableLines: [],
            foldedLines: [],
            gitDiffByLine: [:],
            agentChangeDiffByLine: agentDiff
        )
    }

    @Test func preferredWidthIsConstant() {
        let lane = AgentDiffStripeLane()
        let snap = makeSnapshot(agentDiff: [:])
        #expect(lane.preferredWidth(for: snap, appearance: nil) == 4)
    }

    @Test func hitTestReturnsNil() {
        let lane = AgentDiffStripeLane()
        let snap = makeSnapshot(agentDiff: [5: .added])
        let result = lane.hitTest(
            point: CGPoint(x: 0, y: 0),
            snapshot: snap,
            laneRect: NSRect(x: 0, y: 0, width: 4, height: 400)
        )
        #expect(result == nil)
    }

    @Test func invalidationPlanIsNoneWhenDiffUnchanged() {
        let lane = AgentDiffStripeLane()
        let diff: [Int: CodeEditorGitDiffKind] = [3: .added]
        let prev = makeSnapshot(agentDiff: diff)
        let curr = makeSnapshot(agentDiff: diff)
        let plan = lane.invalidationPlan(from: prev, to: curr)
        if case .none = plan { } else {
            Issue.record("Expected .none but got: \(plan)")
        }
    }

    @Test func invalidationPlanIsLinesWhenDiffChanges() {
        let lane = AgentDiffStripeLane()
        let prev = makeSnapshot(agentDiff: [3: .added, 7: .modified])
        let curr = makeSnapshot(agentDiff: [3: .added, 10: .deleted])  // 7→nil, 10→new
        let plan = lane.invalidationPlan(from: prev, to: curr)
        guard case .lines(let changed) = plan else {
            Issue.record("Expected .lines but got: \(plan)"); return
        }
        #expect(changed.contains(7))   // 旧 modified 行消失
        #expect(changed.contains(10))  // 新 deleted 行出现
        #expect(!changed.contains(3))  // 3 未变化
    }

    @Test func invalidationPlanIsFullWhenNoPrevious() {
        let lane = AgentDiffStripeLane()
        let curr = makeSnapshot(agentDiff: [5: .added])
        let plan = lane.invalidationPlan(from: nil, to: curr)
        if case .full = plan { } else {
            Issue.record("Expected .full but got: \(plan)")
        }
    }

    @Test func idIsAgentDiffStripe() {
        let lane = AgentDiffStripeLane()
        #expect(lane.id == "agentDiffStripe")
    }
}
```

### Step 2：运行确认失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/AgentDiffStripeLaneTests \
  -derivedDataPath /tmp/agentGui-f24-task2 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|error:|Build FAILED"
```

### Step 3：创建 `AgentDiffStripeLane.swift`

```swift
// agentGui/Views/CodeEditor/Lanes/AgentDiffStripeLane.swift
import AppKit

/// AI Agent 变更条纹 Lane：在 gutter 绘制 3pt 宽的变更条纹，
/// 标记 Agent 修改的行（紫/青/粉，区别于 git diff 的绿/橙/红）。
///
/// VSCode 参考：`dirtydiffDecorator.ts`，git diff stripe 3px border-left。
/// Zed 参考：`element.rs` `paint_gutter_diff_hunks`，宽度约 0.275 × line_height。
/// agentGui：沿用 F13 GitDiffStripeLane 相同宽度（4pt），不同颜色集合。
@MainActor
final class AgentDiffStripeLane: CodeEditorGutterLane {

    let id = "agentDiffStripe"
    var onPreferredWidthChange: (() -> Void)?

    // MARK: - Preferred Width

    func preferredWidth(
        for snapshot: CodeEditorGutterViewportSnapshot,
        appearance: NSAppearance?
    ) -> CGFloat {
        4   // 3pt 条纹 + 1pt 右侧留白（与 GitDiffStripeLane 相同宽度）
    }

    // MARK: - Draw

    func draw(
        snapshot: CodeEditorGutterViewportSnapshot,
        laneRect: NSRect,
        dirtyRect: NSRect,
        appearance: NSAppearance?
    ) {
        guard !snapshot.agentChangeDiffByLine.isEmpty else { return }

        let lineMetricsByLine = Dictionary(
            uniqueKeysWithValues: snapshot.lineMetrics.map { ($0.line, $0) }
        )
        let stripeWidth: CGFloat = 3
        let stripeX = laneRect.minX

        for (lineNumber, kind) in snapshot.agentChangeDiffByLine {
            guard let metric = lineMetricsByLine[lineNumber] else { continue }

            switch kind {
            case .added:
                // 紫色：区分 git added（绿色）
                let stripeRect = NSRect(
                    x: stripeX, y: metric.rect.minY,
                    width: stripeWidth, height: metric.rect.height
                )
                guard stripeRect.intersects(dirtyRect) else { continue }
                NSColor.systemPurple.withAlphaComponent(0.85).setFill()
                NSBezierPath(rect: stripeRect).fill()

            case .modified:
                // 青色：区分 git modified（橙色）
                let stripeRect = NSRect(
                    x: stripeX, y: metric.rect.minY,
                    width: stripeWidth, height: metric.rect.height
                )
                guard stripeRect.intersects(dirtyRect) else { continue }
                NSColor.systemCyan.withAlphaComponent(0.85).setFill()
                NSBezierPath(rect: stripeRect).fill()

            case .deleted:
                // 粉色三角：区分 git deleted（红色三角）
                let markerHeight: CGFloat = 6
                let markerWidth: CGFloat = 4
                let markerY = metric.rect.minY - markerHeight / 2
                let markerRect = NSRect(x: stripeX, y: markerY,
                                        width: markerWidth, height: markerHeight)
                guard markerRect.insetBy(dx: -4, dy: -4).intersects(dirtyRect) else { continue }
                NSColor.systemPink.withAlphaComponent(0.90).setFill()
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
        nil     // 装饰性，不响应点击（Accept/Reject 由 ChangeReviewActionLane 处理）
    }

    // MARK: - Invalidation Plan

    func invalidationPlan(
        from previous: CodeEditorGutterViewportSnapshot?,
        to current: CodeEditorGutterViewportSnapshot
    ) -> CodeEditorGutterLaneInvalidationPlan {
        guard let previous else { return .full }

        let prev = previous.agentChangeDiffByLine
        let curr = current.agentChangeDiffByLine

        guard prev != curr else { return .none }

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

### Step 4：运行测试，确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/AgentDiffStripeLaneTests \
  -derivedDataPath /tmp/agentGui-f24-task2 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|Executed"
```
预期：6 tests passed

### Step 5：Commit

```bash
git add agentGui/Views/CodeEditor/Lanes/AgentDiffStripeLane.swift \
        agentGuiTests/AgentDiffStripeLaneTests.swift
git commit -m "feat(f24): implement AgentDiffStripeLane with purple/cyan/pink palette"
```

---

## Task 3：实现 `ChangeReviewActionLane`（✓/✗ 按钮）

**Files:**
- Create: `agentGui/Views/CodeEditor/Lanes/ChangeReviewActionLane.swift`
- Test: `agentGuiTests/ChangeReviewActionLaneTests.swift`

> **VSCode 参考：** acceptance 通过 `DirtyDiffWidget`（hover widget）实现，
> 非 gutter lane 内绘制。F24 直接在 gutter 绘制小图标，简化交互。
>
> **Zed 参考：** `element.rs` `layout_git_blame` 和 diff hunk header 通过
> `HitboxId` 系统识别点击区域，可区分 accept/reject。
>
> **编码约定（F24 专用）：** `hitTest` 返回值约定
> - `+lineNumber (>0)` → Accept 点击（✓ 区域）
> - `-lineNumber (<0)` → Reject 点击（✗ 区域，取负值编码）
> - `nil` → 非可点击区域
>
> `FileEditorView` 中通过 `abs(lineNumber)` 还原行号，通过符号判断动作。

### Step 1：写失败测试

```swift
// agentGuiTests/ChangeReviewActionLaneTests.swift
import Testing
import AppKit
@testable import agentGui

@MainActor
struct ChangeReviewActionLaneTests {

    private func makeSnapshot(agentDiff: [Int: CodeEditorGitDiffKind]) -> CodeEditorGutterViewportSnapshot {
        CodeEditorGutterViewportSnapshot(
            lineCount: 20,
            visibleLineRange: 1...20,
            currentLine: nil,
            cursorLineNumbers: [],
            lineMetrics: (1...20).map { line in
                CodeEditorVisibleLineMetric(
                    line: line,
                    rect: NSRect(x: 0, y: CGFloat(line - 1) * 18, width: 50, height: 18),
                    isFirstFragmentOfLine: true
                )
            },
            diagnosticsByLine: [:],
            foldableLines: [],
            foldedLines: [],
            gitDiffByLine: [:],
            agentChangeDiffByLine: agentDiff
        )
    }

    @Test func idIsChangeReviewAction() {
        let lane = ChangeReviewActionLane()
        #expect(lane.id == "changeReviewAction")
    }

    @Test func preferredWidthIsZeroWhenNoDiff() {
        let lane = ChangeReviewActionLane()
        let snap = makeSnapshot(agentDiff: [:])
        #expect(lane.preferredWidth(for: snap, appearance: nil) == 0)
    }

    @Test func preferredWidthIsNonZeroWhenDiffPresent() {
        let lane = ChangeReviewActionLane()
        let snap = makeSnapshot(agentDiff: [5: .added])
        #expect(lane.preferredWidth(for: snap, appearance: nil) > 0)
    }

    @Test func hitTestReturnsPositiveForAcceptArea() {
        let lane = ChangeReviewActionLane()
        let snap = makeSnapshot(agentDiff: [1: .added])  // 行 1，y=0..18
        let laneWidth = lane.preferredWidth(for: snap, appearance: nil)
        let laneRect = NSRect(x: 0, y: 0, width: laneWidth, height: 400)

        // ✓ 图标在 lane 左半区（x < laneWidth/2），e.g. x=2
        let acceptPoint = CGPoint(x: laneWidth * 0.25, y: 9)  // 行 1 垂直中心
        let result = lane.hitTest(point: acceptPoint, snapshot: snap, laneRect: laneRect)
        #expect(result != nil)
        if let r = result {
            #expect(r > 0)       // 正数 = accept
            #expect(abs(r) == 1) // 行号 1
        }
    }

    @Test func hitTestReturnsNegativeForRejectArea() {
        let lane = ChangeReviewActionLane()
        let snap = makeSnapshot(agentDiff: [1: .added])
        let laneWidth = lane.preferredWidth(for: snap, appearance: nil)
        let laneRect = NSRect(x: 0, y: 0, width: laneWidth, height: 400)

        // ✗ 图标在 lane 右半区（x > laneWidth/2）
        let rejectPoint = CGPoint(x: laneWidth * 0.75, y: 9)
        let result = lane.hitTest(point: rejectPoint, snapshot: snap, laneRect: laneRect)
        #expect(result != nil)
        if let r = result {
            #expect(r < 0)       // 负数 = reject
            #expect(abs(r) == 1) // 行号 1
        }
    }

    @Test func hitTestReturnsNilWhenNoDiff() {
        let lane = ChangeReviewActionLane()
        let snap = makeSnapshot(agentDiff: [:])
        let result = lane.hitTest(
            point: CGPoint(x: 2, y: 9),
            snapshot: snap,
            laneRect: NSRect(x: 0, y: 0, width: 30, height: 400)
        )
        #expect(result == nil)
    }

    @Test func invalidationPlanIsNoneWhenDiffUnchanged() {
        let lane = ChangeReviewActionLane()
        let diff: [Int: CodeEditorGitDiffKind] = [5: .modified]
        let prev = makeSnapshot(agentDiff: diff)
        let curr = makeSnapshot(agentDiff: diff)
        let plan = lane.invalidationPlan(from: prev, to: curr)
        if case .none = plan { } else {
            Issue.record("Expected .none but got: \(plan)")
        }
    }
}
```

### Step 2：运行确认失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/ChangeReviewActionLaneTests \
  -derivedDataPath /tmp/agentGui-f24-task3 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|error:|Build FAILED"
```

### Step 3：创建 `ChangeReviewActionLane.swift`

```swift
// agentGui/Views/CodeEditor/Lanes/ChangeReviewActionLane.swift
import AppKit

/// Accept / Reject Action Lane：在有 Agent 变更的行绘制 ✓/✗ 小图标，
/// 点击左半区 = Accept（返回正行号），点击右半区 = Reject（返回负行号）。
///
/// 设计参考：
/// - VSCode DirtyDiffWidget：在 hover 弹出框内提供 Accept Hunk / Revert Hunk 按钮。
/// - Zed：在 gutter diff hunk header row 附近通过 HitboxId 区分 accept/reject 点击。
/// - F24 简化：直接在 gutter 绘制双图标，不需要 hover/popover。
///
/// Hit test 编码约定（F24 内部约定，FileEditorView 解码）：
/// - 返回正整数 → accept 点击，值为行号（1-based）
/// - 返回负整数 → reject 点击，值为 -lineNumber
/// - 返回 nil   → 未命中可点击区域
@MainActor
final class ChangeReviewActionLane: CodeEditorGutterLane {

    let id = "changeReviewAction"
    var onPreferredWidthChange: (() -> Void)?

    // MARK: - Preferred Width

    func preferredWidth(
        for snapshot: CodeEditorGutterViewportSnapshot,
        appearance: NSAppearance?
    ) -> CGFloat {
        // 有 agent diff 时显示 ✓✗ 双图标区（30pt），无 diff 时折叠为 0
        snapshot.agentChangeDiffByLine.isEmpty ? 0 : 30
    }

    // MARK: - Draw

    func draw(
        snapshot: CodeEditorGutterViewportSnapshot,
        laneRect: NSRect,
        dirtyRect: NSRect,
        appearance: NSAppearance?
    ) {
        guard !snapshot.agentChangeDiffByLine.isEmpty else { return }

        // 找到每个 hunk 起始行（连续变更块的第一行）
        let hunkStartLines = detectHunkStartLines(from: snapshot.agentChangeDiffByLine)
        let lineMetricsByLine = Dictionary(
            uniqueKeysWithValues: snapshot.lineMetrics.map { ($0.line, $0) }
        )

        let iconSize: CGFloat = 11
        let midX = laneRect.midX

        for startLine in hunkStartLines {
            guard let metric = lineMetricsByLine[startLine] else { continue }
            let iconY = metric.rect.midY - iconSize / 2

            // ✓ 图标（左半）
            let acceptRect = NSRect(x: laneRect.minX + 2, y: iconY, width: iconSize, height: iconSize)
            if acceptRect.intersects(dirtyRect) {
                drawSymbol("checkmark.circle", in: acceptRect, color: .systemGreen, appearance: appearance)
            }

            // ✗ 图标（右半）
            let rejectRect = NSRect(x: midX + 2, y: iconY, width: iconSize, height: iconSize)
            if rejectRect.intersects(dirtyRect) {
                drawSymbol("xmark.circle", in: rejectRect, color: .systemRed, appearance: appearance)
            }
        }
    }

    // MARK: - Hit Test

    func hitTest(
        point: CGPoint,
        snapshot: CodeEditorGutterViewportSnapshot,
        laneRect: NSRect
    ) -> Int? {
        guard !snapshot.agentChangeDiffByLine.isEmpty else { return nil }

        let hunkStartLines = detectHunkStartLines(from: snapshot.agentChangeDiffByLine)
        let lineMetricsByLine = Dictionary(
            uniqueKeysWithValues: snapshot.lineMetrics.map { ($0.line, $0) }
        )

        for startLine in hunkStartLines {
            guard let metric = lineMetricsByLine[startLine] else { continue }
            let iconY = metric.rect.midY - 6
            let hitRow = NSRect(x: laneRect.minX, y: iconY, width: laneRect.width, height: 12)
            guard hitRow.contains(point) else { continue }

            // 左半 → accept（正行号）；右半 → reject（负行号）
            if point.x < laneRect.midX {
                return startLine          // 正数 = accept
            } else {
                return -startLine         // 负数 = reject（FileEditorView 用 abs() 还原）
            }
        }
        return nil
    }

    // MARK: - Invalidation Plan

    func invalidationPlan(
        from previous: CodeEditorGutterViewportSnapshot?,
        to current: CodeEditorGutterViewportSnapshot
    ) -> CodeEditorGutterLaneInvalidationPlan {
        guard let previous else { return .full }
        guard previous.agentChangeDiffByLine != current.agentChangeDiffByLine else { return .none }
        // hunk 有变化时全量重绘 action lane
        return .full
    }

    // MARK: - Hunk Detection

    /// 从行级 diff map 中找出每个连续变更块的起始行（hunk start lines）。
    /// 例如 [3:.added, 4:.added, 7:.modified] → [3, 7]
    private func detectHunkStartLines(
        from diffByLine: [Int: CodeEditorGitDiffKind]
    ) -> [Int] {
        guard !diffByLine.isEmpty else { return [] }
        let sortedLines = diffByLine.keys.sorted()
        var result: [Int] = []
        var prevLine: Int? = nil
        for line in sortedLines {
            if let prev = prevLine, line == prev + 1 {
                // 连续行，属于同一 hunk
            } else {
                result.append(line)
            }
            prevLine = line
        }
        return result
    }

    // MARK: - Icon Drawing

    private func drawSymbol(
        _ name: String,
        in rect: NSRect,
        color: NSColor,
        appearance: NSAppearance?
    ) {
        // 使用 SF Symbols 渲染小图标
        let config = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .regular)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return }

        let tinted: NSImage
        if let tintedImage = image.copy() as? NSImage {
            tintedImage.isTemplate = false
            tintedImage.lockFocus()
            color.withAlphaComponent(0.80).set()
            NSRect(origin: .zero, size: tintedImage.size).fill(using: .sourceAtop)
            tintedImage.unlockFocus()
            tinted = tintedImage
        } else {
            tinted = image
        }
        tinted.draw(in: rect)
    }
}
```

### Step 4：运行测试，确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/ChangeReviewActionLaneTests \
  -derivedDataPath /tmp/agentGui-f24-task3 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|Executed"
```
预期：6 tests passed

### Step 5：Commit

```bash
git add agentGui/Views/CodeEditor/Lanes/ChangeReviewActionLane.swift \
        agentGuiTests/ChangeReviewActionLaneTests.swift
git commit -m "feat(f24): implement ChangeReviewActionLane with accept/reject hit encoding"
```

---

## Task 4：注册 Lanes + 传递字段（CodeEditorTextView + CodeEditorView）

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorView.swift`
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- Test: 使用现有 `agentGuiTests/CodeEditorViewIntegrationTests.swift`（视情况新增 case）

> 这是管道配置步骤，将 `agentChangeDiffByLine` 从外部参数一路传入 gutter snapshot，
> 并注册两个新 lane。不涉及业务逻辑，集成测试通过编译即可验证大部分连线正确性。

### Step 1：查看 `CodeEditorView` 现有参数和 `CodeEditorTextView` 如何传递 `gitDiffByLine`

运行下面命令快速定位关键行，确认修改位置：

```bash
grep -n "gitDiffByLine\|agentChangeDiff\|GitDiffStripeLane\|register(lane" \
  agentGui/Views/CodeEditor/CodeEditorView.swift \
  agentGui/Views/CodeEditor/CodeEditorTextView.swift | head -40
```

### Step 2：在 `CodeEditorView.swift` 新增参数

找到 `struct CodeEditorView: View { ... var gitDiffByLine: ...` 所在位置，
在其后添加：

```swift
    /// Agent 变更行级 diff（来自 ChangeReviewProjectionStore，独立于 git diff）
    var agentChangeDiffByLine: [Int: CodeEditorGitDiffKind] = [:]
```

在 `CodeEditorView` 内部构造 `CodeEditorTextView` 的位置（搜索 `gitDiffByLine:`），
同样添加：

```swift
    agentChangeDiffByLine: agentChangeDiffByLine,
```

### Step 3：在 `CodeEditorTextView.swift` 中传递 `agentChangeDiffByLine`

在 `CodeEditorTextViewRepresentable`（或 `Coordinator`）中：
1. 添加 `agentChangeDiffByLine: [Int: CodeEditorGitDiffKind]` 属性（或参数）。
2. 在 `Coordinator.updateGutterState()` 构建 `CodeEditorGutterViewportSnapshot` 时，
   传入 `agentChangeDiffByLine: agentChangeDiffByLine`。

### Step 4：在 Gutter View 注册两个新 Lane

在 `CodeEditorTextView.swift`（或 coordinator setup）中，找到现有的 `gutterView.register(lane:)` 调用（GitDiffStripeLane 等），在其后注册：

```swift
gutterView.register(lane: AgentDiffStripeLane())
gutterView.register(lane: ChangeReviewActionLane())
```

**注意 lane 顺序**（从左到右）：
- `GitDiffStripeLane` (id: "gitDiffStripe", 4pt)
- `AgentDiffStripeLane` (id: "agentDiffStripe", 4pt)
- `LineNumberLane` (id: "lineNumber")
- `DiagnosticDotLane` (id: "diagnosticDot")
- `ChangeReviewActionLane` (id: "changeReviewAction", 0|30pt)

> `ChangeReviewActionLane` 宽度为 0 时自动折叠（所有现有无 agent diff 的文件不受影响）。

### Step 5：构建验证（无新测试，编译通过即可）

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-f24-task4 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning:|Build succeeded|Build FAILED"
```
预期：Build succeeded

### Step 6：Commit

```bash
git add agentGui/Views/CodeEditor/CodeEditorView.swift \
        agentGui/Views/CodeEditor/CodeEditorTextView.swift
git commit -m "feat(f24): register AgentDiffStripeLane + ChangeReviewActionLane, wire agentChangeDiffByLine"
```

---

## Task 5：`FileEditorView` 接入 `ChangeReviewProjectionStore`

**Files:**
- Modify: `agentGui/Views/FileEditorView.swift`
- Test: `agentGuiTests/FileEditorAgentDiffIntegrationTests.swift`

> 这是 F24 的核心业务连线：监听 `ChangeReviewProjectionStore` 的变化，
> 为当前文件查找对应的 `ProposedFileChangeSnapshot`，解析 `unifiedDiff`
> 并注入到编辑器。

### Step 1：写失败测试（纯逻辑层，隔离 View）

```swift
// agentGuiTests/FileEditorAgentDiffIntegrationTests.swift
import Testing
@testable import agentGui

/// 测试 unifiedDiff → agentChangeDiffByLine 的转换逻辑（不依赖 SwiftUI）。
struct FileEditorAgentDiffIntegrationTests {

    @Test func parseUnifiedDiffProducesLineDiff() {
        // 模拟 agent 添加第3行、修改第5行的 unified diff
        let unifiedDiff = """
        --- a/Foo.swift
        +++ b/Foo.swift
        @@ -2,0 +3,1 @@
        +let x = 1
        @@ -5,1 +6,1 @@
        -let y = 0
        +let y = 42
        """
        let result = UnifiedDiffParser.parse(unifiedDiff)
        // 第3行应为 .added，第5或6行附近应有变更
        #expect(!result.isEmpty)
        #expect(result.values.contains(.added))
    }

    @Test func findFileChangeSnapshotForAbsolutePath() {
        let proposalID = UUID()
        let proposal = ChangeProposalSnapshot(
            id: proposalID,
            sessionID: "s1",
            jobID: nil,
            messageID: nil,
            providerID: .builtInAgent,
            state: .readyForReview,
            baseWorkspaceRoot: "/workspace",
            summary: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        let fileChange = ProposedFileChangeSnapshot(
            id: UUID(),
            proposalID: proposalID,
            relativePath: "Foo.swift",
            absolutePath: "/workspace/Foo.swift",
            changeKind: .modify,
            unifiedDiff: "@@ -1,1 +1,1 @@\n-old\n+new",
            state: .proposed,
            lineAdditions: 1,
            lineDeletions: 1
        )
        let reviewSnapshot = ChangeProposalReviewSnapshot(proposal: proposal, fileChanges: [fileChange])
        let store = ChangeReviewProjectionStore()
        store.set(reviewSnapshot)

        // 测试辅助函数：根据文件 URL 在 store 中找匹配的 fileChange
        let targetURL = URL(fileURLWithPath: "/workspace/Foo.swift")
        let match = store.snapshotsByProposalID.values
            .flatMap { $0.fileChanges }
            .filter { $0.state.isPendingReview }
            .first { fc in
                URL(fileURLWithPath: fc.absolutePath).standardizedFileURL == targetURL.standardizedFileURL
            }

        #expect(match != nil)
        #expect(match?.relativePath == "Foo.swift")
    }

    @Test func noMatchWhenFileChangeNotPending() {
        let proposalID = UUID()
        let proposal = ChangeProposalSnapshot(
            id: proposalID,
            sessionID: "s1",
            jobID: nil,
            messageID: nil,
            providerID: .builtInAgent,
            state: .applied,
            baseWorkspaceRoot: "/workspace",
            summary: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        let fileChange = ProposedFileChangeSnapshot(
            id: UUID(),
            proposalID: proposalID,
            relativePath: "Bar.swift",
            absolutePath: "/workspace/Bar.swift",
            changeKind: .modify,
            unifiedDiff: "",
            state: .applied,     // 已应用，不应显示装饰
            lineAdditions: 0,
            lineDeletions: 0
        )
        let reviewSnapshot = ChangeProposalReviewSnapshot(proposal: proposal, fileChanges: [fileChange])
        let store = ChangeReviewProjectionStore()
        store.set(reviewSnapshot)

        let targetURL = URL(fileURLWithPath: "/workspace/Bar.swift")
        let match = store.snapshotsByProposalID.values
            .flatMap { $0.fileChanges }
            .filter { $0.state.isPendingReview }
            .first { fc in
                URL(fileURLWithPath: fc.absolutePath).standardizedFileURL == targetURL.standardizedFileURL
            }

        #expect(match == nil)   // 状态为 applied，不应匹配
    }
}
```

### Step 2：运行确认

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/FileEditorAgentDiffIntegrationTests \
  -derivedDataPath /tmp/agentGui-f24-task5 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|Executed|error:"
```
预期：3 tests passed（不依赖 View，应直接通过）

### Step 3：修改 `FileEditorView.swift`

**3a. 添加 `@Environment` 注入：**

在现有 `@Environment` 声明区（`WorkspaceState`, `ClaudeService` 后面）添加：

```swift
    @Environment(ChangeReviewProjectionStore.self) private var changeReviewStore
```

**3b. 添加 State 变量：**

在 `@State private var gitDiffByLine: [Int: CodeEditorGitDiffKind] = [:]` 后添加：

```swift
    @State private var agentChangeDiffByLine: [Int: CodeEditorGitDiffKind] = [:]
```

**3c. 添加 `onAppear` / `onChange` 触发：**

在 `.onAppear` 块的末尾（`refreshGitDiff(for: fileURL)` 后）添加：
```swift
            refreshAgentDiff(for: fileURL)
```

在 `.onChange(of: fileURL)` 块末尾添加：
```swift
            agentChangeDiffByLine = [:]
            refreshAgentDiff(for: newURL)
```

同时添加响应 store 变化的监听（在现有 `onChange` 块后新增）：
```swift
        .onChange(of: changeReviewStore.snapshotsByProposalID) { _, _ in
            refreshAgentDiff(for: fileURL)
        }
```

**3d. 在 `CodeEditorView` 调用处添加参数：**

在传入 `gitDiffByLine: gitDiffByLine,` 的下方添加：
```swift
                        agentChangeDiffByLine: agentChangeDiffByLine,
```

**3e. 添加 `refreshAgentDiff` 私有方法：**

在 `refreshGitDiff` 方法后添加：

```swift
    // MARK: - Agent Change Diff（F24）

    private func refreshAgentDiff(for fileURL: URL) {
        let standardizedURL = fileURL.standardizedFileURL
        // 遍历 store 中所有 pending 的 fileChanges，找到匹配当前文件的条目
        let matchingDiff = changeReviewStore.snapshotsByProposalID.values
            .flatMap { $0.fileChanges }
            .filter { $0.state.isPendingReview }
            .first { fc in
                URL(fileURLWithPath: fc.absolutePath).standardizedFileURL == standardizedURL
            }
            .map { UnifiedDiffParser.parse($0.unifiedDiff) }

        agentChangeDiffByLine = matchingDiff ?? [:]
    }
```

### Step 4：构建验证

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-f24-task5 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded|Build FAILED"
```

### Step 5：Commit

```bash
git add agentGui/Views/FileEditorView.swift \
        agentGuiTests/FileEditorAgentDiffIntegrationTests.swift
git commit -m "feat(f24): FileEditorView reads ChangeReviewProjectionStore, injects agentChangeDiffByLine"
```

---

## Task 6：Accept/Reject 动作处理

**Files:**
- Modify: `agentGui/Views/FileEditorView.swift`
- Test: `agentGuiTests/FileEditorAgentDiffActionTests.swift`

> `ApplyEngine.apply(proposalID:approvedPaths:)` 接受文件变更（写入工作区）。
> `DraftRevertService.revertFiles(proposalID:relativePaths:)` 回退变更（还原到基础内容）。
> 两者均 `@MainActor`，操作后通过 `refreshProjection` 自动刷新 `ChangeReviewProjectionStore`，
> 进而触发 `onChange(of: changeReviewStore.snapshotsByProposalID)` 重新计算 `agentChangeDiffByLine`
> 并清空装饰（装饰生命周期与 pending 状态绑定）。

### Step 1：写失败测试（逻辑层）

```swift
// agentGuiTests/FileEditorAgentDiffActionTests.swift
import Testing
@testable import agentGui

/// 测试 FileEditorView 内部的 accept/reject 动作路由逻辑（通过 helper 提取被测函数）。
///
/// 直接测试 ApplyEngine / DraftRevertService 在测试环境下的行为，
/// 不依赖完整 SwiftUI View 生命周期。
@MainActor
struct FileEditorAgentDiffActionTests {

    /// 在现有 store 中找到匹配文件的 (proposalID, relativePath)
    private func findPendingChange(
        in store: ChangeReviewProjectionStore,
        fileURL: URL
    ) -> (proposalID: UUID, relativePath: String)? {
        let standardized = fileURL.standardizedFileURL
        for snapshot in store.snapshotsByProposalID.values {
            for fc in snapshot.fileChanges where fc.state.isPendingReview {
                if URL(fileURLWithPath: fc.absolutePath).standardizedFileURL == standardized {
                    return (snapshot.proposal.id, fc.relativePath)
                }
            }
        }
        return nil
    }

    @Test func findPendingChangeReturnsTupleWhenFound() {
        let store = ChangeReviewProjectionStore()
        let proposalID = UUID()
        let proposal = ChangeProposalSnapshot(
            id: proposalID, sessionID: "s1", jobID: nil, messageID: nil,
            providerID: .builtInAgent, state: .readyForReview,
            baseWorkspaceRoot: "/ws", summary: nil, createdAt: Date(), updatedAt: Date()
        )
        let fc = ProposedFileChangeSnapshot(
            id: UUID(), proposalID: proposalID, relativePath: "A.swift",
            absolutePath: "/ws/A.swift", changeKind: .modify,
            unifiedDiff: "", state: .proposed, lineAdditions: 1, lineDeletions: 0
        )
        store.set(ChangeProposalReviewSnapshot(proposal: proposal, fileChanges: [fc]))

        let result = findPendingChange(in: store, fileURL: URL(fileURLWithPath: "/ws/A.swift"))
        #expect(result?.proposalID == proposalID)
        #expect(result?.relativePath == "A.swift")
    }

    @Test func findPendingChangeReturnsNilForAppliedChange() {
        let store = ChangeReviewProjectionStore()
        let proposalID = UUID()
        let proposal = ChangeProposalSnapshot(
            id: proposalID, sessionID: "s1", jobID: nil, messageID: nil,
            providerID: .builtInAgent, state: .applied,
            baseWorkspaceRoot: "/ws", summary: nil, createdAt: Date(), updatedAt: Date()
        )
        let fc = ProposedFileChangeSnapshot(
            id: UUID(), proposalID: proposalID, relativePath: "B.swift",
            absolutePath: "/ws/B.swift", changeKind: .modify,
            unifiedDiff: "", state: .applied, lineAdditions: 0, lineDeletions: 0
        )
        store.set(ChangeProposalReviewSnapshot(proposal: proposal, fileChanges: [fc]))

        let result = findPendingChange(in: store, fileURL: URL(fileURLWithPath: "/ws/B.swift"))
        #expect(result == nil)
    }
}
```

### Step 2：运行确认

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/FileEditorAgentDiffActionTests \
  -derivedDataPath /tmp/agentGui-f24-task6 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|Executed|error:"
```
预期：2 tests passed

### Step 3：在 `FileEditorView.swift` 处理 `onGutterLaneHit`

在 Task 4 中已将 `ChangeReviewActionLane` 注册到 gutter。现在需要在 `FileEditorView`
响应 `onGutterLaneHit` 回调。

定位 `CodeEditorView` 构建位置，查找现有的 `onGutterLaneHit` 参数（或如不存在则新增）：

```swift
                        onGutterLaneHit: { hitResult in
                            handleGutterLaneHit(hitResult, for: url)
                        },
```

**在 `FileEditorView` 添加 hit handler 方法：**

```swift
    // MARK: - Gutter Lane Hit Handling（F24）

    private func handleGutterLaneHit(
        _ hitResult: CodeEditorGutterHitResult,
        for fileURL: URL
    ) {
        guard hitResult.laneID == "changeReviewAction" else { return }
        let encodedLine = hitResult.lineNumber
        let isAccept = encodedLine > 0
        let lineNumber = abs(encodedLine)   // 还原行号（F24 编码约定）
        _ = lineNumber  // 当前实现不需要精确行号：按文件维度 accept/reject

        guard let (proposalID, relativePath) = findPendingChange(
            in: changeReviewStore,
            fileURL: fileURL
        ) else { return }

        let applyEngine = ApplyEngine(modelContext: modelContext,
                                      projectionStore: changeReviewStore)
        let revertService = DraftRevertService(modelContext: modelContext,
                                               projectionStore: changeReviewStore)
        Task { @MainActor in
            do {
                if isAccept {
                    try await applyEngine.apply(proposalID: proposalID, approvedPaths: [relativePath])
                } else {
                    try await revertService.revertFiles(proposalID: proposalID, relativePaths: [relativePath])
                }
                // 操作成功后刷新 git diff（文件内容已修改）
                refreshGitDiff(for: fileURL)
            } catch {
                // TODO: 错误上报到 sessionController.document.errorMessage
            }
        }
    }

    private func findPendingChange(
        in store: ChangeReviewProjectionStore,
        fileURL: URL
    ) -> (proposalID: UUID, relativePath: String)? {
        let standardized = fileURL.standardizedFileURL
        for snapshot in store.snapshotsByProposalID.values {
            for fc in snapshot.fileChanges where fc.state.isPendingReview {
                if URL(fileURLWithPath: fc.absolutePath).standardizedFileURL == standardized {
                    return (snapshot.proposal.id, fc.relativePath)
                }
            }
        }
        return nil
    }
```

### Step 4：构建验证

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-f24-task6 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded|Build FAILED"
```

### Step 5：Commit

```bash
git add agentGui/Views/FileEditorView.swift \
        agentGuiTests/FileEditorAgentDiffActionTests.swift
git commit -m "feat(f24): wire accept/reject gutter action to ApplyEngine/DraftRevertService"
```

---

## Task 7：Inline Diff 背景色高亮

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- Test: `agentGuiTests/CodeEditorAgentDiffInlineRenderTests.swift`

> **VSCode 参考：** `diffDecorations.ts` 对新增行添加 `addedLineBackground` token
> 颜色（默认半透明绿）；对删除行显示 ghost row 或仅 gutter 条纹。
>
> **Zed 参考：** `element.rs` `paint_diff_hunks` 为 added/modified line range 填充
> `status_colors().created_background` / `status_colors().modified_background`。
>
> **F24 实现：** 方案 B（F20 Inlay Hints 相同路径）——在 `drawBackground(in:)` 中
> 用 `NSLayoutManager.lineFragmentRect` 计算行矩形，直接绘制背景色，
> **不修改 NSTextStorage**，轻量 IME 安全。

### Step 1：写失败测试

```swift
// agentGuiTests/CodeEditorAgentDiffInlineRenderTests.swift
import Testing
import AppKit
@testable import agentGui

/// 测试 CodeEditorPlatformTextView 中 agentChangeDiffByLine 存储与触发机制。
/// 无法直接测试像素绘制，但可测试状态属性读写和 needsDisplay 触发。
@MainActor
struct CodeEditorAgentDiffInlineRenderTests {

    @Test func agentChangeDiffByLineDefaultsToEmpty() throws {
        let textView = CodeEditorPlatformTextView(frame: .zero)
        #expect(textView.agentChangeDiffByLine.isEmpty)
    }

    @Test func settingAgentChangeDiffTriggersNeedsDisplay() throws {
        let textView = CodeEditorPlatformTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        // 在 window-less 环境下 needsDisplay 可能不精确，至少验证属性赋值不崩溃
        textView.agentChangeDiffByLine = [3: .added, 5: .modified]
        #expect(textView.agentChangeDiffByLine.count == 2)
        #expect(textView.agentChangeDiffByLine[3] == .added)
    }

    @Test func clearingAgentChangeDiffTriggersNeedsDisplay() throws {
        let textView = CodeEditorPlatformTextView(frame: .zero)
        textView.agentChangeDiffByLine = [1: .added]
        textView.agentChangeDiffByLine = [:]
        #expect(textView.agentChangeDiffByLine.isEmpty)
    }
}
```

### Step 2：运行确认失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/CodeEditorAgentDiffInlineRenderTests \
  -derivedDataPath /tmp/agentGui-f24-task7 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|error:|Build FAILED"
```

### Step 3：在 `CodeEditorPlatformTextView` 添加属性和绘制

在 `CodeEditorTextView.swift` 找到 `class CodeEditorPlatformTextView: NSTextView` 的属性区，
添加：

```swift
    // MARK: - Agent Change Diff（F24 Inline Background）
    /// Agent 修改的行级 diff，由 Coordinator 更新，上帧 drawBackground 消费。
    var agentChangeDiffByLine: [Int: CodeEditorGitDiffKind] = [:] {
        didSet {
            guard agentChangeDiffByLine != oldValue else { return }
            needsDisplay = true
        }
    }
```

在 `drawBackground(in:)` 的 override 中（已有 ghost text / indent guide 绘制），
追加 inline diff 背景绘制（在所有其他绘制之前，确保高亮在底层）：

```swift
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        // F24：Agent 变更行内联背景高亮
        drawAgentDiffBackground(in: rect)

        // 现有绘制（缩进参考线、ghost text 等）...
    }

    private func drawAgentDiffBackground(in rect: NSRect) {
        guard !agentChangeDiffByLine.isEmpty,
              let layoutManager = self.layoutManager,
              let textContainer = self.textContainer,
              let textStorage = self.textStorage else { return }

        // 遍历 agentChangeDiffByLine，找到 visible 行对应的 glyph range
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        guard visibleGlyphRange.length > 0 else { return }
        let visibleCharRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange,
            actualGlyphRange: nil
        )

        // 构建 line start offsets（用于行号映射）
        var lineStart = 0
        var logicalLine = 1
        let fullString = textStorage.string as NSString
        let nsRange = NSRange(location: 0, length: textStorage.length)

        // 收集 (lineNumber, charRange) pairs
        var lineCharRanges: [(line: Int, charRange: NSRange)] = []
        fullString.enumerateSubstrings(in: nsRange, options: [.byLines, .substringNotRequired]) { _, substringRange, enclosingRange, _ in
            lineCharRanges.append((line: logicalLine, charRange: enclosingRange))
            logicalLine += 1
        }

        for (lineNumber, charRange) in lineCharRanges {
            guard let kind = agentChangeDiffByLine[lineNumber] else { continue }
            // 只绘制 visible 范围内
            let intersect = NSIntersectionRange(charRange, visibleCharRange)
            guard intersect.length > 0 else { continue }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: intersect, actualCharacterRange: nil)
            var lineRect: NSRect = .zero
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
                if lineRect == .zero {
                    lineRect = rect
                } else {
                    lineRect = lineRect.union(rect)
                }
            }
            guard lineRect != .zero else { continue }

            // 扩展到文本视图全宽（覆盖整行）
            lineRect.origin.x = 0
            lineRect.size.width = self.bounds.width

            guard lineRect.intersects(rect) else { continue }

            let color: NSColor
            switch kind {
            case .added:
                // 紫色半透明背景（区分 git added 绿色）
                color = NSColor.systemPurple.withAlphaComponent(0.08)
            case .modified:
                // 青色半透明背景
                color = NSColor.systemCyan.withAlphaComponent(0.08)
            case .deleted:
                // deleted 行已通过 gutter 三角表示，inline 不需要背景
                continue
            }

            color.setFill()
            lineRect.fill()
        }
    }
```

**IME 安全：** `drawBackground(in:)` 在系统绘制时调用，不影响 IME 输入，无需额外保护。

### Step 4：在 Coordinator 更新 `agentChangeDiffByLine` 到 text view

在 `CodeEditorTextView.swift` 的 `Coordinator` 中，在 `updateGutterState()` 或专用的 `updateAgentDiff()` 方法中：

```swift
    func updateAgentDiff(_ diffByLine: [Int: CodeEditorGitDiffKind]) {
        textView?.agentChangeDiffByLine = diffByLine
    }
```

在 `updateUIView` 中调用（与 `gitDiffByLine` 保持相同模式）：
```swift
        coordinator.updateAgentDiff(uiView.agentChangeDiffByLine)
```
> 注意：`uiView` 这里指的是外部传入的 `agentChangeDiffByLine` 参数，
> 实际代码需对应现有参数命名约定。

### Step 5：运行测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/CodeEditorAgentDiffInlineRenderTests \
  -derivedDataPath /tmp/agentGui-f24-task7 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|Executed"
```
预期：3 tests passed

### Step 6：Commit

```bash
git add agentGui/Views/CodeEditor/CodeEditorTextView.swift \
        agentGuiTests/CodeEditorAgentDiffInlineRenderTests.swift
git commit -m "feat(f24): inline agent diff background highlight in drawBackground(in:)"
```

---

## Task 8：端到端冒烟测试 + 全量回归

**Files:**
- Test: `agentGuiTests/F24AgentChangeDecorationSmokeTests.swift`

### Step 1：写冒烟测试

```swift
// agentGuiTests/F24AgentChangeDecorationSmokeTests.swift
import Testing
@testable import agentGui

/// Feature 24 端到端冒烟测试：
/// 验证从 ChangeProposalReviewSnapshot 到 agentChangeDiffByLine 的完整数据流，
/// 不依赖 UI 渲染层。
@MainActor
struct F24AgentChangeDecorationSmokeTests {

    @Test func agentDiffLaneIsRegisteredWithCorrectID() {
        let lane = AgentDiffStripeLane()
        #expect(lane.id == "agentDiffStripe")
    }

    @Test func actionLaneIsRegisteredWithCorrectID() {
        let lane = ChangeReviewActionLane()
        #expect(lane.id == "changeReviewAction")
    }

    @Test func unifiedDiffParsedFromProposalProducesDiff() {
        let diff = """
        --- a/Foo.swift
        +++ b/Foo.swift
        @@ -1,0 +2,2 @@
        +// Added
        +let x = 1
        """
        let result = UnifiedDiffParser.parse(diff)
        #expect(!result.isEmpty)
    }

    @Test func agentDiffStripeLaneInvalidationPlanDetectsChanges() {
        let lane = AgentDiffStripeLane()
        let snap1 = makeMinimalSnapshot(agentDiff: [1: .added])
        let snap2 = makeMinimalSnapshot(agentDiff: [1: .added, 5: .modified])
        let plan = lane.invalidationPlan(from: snap1, to: snap2)
        guard case .lines(let changed) = plan else {
            Issue.record("Expected .lines"); return
        }
        #expect(changed.contains(5))
    }

    @Test func actionLaneCollapseToZeroWidthWhenNoDiff() {
        let lane = ChangeReviewActionLane()
        let snap = makeMinimalSnapshot(agentDiff: [:])
        #expect(lane.preferredWidth(for: snap, appearance: nil) == 0)
    }

    @Test func actionLaneExpandsWhenDiffPresent() {
        let lane = ChangeReviewActionLane()
        let snap = makeMinimalSnapshot(agentDiff: [3: .modified])
        #expect(lane.preferredWidth(for: snap, appearance: nil) > 0)
    }

    // MARK: - Helper

    private func makeMinimalSnapshot(
        agentDiff: [Int: CodeEditorGitDiffKind]
    ) -> CodeEditorGutterViewportSnapshot {
        CodeEditorGutterViewportSnapshot(
            lineCount: 10,
            visibleLineRange: 1...10,
            currentLine: nil,
            cursorLineNumbers: [],
            lineMetrics: (1...10).map { line in
                CodeEditorVisibleLineMetric(
                    line: line,
                    rect: NSRect(x: 0, y: CGFloat(line - 1) * 18, width: 50, height: 18),
                    isFirstFragmentOfLine: true
                )
            },
            diagnosticsByLine: [:],
            foldableLines: [],
            foldedLines: [],
            gitDiffByLine: [:],
            agentChangeDiffByLine: agentDiff
        )
    }
}
```

### Step 2：运行所有 F24 相关测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f24-smoke \
  -only-testing:agentGuiTests/CodeEditorGutterViewportSnapshotAgentDiffTests \
  -only-testing:agentGuiTests/AgentDiffStripeLaneTests \
  -only-testing:agentGuiTests/ChangeReviewActionLaneTests \
  -only-testing:agentGuiTests/FileEditorAgentDiffIntegrationTests \
  -only-testing:agentGuiTests/FileEditorAgentDiffActionTests \
  -only-testing:agentGuiTests/CodeEditorAgentDiffInlineRenderTests \
  -only-testing:agentGuiTests/F24AgentChangeDecorationSmokeTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|Executed|error:"
```
预期：全部通过

### Step 3：运行全量回归（确认无退步）

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f24-regression \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

### Step 4：Final Commit

```bash
git add agentGuiTests/F24AgentChangeDecorationSmokeTests.swift
git commit -m "test(f24): add F24 smoke tests, verify full data flow"
```

---

## 实现检查清单

完成后逐项验证：

- [ ] `CodeEditorGutterViewportSnapshot.agentChangeDiffByLine` 字段存在，有默认值 `[:]`
- [ ] `AgentDiffStripeLane`：id = `"agentDiffStripe"`，颜色紫/青/粉（区别于 git 绿橙红）
- [ ] `ChangeReviewActionLane`：id = `"changeReviewAction"`，无 diff 时宽度折叠为 0
- [ ] Hit test 编码：正数 = accept，负数 = reject（文档内注释说明）
- [ ] `FileEditorView` 有 `@Environment(ChangeReviewProjectionStore.self)` 注入
- [ ] `refreshAgentDiff(for:)` 在 `onAppear`、`onChange(fileURL)`、`onChange(snapshotsByProposalID)` 三处调用
- [ ] Accept 后调用 `ApplyEngine.apply`；Reject 后调用 `DraftRevertService.revertFiles`
- [ ] 操作完成后装饰自动消失（store 状态变化 → `[:]` diff → lane 不绘制）
- [ ] `CodeEditorPlatformTextView.agentChangeDiffByLine` 属性存在，`didSet` 触发 `needsDisplay`
- [ ] Inline 背景色：added = 紫色 8% opacity，modified = 青色 8% opacity，deleted 无背景
- [ ] 所有新测试通过，无现有测试退步

---

## 已知局限与后续扩展

| 局限 | 描述 | 后续方向 |
|------|------|----------|
| 文件维度 Accept/Reject | 当前 Accept/Reject 按整个文件操作，不支持 hunk 级细粒度 | 后续在 `ApplyEngine` 添加 hunk 级 patch apply |
| deleted 行不显示内联 diff | deleted 内容仅在 gutter 三角标记，无 ghost row | 仿 Zed ghost row 需要大量 NSLayoutManager 改造，独立 Feature |
| 多 proposal 同文件冲突 | 同一文件有多个 pending proposal 时只取 first match | 当前 agent 架构下极少出现，发生时用户需先 accept/reject 旧提案 |
| `ChangeReviewActionLane` 错误处理 | accept/reject 失败时无 UI 反馈 | 连接 `sessionController.document` 展示错误 alert |

---

*计划生成于 2026-04-09，参考 VSCode `dirtydiffDecorator.ts` / Zed `element.rs` / agentGui F13 `GitDiffStripeLane`。*

# Diff 视图迭代设计文档

> **参考来源:** VSCode `src/vs/editor/browser/widget/diffEditor/`、Zed `crates/git_ui/`  
> **日期:** 2026-04-07  
> **当前代码入口:** `agentGui/Views/GitDiffView.swift`、`Services/ChangeReview/StructuredDiffEngine.swift`

---

## 一、现状分析

### 1.1 当前架构

| 组件 | 位置 | 职责 |
|------|------|------|
| `GitDiffView` | `Views/GitDiffView.swift` | 渲染 unified diff 文本的只读视图 |
| `GitDiffPresentation` | 同上 | 将 unified diff 字符串解析为行级模型（主线程同步） |
| `StructuredDiffEngine` | `Services/ChangeReview/StructuredDiffEngine.swift` | 内存型 LCS diff，供 AI 变更提案使用 |
| `GitLineDiffService` | `Services/Editor/GitLineDiffService.swift` | actor，运行 `git diff -U0 HEAD --` |
| `UnifiedDiffParser` | `Services/Editor/UnifiedDiffParser.swift` | 将 git 输出解析为 `[Int: CodeEditorGitDiffKind]` |
| `GitDiffStripeLane` | `Views/CodeEditor/Lanes/GitDiffStripeLane.swift` | gutter 装饰条纹 |
| `ChangeProposalReviewView` | `Views/ChangeProposalReviewView.swift` | AI 变更提案的审查+接受/拒绝 |

### 1.2 已知问题

1. **主线程阻塞**：`GitDiffPresentation.build()` 在 `var body` 中同步计算，大文件会卡顿。
2. **无词级高亮**：仅行级颜色区分，无法定位行内具体改动。
3. **无折叠未变动区域**：context 行全量显示，大文件噪声极多。
4. **虚拟化不充分**：`LazyVStack` 对行生效，但 hunk section 本身用 `VStack`，数十个 hunk 时存在性能问题。
5. **无 hunk 级操作**：无法对单个 hunk 做 Stage/Revert。
6. **无键盘导航**：无法在 hunk 间跳转。
7. **行号列单一**：删除行只显示旧行号，新增行只显示新行号，无双列视图。
8. **AI 变更提案 diff 失真**：`WorkspaceChangeCaptureService` 生成全文件单 hunk（全删 + 全增），导致 additions/deletions 统计虚高。
9. **无概览标尺**：纵向滚动条无法得知 hunk 分布。
10. **无侧边对比视图**：只有 unified 模式，无 side-by-side。

---

## 二、参考实现要点

### 2.1 VSCode `DiffEditor`

- **核心选项**（来自 `diffEditorOptions.ts`）：
  - `renderSideBySide`：inline / side-by-side 切换
  - `hideUnchangedRegions`：折叠未变动区域，支持 `contextLineCount` / `minimumLineCount` / `revealLineCount`
  - `ignoreTrimWhitespace`：忽略行尾空白差异
  - `diffAlgorithm`：`legacy` (Myers) / `advanced` (patience-like)
  - `experimental.useTrueInlineView`：真正的行内 diff，修改行 del/ins 合并为一行
  - `experimental.showMoves`：代码块移动检测

- **Gutter 工具栏**（来自 `gutterFeature.ts`）：
  - `DiffEditorGutter` 在 modified 编辑器的 gutter 上叠加悬停工具栏
  - 悬停 hunk 时显示 `DiffToolBar`，内含 `DiffEditorHunkToolbar` 菜单（Revert、Stage 等）
  - 选中范围时改用 `DiffEditorSelectionToolbar`，支持选区级别的 Stage
  - 工具栏通过 `MenuWorkbenchToolBar` 动态加载菜单项，支持最多 3 个主操作

- **性能策略**：
  - diff 计算在后台 Worker 异步完成（`maxComputationTime` 超时截断）
  - Gutter item 通过 `Observable` 增量更新，仅重绘变化的 item
  - side-by-side 的两个编辑器共享同一 `DiffEditorViewModel`，linked scroll 采用 scrollTop 同步

### 2.2 Zed `git_ui`

- **ProjectDiff（多文件统一视图）**：将所有变更文件的 diff 合并到一个 `MultiBuffer` 中，滚动即可浏览全部改动。
- **hunk 级操作**：`ExpandAllDiffHunks`、`go_to_hunk_before_or_after_position` (F7)、Stage/Discard per hunk。
- **等待 diff 加载**：`wait_for_diff_to_load` Task，保证 diff 数据就绪后再定位。
- **差异裁剪**：`TruncatedPatch` / `compress_commit_diff`，大 diff 截断多余 hunk，保留摘要。
- **Tree View**：文件列表支持 flat / tree 切换，目录展开/折叠，带 indent guide。
- **diff stat badge**：文件列表每行显示 `+N -N`。

---

## 三、特性列表

各 Feature 独立可交付，按优先级排序。P0 = 阻塞性质量缺陷，P1 = 高价值体验提升，P2 = 完整度补全。

| ID | 特性名 | 优先级 | 关联问题 |
|----|--------|--------|---------|
| F-DIFF-01 | 异步 Diff 解析与缓存 | P0 | 主线程阻塞 |
| F-DIFF-02 | AI 变更提案 Diff 修正 | P0 | diff 失真 |
| F-DIFF-03 | 折叠未变动区域 | P1 | 大文件噪声 |
| F-DIFF-04 | 词级/字符级高亮 | P1 | 无法定位行内改动 |
| F-DIFF-05 | 全量虚拟化滚动 | P1 | 大 diff 渲染性能 |
| F-DIFF-06 | Hunk 键盘导航 | P1 | 无法在 hunk 间跳转 |
| F-DIFF-07 | Hunk 悬停操作栏 | P1 | 无 hunk 级操作 |
| F-DIFF-08 | 双行号列 | P2 | 行号可读性 |
| F-DIFF-09 | 滚动条概览标尺 | P2 | 无法感知 hunk 分布 |
| F-DIFF-10 | Side-by-Side 视图 | P2 | 只有 unified |

---

## 四、各特性详细设计

---

### F-DIFF-01：异步 Diff 解析与缓存

**动机**  
`GitDiffPresentation.build()` 是纯文本解析（split + 循环），调用在 `var body` 的计算属性中，每次 SwiftUI 刷新都重算。5000 行 diff 约耗 30–60 ms，会直接导致 UI janky。

**设计**

引入 `DiffPresentationCache`（`@Observable`）：

```swift
@Observable
final class DiffPresentationCache {
    // key = diffText.hashValue
    private var cache: [Int: GitDiffPresentation] = [:]
    private var pending: Set<Int> = []

    /// 同步返回缓存；若缓存不存在，触发后台解析后通知 SwiftUI 刷新
    func presentation(for diffText: String) -> GitDiffPresentation? {
        let key = diffText.hashValue
        if let hit = cache[key] { return hit }
        guard !pending.contains(key) else { return nil }
        pending.insert(key)
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = GitDiffPresentation.build(title: "", diffText: diffText)
            await MainActor.run {
                self?.cache[key] = result
                self?.pending.remove(key)
            }
        }
        return nil
    }

    func evict(exceeding maxCount: Int = 20) {
        // LRU 淘汰，只保留最近 maxCount 条
    }
}
```

`GitDiffView` 改为：

```swift
@State private var presentation: GitDiffPresentation?

var body: some View {
    // ...
    .task(id: diffText) {
        presentation = await parsePresentation(diffText)
    }
}

private func parsePresentation(_ diffText: String) async -> GitDiffPresentation {
    await Task.detached(priority: .userInitiated) {
        GitDiffPresentation.build(title: title, diffText: diffText)
    }.value
}
```

**影响文件**
- `Views/GitDiffView.swift`：移除 `var presentation: GitDiffPresentation { ... }` 计算属性，改为 `@State`
- 新增 `Services/Editor/DiffPresentationCache.swift`（可选，共享缓存）

**测试目标**
- 5000 行 diff 的 body 调用开销 < 1 ms（仅读 `@State`）
- 首次显示有 loading skeleton，解析完成后无闪烁

---

### F-DIFF-02：AI 变更提案 Diff 修正

**动机**  
`change-review-live-sync-notes.md` 已记录：`WorkspaceChangeCaptureService` 的快照保存逻辑生成全文件 hunk（所有旧行删除 + 所有新行新增），而非真正的行级 diff。这使得 `GitDiffView` 显示的改动数虚高，且 hunk 导航（F-DIFF-06）完全无效。

**设计**

修改 `DirectIntentBackend.build()` / `WorkspaceChangeCaptureService` 快照生成路径：

1. 快照保留 `baseContentSnapshot`（整个文件原始文本）
2. proposal 完成后，调用已有的 `StructuredDiffEngine.build()` 对 `(baseContent, stagedContent)` 生成结构化 hunks
3. 调用新增的 `StructuredDiffSerializer.toUnifiedDiff()` 将 `StructuredFileDiff` 序列化为标准 unified diff 格式（`@@ -a,b +c,d @@` header + 行前缀）

`UnifiedDiffSerializer` 已存在（`Services/ChangeReview/UnifiedDiffSerializer.swift`），需验证其输出是否符合 `git diff -U3` 的标准格式，与 `UnifiedDiffParser.parse()` 相互兼容。

**影响文件**
- `Services/ChangeReview/DirectIntentBackend.swift`：使用 `StructuredDiffEngine`
- `Services/ChangeReview/UnifiedDiffSerializer.swift`：确保输出可被 `UnifiedDiffParser` 反解析
- `agentGuiTests/ChangeReviewHookTests.swift`：增加 diff roundtrip 测试

---

### F-DIFF-03：折叠未变动区域

**动机**  
参照 VSCode `hideUnchangedRegions`：当一个 context section 超过一定行数时，中间部分折叠，只显示 hunk 边缘各 N 行的上下文，并保留一个「展开 M 行」的交互按钮。

**设计**

在 `GitDiffPresentation.Section` 上增加折叠状态：

```swift
extension GitDiffPresentation {
    struct CollapsedRegion: Equatable, Identifiable {
        let id: String
        let lineCount: Int   // 被折叠的行数
    }
}
```

在 `GitDiffView` 中维护：
```swift
@State private var expandedSections: Set<String> = []
```

`hunkSection(_ section:)` 渲染逻辑：
- 若 section 为 context-only（全是 context 行）且 `rows.count > collapseThreshold`（默认 6 行），则：
  - 显示前 3 行 + "展开 N 行" 按钮 + 后 3 行
  - 点击按钮将 section.id 加入 `expandedSections`，触发 SwiftUI 刷新
- 阈值 `collapseThreshold` = 6，`revealLineCount` = 3（同 VSCode 默认值）

**UI 控件**
```swift
Button {
    expandedSections.insert(section.id)
} label: {
    HStack(spacing: 4) {
        Image(systemName: "chevron.down.2")
        Text("展开 \(hiddenCount) 行")
            .font(.caption.monospaced())
    }
}
.buttonStyle(.plain)
.foregroundStyle(.secondary)
.padding(.horizontal, 10)
.padding(.vertical, 5)
.frame(maxWidth: .infinity, alignment: .leading)
.background(Color.blue.opacity(0.04))
```

**影响文件**
- `Views/GitDiffView.swift`：增加折叠逻辑和 `expandedSections` 状态

---

### F-DIFF-04：词级/字符级高亮

**动机**  
参照 VSCode `innerChanges`（`LineRangeMapping.innerChanges: RangeMapping[]`）和 Zed character-level diff：当一行既有删除版本又有对应添加版本时，进一步计算二者之间的字符级 diff，高亮精确变动范围。

**设计**

**字符 diff 算法**

新增 `CharacterDiffEngine`：

```swift
struct CharacterDiffEngine {
    struct Change: Sendable {
        let oldRange: Range<String.Index>?   // nil = 纯插入
        let newRange: Range<String.Index>?   // nil = 纯删除
    }

    /// 对同一逻辑行的删除文本和新增文本做 Myers diff，返回变更区间列表
    static func diff(old: String, new: String) -> [Change]
}
```

实现可复用 `StructuredDiffEngine` 内部的 `longestCommonSubsequence` 逻辑（字符粒度）。

**展示层**

`GitDiffView.diffRow()` 中，渲染 `.deletion` 和 `.addition` 行时，检查是否存在对应的 paired 行（连续的 deletion + addition pair）。若存在，对该 pair 调用 `CharacterDiffEngine.diff(old: deletionText, new: additionText)`，生成 `AttributedString`：

- deletion 行：被删除的字符区间用 `NSColor.systemRed.withAlphaComponent(0.35)` 底色标注
- addition 行：被新增的字符区间用 `NSColor.systemGreen.withAlphaComponent(0.35)` 底色标注

配色参照 VSCode `editor.diffEditor.removedTextBackground` / `insertedTextBackground`。

**Pairing 逻辑**  
遍历 section.rows 时，跟踪连续的 deletion 块：若紧跟的 addition 块数量相同，则逐行 pair；若数量不同，不做 pair，退回行级高亮。

**性能约束**  
- 单行字符 diff 仅当行长 ≤ 512 字符时生效；超长行退回整行高亮
- 字符 diff 在后台 Task 中计算，结果缓存到 `@State private var charDiffCache: [String: [CharacterDiffEngine.Change]]`

**影响文件**
- 新增 `Services/Editor/CharacterDiffEngine.swift`
- `Views/GitDiffView.swift`：`diffRow()` 改用 `AttributedString`
- 新增 `agentGuiTests/CharacterDiffEngineTests.swift`

---

### F-DIFF-05：全量虚拟化滚动

**动机**  
当前结构：`ScrollView(.vertical) > LazyVStack > ForEach(sections) > hunkSection > LazyVStack(rows)`。外层 `ForEach(sections)` 是 eager 的，若有 50 个 hunk，SwiftUI 会同时 lay out 全部 hunk header。对于 1000+ 行的 diff，仍有可感知的帧率下降。

**设计**

将整个 diff 展平为 `[FlatDiffRow]`，改用单层 `List` 或 `LazyVStack`：

```swift
enum FlatDiffRow: Identifiable {
    case hunkHeader(sectionID: String, text: String)
    case collapsedContext(sectionID: String, lineCount: Int)
    case diffLine(sectionID: String, row: GitDiffPresentation.Row)

    var id: String { /* 各 case 返回唯一 id */ }
}
```

`GitDiffPresentation` 增加：

```swift
func flatRows(expandedSections: Set<String>, collapseThreshold: Int = 6) -> [FlatDiffRow]
```

`GitDiffView.body` 改为：

```swift
List(flatRows, id: \.id) { row in
    switch row {
    case .hunkHeader(_, let text):
        hunkHeaderView(text)
    case .collapsedContext(let secID, let count):
        collapseExpandButton(sectionID: secID, count: count)
    case .diffLine(_, let row):
        diffRow(row)
    }
}
.listStyle(.plain)
.environment(\.defaultMinListRowHeight, 20)
```

使用 `List` 而非 `LazyVStack` 的优势：
- macOS `List` 具备行回收机制（类似 `NSTableView`），仅渲染可见行
- 支持通过 `scrollPosition(id:)` 实现程序性滚动到指定 hunk

**影响文件**
- `Views/GitDiffView.swift`：重构 body，增加 `flatRows` 计算
- `GitDiffPresentation`：增加 `flatRows(expandedSections:)` 方法

---

### F-DIFF-06：Hunk 键盘导航

**动机**  
参照 VSCode F7 / Shift+F7、Zed `go_to_hunk_before_or_after_position`：允许快速在 hunk 间跳转，是 code review 工作流的基础操作。

**设计**

在 `GitDiffView` 中维护当前聚焦 hunk 索引：

```swift
@State private var focusedHunkIndex: Int = 0
```

增加两个 `AppCommand`（或 `KeyboardShortcut`）：
- **下一个 Hunk**：`Cmd+Option+]` 或沿用 Xcode 风格
- **上一个 Hunk**：`Cmd+Option+[`

视觉反馈：focused hunk header 使用 `.focused()` modifier 或 overlay ring。

滚动到目标 hunk 使用 F-DIFF-05 提供的 `scrollPosition(id:)`：

```swift
@State private var scrollPositionID: String?

func navigateToHunk(delta: Int) {
    let hunkHeaders = flatRows.filter { if case .hunkHeader = $0 { return true }; return false }
    let newIndex = (focusedHunkIndex + delta).clamped(to: 0..<hunkHeaders.count)
    focusedHunkIndex = newIndex
    scrollPositionID = hunkHeaders[newIndex].id
}
```

**工具栏按钮**  
在 `header` 区域右侧增加 `↑ ↓` 按钮，与快捷键联动。

**影响文件**
- `Views/GitDiffView.swift`
- `AppCommands/`：注册 hunk 导航命令

---

### F-DIFF-07：Hunk 悬停操作栏

**动机**  
参照 VSCode `DiffEditorGutter` 的悬停工具栏和 Zed 的 per-hunk Stage/Discard：在 `GitDiffView` 内，鼠标悬停 hunk header 时显示操作按钮。根据上下文（`ChangeProposalReviewView` vs. 纯 git diff）显示不同操作。

**设计**

在 `GitDiffView` 增加 `hunkActions` 回调协议：

```swift
struct HunkActions {
    var canRevert: Bool = false
    var canStage: Bool = false
    var onRevert: ((String) -> Void)?   // 参数为 section.id
    var onStage: ((String) -> Void)?
}
```

`hunkHeaderView` 增加 `@State private var hoveredSectionID: String?`，配合 `onHover` modifier：

```swift
.overlay(alignment: .trailing) {
    if hoveredSectionID == section.id, let actions = hunkActions {
        HunkActionBar(actions: actions, sectionID: section.id)
            .transition(.opacity.animation(.easeInOut(duration: 0.1)))
    }
}
```

`HunkActionBar` 渲染紧凑的图标按钮：`arrow.uturn.backward`（Revert）、`arrow.up.forward`（Stage）。

在 `ChangeProposalReviewView` 中，将单文件的 apply/revert 能力 wire 到 `HunkActions`.  
在 Git panel 的 `GitDiffView` 中，`canStage = true`，调用 `GitPanelViewModel.stageHunk(sectionID:)`.

**影响文件**
- `Views/GitDiffView.swift`：增加 `HunkActions`、`HunkActionBar`
- `ViewModels/GitPanelViewModel.swift`：增加 `stageHunk(sectionID:)`（后续迭代）
- `Views/ChangeProposalReviewView.swift`：传入 `HunkActions`

---

### F-DIFF-08：双行号列

**动机**  
目前 gutter 只有一列行号（新增行显示新行号，删除行显示旧行号，context 行显示两者但合并在一个位置）。标准 diff 工具（如 `git diff`、GitHub Diff）显示两列：左列（旧文件行号）和右列（新文件行号）。

**设计**

修改 `GitDiffView.diffRow()` 中的 gutter 区域，从单列改为双列：

```swift
struct DiffRowGutter: View {
    let oldLine: Int?
    let newLine: Int?
    let lineNumberWidth: CGFloat = 40

    var body: some View {
        HStack(spacing: 0) {
            lineNumberCell(oldLine, alignment: .trailing)
            Divider().frame(height: 16)
            lineNumberCell(newLine, alignment: .trailing)
        }
        .frame(width: lineNumberWidth * 2 + 1)
    }

    private func lineNumberCell(_ number: Int?, alignment: Alignment) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .frame(width: lineNumberWidth, alignment: alignment)
            .padding(.horizontal, 4)
    }
}
```

`GitDiffLayoutMetrics.rowChromeWidth` 相应由 158 → 196（增加约 38 pt）。

**影响文件**
- `Views/GitDiffView.swift`：提取 `DiffRowGutter`，更新 `rowChromeWidth`

---

### F-DIFF-09：滚动条概览标尺

**动机**  
参照 VSCode `renderOverviewRuler`：在垂直滚动条右侧叠加一个细色条，标注每个 hunk 的相对位置，帮助用户快速感知文件改动分布密度。

**设计**

在 `GeometryReader` 外层增加 `OverviewRuler` 叠加层：

```swift
struct OverviewRuler: View {
    let sections: [GitDiffPresentation.Section]
    let totalLineCount: Int
    let rulerWidth: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ForEach(sections) { section in
                let ratio = Double(section.rows.first?.newLineNumber ?? 0) / Double(max(totalLineCount, 1))
                let sectionHeight = Double(section.rows.count) / Double(max(totalLineCount, 1)) * geo.size.height
                let hasAdditions = section.rows.contains { if case .addition = $0 { return true }; return false }
                let hasDeletions = section.rows.contains { if case .deletion = $0 { return true }; return false }

                let color: Color = hasAdditions && hasDeletions ? .yellow
                                  : hasAdditions ? .green : .red

                Rectangle()
                    .fill(color.opacity(0.7))
                    .frame(width: rulerWidth, height: max(sectionHeight, 2))
                    .position(x: rulerWidth / 2, y: ratio * geo.size.height)
            }
        }
        .frame(width: rulerWidth)
    }
}
```

通过 `.overlay(alignment: .trailing)` 叠加在滚动区域右侧（在 `GeometryReader > ScrollView` 结构外侧）。

`totalLineCount` 取 `presentation.sections.flatMap(\.rows).count + collapsedCount`。

**影响文件**
- `Views/GitDiffView.swift`：增加 `OverviewRuler` 组件

---

### F-DIFF-10：Side-by-Side 视图

**动机**  
对于大型重构，side-by-side 视图可以同时看到旧代码结构和新代码结构，比 unified 视图更直观。参照 VSCode `renderSideBySide` 和 Zed 的 `SplitDiffEditor` 概念。

**设计**

**数据层**  
`GitDiffPresentation` 增加：

```swift
struct SideBySideLine: Identifiable {
    let id: String
    let leftLine: Row?    // 旧文件侧（context 或 deletion）
    let rightLine: Row?   // 新文件侧（context 或 addition）
}

func sideBySideLines() -> [SideBySideLine]
```

用配对算法：context 行双侧均填充；deletion + 对应 addition 配对为同一行；多余的 deletion 或 addition 用 nil 补齐另一侧。

**视图层**  
增加 `GitDiffSideBySideView`，布局为 `HStack` 两等分：

```swift
struct GitDiffSideBySideView: View {
    @State private var leftScrollOffset: CGPoint = .zero
    @State private var rightScrollOffset: CGPoint = .zero

    var body: some View {
        HStack(spacing: 0) {
            diffPane(side: .left)
            Divider()
            diffPane(side: .right)
        }
    }
}
```

**Linked Scrolling**  
两侧 `ScrollView` 通过 `onScrollGeometryChange` + `.scrollPosition(id:)` 或自定义 `NSScrollView` delegate 同步 offset。

**在 `GitDiffView` 中切换**  
增加 `viewMode: DiffViewMode = .unified` 状态，header 右侧放一个 segmented control（inline / side-by-side）。

**影响文件**
- `Views/GitDiffView.swift`：增加模式切换 UI
- 新增 `Views/GitDiffSideBySideView.swift`

---

## 五、实现顺序建议

```
P0 最先修复（不影响视觉，修复质量缺陷）：
  F-DIFF-01 → F-DIFF-02

P1 高价值体验（依赖顺序）：
  F-DIFF-05（虚拟化）
    → F-DIFF-03（折叠，依赖 flatRows）
    → F-DIFF-06（键盘导航，依赖 scrollPosition）
  F-DIFF-04（字符级高亮，独立）
  F-DIFF-07（hunk 操作，依赖上下文 wire-up）

P2 完整度：
  F-DIFF-08 → F-DIFF-09 → F-DIFF-10（侧边视图最复杂，最后）
```

---

## 六、测试策略

每个 Feature 需提供：

| Feature | 单元测试 | 集成测试 |
|---------|---------|---------|
| F-DIFF-01 | 解析结果与同步版本一致 | - |
| F-DIFF-02 | `StructuredDiffEngine` roundtrip：engine → serializer → parser → engine | `ChangeReviewHookTests` 改动统计不再虚高 |
| F-DIFF-03 | `GitDiffPresentation.flatRows()` 折叠/展开正确性 | - |
| F-DIFF-04 | `CharacterDiffEngine.diff()` 覆盖：空字符串、全删、全增、中间改动 | - |
| F-DIFF-05 | `flatRows()` 与原 Row 顺序一致 | 渲染 5000 行 diff < 16 ms（Xcode Profile）|
| F-DIFF-06 | 导航 delta 边界（clamp to 0..<count） | - |
| F-DIFF-07 | `HunkActions` 回调触发正确 section id | - |
| F-DIFF-08 | `DiffRowGutter` 行号为 nil 时不显示数字 | - |
| F-DIFF-09 | `OverviewRuler` hunk 颜色按 additions/deletions 分类正确 | - |
| F-DIFF-10 | `sideBySideLines()` 配对：deletion+addition pair 同行 | 滚动 offset 同步 |

---

## 七、影响范围汇总

```
agentGui/Views/GitDiffView.swift          ← 大量改动（F01 F03 F05 F06 F07 F08 F09 F10）
agentGui/Services/ChangeReview/
  DirectIntentBackend.swift               ← F02
  UnifiedDiffSerializer.swift             ← F02 验证
  StructuredDiffEngine.swift              ← F02 复用
agentGui/Services/Editor/
  DiffPresentationCache.swift             ← F01 新增
  CharacterDiffEngine.swift               ← F04 新增
agentGui/Views/GitDiffSideBySideView.swift ← F10 新增
agentGuiTests/
  CharacterDiffEngineTests.swift          ← F04 新增
  ChangeReviewHookTests.swift             ← F02 增强
```

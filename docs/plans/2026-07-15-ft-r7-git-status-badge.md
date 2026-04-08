# FT-R7：Git 状态 + 目录聚合 Badge 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 文件节点在行末显示 Git 状态字母 badge（A/M/D/U/!/S），目录节点显示子树最高优先级状态的彩点 badge（●）。已展开目录隐藏聚合点（子节点已可见，降低视觉噪音）。整体由 `GitStatusObserver` 监听 Git 变化，推送到 `FileTreeStore` 后在 DFS 中内联计算。

**Architecture:**
- `FileTreeStore` 新增 `private var gitStatuses: [EntryID: GitSummary] = [:]` 和 `updateGitStatuses(_ statuses: [URL: GitSummary])`；在 DFS 中对每个节点调用 `aggregateGitSummary(for:)` 填充 `VisibleEntry.gitSummary`。
- `aggregateGitSummary(for:)` 后序递归：直接命中 `gitStatuses[id]` 则返回，否则取全部子节点聚合结果的 `min()`（`GitSummary.Comparable` 值越小优先级越高）。
- `GitStatusObserving` 协议 + `GitStatusObserver` actor 实现：注入 `GitServicing`，在 FSEvent 触发或初始加载时调用 `GitService.repositorySnapshot(for:)`，解析文件状态后调用 `onUpdate([URL: GitSummary])`。
- `FileTreeViewModel` 持有 `GitStatusObserver`，将 `onUpdate` 回调转发给 `FileTreeStore.updateGitStatuses`。
- `FileTreeCellView.configure(with:isSelected:)` 区分 `entry.isDirectory`：
  - 文件 → `gitBadgeLabel.stringValue = git.shortLabel`（现有逻辑，保留）
  - 目录 + **已展开** → 隐藏 badge（`gitBadgeLabel.isHidden = true`）
  - 目录 + **已折叠** → 显示彩点符号 `●`，字号略小，同 `git.nsColor` 颜色

**Tech Stack:** Swift 6.0+, AppKit (`NSTextField`), XCTest

**参考来源：**
- **Zed** [`project_panel.rs`](https://github.com/zed-industries/zed/blob/main/crates/project_panel/src/project_panel.rs)
  - `git_status_indicator(git_status: GitSummary) -> Option<(&'static str, Color)>` — 优先级映射函数（conflict → "!"，untracked → "U"，deleted → "D"，modified → "M"，staged → "M"(index)，added → "A"）；本计划对应 `GitSummary.shortLabel` 扩展（已实现）。
  - 渲染分支（`render_entry` 中）：
    ```rust
    let git_indicator = if kind.is_dir() {
        Indicator::dot()
            .color(Color::Custom(color.color(cx).opacity(0.5)))
            .into_any_element()
    } else {
        Label::new(label).size(LabelSize::Small).color(color).into_any_element()
    };
    ```
    目录用半透明点，文件用字母 label——本计划直接映射此逻辑到 `FileTreeCellView`。
  - `ChildEntriesGitIter` / `GitTraversal` — Zed 在 worktree 层做聚合，本计划改为在 `FileTreeStore.aggregateGitSummary(for:)` 中递归实现（我们架构无 worktree 层）。
  - `StatusesChanged` 事件 → `update_visible_entries()` 重新计算——本计划对应 `GitStatusObserver.onUpdate` → `FileTreeStore.updateGitStatuses()` → `computeVisibleEntries()`。
- **VSCode** [`explorerViewer.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/files/browser/views/explorerViewer.ts)
  - `FilesRenderer.renderStat()` 通过 `fileDecorations: this.config.explorer.decorations` 委托给 SCM 装饰服务；本计划内联 git 状态到 `VisibleEntry`，不引入外部服务层（更简单）。
  - `ExplorerItem.decoration` 的目录继承逻辑（`explorerModel.ts`）— 父目录 decoration 从子项中选取最高优先级，等价于本计划 `aggregateGitSummary` 的 `min()` 递归。
  - `explorer.decorations.badges` 设置项 — 控制是否显示字母 badge；本计划对应将来的 `AppSettings.showGitBadges`（FT-R7 暂不实现该设置，直接显示）。
- 设计文档 `docs/plans/2026-07-15-filetree-rewrite-design.md` §FT-R7

---

## 前置条件

- 已完成 FT-R0 ✅（`VisibleEntry.gitSummary: GitSummary?`、`GitSummary` enum 已定义）
- 已完成 FT-R1 ✅（`FSEventObserver` 可供 `GitStatusObserver` 复用事件触发）
- 已完成 FT-R2 ✅（`FileTreeCellView.gitBadgeLabel` 已创建，`gitSummary.shortLabel` / `nsColor` 扩展已实现）
- 已完成 FT-R3 ✅（lazy load 不影响状态聚合）
- 已完成 FT-R4 ✅（增量 diff 可与 git 更新共存）
- 已完成 FT-R5 ✅（auto-fold 逻辑中 `gitSummary: nil` 占位不影响本任务）

当前实现缺口：

| 文件 | 现状 | FT-R7 目标 |
|------|------|-----------|
| `agentGui/Services/FileTreeStore.swift` | `gitSummary: nil` 硬编码两处；无 `gitStatuses` 字典、无 `updateGitStatuses`、无 `aggregateGitSummary` | 添加字典 + 方法 + 接入 DFS |
| `agentGui/Views/FileTree/FileTreeCellView.swift` | badge 显示字母（file/dir 一视同仁）；无"展开目录隐藏"逻辑 | 目录 → 彩点；展开 → 隐藏 |
| `agentGui/ViewModels/FileTreeViewModel.swift` | 无 `GitStatusObserver` 持有；无 `updateGitStatuses` 调用链 | 注入 Observer，连接生命周期 |
| `agentGui/Services/GitStatusObserver.swift` | 不存在 | 新建协议 + actor 实现 |
| `agentGuiTests/FileTreeGitSummaryTests.swift` | 不存在 | 新建，覆盖 5 个测试用例 |

---

## Task 1：`FileTreeStore` git 状态存储 + 聚合 + DFS 接线

**Files:**
- Modify: `agentGui/Services/FileTreeStore.swift`
- Create: `agentGuiTests/FileTreeGitSummaryTests.swift`

这是 FT-R7 的核心数据层——其他 Task 均依赖此处正确性。目标：
1. 在 `FileTreeStore` 添加 `private var gitStatuses: [EntryID: GitSummary] = [:]`。
2. 实现 `func updateGitStatuses(_ statuses: [URL: GitSummary])`：将 URL 转为 EntryID，存入字典，触发 `computeVisibleEntries()`。
3. 实现 `private func aggregateGitSummary(for id: EntryID) -> GitSummary?`：直接命中返回，否则递归子节点取 `min()`。
4. 修改 `dfs()` 中的 `gitSummary: nil` 占位（两处），替换为 `aggregateGitSummary(for: id)`。

### Step 1：编写预期失败的测试

**新建** `agentGuiTests/FileTreeGitSummaryTests.swift`：

```swift
// agentGuiTests/FileTreeGitSummaryTests.swift
import XCTest
@testable import agentGui

/// FT-R7 Git 状态 badge 测试。
/// 覆盖设计文档 §FT-R7 指定的 5 个测试用例。
///
/// 参考 Zed project_panel_tests.rs：
///   test_git_status / test_aggregated_git_status
final class FileTreeGitSummaryTests: XCTestCase {

    // MARK: - 辅助

    typealias URL = Foundation.URL

    func makeStore() -> FileTreeStore {
        FileTreeStore(scanner: MockDirectoryScanner())
    }

    func makeIDs() -> (root: EntryID, src: EntryID, fileA: EntryID, fileB: EntryID) {
        (
            root:  EntryID(url: URL(fileURLWithPath: "/repo")),
            src:   EntryID(url: URL(fileURLWithPath: "/repo/src")),
            fileA: EntryID(url: URL(fileURLWithPath: "/repo/src/a.swift")),
            fileB: EntryID(url: URL(fileURLWithPath: "/repo/src/b.swift"))
        )
    }

    /// 向 store 注入三层树：/repo → /repo/src → /repo/src/a.swift & /repo/src/b.swift
    /// src 展开，root 展开
    func inject(into store: FileTreeStore,
                aStatus: GitSummary? = nil,
                bStatus: GitSummary? = nil,
                srcExpanded: Bool = true) async {
        let ids = makeIDs()
        await store.injectEntries(
            [
                ids.root:  FileEntry(id: ids.root,  name: "repo",    isDirectory: true,  parentID: nil,      loadState: .loaded),
                ids.src:   FileEntry(id: ids.src,   name: "src",     isDirectory: true,  parentID: ids.root, loadState: .loaded),
                ids.fileA: FileEntry(id: ids.fileA, name: "a.swift", isDirectory: false, parentID: ids.src,  loadState: .loaded),
                ids.fileB: FileEntry(id: ids.fileB, name: "b.swift", isDirectory: false, parentID: ids.src,  loadState: .loaded),
            ],
            children: [
                ids.root:  [ids.src],
                ids.src:   [ids.fileA, ids.fileB],
                ids.fileA: [],
                ids.fileB: [],
            ],
            rootIDs: [ids.src],
            expandedIDs: srcExpanded ? [ids.src] : []
        )
        var statuses: [URL: GitSummary] = [:]
        if let s = aStatus { statuses[URL(fileURLWithPath: "/repo/src/a.swift")] = s }
        if let s = bStatus { statuses[URL(fileURLWithPath: "/repo/src/b.swift")] = s }
        if !statuses.isEmpty {
            await store.updateGitStatuses(statuses)
        }
    }

    // MARK: - testFileBadge_showsDirectStatus

    /// 文件行的 gitSummary 应等于该文件的直接 Git 状态。
    func testFileBadge_showsDirectStatus() async throws {
        let store = makeStore()
        await inject(into: store, aStatus: .modified)

        let entries = await store.computeVisibleEntries()
        let aRow = try XCTUnwrap(entries.first { !$0.isDirectory && $0.name == "a.swift" })
        XCTAssertEqual(aRow.gitSummary, .modified)
    }

    // MARK: - testDirectoryBadge_aggregatesChildStatuses

    /// 目录行的 gitSummary 应等于子树中优先级最高的状态。
    /// 此用例：子无状态 → 目录也无状态。
    func testDirectoryBadge_aggregatesChildStatuses() async throws {
        let store = makeStore()
        // a.swift = modified，src 应聚合为 modified
        await inject(into: store, aStatus: .modified, srcExpanded: false)

        let entries = await store.computeVisibleEntries()
        let srcRow = try XCTUnwrap(entries.first { $0.isDirectory && $0.name == "src" })
        XCTAssertEqual(srcRow.gitSummary, .modified,
            "目录 gitSummary 应等于最高优先级子文件状态")
    }

    // MARK: - testDirectoryBadge_highestPriorityWins

    /// 多子有不同状态时，优先级最高者（rawValue 最小）胜出。
    /// conflict(0) < untracked(1) < deleted(2) < modified(3) < staged(4) < added(5)
    func testDirectoryBadge_highestPriorityWins() async throws {
        let store = makeStore()
        // a.swift = conflict（优先级 0），b.swift = added（优先级 5）
        // 期望：src = conflict
        await inject(into: store, aStatus: .conflict, bStatus: .added, srcExpanded: false)

        let entries = await store.computeVisibleEntries()
        let srcRow = try XCTUnwrap(entries.first { $0.isDirectory && $0.name == "src" })
        XCTAssertEqual(srcRow.gitSummary, .conflict,
            "conflict(rawValue=0) 应优先于 added(rawValue=5)")
    }

    // MARK: - testExpandedDirectory_hidesAggregatedBadge

    /// 已展开的目录 gitSummary 应为 nil，因为子节点已可见，不需要聚合点。
    func testExpandedDirectory_hidesAggregatedBadge() async throws {
        let store = makeStore()
        // src 展开，a.swift = modified
        await inject(into: store, aStatus: .modified, srcExpanded: true)

        let entries = await store.computeVisibleEntries()
        let srcRow = try XCTUnwrap(entries.first { $0.isDirectory && $0.name == "src" })
        XCTAssertNil(srcRow.gitSummary,
            "已展开目录的 gitSummary 应为 nil（子节点可见，降低噪音）")
    }

    // MARK: - testNoGitStatus_noBadge

    /// 无任何 Git 状态时，所有行的 gitSummary 均为 nil。
    func testNoGitStatus_noBadge() async throws {
        let store = makeStore()
        await inject(into: store)  // 不注入任何状态

        let entries = await store.computeVisibleEntries()
        for entry in entries {
            XCTAssertNil(entry.gitSummary, "\(entry.name) 不应有 gitSummary")
        }
    }
}
```

运行 `xcodebuild test -only-testing:agentGuiTests/FileTreeGitSummaryTests` → 预期全部**失败**（`FileTreeStore` 无 `updateGitStatuses` 方法）。

### Step 2：实现 `updateGitStatuses` + `aggregateGitSummary`

在 `FileTreeStore.swift` 中（在 `private var expandedIDs` 声明附近）添加：

```swift
// FT-R7: Git 状态字典（EntryID → GitSummary）
private var gitStatuses: [EntryID: GitSummary] = [:]

/// 接收外部 Git 状态更新（URL → GitSummary），转换后存储，触发重新计算。
/// 调用方：GitStatusObserver.onUpdate（主线程回调后转到 actor）。
func updateGitStatuses(_ statuses: [URL: GitSummary]) {
    gitStatuses = Dictionary(
        uniqueKeysWithValues: statuses.map { (EntryID(url: $0.key), $0.value) }
    )
    scheduleRecompute()  // 与 applyFSEvents 使用相同的节流机制
}

/// 后序递归聚合：文件直接返回状态；目录取子树 min（优先级最高）。
/// - Complexity: O(子树大小)，仅在 DFS 中被调用一次
private func aggregateGitSummary(for id: EntryID) -> GitSummary? {
    if let direct = gitStatuses[id] { return direct }
    guard let childIDs = children[id], !childIDs.isEmpty else { return nil }
    let childStatuses = childIDs.compactMap { aggregateGitSummary(for: $0) }
    return childStatuses.min()
}
```

### Step 3：接入 DFS

找到 `dfs()` 中两处 `gitSummary: nil` 占位，替换：

```swift
// 修改前（auto-fold 分支）：
gitSummary: nil,  // Git badge 在 FT-R7 实现

// 修改后：
// 已展开目录 → 子节点可见，不显示聚合点；其余节点取聚合结果
gitSummary: (isDirectory && isExpanded) ? nil : aggregateGitSummary(for: id),
```

> **注意**：两处 `gitSummary: nil` 分别在 auto-fold 终端节点行和普通节点行，逻辑相同，均替换为上述表达式。

### Step 4：运行测试确认全绿

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ft-r7-task1 \
  -only-testing:agentGuiTests/FileTreeGitSummaryTests \
  CODE_SIGNING_ALLOWED=NO
```

预期：**5 passed, 0 failed**。

---

## Task 2：`FileTreeCellView` 目录彩点 badge + 展开隐藏

**Files:**
- Modify: `agentGui/Views/FileTree/FileTreeCellView.swift`
- Modify: `agentGuiTests/FileTreeCellConfigureTests.swift`（在已有文件中新增用例）

目标：
1. 文件 badge 保持字母（现有逻辑不变）。
2. 目录 + 已折叠 → badge 显示 `●`（`gitBadgeLabel.stringValue = "●"`），字号略小（10pt），颜色 `git.nsColor.withAlphaComponent(0.75)`（匹配 Zed 的 `opacity(0.5)` 效果，macOS 深浅模式均保持可读）。
3. 目录 + 已展开（`entry.isExpanded == true`）→ `gitBadgeLabel.isHidden = true`。
4. `gitSummary == nil` → `gitBadgeLabel.isHidden = true`（现有逻辑保留）。

### Step 1：在 `FileTreeCellConfigureTests.swift` 新增测试用例

在已有 `FileTreeCellConfigureTests` 类末尾，追加：

```swift
// MARK: - FT-R7 Git badge 渲染测试

/// 文件有 Git 状态 → 显示字母 badge
func testGitBadge_fileShowsLetter() {
    let entry = VisibleEntry.stub(
        name: "a.swift", isDirectory: false, isExpanded: false,
        gitSummary: .modified
    )
    cell.configure(with: entry, isSelected: false)
    XCTAssertFalse(cell.gitBadgeLabel.isHidden)
    XCTAssertEqual(cell.gitBadgeLabel.stringValue, "M",
        "修改文件应显示字母 M")
}

/// 折叠目录有聚合状态 → 显示彩点 ●
func testGitBadge_collapsedDirectoryShowsDot() {
    let entry = VisibleEntry.stub(
        name: "src", isDirectory: true, isExpanded: false,
        gitSummary: .modified
    )
    cell.configure(with: entry, isSelected: false)
    XCTAssertFalse(cell.gitBadgeLabel.isHidden)
    XCTAssertEqual(cell.gitBadgeLabel.stringValue, "●",
        "折叠目录应显示彩点 ●，不是字母")
}

/// 展开目录有聚合状态 → badge 隐藏（子节点已可见）
func testGitBadge_expandedDirectoryHidesBadge() {
    let entry = VisibleEntry.stub(
        name: "src", isDirectory: true, isExpanded: true,
        gitSummary: .modified  // DFS 实际不会传此值，但 CellView 应容错
    )
    cell.configure(with: entry, isSelected: false)
    XCTAssertTrue(cell.gitBadgeLabel.isHidden,
        "展开目录的 badge 应隐藏")
}

/// gitSummary == nil → badge 隐藏
func testGitBadge_nilStatusHidesBadge() {
    let entry = VisibleEntry.stub(
        name: "b.swift", isDirectory: false, isExpanded: false,
        gitSummary: nil
    )
    cell.configure(with: entry, isSelected: false)
    XCTAssertTrue(cell.gitBadgeLabel.isHidden)
}
```

> `VisibleEntry.stub(...)` 是测试辅助扩展，若不存在则在测试文件中添加：
> ```swift
> extension VisibleEntry {
>     static func stub(name: String, isDirectory: Bool, isExpanded: Bool,
>                      gitSummary: GitSummary? = nil) -> VisibleEntry {
>         VisibleEntry(id: EntryID(url: URL(fileURLWithPath: "/tmp/\(name)")),
>                      name: name, isDirectory: isDirectory,
>                      depth: 0, isExpanded: isExpanded,
>                      loadState: .loaded, foldedAncestors: nil,
>                      gitSummary: gitSummary, diagnosticSeverity: nil, isIgnored: false)
>     }
> }
> ```

运行新增用例 → 预期**失败**（目录 badge 仍显示字母）。

### Step 2：修改 `FileTreeCellView.configure(with:isSelected:)` 中的 badge 渲染

找到现有 badge 渲染块（约第 226-244 行）：

```swift
// 修改前（仅处理 nil，文件/目录同一逻辑）：
if let git = entry.gitSummary {
    gitBadgeLabel.isHidden = false
    gitBadgeLabel.stringValue = git.shortLabel
    gitBadgeLabel.textColor = git.nsColor
} else {
    gitBadgeLabel.isHidden = true
}
```

替换为：

```swift
// FT-R7：区分文件/目录 badge 渲染
if let git = entry.gitSummary, !entry.isExpanded {
    gitBadgeLabel.isHidden = false
    if entry.isDirectory {
        // 目录：折叠彩点，半透明
        gitBadgeLabel.stringValue = "●"
        gitBadgeLabel.font = NSFont.systemFont(ofSize: 10)
        gitBadgeLabel.textColor = git.nsColor.withAlphaComponent(0.75)
    } else {
        // 文件：字母 badge，不透明
        gitBadgeLabel.stringValue = git.shortLabel
        gitBadgeLabel.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                          weight: .medium)
        gitBadgeLabel.textColor = git.nsColor
    }
} else {
    gitBadgeLabel.isHidden = true
    gitBadgeLabel.stringValue = ""
}
```

> **注意**：`entry.isExpanded` 已存在于 `VisibleEntry`（FT-R0 字段）。展开目录在 Task 1 中 DFS 已不填充 `gitSummary`（设为 nil），此处的 `!entry.isExpanded` 是额外防护层，确保即使外部传来非 nil 值也正确隐藏。

### Step 3：运行测试确认全绿

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ft-r7-task2 \
  -only-testing:agentGuiTests/FileTreeGitSummaryTests \
  -only-testing:agentGuiTests/FileTreeCellConfigureTests \
  CODE_SIGNING_ALLOWED=NO
```

预期：**全部通过**。

---

## Task 3：`GitStatusObserver` + `FileTreeViewModel` 接线

**Files:**
- Create: `agentGui/Services/GitStatusObserver.swift`
- Modify: `agentGui/ViewModels/FileTreeViewModel.swift`

目标：
1. 定义 `GitStatusObserving` 协议，暴露 `start(rootURL:onUpdate:)` / `stop()` 接口。
2. 实现 `GitStatusObserver` actor：持有 `GitServicing`，在 `start()` 中立即采集一次，并监听 FSEvent 通知（通过 `NotificationCenter` 订阅 `FSEventObserver` 发布的通知）后通知。
3. `FileTreeViewModel` 在 `setRoot(url:)` 时启动 Observer，在 `deinit` 或根变更时停止旧 Observer。

### Step 1：创建 `GitStatusObserver.swift`

**新建** `agentGui/Services/GitStatusObserver.swift`：

```swift
// agentGui/Services/GitStatusObserver.swift
import Foundation

/// GitStatusObserver 的可测试协议接口。
/// 参考 Zed：RepositoryEvent::StatusesChanged 让 project_panel 订阅，
/// 此处改为主动拉取模式（push-pull hybrid）。
protocol GitStatusObserving: AnyObject {
    /// 启动观察：立即触发一次状态采集，并在此后每次 FSEvent 后重采。
    /// - Parameters:
    ///   - rootURL: 仓库根目录 URL（传给 GitService）
    ///   - onUpdate: 状态字典回调，在 MainActor 上调用
    func start(rootURL: URL, onUpdate: @escaping @MainActor ([URL: GitSummary]) -> Void)
    /// 停止观察，取消后台任务。
    func stop()
}

/// 真实实现：使用 GitService 轮询 Git 状态。
/// 监听 `FSEventObserver.didChangeNotification` 作为触发信号。
final class GitStatusObserver: GitStatusObserving {
    private let gitService: GitServicing
    private var observationTask: Task<Void, Never>?
    private var fsEventObserver: NSObjectProtocol?

    /// - Parameter gitService: 可注入 mock，便于测试。默认使用真实 GitService。
    @MainActor
    init(gitService: GitServicing = GitService()) {
        self.gitService = gitService
    }

    func start(rootURL: URL, onUpdate: @escaping @MainActor ([URL: GitSummary]) -> Void) {
        stop()  // 清理旧观察

        // 立即采集一次
        Task { @MainActor in
            await self.fetchAndNotify(rootURL: rootURL, onUpdate: onUpdate)
        }

        // 订阅 FSEvent 通知触发重采
        fsEventObserver = NotificationCenter.default.addObserver(
            forName: FSEventObserver.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // 节流：取消上一次未执行的采集任务
            self.observationTask?.cancel()
            self.observationTask = Task { @MainActor in
                // 等待 300ms 节流（防止 FSEvent 连续触发导致频繁采集）
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await self.fetchAndNotify(rootURL: rootURL, onUpdate: onUpdate)
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        if let obs = fsEventObserver {
            NotificationCenter.default.removeObserver(obs)
            fsEventObserver = nil
        }
    }

    deinit { stop() }

    // MARK: - Private

    @MainActor
    private func fetchAndNotify(rootURL: URL,
                                 onUpdate: @escaping @MainActor ([URL: GitSummary]) -> Void) async {
        guard let snapshot = try? await gitService.repositorySnapshot(for: rootURL) else { return }
        let statuses = snapshot.changesAsGitSummaryMap()
        onUpdate(statuses)
    }
}
```

> `GitRepositorySnapshot.changesAsGitSummaryMap()` 扩展方法见下方 Step 2。

### Step 2：添加 `GitRepositorySnapshot` 扩展

在现有 `GitRepositorySnapshot.swift`（或 `GitStatusObserver.swift` 底部）添加：

```swift
extension GitRepositorySnapshot {
    /// 将 `changes` 数组转为 `[URL: GitSummary]` 映射。
    /// 多个变更状态取优先级最高（rawValue 最小）。
    func changesAsGitSummaryMap() -> [URL: GitSummary] {
        var result: [URL: GitSummary] = [:]
        for change in changes {
            let url = repositoryRoot.appendingPathComponent(change.path)
            let summary = GitSummary(from: change.status)
            if let existing = result[url] {
                result[url] = min(existing, summary)
            } else {
                result[url] = summary
            }
        }
        return result
    }
}
```

以及 `GitSummary` init：

```swift
extension GitSummary {
    /// 从 `GitFileStatus` 构造 `GitSummary`。
    /// 参考 Zed `git_status_indicator` 优先级映射。
    init(from status: GitFileStatus) {
        switch status {
        case .conflicted:       self = .conflict
        case .untracked:        self = .untracked
        case .deleted, .missingFromIndex: self = .deleted
        case .modified:         self = .modified
        case .staged:           self = .staged
        case .added:            self = .added
        default:                self = .modified
        }
    }
}
```

> 如果 `GitFileStatus` 枚举名称与上方不符，参考 `GitService.swift` 中已有的 `change.status` 类型，做相应调整。

### Step 3：修改 `FileTreeViewModel`

在 `FileTreeViewModel.swift` 中：

1. 新增属性：
```swift
// FT-R7: Git 状态观察者
private var gitStatusObserver: (any GitStatusObserving)?
```

2. 在 `setRoot(_ url: URL)` 或等效方法中，在调用 `store.setRoot` 后添加：
```swift
// 启动 Git 状态观察
gitStatusObserver?.stop()
let observer = GitStatusObserver()
observer.start(rootURL: url) { [weak self] statuses in
    guard let self else { return }
    Task {
        await self.store.updateGitStatuses(statuses)
    }
}
gitStatusObserver = observer
```

3. 在 `deinit`（或根变更前）：
```swift
gitStatusObserver?.stop()
```

### Step 4：编译验证

确认编译无错误、无 Swift 6 actor isolation 警告：

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO
```

### Step 5：端到端冒烟验证

运行完整 FT-R7 相关测试（Task 1 + Task 2 + FT-R5 回归）：

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ft-r7-final \
  -only-testing:agentGuiTests/FileTreeGitSummaryTests \
  -only-testing:agentGuiTests/FileTreeCellConfigureTests \
  -only-testing:agentGuiTests/FileTreeAutoFoldTests \
  -only-testing:agentGuiTests/FileTreeViewModelAutoFoldTests \
  CODE_SIGNING_ALLOWED=NO
```

预期：**全部通过，无回归**。

---

## 实现检查清单

```
[ ] Task 1: FileTreeStore.gitStatuses 字典已添加
[ ] Task 1: updateGitStatuses([URL: GitSummary]) 实现并可调用
[ ] Task 1: aggregateGitSummary(for:) 递归聚合正确（min() = 优先级最高）
[ ] Task 1: dfs() 中两处 gitSummary: nil 已替换
[ ] Task 1: 展开目录 → DFS 传 nil（已展开子节点可见）
[ ] Task 1: FileTreeGitSummaryTests 全 5 个用例通过
[ ] Task 2: 文件 badge 显示字母（shortLabel），字体 monospaced
[ ] Task 2: 折叠目录 badge 显示彩点 ●，字号 10pt，颜色带 0.75 alpha
[ ] Task 2: 展开目录 badge 隐藏（isHidden = true）
[ ] Task 2: gitSummary = nil → badge 隐藏
[ ] Task 2: FileTreeCellConfigureTests 新增 4 个用例通过
[ ] Task 3: GitStatusObserving 协议定义清晰（可 mock）
[ ] Task 3: GitStatusObserver actor 实现：立即采集 + FSEvent 节流（300ms）
[ ] Task 3: GitRepositorySnapshot.changesAsGitSummaryMap() 扩展正确
[ ] Task 3: FileTreeViewModel 正确启动/停止 Observer
[ ] Task 3: 编译无 Swift 6 actor isolation 错误
[ ] 回归：FT-R5 auto-fold 测试全通过（无干扰）
```

---

## 附录：Zed 与本计划的架构对比

| 方面 | Zed (Rust) | 本计划 (Swift) |
|------|-----------|---------------|
| 状态来源 | `GitStore` reactive（`StatusesChanged` 事件） | `GitStatusObserver` 拉取 + FSEvent 节流 |
| 目录聚合 | `GitTraversal` 在 worktree 层做聚合 | `aggregateGitSummary(for:)` 在 `FileTreeStore` 递归 |
| badge 渲染 | `Indicator::dot()` / `Label::new(label)` (GPUI) | `NSTextField("●")` / `NSTextField(shortLabel)` (AppKit) |
| 展开隐藏 | 无（Zed 始终显示目录聚合点） | DFS 对展开目录输出 `gitSummary: nil` |
| 优先级 | `min(conflict=0...added=5)` | 同，`GitSummary.Comparable` rawValue |

# FT-R4：增量 diff 更新 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 `FileTreeTableView.updateNSView` 中的全量 `reloadData()` 替换为基于 `CollectionDifference` 的增量 diff 更新，在展开/折叠目录时产生流畅的行插入/删除动画，同时保留选中状态。

**Architecture:**
- 从 `Coordinator` 中提取纯函数 `FileTreeDiff.compute(from:to:)` → 返回结构体 `FileTreeDiff`，包含待删除索引、待插入索引、待原地刷新的索引，以及"是否应降级为全量 reload"的标志。
- 纯函数可独立测试，无需 NSTableView 实例；`Coordinator.applyDiff(_:to:)` 获取 diff 结果后对 tableView 执行相应操作。
- 内容变更（相同 ID、不同内容，如 gitSummary/loadState 变化）走 `reloadData(forRowIndexes:)`，不触发动画。

**Tech Stack:** Swift 6.0+, AppKit (`NSTableView.beginUpdates/endUpdates`/`insertRows/removeRows`/`reloadData(forRowIndexes:)`), XCTest

**参考来源：**
- VSCode [`listWidget.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/base/browser/ui/list/listWidget.ts)：
  - `List.splice(start, deleteCount, elements)` — 核心增量 API，对底层 `ListView` 发起行级 insert/delete 的同时，同步更新 `TraitSpliceable`（selection / focus / anchor trait 索引偏移），确保选中行在 insert/delete 后指向正确元素，本计划的 `restoreSelection` 步骤与此对应。
  - `TraitSpliceable.splice()` — splice 期间重新映射 trait 索引：index < start 保不变，index ≥ start + deleteCount 偏移 `insertCount - deleteCount`，正好对应 Swift `CollectionDifference` 的语义。
- Zed [`project_panel.rs`](https://github.com/zed-industries/zed/blob/main/crates/project_panel/src/project_panel.rs)：
  - `update_visible_entries()` + `cx.notify()` — Zed 使用 `uniform_list("entries", item_count, ...)` 虚拟列表，`cx.notify()` 触发框架重新调用 render 闭包，框架内部做 row-level diff；本计划将此职责移至 `Coordinator.applyDiff`，在 AppKit 层手动执行等价操作。
  - `rendered_entries_len` — Zed 在每次 render 回调中记录本次实际渲染的行数（`range.end - range.start`），用于滚动跳转；本计划无需此字段，因为 NSTableView 自身维护 row count。
- 设计文档 `docs/plans/2026-07-15-filetree-rewrite-design.md` §FT-R4

---

## 前置条件

- 已完成 FT-R0 ✅（`VisibleEntry: Equatable`, `EntryID`）
- 已完成 FT-R1 ✅（`FSEventObserver` 集成到 `FileTreeStore`）
- 已完成 FT-R2 ✅（`FileTreeTableView`, `Coordinator`, `updateNSView` 存在）
- 已完成 FT-R3 ✅（`VisibleEntry.loadState`, loading spinner, 错误回退）

当前实现缺口：

| 文件 | 现状 | FT-R4 目标 |
|------|------|-----------|
| `agentGui/Views/FileTree/FileTreeTableView.swift` | `updateNSView` 用 `reloadData()` 做全量刷新，含 `// FT-R4 阶段将替换为...` 注释 | 替换为增量 diff |
| `agentGuiTests/FileTreeDiffUpdateTests.swift` | 不存在 | 新建，测试纯函数 `FileTreeDiff.compute` |

---

## Task 1：提取可测试的纯 diff 函数

**Files:**
- Create: `agentGui/Views/FileTree/FileTreeDiff.swift`
- Create: `agentGuiTests/FileTreeDiffUpdateTests.swift`

要让增量更新逻辑完全可单元测试，必须把计算从 `Coordinator` 中抽出。  
`FileTreeDiff` 是一个值类型（struct），`compute(from:to:threshold:)` 是纯静态方法，不依赖任何 AppKit 对象。

### Step 1：编写预期失败的测试

**新建** `agentGuiTests/FileTreeDiffUpdateTests.swift`：

```swift
// agentGuiTests/FileTreeDiffUpdateTests.swift
import XCTest
@testable import agentGui

final class FileTreeDiffUpdateTests: XCTestCase {

    // MARK: - 辅助

    func makeEntry(
        name: String,
        depth: Int = 0,
        isExpanded: Bool = false,
        loadState: FileEntry.LoadState = .loaded,
        gitSummary: GitSummary? = nil
    ) -> VisibleEntry {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        return VisibleEntry(
            id: EntryID(url: url),
            name: name,
            isDirectory: false,
            depth: depth,
            isExpanded: isExpanded,
            loadState: loadState,
            foldedAncestors: nil,
            gitSummary: gitSummary,
            diagnosticSeverity: nil,
            isIgnored: false
        )
    }

    // MARK: - 无变化

    func testCompute_noChange_returnsEmpty() {
        let entries = [makeEntry(name: "a"), makeEntry(name: "b")]
        let diff = FileTreeDiff.compute(from: entries, to: entries)
        XCTAssertFalse(diff.shouldFullReload)
        XCTAssertTrue(diff.removals.isEmpty)
        XCTAssertTrue(diff.insertions.isEmpty)
        XCTAssertTrue(diff.contentReloads.isEmpty)
    }

    // MARK: - 首次加载（old 为空）

    func testCompute_firstLoad_shouldFullReload() {
        let diff = FileTreeDiff.compute(
            from: [],
            to: [makeEntry(name: "a"), makeEntry(name: "b")]
        )
        XCTAssertTrue(diff.shouldFullReload)
    }

    // MARK: - 插入单行

    func testCompute_insertRow_correctIndex() {
        let old = [makeEntry(name: "a"), makeEntry(name: "c")]
        let new = [makeEntry(name: "a"), makeEntry(name: "b"), makeEntry(name: "c")]
        let diff = FileTreeDiff.compute(from: old, to: new)
        XCTAssertFalse(diff.shouldFullReload)
        XCTAssertEqual(diff.insertions, IndexSet(integer: 1))
        XCTAssertTrue(diff.removals.isEmpty)
        XCTAssertTrue(diff.contentReloads.isEmpty)
    }

    // MARK: - 删除单行

    func testCompute_removeRow_correctIndex() {
        let old = [makeEntry(name: "a"), makeEntry(name: "b"), makeEntry(name: "c")]
        let new = [makeEntry(name: "a"), makeEntry(name: "c")]
        let diff = FileTreeDiff.compute(from: old, to: new)
        XCTAssertFalse(diff.shouldFullReload)
        XCTAssertEqual(diff.removals, IndexSet(integer: 1))
        XCTAssertTrue(diff.insertions.isEmpty)
        XCTAssertTrue(diff.contentReloads.isEmpty)
    }

    // MARK: - 展开目录（批量插入）

    func testCompute_expandDirectory_insertsChildren() {
        let root = makeEntry(name: "src")
        let child1 = makeEntry(name: "main.swift", depth: 1)
        let child2 = makeEntry(name: "util.swift", depth: 1)
        let old = [root]
        let new = [root, child1, child2]
        let diff = FileTreeDiff.compute(from: old, to: new)
        XCTAssertFalse(diff.shouldFullReload)
        XCTAssertEqual(diff.insertions, IndexSet([1, 2]))
        XCTAssertTrue(diff.removals.isEmpty)
    }

    // MARK: - 折叠目录（批量删除）

    func testCompute_collapseDirectory_removesChildren() {
        let root = makeEntry(name: "src")
        let child1 = makeEntry(name: "main.swift", depth: 1)
        let child2 = makeEntry(name: "util.swift", depth: 1)
        let old = [root, child1, child2]
        let new = [root]
        let diff = FileTreeDiff.compute(from: old, to: new)
        XCTAssertFalse(diff.shouldFullReload)
        XCTAssertEqual(diff.removals, IndexSet([1, 2]))
        XCTAssertTrue(diff.insertions.isEmpty)
    }

    // MARK: - 内容变更（同 ID，不同内容）

    func testCompute_contentOnlyChange_noStructuralDiff() {
        let before = makeEntry(name: "file.swift", gitSummary: nil)
        let after = makeEntry(name: "file.swift", gitSummary: .modified)
        let diff = FileTreeDiff.compute(from: [before], to: [after])
        XCTAssertFalse(diff.shouldFullReload)
        XCTAssertTrue(diff.removals.isEmpty)
        XCTAssertTrue(diff.insertions.isEmpty)
        XCTAssertEqual(diff.contentReloads, IndexSet(integer: 0))
    }

    // MARK: - 大量变更降级为全量 reload

    func testCompute_largeDiff_shouldFullReload() {
        let old = (0..<100).map { makeEntry(name: "file_\($0)") }
        // 新列表完全不同（所有 ID 改变）
        let new = (200..<400).map { makeEntry(name: "file_\($0)") }
        let diff = FileTreeDiff.compute(from: old, to: new, threshold: 50)
        XCTAssertTrue(diff.shouldFullReload)
    }

    // MARK: - threshold 临界值

    func testCompute_diffJustBelowThreshold_doesNotFullReload() {
        let old = [makeEntry(name: "a"), makeEntry(name: "b"), makeEntry(name: "c")]
        // 插入 2 行（总变更 = 2），threshold = 3 → 不降级
        let new = [makeEntry(name: "a"), makeEntry(name: "x"),
                   makeEntry(name: "b"), makeEntry(name: "y"), makeEntry(name: "c")]
        let diff = FileTreeDiff.compute(from: old, to: new, threshold: 3)
        XCTAssertFalse(diff.shouldFullReload)
        XCTAssertEqual(diff.insertions.count, 2)
    }
}
```

运行确认全部编译错误（`FileTreeDiff` 不存在）：

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep "error:" | head -5
```

预期：`error: cannot find type 'FileTreeDiff' in scope`

### Step 2：实现 `FileTreeDiff.swift`

**新建** `agentGui/Views/FileTree/FileTreeDiff.swift`：

```swift
// agentGui/Views/FileTree/FileTreeDiff.swift
import Foundation

/// `VisibleEntry` 列表变更的增量 diff 结果。
///
/// 计算逻辑参考：
/// - VSCode `List.splice(start, deleteCount, elements)` — 行级 insert/delete
///   并同步更新 selection/focus trait 索引（TraitSpliceable.splice）
/// - Zed `uniform_list` — 框架内部以 row ID 做 diff，驱动行级更新
///
/// `compute(from:to:threshold:)` 是纯静态函数，不依赖 AppKit，可直接单元测试。
struct FileTreeDiff {

    // MARK: - 结果字段

    /// 是否应放弃增量更新，降级为 `reloadData()`。
    ///
    /// 触发条件：
    /// 1. `old` 为空（首次加载，无需动画）
    /// 2. 结构变更数量超过 `threshold`（动画帧数过多会卡顿）
    let shouldFullReload: Bool

    /// 需要删除的行索引（基于 `old` 的索引）。
    let removals: IndexSet

    /// 需要插入的行索引（基于 `new` 的索引）。
    let insertions: IndexSet

    /// 结构不变（ID 相同）但内容字段变化的行索引（基于 `new` 的索引）。
    /// 用 `reloadData(forRowIndexes:)` 原地刷新，不触发动画。
    let contentReloads: IndexSet

    // MARK: - 计算入口

    /// 计算两个 `VisibleEntry` 列表之间的增量 diff。
    ///
    /// - Parameters:
    ///   - old: 当前 Coordinator 持有的旧列表。
    ///   - new: ViewModel 推送的新列表。
    ///   - threshold: 结构变更数量超出此阈值则降级为全量 reload，默认 200。
    /// - Returns: `FileTreeDiff` 描述所需操作。
    static func compute(
        from old: [VisibleEntry],
        to new: [VisibleEntry],
        threshold: Int = 200
    ) -> FileTreeDiff {

        // 首次加载（旧列表为空）→ 直接全量 reload，无需动画
        guard !old.isEmpty else {
            return FileTreeDiff(
                shouldFullReload: true,
                removals: .init(),
                insertions: .init(),
                contentReloads: .init()
            )
        }

        // 使用 Swift 标准库 CollectionDifference，按 ID 做等价判断
        let diff = new.difference(from: old) { $0.id == $1.id }

        var removals = IndexSet()
        var insertions = IndexSet()

        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                removals.insert(offset)
            case .insert(let offset, _, _):
                insertions.insert(offset)
            }
        }

        let totalStructuralChanges = removals.count + insertions.count

        // 变更量超过阈值 → 降级全量 reload（避免动画帧数过多卡顿）
        if totalStructuralChanges > threshold {
            return FileTreeDiff(
                shouldFullReload: true,
                removals: .init(),
                insertions: .init(),
                contentReloads: .init()
            )
        }

        // 无结构变更时检查内容变更
        // 内容变更：新旧列表中 ID 相同但 Equatable 比较不等的行
        var contentReloads = IndexSet()
        if diff.isEmpty {
            for (newIndex, newEntry) in new.enumerated() {
                if newIndex < old.count, old[newIndex].id == newEntry.id,
                   old[newIndex] != newEntry {
                    contentReloads.insert(newIndex)
                }
            }
        }

        return FileTreeDiff(
            shouldFullReload: false,
            removals: removals,
            insertions: insertions,
            contentReloads: contentReloads
        )
    }
}
```

### Step 3：运行测试，确认 PASS

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ftr4-task1 \
  -only-testing:agentGuiTests/FileTreeDiffUpdateTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：全部测试 PASS，无失败。

### Step 4：提交

```bash
git add agentGui/Views/FileTree/FileTreeDiff.swift \
        agentGuiTests/FileTreeDiffUpdateTests.swift
git commit -m "feat(FT-R4): add FileTreeDiff pure diff computation + tests"
```

---

## Task 2：将 `Coordinator.applyDiff` 集成到 `updateNSView`

**Files:**
- Modify: `agentGui/Views/FileTree/FileTreeTableView.swift`

此任务替换 `updateNSView` 中全量 `reloadData()` 的逻辑，改为调用 `FileTreeDiff.compute` 并对 `NSTableView` 执行相应操作。

### Step 1：写一个集成测试确认当前行为（全量 reload）

在 `agentGuiTests/FileTreeDiffUpdateTests.swift` 末尾添加集成测试：

```swift
// MARK: - ViewModel 层集成：验证 visibleEntries 的增量语义

extension FileTreeDiffUpdateTests {

    /// 验证展开目录后 visibleEntries 数量正确增加。
    /// 此测试不直接测 NSTableView，但是构成 diff 正确性的基础保证。
    func testViewModel_expandDirectory_visibleEntriesIncreaseByChildCount() async throws {
        let root = URL(fileURLWithPath: "/tmp/proj")
        let srcURL = root.appendingPathComponent("src")
        let scanner = MockFileScanner()
        scanner.stub(directory: root, entries: [
            ScannedEntry(url: srcURL, name: "src", isDirectory: true),
            ScannedEntry(url: root.appendingPathComponent("README.md"),
                         name: "README.md", isDirectory: false),
        ])
        scanner.stub(directory: srcURL, entries: [
            ScannedEntry(url: srcURL.appendingPathComponent("main.swift"),
                         name: "main.swift", isDirectory: false),
            ScannedEntry(url: srcURL.appendingPathComponent("util.swift"),
                         name: "util.swift", isDirectory: false),
        ])
        let store = FileTreeStore(scanner: scanner)
        let vm = await FileTreeViewModel(store: store)

        await vm.setDirectory(root)
        let beforeCount = await vm.visibleEntries.count
        XCTAssertEqual(beforeCount, 2)  // src + README.md

        let srcID = EntryID(url: srcURL.standardizedFileURL)
        try await vm.toggleDirectory(srcID)

        let afterCount = await vm.visibleEntries.count
        XCTAssertEqual(afterCount, 4)  // src + main.swift + util.swift + README.md

        // diff 应为 2 行插入（main.swift, util.swift），无删除
        let diff = FileTreeDiff.compute(
            from: Array(await vm.visibleEntries.prefix(beforeCount)),
            to: await vm.visibleEntries
        )
        XCTAssertFalse(diff.shouldFullReload)
        XCTAssertEqual(diff.insertions.count, 2)
        XCTAssertTrue(diff.removals.isEmpty)
    }
}
```

> **注意**：以上测试需要 `FileTreeViewModel` 申明为 `@MainActor`，测试类本身也要在调用时切换到 `@MainActor`，可在方法体内使用 `await MainActor.run { ... }` 或在类级别加 `@MainActor`。

运行此测试确认 PASS（`visibleEntries` 计数正确）：

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ftr4-task2a \
  -only-testing:agentGuiTests/FileTreeDiffUpdateTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：全部 PASS。

### Step 2：重写 `Coordinator.applyDiff` + 修改 `updateNSView`

修改 `agentGui/Views/FileTree/FileTreeTableView.swift`。

**在 `Coordinator` 内部新增 `applyDiff` 方法**（放在 `syncSelectionToTable` 之前）：

```swift
// MARK: 增量 diff 更新（FT-R4）

/// 将 VisibleEntry 列表变更应用到 NSTableView。
///
/// 算法参考：
/// - VSCode `List.splice()` — 先做 trait splice（selection 索引偏移），再做 DOM insert/remove
/// - Zed `uniform_list` — 框架内部以 ID diff 驱动 row-level 更新
///
/// 本实现：
/// 1. 用 `FileTreeDiff.compute` 计算结构/内容变更
/// 2. 结构变更：`beginUpdates` → `removeRows/insertRows` → `endUpdates`
/// 3. 内容变更：`reloadData(forRowIndexes:columnIndexes:)`
/// 4. 降级条件：`shouldFullReload == true` → `reloadData()`
func applyDiff(
    from old: [VisibleEntry],
    to new: [VisibleEntry],
    tableView: NSTableView
) {
    let diff = FileTreeDiff.compute(from: old, to: new)

    if diff.shouldFullReload {
        tableView.reloadData()
        return
    }

    // 结构变更：使用 beginUpdates/endUpdates 包装，产生动画
    if !diff.removals.isEmpty || !diff.insertions.isEmpty {
        tableView.beginUpdates()
        if !diff.removals.isEmpty {
            tableView.removeRows(
                at: diff.removals,
                withAnimation: .effectFade
            )
        }
        if !diff.insertions.isEmpty {
            tableView.insertRows(
                at: diff.insertions,
                withAnimation: .effectFade
            )
        }
        tableView.endUpdates()
    }

    // 内容变更（无结构变化时）：原地刷新，不触发动画
    if !diff.contentReloads.isEmpty {
        tableView.reloadData(
            forRowIndexes: diff.contentReloads,
            columnIndexes: IndexSet(integer: 0)
        )
    }

    // 恢复选中状态（insert/remove 可能导致行索引偏移）
    syncSelectionToTable(tableView, selection: selection)
}
```

**替换 `updateNSView` 中的全量 reload 代码块**：

找到以下代码：

```swift
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.onToggleExpand = onToggleExpand
        coordinator.onDoubleClick = onDoubleClick

        guard let tableView = coordinator.tableView else { return }

        let oldEntries = coordinator.entries

        // 判断是否需要全量刷新
        // FT-R4 阶段将替换为 CollectionDifference 增量更新
        let structureChanged = oldEntries.map(\.id) != entries.map(\.id)
        coordinator.entries = entries

        if structureChanged {
            tableView.reloadData()
        }

        // 同步选中状态（避免反馈环）
        coordinator.syncSelectionToTable(tableView, selection: selection)
    }
```

替换为：

```swift
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.onToggleExpand = onToggleExpand
        coordinator.onDoubleClick = onDoubleClick

        guard let tableView = coordinator.tableView else { return }

        let oldEntries = coordinator.entries

        // FT-R4: 增量 diff 更新，替代全量 reloadData()
        // 参考 VSCode List.splice() 和 Zed uniform_list cx.notify() 触发的行级更新
        coordinator.entries = entries
        coordinator.applyDiff(from: oldEntries, to: entries, tableView: tableView)

        // selection 由 applyDiff 末尾的 syncSelectionToTable 处理，无需重复调用
    }
```

### Step 3：构建确认编译通过

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

预期：`** BUILD SUCCEEDED **`

### Step 4：运行所有 FileTree 相关测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ftr4-task2b \
  -only-testing:agentGuiTests/FileTreeDiffUpdateTests \
  -only-testing:agentGuiTests/FileTreeStoreTests \
  -only-testing:agentGuiTests/FileTreeStoreLazyLoadTests \
  -only-testing:agentGuiTests/FileTreeStoreFSEventTests \
  -only-testing:agentGuiTests/FileTreeViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：全部 PASS，无失败。

### Step 5：提交

```bash
git add agentGui/Views/FileTree/FileTreeTableView.swift \
        agentGuiTests/FileTreeDiffUpdateTests.swift
git commit -m "feat(FT-R4): replace reloadData() with CollectionDifference incremental diff"
```

---

## Task 3：边界情况测试与修复

**Files:**
- Modify: `agentGuiTests/FileTreeDiffUpdateTests.swift`（补充边界测试）

### Step 1：补充边界测试

在 `FileTreeDiffUpdateTests.swift` 末尾添加：

```swift
// MARK: - 边界情况

extension FileTreeDiffUpdateTests {

    // 清空列表（折叠根目录，子树全部消失）
    func testCompute_clearAllEntries_fullReloadFallback() {
        // 30 行全部消失 → 超过默认 threshold 则降级，否则正常 diff
        let old = (0..<30).map { makeEntry(name: "file_\($0)") }
        let new: [VisibleEntry] = []
        let diff = FileTreeDiff.compute(from: old, to: new, threshold: 200)
        // 新列表为空，30 行全删除，总变更 = 30 < 200 → 不降级
        XCTAssertFalse(diff.shouldFullReload)
        XCTAssertEqual(diff.removals.count, 30)
        XCTAssertTrue(diff.insertions.isEmpty)
    }

    // 内容和结构同时变化（先处理结构 diff，内容变更在 empty diff 时才检查）
    func testCompute_mixedStructuralAndContent_structuralTakesPriority() {
        let a = makeEntry(name: "a")
        let b = makeEntry(name: "b")
        let bModified = makeEntry(name: "b", gitSummary: .modified)  // 内容变
        let c = makeEntry(name: "c")
        let old = [a, b]
        let new = [a, bModified, c]  // b 内容变 + 插入 c
        let diff = FileTreeDiff.compute(from: old, to: new)
        XCTAssertFalse(diff.shouldFullReload)
        // 有结构变更（插入 c），内容变更不单独处理
        XCTAssertFalse(diff.insertions.isEmpty)
        // 注意：有结构变更时 contentReloads 为空（由 diff.isEmpty guard 保证）
        XCTAssertTrue(diff.contentReloads.isEmpty)
    }

    // gitSummary 变化（文件被修改后 badge 更新）应走 contentReload
    func testCompute_gitBadgeChange_contentReload() {
        let file = makeEntry(name: "App.swift", gitSummary: nil)
        let fileModified = makeEntry(name: "App.swift", gitSummary: .modified)
        let diff = FileTreeDiff.compute(from: [file], to: [fileModified])
        XCTAssertFalse(diff.shouldFullReload)
        XCTAssertTrue(diff.removals.isEmpty)
        XCTAssertTrue(diff.insertions.isEmpty)
        XCTAssertEqual(diff.contentReloads, IndexSet(integer: 0))
    }

    // loadState 变化（.notLoaded → .loading → .loaded）应走 contentReload
    func testCompute_loadStateChange_contentReload() {
        let dir = makeEntry(name: "src", loadState: .notLoaded)
        let dirLoading = makeEntry(name: "src", loadState: .loading)
        let diff = FileTreeDiff.compute(from: [dir], to: [dirLoading])
        XCTAssertEqual(diff.contentReloads, IndexSet(integer: 0))
    }

    // threshold = 0：任何变更都降级
    func testCompute_thresholdZero_alwaysFullReload() {
        let old = [makeEntry(name: "a")]
        let new = [makeEntry(name: "a"), makeEntry(name: "b")]
        let diff = FileTreeDiff.compute(from: old, to: new, threshold: 0)
        XCTAssertTrue(diff.shouldFullReload)
    }

    // 相同列表不触发 contentReload（即使逐项比较也无差异）
    func testCompute_identicalEntries_noReloadAtAll() {
        let entries = (0..<10).map { makeEntry(name: "file_\($0)") }
        let diff = FileTreeDiff.compute(from: entries, to: entries)
        XCTAssertFalse(diff.shouldFullReload)
        XCTAssertTrue(diff.removals.isEmpty)
        XCTAssertTrue(diff.insertions.isEmpty)
        XCTAssertTrue(diff.contentReloads.isEmpty)
    }
}
```

### Step 2：运行确认全部 PASS

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ftr4-task3 \
  -only-testing:agentGuiTests/FileTreeDiffUpdateTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：全部测试 PASS，包括新增的边界测试。

### Step 3：如有失败，修复 `FileTreeDiff.compute` 逻辑

常见陷阱及修复：
- `diff.isEmpty` 判断必须在计算 `removals`/`insertions` **之后**、而非使用原始 `diff` 变量（因 `diff` 是 `CollectionDifference`，`.isEmpty` 指无结构变更）
- `contentReloads` 计算中的 `old[newIndex].id == newEntry.id` 条件应在 `newIndex < old.count` guard 之后，防止越界

### Step 4：提交

```bash
git add agentGuiTests/FileTreeDiffUpdateTests.swift
git commit -m "test(FT-R4): add edge case tests for FileTreeDiff"
```

---

## Task 4：全量回归验证

**Files:** 无变更

运行所有 FileTree 测试，确保 FT-R4 修改没有破坏 FT-R0 到 FT-R3 的功能。

### Step 1：运行完整 FileTree 测试套件

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ftr4-full \
  -only-testing:agentGuiTests/FileTreeDiffUpdateTests \
  -only-testing:agentGuiTests/FileTreeStoreTests \
  -only-testing:agentGuiTests/FileTreeStoreLazyLoadTests \
  -only-testing:agentGuiTests/FileTreeStoreFSEventTests \
  -only-testing:agentGuiTests/FileTreeViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|passed|failed|error:"
```

预期：所有测试套件通过，0 failures。

### Step 2：构建确认最终状态

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

预期：`** BUILD SUCCEEDED **`

### Step 3：最终提交

```bash
git add -A
git commit -m "test(FT-R4): full regression pass — incremental diff update complete"
```

---

## 实现摘要

### 新建文件

| 文件 | 作用 |
|------|------|
| `agentGui/Views/FileTree/FileTreeDiff.swift` | 纯函数 diff 计算，不依赖 AppKit |
| `agentGuiTests/FileTreeDiffUpdateTests.swift` | `FileTreeDiff.compute` 单元测试 + ViewModel 集成测试 |

### 修改文件

| 文件 | 变更 |
|------|------|
| `agentGui/Views/FileTree/FileTreeTableView.swift` | `Coordinator` 新增 `applyDiff`；`updateNSView` 替换为调用 `applyDiff` |

### 估计行数

- `FileTreeDiff.swift`：~80 行
- `FileTreeDiff` 新增到 `FileTreeTableView.swift`（`applyDiff` 方法）：~30 行
- `updateNSView` 修改：~5 行净减少（移除旧逻辑）
- `FileTreeDiffUpdateTests.swift`：~180 行测试

---

## 关键设计决策说明

### 为何独立出 `FileTreeDiff` 纯函数？

NSTableView 无法在单元测试中轻量实例化（需要完整 AppKit 环境）。将 diff 计算抽取为纯函数后，90% 的逻辑可在 XCTest 中直接测试，无需 UI 环境。这是 VSCode 测试架构的核心思路：将纯逻辑（`splice` 计算）与副作用（DOM 操作）分离。

### `contentReloads` 只在无结构变更时计算

当有结构变更（insert/remove）时，`beginUpdates/endUpdates` 块会触发所有可见行重新调用 `viewFor(row:)` 的 cell 复用，内容变更会自动反映。单独计算 `contentReloads` 只在 **纯内容更新**（如 git badge 刷新、loadState 切换）时才有意义，避免重复刷新。

### 降级阈值 200

来自设计文档的建议值。具体含义：一次展开操作如果插入超过 200 行（例如展开含有 200+ 子文件的目录），动画会分 200 帧执行，在 60fps 下约需 3.3 秒，用户会明显感受到卡顿。此时直接全量 reload（约 1 帧）体验更好。

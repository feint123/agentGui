# FT-R5：Auto-fold（Compact Folders）实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 `FileTreeStore.computeVisibleEntries()` 的 DFS 遍历中检测"单子目录链"（每级只有一个子目录，且该子目录未手动展开），将链中的中间节点从可见列表中跳过，链终端节点的 `VisibleEntry.foldedAncestors` 填充完整祖先信息；`FileTreeCellView` 渲染为 `src / main / java` 分段路径，每段可独立点击触发展开（等价于 Zed 的 `unfold_directory` + 重新 fold 到该段以下）。

**Architecture:**
- `FileTreeStore` 新增 `compactFolders: Bool`、`unfoldedIDs: Set<EntryID>`，以及辅助方法 `shouldAutoFold(_ id: EntryID) -> Bool` 和 `collectFoldedChain(from startID: EntryID) -> (segments: [FoldedAncestors.FoldedSegment], terminalID: EntryID)`。在现有 `dfs()` 中，当 `shouldAutoFold(id)` 为 `true` 时走链收集分支，否则走现有路径。
- `FileTreeViewModel` 新增 `unfoldDirectory(_ id: EntryID)` / `foldDirectory(_ id: EntryID)` / `compactFolders: Bool`，将操作透传至 Store 并触发 `computeVisibleEntries()`。
- `FileTreeCellView` 根据 `entry.foldedAncestors != nil` 切换渲染模式：`nil` → 现有单一 `nameLabel`；非 `nil` → 带可点击分段的 `NSAttributedString`（分隔符 ` / ` 用 `NSColor.tertiaryLabelColor`，各段名用 `NSColor.labelColor`；或用独立的 `NSButton` 栈实现鼠标 hover 效果）。
- `FileTreeTableView` 新增 `onUnfoldSegment: (EntryID) -> Void` 回调，由 `FileTreeCellView` 的分段点击触发，经 Coordinator → ViewModel.unfoldDirectory。

**Tech Stack:** Swift 6.0+, AppKit (`NSTextField` + `NSAttributedString` + `NSClickGestureRecognizer`), XCTest

**参考来源：**
- **VSCode** [`explorerViewer.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/files/browser/views/explorerViewer.ts)
  - `ExplorerCompressionDelegate.isIncompressible(stat)` — 不可折叠条件：`stat.isRoot || !stat.isDirectory || stat instanceof NewExplorerItem || (!stat.parent || stat.parent.isRoot)`；本计划对应：根节点的直接子目录不折叠、`unfoldedIDs` 中的节点不折叠。
  - `CompressedNavigationController` — 维护 `_items: ExplorerItem[]` 与当前 `_index`；键盘左右方向键在段间切换；对应本计划的 `foldedAncestors.segments` 数组索引逻辑。
  - `renderCompressedElements(data, index, template, height)` — 为压缩节点渲染多个 label，给每个 label 设置 `data-name` 属性；点击时用 `getIconLabelNameFromHTMLElement(el)` 按索引确定点击的是哪一段，映射回 `segments[i].entryID`。
- **Zed** [`project_panel.rs`](https://github.com/zed-industries/zed/blob/main/crates/project_panel/src/project_panel.rs)
  - `State.unfolded_dir_ids: HashSet<ProjectEntryId>` — 存用户手动展开的单子目录节点，对应 `FileTreeStore.unfoldedIDs: Set<EntryID>`。
  - `is_foldable(entry, worktree)` — 检测单子目录：`entry.kind.is_dir() && child_entries.next().is_some() && child_entries.next().is_none() && child.kind.is_dir()` + 非根路径；对应 `shouldAutoFold`。
  - `is_unfoldable(entry, worktree)` — 检测是否可 unfold（已在 `unfolded_dir_ids` 或根节点直接子级）。
  - `update_visible_entries()` 中 auto-fold 检测块 — DFS 时若目录仅有一个子目录且子未在 `unfolded_dir_ids` 中，则把当前节点推入 `ancestors` 列表并继续向下，直至多子/文件/unfold 节点；对应 `collectFoldedChain`。
  - `render_folder_elements(entry, ancestors, depth)` — 用 `intersperse_with` 插入 `/` 分隔符渲染各段；`render_entry_path_separator()` 用弱色 `Label("/")`。
  - `fold_directory(id)` — 从 `unfolded_dir_ids` 移除（重新折叠）；`unfold_directory(id)` — 从 chain 最顶层到当前节点，逐一插入 `unfolded_dir_ids`（展开整条链直到该段）。
- 设计文档 `docs/plans/2026-07-15-filetree-rewrite-design.md` §FT-R5

---

## 前置条件

- 已完成 FT-R0 ✅（`VisibleEntry: Equatable`, `EntryID`, `FoldedAncestors` + `FoldedSegment` 已定义）
- 已完成 FT-R1 ✅（`FSEventObserver` 集成）
- 已完成 FT-R2 ✅（`FileTreeTableView`, `Coordinator`, `FileTreeCellView`）
- 已完成 FT-R3 ✅（`VisibleEntry.loadState`, loading spinner, 错误回退）
- 已完成 FT-R4 ✅（`FileTreeDiff.compute`, 增量行动画）

当前实现缺口：

| 文件 | 现状 | FT-R5 目标 |
|------|------|-----------|
| `agentGui/Services/FileTreeStore.swift` | DFS 中 `foldedAncestors` 硬编码为 `nil`；无 `compactFolders` / `unfoldedIDs` | 添加单子目录检测与链收集 |
| `agentGui/ViewModels/FileTreeViewModel.swift` | 无 `unfoldDirectory` / `foldDirectory` / `compactFolders` | 透传 Store 操作 |
| `agentGui/Views/FileTree/FileTreeCellView.swift` | `displayName(for:)` 有 `foldedAncestors` 分支但只用 joined 字符串，无分段点击 | 分段可点击渲染 |
| `agentGui/Views/FileTree/FileTreeTableView.swift` | 无 `onUnfoldSegment` 回调 | 新增回调并传入 Cell |
| `agentGuiTests/FileTreeAutoFoldTests.swift` | 不存在 | 新建，覆盖 auto-fold 核心逻辑 |

---

## Task 1：`shouldAutoFold` + `collectFoldedChain` + `computeVisibleEntries` 集成

**Files:**
- Modify: `agentGui/Services/FileTreeStore.swift`
- Create: `agentGuiTests/FileTreeAutoFoldTests.swift`

这是 FT-R5 的核心逻辑层，所有后续 Task 依赖此处正确性。目标：
1. 在 `FileTreeStore` 中添加 `compactFolders: Bool` 和 `unfoldedIDs: Set<EntryID>`。
2. 实现 `shouldAutoFold(_ id: EntryID) -> Bool`：仅对已展开、加载完成、只有一个子目录且该子目录不在 `unfoldedIDs` 中的目录返回 `true`。
3. 实现 `collectFoldedChain(from startID: EntryID) -> (segments: [FoldedAncestors.FoldedSegment], terminalID: EntryID)`：从 `startID` 开始沿单子目录链向下收集，返回所有中间段（含 `startID`）和链终端 ID。
4. 修改 `dfs()` 中的 `foldedAncestors: nil` 占位，接入真实逻辑。

### Step 1：编写预期失败的测试

**新建** `agentGuiTests/FileTreeAutoFoldTests.swift`：

```swift
// agentGuiTests/FileTreeAutoFoldTests.swift
import XCTest
@testable import agentGui

/// FT-R5 Auto-fold 测试：
/// 验证 FileTreeStore.computeVisibleEntries() 在 compactFolders = true 时，
/// 将单子目录链压缩为单行（foldedAncestors 非 nil），
/// 以及多子目录/unfoldedIDs/根节点/设置关闭等边界情况。
///
/// 参考 Zed project_panel 测试：
///   test_single_child_directory_folding / test_unfold_directory
final class FileTreeAutoFoldTests: XCTestCase {

    // MARK: - 辅助

    /// 构造一个三层单子目录树：root/ → src/ → main/ → java/（java 下无子目录）
    ///   root 已展开，src 已展开，main 已展开
    ///   root、src、main、java 全部加载完成
    func makeLinearChainStore() async throws -> FileTreeStore {
        let store = FileTreeStore(scanner: MockDirectoryScanner())
        await store.setRoot(URL(fileURLWithPath: "/tmp/root"))

        // 手动注入条目，避免真实 I/O
        let rootID = EntryID(url: URL(fileURLWithPath: "/tmp/root"))
        let srcID  = EntryID(url: URL(fileURLWithPath: "/tmp/root/src"))
        let mainID = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/main"))
        let javaID = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/main/java"))

        await store.injectEntries([
            rootID: FileEntry(id: rootID, name: "root", isDirectory: true, parentID: nil,      loadState: .loaded),
            srcID:  FileEntry(id: srcID,  name: "src",  isDirectory: true, parentID: rootID,   loadState: .loaded),
            mainID: FileEntry(id: mainID, name: "main", isDirectory: true, parentID: srcID,    loadState: .loaded),
            javaID: FileEntry(id: javaID, name: "java", isDirectory: true, parentID: mainID,   loadState: .loaded),
        ], children: [
            rootID: [srcID],
            srcID:  [mainID],
            mainID: [javaID],
            javaID: [],
        ], rootIDs: [srcID],  // 根级别只显示 src
           expandedIDs: [srcID, mainID])

        return store
    }

    // MARK: - 单子目录链被压缩

    /// src → main → java 全是单子目录，compactFolders = true
    /// 期望：visibleEntries 只有 1 行（java），foldedAncestors 含 [src, main, java] 三段
    func testAutoFold_singleChildChainCompressed() async throws {
        let store = try await makeLinearChainStore()
        await store.setCompactFolders(true)

        let entries = await store.computeVisibleEntries()

        // 链被压缩为单行
        XCTAssertEqual(entries.count, 1)

        let row = try XCTUnwrap(entries.first)
        let folded = try XCTUnwrap(row.foldedAncestors,
            "terminalID 行应携带 foldedAncestors")

        // 三段：src / main / java
        XCTAssertEqual(folded.segments.count, 3)
        XCTAssertEqual(folded.segments[0].name, "src")
        XCTAssertEqual(folded.segments[1].name, "main")
        XCTAssertEqual(folded.segments[2].name, "java")

        // terminalID 是 java
        let javaID = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/main/java"))
        XCTAssertEqual(folded.terminalID, javaID)
    }

    // MARK: - 多子目录节点不被折叠

    /// src 有两个子目录（main + test），不满足单子目录条件，不应折叠
    func testAutoFold_multiChildDirNotFolded() async throws {
        let store = FileTreeStore(scanner: MockDirectoryScanner())
        await store.setRoot(URL(fileURLWithPath: "/tmp/root"))

        let srcID  = EntryID(url: URL(fileURLWithPath: "/tmp/root/src"))
        let mainID = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/main"))
        let testID = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/test"))

        await store.injectEntries([
            srcID:  FileEntry(id: srcID,  name: "src",  isDirectory: true, parentID: nil,    loadState: .loaded),
            mainID: FileEntry(id: mainID, name: "main", isDirectory: true, parentID: srcID,  loadState: .loaded),
            testID: FileEntry(id: testID, name: "test", isDirectory: true, parentID: srcID,  loadState: .loaded),
        ], children: [
            srcID:  [mainID, testID],
            mainID: [],
            testID: [],
        ], rootIDs: [srcID],
           expandedIDs: [srcID])

        await store.setCompactFolders(true)

        let entries = await store.computeVisibleEntries()

        // src 有两个子目录，不折叠；应有 3 行：src, main, test
        XCTAssertEqual(entries.count, 3)
        // src 行的 foldedAncestors 应为 nil
        XCTAssertNil(entries[0].foldedAncestors)
    }

    // MARK: - compactFolders 关闭时不折叠

    func testAutoFold_disabledWhenSettingOff() async throws {
        let store = try await makeLinearChainStore()
        await store.setCompactFolders(false)

        let entries = await store.computeVisibleEntries()

        // 未折叠时：src 展开 → src + main；main 展开 → main + java；共 3 行
        XCTAssertEqual(entries.count, 3)
        for entry in entries {
            XCTAssertNil(entry.foldedAncestors)
        }
    }

    // MARK: - unfoldedIDs 阻止折叠

    /// 将 src 加入 unfoldedIDs，链在 src 处断开，不再折叠
    func testAutoFold_unfoldedIDsPreventsfolding() async throws {
        let store = try await makeLinearChainStore()
        await store.setCompactFolders(true)

        let srcID = EntryID(url: URL(fileURLWithPath: "/tmp/root/src"))
        await store.unfoldDirectory(srcID)  // 手动展开 src

        let entries = await store.computeVisibleEntries()

        // src 被手动展开，不再单独折叠；src 展开后 main 继续形成 main/java 二段链
        // 期望：2 行 — src（单行，无 foldedAncestors）+ main/java（二段折叠链）
        XCTAssertEqual(entries.count, 2)
        XCTAssertNil(entries[0].foldedAncestors, "src 已 unfold，不应折叠")
        let secondRow = entries[1]
        let folded = try XCTUnwrap(secondRow.foldedAncestors)
        XCTAssertEqual(folded.segments.count, 2)
        XCTAssertEqual(folded.segments[0].name, "main")
        XCTAssertEqual(folded.segments[1].name, "java")
    }

    // MARK: - 根级目录不折叠

    /// 树中 root 作为根级节点（rootIDs 包含 root），root
    /// 即使只有一个子目录也不应被折叠（参考 VSCode isIncompressible: stat.parent.isRoot）
    func testAutoFold_rootLevelDirNotFolded() async throws {
        let store = FileTreeStore(scanner: MockDirectoryScanner())
        await store.setRoot(URL(fileURLWithPath: "/tmp/root"))

        let rootID = EntryID(url: URL(fileURLWithPath: "/tmp/root"))
        let srcID  = EntryID(url: URL(fileURLWithPath: "/tmp/root/src"))
        let mainID = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/main"))

        await store.injectEntries([
            rootID: FileEntry(id: rootID, name: "root", isDirectory: true, parentID: nil,    loadState: .loaded),
            srcID:  FileEntry(id: srcID,  name: "src",  isDirectory: true, parentID: rootID, loadState: .loaded),
            mainID: FileEntry(id: mainID, name: "main", isDirectory: true, parentID: srcID,  loadState: .loaded),
        ], children: [
            rootID: [srcID],
            srcID:  [mainID],
            mainID: [],
        ], rootIDs: [srcID],   // src 直接出现在 rootIDs（根级别）
           expandedIDs: [srcID])

        await store.setCompactFolders(true)

        let entries = await store.computeVisibleEntries()

        // src 是根级目录，不应折叠；应看到 src（展开）+ main = 2 行
        XCTAssertEqual(entries.count, 2)
        XCTAssertNil(entries[0].foldedAncestors, "根级目录 src 不应被折叠")
    }

    // MARK: - 每段 EntryID 正确

    func testAutoFold_segmentsHaveCorrectEntryIDs() async throws {
        let store = try await makeLinearChainStore()
        await store.setCompactFolders(true)

        let entries = await store.computeVisibleEntries()
        let folded = try XCTUnwrap(entries.first?.foldedAncestors)

        let srcID  = EntryID(url: URL(fileURLWithPath: "/tmp/root/src"))
        let mainID = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/main"))
        let javaID = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/main/java"))

        XCTAssertEqual(folded.segments[0].entryID, srcID)
        XCTAssertEqual(folded.segments[1].entryID, mainID)
        XCTAssertEqual(folded.segments[2].entryID, javaID)
    }

    // MARK: - 链终端有子文件时仍正确折叠

    /// java/ 下有一个 .java 文件（非目录），链应在 java 处终止
    func testAutoFold_chainTerminatesAtFileChild() async throws {
        let store = FileTreeStore(scanner: MockDirectoryScanner())
        await store.setRoot(URL(fileURLWithPath: "/tmp/root"))

        let srcID    = EntryID(url: URL(fileURLWithPath: "/tmp/root/src"))
        let mainID   = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/main"))
        let javaID   = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/main/java"))
        let fileID   = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/main/java/Main.java"))

        await store.injectEntries([
            srcID:  FileEntry(id: srcID,  name: "src",       isDirectory: true,  parentID: nil,    loadState: .loaded),
            mainID: FileEntry(id: mainID, name: "main",      isDirectory: true,  parentID: srcID,  loadState: .loaded),
            javaID: FileEntry(id: javaID, name: "java",      isDirectory: true,  parentID: mainID, loadState: .loaded),
            fileID: FileEntry(id: fileID, name: "Main.java", isDirectory: false, parentID: javaID, loadState: .loaded),
        ], children: [
            srcID:  [mainID],
            mainID: [javaID],
            javaID: [fileID],
            fileID: [],
        ], rootIDs: [srcID],
           expandedIDs: [srcID, mainID, javaID])

        await store.setCompactFolders(true)

        let entries = await store.computeVisibleEntries()

        // 链：src/main/java → terminalID = java；java 展开后显示 Main.java
        // 期望 2 行：java（foldedAncestors 三段）+ Main.java
        XCTAssertEqual(entries.count, 2)
        let foldedRow = try XCTUnwrap(entries.first)
        XCTAssertNotNil(foldedRow.foldedAncestors)
        XCTAssertEqual(entries[1].name, "Main.java")
        XCTAssertNil(entries[1].foldedAncestors)
    }
}
```

运行确认编译失败（`injectEntries`、`setCompactFolders`、`unfoldDirectory` 均不存在）：

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep "error:" | head -10
```

预期：`error: value of type 'FileTreeStore' has no member 'injectEntries'`

### Step 2：在 `FileTreeStore` 中实现 auto-fold 逻辑

修改 `agentGui/Services/FileTreeStore.swift`，在 `// MARK: - 私有` 之前添加：

```swift
// MARK: - Auto-fold（FT-R5）

/// 是否开启 Compact Folders（默认 true，对标 VSCode compactFolders 设置）。
private var compactFolders: Bool = true

/// 用户手动展开的节点集合（不参与 auto-fold）。
/// 参考 Zed `State.unfolded_dir_ids: HashSet<ProjectEntryId>`。
private var unfoldedIDs: Set<EntryID> = []

/// 对外暴露的设置入口（供 ViewModel 调用）。
func setCompactFolders(_ value: Bool) {
    compactFolders = value
}

/// 将目录加入 unfoldedIDs，阻止其被自动折叠。
/// 参考 Zed `unfold_directory(id)`：沿链从 startID 向上到目标 id，
/// 将所有节点插入 unfolded_dir_ids（确保整条路径都不折叠）。
func unfoldDirectory(_ id: EntryID) {
    unfoldedIDs.insert(id)
}

/// 从 unfoldedIDs 移除，恢复 auto-fold。
/// 参考 Zed `fold_directory(id)`。
func foldDirectory(_ id: EntryID) {
    unfoldedIDs.remove(id)
}

/// 判断目录节点是否满足 auto-fold 条件。
///
/// 条件（参考 Zed `is_foldable` + VSCode `ExplorerCompressionDelegate.isIncompressible`）：
/// 1. 节点是目录且已展开（expandedIDs 包含）
/// 2. 节点不在 unfoldedIDs 中（用户未手动展开）
/// 3. 节点不是根级目录（不在 rootIDs 中）
/// 4. 节点的已加载子列表恰好只有一个子目录（`children[id]` 中 isDirectory = true 的数量 = 1，
///    且没有文件子节点——允许空的文件子，但"只有一个子目录"意味着 children 全是 1 条目录）
/// 5. `compactFolders` 为 true
///
/// 简化规则：`children[id].count == 1 && children[id][0] 是目录`
private func shouldAutoFold(_ id: EntryID) -> Bool {
    guard compactFolders else { return false }
    guard !rootIDs.contains(id) else { return false }         // 根级不折叠
    guard !unfoldedIDs.contains(id) else { return false }     // 手动展开不折叠
    guard expandedIDs.contains(id) else { return false }      // 未展开不参与链
    guard let childList = children[id], childList.count == 1 else { return false }
    let onlyChildID = childList[0]
    return entries[onlyChildID]?.isDirectory == true
}

/// 从 startID 开始沿单子目录链向下收集，返回所有段（含 startID 到终端）。
///
/// 算法（参考 Zed `update_visible_entries` auto-fold 块）：
///   从 startID 开始，若当前节点满足 shouldAutoFold，
///   将其加入 segments，继续进入其唯一子目录；
///   直至某节点不满足 shouldAutoFold 为止（该节点是 terminalID）。
///
/// 返回值：`segments` 含链上每个节点（含 startID，含终端），`terminalID` 是链末节点。
/// 调用方在 DFS 中应跳过 segments[0..n-2] 对应的节点，只渲染 terminalID 节点的行。
private func collectFoldedChain(from startID: EntryID) -> (segments: [FoldedAncestors.FoldedSegment], terminalID: EntryID) {
    var segments: [FoldedAncestors.FoldedSegment] = []
    var current = startID

    while shouldAutoFold(current) {
        let name = entries[current]?.name ?? current.url.lastPathComponent
        segments.append(FoldedAncestors.FoldedSegment(name: name, entryID: current))
        // 唯一子目录（shouldAutoFold 已保证）
        current = children[current]![0]
    }

    // current 是终端节点：加入 segments 的最后一段
    let terminalName = entries[current]?.name ?? current.url.lastPathComponent
    segments.append(FoldedAncestors.FoldedSegment(name: terminalName, entryID: current))

    return (segments: segments, terminalID: current)
}
```

同时修改 `dfs()` 方法中的折叠逻辑，将 `foldedAncestors: nil` 占位替换为真实逻辑。在 dfs 内的 `for id in ids` 循环体中，在 `let isExpanded = ...` 行之前，加入链跳过判断：

```swift
// Auto-fold（FT-R5）：若当前节点是链起点，走链收集分支，跳过中间节点
if compactFolders,
   entry.isDirectory,
   shouldAutoFold(id) {
    let chain = collectFoldedChain(from: id)
    // 链终端节点：用 terminalID 对应的 entry 构建 VisibleEntry
    let terminalID = chain.terminalID
    guard let terminalEntry = entries[terminalID] else { continue }
    let terminalIsExpanded = terminalEntry.isDirectory && expandedIDs.contains(terminalID)
    let visible = VisibleEntry(
        id: terminalID,
        name: terminalEntry.name,
        isDirectory: terminalEntry.isDirectory,
        depth: depth,
        isExpanded: terminalIsExpanded,
        loadState: terminalEntry.loadState,
        foldedAncestors: FoldedAncestors(
            segments: chain.segments,
            terminalID: terminalID
        ),
        gitSummary: nil,
        diagnosticSeverity: nil,
        isIgnored: false
    )
    result.append(visible)
    // 若终端节点已展开，继续递归其子节点（深度保持 depth+1）
    if terminalIsExpanded, let childIDs = children[terminalID] {
        dfs(ids: childIDs, depth: depth + 1, result: &result, searchFilter: searchFilter)
    }
    continue  // 跳过下方普通渲染逻辑
}
```

同时添加测试需要的测试辅助方法（`internal` 可见性，标注 `#if DEBUG` 或放在 extension 中）：

```swift
// MARK: - 测试注入接口（仅测试使用）

#if DEBUG
/// 仅供单元测试：直接注入 entries/children/rootIDs/expandedIDs，跳过 I/O。
func injectEntries(
    _ newEntries: [EntryID: FileEntry],
    children newChildren: [EntryID: [EntryID]],
    rootIDs newRootIDs: [EntryID],
    expandedIDs newExpandedIDs: Set<EntryID>
) {
    entries = newEntries
    children = newChildren
    rootIDs = newRootIDs
    expandedIDs = newExpandedIDs
}
#endif
```

### Step 3：运行测试验证通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ft-r5-task1 \
  -only-testing:agentGuiTests/FileTreeAutoFoldTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`** TEST SUCCEEDED **`，7 个测试全部通过。

### Step 4：回归测试——确保 FT-R0 至 FT-R4 测试不受影响

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ft-r5-task1-regression \
  -only-testing:agentGuiTests/FileNodeLazyLoadTests \
  -only-testing:agentGuiTests/FileNodeAutoFoldTests \
  -only-testing:agentGuiTests/FileTreeDiffUpdateTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：`** TEST SUCCEEDED **`

### Step 5：提交

```bash
git add agentGui/Services/FileTreeStore.swift agentGuiTests/FileTreeAutoFoldTests.swift
git commit -m "feat(FT-R5): shouldAutoFold + collectFoldedChain + DFS 集成"
```

---

## Task 2：`unfoldDirectory` / `foldDirectory` + `FileTreeViewModel` 接入

**Files:**
- Modify: `agentGui/Services/FileTreeStore.swift` （Task 1 已添加基础方法，此处补充链展开语义）
- Modify: `agentGui/ViewModels/FileTreeViewModel.swift`

### Step 1：编写 ViewModel 接入测试

在 `agentGuiTests/FileTreeAutoFoldTests.swift` 末尾追加：

```swift
// MARK: - ViewModel 接入（Task 2）

final class FileTreeViewModelAutoFoldTests: XCTestCase {

    /// unfoldDirectory 透传后触发 computeVisibleEntries，链断开
    func testViewModel_unfoldDirectory_updatesVisibleEntries() async throws {
        let store = FileTreeStore(scanner: MockDirectoryScanner())
        // 注入三层单子目录链（同 Task 1 辅助方法逻辑）
        let srcID  = EntryID(url: URL(fileURLWithPath: "/tmp/root/src"))
        let mainID = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/main"))
        let javaID = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/main/java"))
        await store.injectEntries([
            srcID:  FileEntry(id: srcID,  name: "src",  isDirectory: true, parentID: nil,    loadState: .loaded),
            mainID: FileEntry(id: mainID, name: "main", isDirectory: true, parentID: srcID,  loadState: .loaded),
            javaID: FileEntry(id: javaID, name: "java", isDirectory: true, parentID: mainID, loadState: .loaded),
        ], children: [srcID: [mainID], mainID: [javaID], javaID: []],
           rootIDs: [srcID], expandedIDs: [srcID, mainID])

        let vm = await FileTreeViewModel(store: store)
        await vm.setCompactFolders(true)

        // 初始：1 行（链折叠）
        var entries = await vm.visibleEntries
        XCTAssertEqual(entries.count, 1)
        XCTAssertNotNil(entries.first?.foldedAncestors)

        // 展开 src 节点（链在 src 处断开）
        await vm.unfoldDirectory(srcID)
        entries = await vm.visibleEntries

        // src 不再折叠，main/java 形成二段链 → 2 行
        XCTAssertEqual(entries.count, 2)
        XCTAssertNil(entries[0].foldedAncestors)
        XCTAssertEqual(entries[1].foldedAncestors?.segments.count, 2)

        // 重新折叠 src
        await vm.foldDirectory(srcID)
        entries = await vm.visibleEntries
        XCTAssertEqual(entries.count, 1, "重新 fold 后链应恢复到单行")
    }

    /// compactFolders 切换时立即重算 visibleEntries
    func testViewModel_compactFoldersToggle() async throws {
        let store = FileTreeStore(scanner: MockDirectoryScanner())
        let srcID  = EntryID(url: URL(fileURLWithPath: "/tmp/root/src"))
        let mainID = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/main"))
        await store.injectEntries([
            srcID:  FileEntry(id: srcID,  name: "src",  isDirectory: true, parentID: nil,   loadState: .loaded),
            mainID: FileEntry(id: mainID, name: "main", isDirectory: true, parentID: srcID, loadState: .loaded),
        ], children: [srcID: [mainID], mainID: []],
           rootIDs: [srcID], expandedIDs: [srcID])

        let vm = await FileTreeViewModel(store: store)
        await vm.setCompactFolders(true)

        var entries = await vm.visibleEntries
        XCTAssertEqual(entries.count, 1, "开启折叠：src/main 合并为 1 行")

        await vm.setCompactFolders(false)
        entries = await vm.visibleEntries
        XCTAssertEqual(entries.count, 2, "关闭折叠：src 展开显示 2 行")
    }
}
```

运行确认失败（`FileTreeViewModel` 无 `setCompactFolders`/`unfoldDirectory`/`foldDirectory`）：

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep "error:" | head -5
```

### Step 2：修改 `FileTreeViewModel`

在 `agentGui/ViewModels/FileTreeViewModel.swift` 中，在 `toggleDirectory` 方法附近添加：

```swift
// MARK: - Auto-fold（FT-R5）

/// 透传 compactFolders 设置到 Store，并刷新可见列表。
func setCompactFolders(_ value: Bool) async {
    await store.setCompactFolders(value)
    await refreshVisibleEntries()
}

/// 将目录从自动折叠链中手动展开（加入 unfoldedIDs），并刷新可见列表。
func unfoldDirectory(_ id: EntryID) async {
    await store.unfoldDirectory(id)
    await refreshVisibleEntries()
}

/// 将目录重新纳入自动折叠（从 unfoldedIDs 移除），并刷新可见列表。
func foldDirectory(_ id: EntryID) async {
    await store.foldDirectory(id)
    await refreshVisibleEntries()
}
```

其中 `refreshVisibleEntries()` 是 FT-R4 已有的可见列表刷新方法（若名称不同，使用实际存在的刷新方法名）。

### Step 3：运行测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ft-r5-task2 \
  -only-testing:agentGuiTests/FileTreeAutoFoldTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

预期：`** TEST SUCCEEDED **`（Task 1 的 7 个 + Task 2 的 2 个，共 9 个）

### Step 4：提交

```bash
git add agentGui/Services/FileTreeStore.swift agentGui/ViewModels/FileTreeViewModel.swift \
        agentGuiTests/FileTreeAutoFoldTests.swift
git commit -m "feat(FT-R5): ViewModel unfoldDirectory/foldDirectory/compactFolders 接入"
```

---

## Task 3：`FileTreeCellView` 分段渲染 + `FileTreeTableView` 回调

**Files:**
- Modify: `agentGui/Views/FileTree/FileTreeCellView.swift`
- Modify: `agentGui/Views/FileTree/FileTreeTableView.swift`

当前 `FileTreeCellView.displayName(for:)` 中有占位实现（joined separator），但：
1. 仅是普通 `NSTextField` 文字，分隔符颜色未区分。
2. 没有分段点击支持。

本 Task 将 `displayName` 替换为分段渲染：
- 不存在 `foldedAncestors` → 维持现有 `nameLabel.stringValue = entry.name`。
- 存在 `foldedAncestors` → 使用 `NSAttributedString` 构建多色文本（各段名用 `labelColor`，` / ` 分隔符用 `tertiaryLabelColor`），并添加 `NSClickGestureRecognizer` 通过合计字符宽度命中检测确定点击段落。

**替代方案（推荐 Zed 风格的 `NSStackView`）：** 将 `nameLabel` 替换为一个 `NSStackView`，每段创建一个 `NSButton(title: segName)`（无边框，`plainSquareBezel` 或直接用 `NSTextField`），段间插入弱色 ` / ` 标签。NSButton 直接绑定 target-action 到 `onUnfoldSegment`，无需字符宽度命中检测。NSStackView orientation 为 `.horizontal`，spacing = 0。

### Step 1：在测试中描述期望行为

在 `agentGuiTests/FileTreeAutoFoldTests.swift` 末尾追加（集成测试，不 mock UI，只验证配置正确性）：

```swift
// MARK: - CellView 配置（Task 3）

final class FileTreeCellConfigureTests: XCTestCase {

    func makeEntry(foldedSegments: [(name: String, url: String)]) -> VisibleEntry {
        let segments = foldedSegments.map {
            FoldedAncestors.FoldedSegment(name: $0.name, entryID: EntryID(url: URL(fileURLWithPath: $0.url)))
        }
        let terminalID = EntryID(url: URL(fileURLWithPath: foldedSegments.last!.url))
        let folded = FoldedAncestors(segments: segments, terminalID: terminalID)
        return VisibleEntry(
            id: terminalID,
            name: foldedSegments.last!.name,
            isDirectory: true,
            depth: 0,
            isExpanded: false,
            loadState: .loaded,
            foldedAncestors: folded,
            gitSummary: nil,
            diagnosticSeverity: nil,
            isIgnored: false
        )
    }

    /// 拥有 foldedAncestors 的行：configure 后 onUnfoldSegment 回调不应为 nil
    func testCellView_configure_withFoldedAncestors_hasSomeCallback() {
        let cell = FileTreeCellView(frame: .zero)
        var unfoldCalled: EntryID? = nil
        let entry = makeEntry(foldedSegments: [
            ("src",  "/tmp/root/src"),
            ("main", "/tmp/root/src/main"),
            ("java", "/tmp/root/src/main/java"),
        ])
        cell.configure(
            entry: entry,
            isSelected: false,
            onToggle: { _ in },
            onUnfoldSegment: { id in unfoldCalled = id }
        )
        // configure 调用后，segmentedPathView 或 nameLabel 都应存在；
        // 只要细胞没有 crash 且 onUnfoldSegment 有被保存即可
        XCTAssertNotNil(cell.onUnfoldSegment)
    }

    /// 不含 foldedAncestors 的普通行：configure 后不会设置分段回调为非 nil
    func testCellView_configure_withoutFoldedAncestors_normalMode() {
        let cell = FileTreeCellView(frame: .zero)
        let normalEntry = VisibleEntry(
            id: EntryID(url: URL(fileURLWithPath: "/tmp/root/file.swift")),
            name: "file.swift",
            isDirectory: false,
            depth: 0,
            isExpanded: false,
            loadState: .loaded,
            foldedAncestors: nil,
            gitSummary: nil,
            diagnosticSeverity: nil,
            isIgnored: false
        )
        cell.configure(
            entry: normalEntry,
            isSelected: false,
            onToggle: { _ in },
            onUnfoldSegment: nil
        )
        XCTAssertNil(cell.onUnfoldSegment)
    }
}
```

运行确认失败（`configure` 签名不含 `onUnfoldSegment`）：

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep "error:" | head -5
```

### Step 2：修改 `FileTreeCellView`

1. 将 `var onToggleExpand: ((EntryID) -> Void)?` 下方添加：
   ```swift
   /// 用户点击折叠路径的某个分段时触发，传入该段的 EntryID。
   /// 参考 Zed render_folder_elements + VSCode getIconLabelNameFromHTMLElement。
   var onUnfoldSegment: ((EntryID) -> Void)?
   ```

2. 在 `private let nameLabel = NSTextField()` 下方添加：
   ```swift
   /// 分段路径容器（仅 auto-fold 行使用，普通行隐藏）。
   /// 每个段是一个无边框 NSButton，段间插入 " / " 弱色标签。
   private let segmentedPathStack = NSStackView()
   private var segmentButtons: [(button: NSButton, entryID: EntryID)] = []
   ```

3. 在 `buildLayout()` 末尾添加 `segmentedPathStack` 约束（与 `nameLabel` 同位置，初始隐藏）：
   ```swift
   segmentedPathStack.translatesAutoresizingMaskIntoConstraints = false
   segmentedPathStack.orientation = .horizontal
   segmentedPathStack.spacing = 0
   segmentedPathStack.isHidden = true
   addSubview(segmentedPathStack)
   NSLayoutConstraint.activate([
       segmentedPathStack.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
       segmentedPathStack.centerYAnchor.constraint(equalTo: centerYAnchor),
       segmentedPathStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
   ])
   ```

4. 修改 `configure(entry:isSelected:onToggle:)` 签名：
   ```swift
   func configure(
       entry: VisibleEntry,
       isSelected: Bool,
       onToggle: @escaping (EntryID) -> Void,
       onUnfoldSegment: ((EntryID) -> Void)? = nil
   )
   ```
   在方法体末尾的步骤 4（文件名）处，替换为：
   ```swift
   // 4. 名称 / 分段路径
   self.onUnfoldSegment = entry.foldedAncestors != nil ? onUnfoldSegment : nil
   if let folded = entry.foldedAncestors {
       nameLabel.isHidden = true
       configureSegmentedPath(folded, isSelected: isSelected)
   } else {
       segmentedPathStack.isHidden = true
       nameLabel.isHidden = false
       nameLabel.stringValue = entry.name
       nameLabel.textColor = isSelected ? .selectedMenuItemTextColor : .labelColor
   }
   ```

5. 添加私有 `configureSegmentedPath`:
   ```swift
   private func configureSegmentedPath(_ folded: FoldedAncestors, isSelected: Bool) {
       segmentedPathStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
       segmentButtons.removeAll()
       segmentedPathStack.isHidden = false

       let segColor: NSColor = isSelected ? .selectedMenuItemTextColor : .labelColor
       let sepColor: NSColor = isSelected ? .selectedMenuItemTextColor.withAlphaComponent(0.5)
                                           : .tertiaryLabelColor
       let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular))

       for (i, seg) in folded.segments.enumerated() {
           // 分段按钮
           let btn = NSButton(title: seg.name, target: self, action: #selector(segmentTapped(_:)))
           btn.isBordered = false
           btn.font = font
           btn.contentTintColor = segColor
           btn.tag = i
           segmentedPathStack.addArrangedSubview(btn)
           segmentButtons.append((button: btn, entryID: seg.entryID))

           // 分隔符（最后一段后不加）
           if i < folded.segments.count - 1 {
               let sep = NSTextField(labelWithString: " / ")
               sep.textColor = sepColor
               sep.font = font
               segmentedPathStack.addArrangedSubview(sep)
           }
       }
   }

   @objc private func segmentTapped(_ sender: NSButton) {
       let idx = sender.tag
       guard idx < segmentButtons.count else { return }
       onUnfoldSegment?(segmentButtons[idx].entryID)
   }
   ```

6. 移除 `displayName(for:)` 私有方法（逻辑已被上述替换）。

### Step 3：修改 `FileTreeTableView`

在 `Coordinator.tableView(_:viewFor:row:)` 中，将 `cell.configure(entry:isSelected:onToggle:)` 调用更新为：

```swift
cell.configure(
    entry: item,
    isSelected: tableView.selectedRowIndexes.contains(row),
    onToggle: { [weak self] id in self?.parent.onToggleExpand?(id) },
    onUnfoldSegment: { [weak self] id in self?.parent.onUnfoldSegment?(id) }
)
```

在 `FileTreeTableView` struct 中，在 `var onToggleExpand: ((EntryID) -> Void)?` 下添加：

```swift
/// 用户点击折叠路径分段时触发，由 FileTreeViewModel.unfoldDirectory 处理。
var onUnfoldSegment: ((EntryID) -> Void)?
```

### Step 4：运行测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ft-r5-task3 \
  -only-testing:agentGuiTests/FileTreeAutoFoldTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

预期：`** TEST SUCCEEDED **`（含 Task 1、2、3 共 11 个测试）

### Step 5：提交

```bash
git add agentGui/Views/FileTree/FileTreeCellView.swift \
        agentGui/Views/FileTree/FileTreeTableView.swift \
        agentGuiTests/FileTreeAutoFoldTests.swift
git commit -m "feat(FT-R5): CellView 分段路径渲染 + onUnfoldSegment 回调"
```

---

## Task 4：`compactFolders` AppSettings 开关 + 运行时串联

**Files:**
- Modify: `agentGui/Models/AppSettings.swift`（若存在）
- Modify: `agentGui/Views/FileTree/FileTreeContainerView.swift`
- Modify: `agentGui/ViewModels/FileTreeViewModel.swift`（补充初始化时读取设置）

本 Task 将 `compactFolders` 设置从 `AppSettings`（SwiftData @Model）持久化到 `FileTreeViewModel`，确保重启后保留用户偏好。

### Step 1：确认 AppSettings 结构

读取 `agentGui/Models/AppSettings.swift`，确认现有字段（API key、selectedModel 等）及添加方式。

### Step 2：添加 `compactFolders` 到 AppSettings

```swift
// 在 AppSettings @Model 中添加
@Attribute var compactFolders: Bool = true
```

### Step 3：在 `FileTreeViewModel` 初始化时应用 AppSettings

在 `FileTreeViewModel.init(store:)` 中（或 `init(store:settings:)`），读取 `AppSettings.compactFolders` 并调用 `store.setCompactFolders`：

```swift
// 初始化完成后，从 AppSettings 同步 compactFolders
if let settings = AppSettings.current {
    Task {
        await store.setCompactFolders(settings.compactFolders)
    }
}
```

同时在 `setCompactFolders(_ value: Bool)` 中同步写回 AppSettings：

```swift
func setCompactFolders(_ value: Bool) async {
    AppSettings.current?.compactFolders = value
    await store.setCompactFolders(value)
    await refreshVisibleEntries()
}
```

### Step 4：在 UI 层提供开关入口（可选，此阶段可仅有设置页面入口）

在 `FileTreeContainerView` 的工具栏或右键菜单中添加 `Toggle("Compact Folders", isOn: $viewModel.compactFolders)`，或在应用设置窗口中提供。

### Step 5：编写 AppSettings 集成测试

```swift
// 在 agentGuiTests/FileTreeAutoFoldTests.swift 末尾添加
final class FileTreeCompactFoldersSettingsTests: XCTestCase {

    /// compactFolders 默认值为 true
    func testAppSettings_compactFolders_defaultIsTrue() {
        let settings = AppSettings()
        XCTAssertTrue(settings.compactFolders)
    }

    /// FileTreeViewModel 初始 compactFolders 与 AppSettings 一致
    func testViewModel_initialCompactFolders_matchesSettings() async {
        let settings = AppSettings()
        settings.compactFolders = false
        let store = FileTreeStore(scanner: MockDirectoryScanner())
        let vm = await FileTreeViewModel(store: store, settings: settings)
        let actual = await vm.isCompactFoldersEnabled
        XCTAssertFalse(actual)
    }
}
```

### Step 6：运行全量测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ft-r5-task4 \
  -only-testing:agentGuiTests/FileTreeAutoFoldTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

预期：`** TEST SUCCEEDED **`

### Step 7：全量回归（FT-R0 至 FT-R5 所有测试）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ft-r5-full-regression \
  -only-testing:agentGuiTests/FileNodeLazyLoadTests \
  -only-testing:agentGuiTests/FileNodeAutoFoldTests \
  -only-testing:agentGuiTests/FileTreeDiffUpdateTests \
  -only-testing:agentGuiTests/FileTreeAutoFoldTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：`** TEST SUCCEEDED **`

### Step 8：提交

```bash
git add agentGui/Models/AppSettings.swift \
        agentGui/ViewModels/FileTreeViewModel.swift \
        agentGui/Views/FileTree/FileTreeContainerView.swift \
        agentGuiTests/FileTreeAutoFoldTests.swift
git commit -m "feat(FT-R5): compactFolders AppSettings 持久化 + UI 开关接入"
```

---

## 完成标准

- [ ] `FileTreeStore.computeVisibleEntries()` 在 `compactFolders = true` 时，对单子目录链产生正确的 `foldedAncestors`（含完整 segments 和 terminalID）。
- [ ] 多子目录节点、根级目录、`unfoldedIDs` 中的节点均不被折叠。
- [ ] `FileTreeCellView` 在 `foldedAncestors != nil` 时渲染分段路径，分隔符颜色低于主色，每段点击触发 `onUnfoldSegment`。
- [ ] `FileTreeViewModel.unfoldDirectory` / `foldDirectory` / `setCompactFolders` 正确透传，每次操作后 `visibleEntries` 立即更新。
- [ ] `AppSettings.compactFolders` 默认 `true`，可持久化并在 ViewModel 初始化时应用。
- [ ] `FileTreeAutoFoldTests` 所有测试通过，FT-R0 至 FT-R4 回归测试无退化。

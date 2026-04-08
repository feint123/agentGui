# FT-R9：拖放（Drag & Drop）实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在新 `FileTreeTableView`（`NSTableView`）上实现完整的拖放功能，支持：内部文件/文件夹拖拽移动（Move）、Option 拖动复制（Copy）、拖拽到折叠目录上悬停 500ms 自动展开、Auto-fold 折叠段作为独立拖放目标、面板边缘自动滚动（16ms 周期）、外部文件拖入（Copy 到目标目录），以及拖入到自身目录或子目录的禁止验证。

**Architecture:**
- `FileTreeDropValidator` — 纯函数/值类型，封装所有验证逻辑（目标必须是目录、不能拖入自身后代、去重嵌套源、同父目录检测），替代旧 `WorkspaceTreeDropCoordinator`。
- `FileTreeDropPlan` — 拖放决策结果值类型，携带 `draggedIDs: [EntryID]`、`destinationID: EntryID`、`isMove: Bool`。
- `FileTreeDragState` — 可观察的拖动上下文值，存于 `FileTreeTableView.Coordinator`（非 Actor），追踪 `hoveredEntryID`、`hoverExpandTask`、`edgeScrollTask`。
- **NSTableView 拖放代理**（Coordinator 中实现）：`pasteboardWriterForRow` 写内部 pasteboard、`validateDrop` 调验证器并重定向目标行到 `.on`、`acceptDrop` 触发 ViewModel 操作。外部文件注册 `NSPasteboard.PasteboardType.fileURL` 类型。
- **ViewModel 操作层**（`FileTreeViewModel`）：`moveEntries(_:to:)`、`copyEntries(_:to:)` — 均在后台调用 `WorkspaceFileTreeOperations`，完成后刷新受影响目录。
- 旧代码 `WorkspaceTreeDropCoordinator.swift` 在 Task 5 删除。

**Tech Stack:** Swift 6.0+, AppKit（`NSTableView NSDraggingInfo`、`NSPasteboardWriting`、`NSFilePromiseProvider`），XCTest，`DispatchWorkItem`（hover 500ms timer & edge-scroll 16ms timer）

**参考来源：**

- **Zed** [`crates/project_panel/src/project_panel.rs`](https://github.com/zed-industries/zed/blob/main/crates/project_panel/src/project_panel.rs)
  - `DragTarget` enum — `.Entry { entry_id, highlight_entry_id }` / `.Background`；`drag_target_entry: Option<DragTarget>` 追踪当前高亮目标；对应本计划 `FileTreeDragState.hoveredEntryID` + `FileTreeTableView.Coordinator` 的 `drop target row`。
  - `hover_expand_task: Option<Task<()>>` — 悬停 500ms 后调 `expand_entry`，光标移出时 `hover_expand_task.take()` 取消；对应本计划 `FileTreeDragState.hoverExpandWork: DispatchWorkItem?`。
  - `hover_scroll_task: Option<Task<()>>` — `handle_drag_move` 内按 `hovered_region_offset` (`<= 0.05`→ +8px/frame、`<= 0.15`→+5px，> 0.95 / > 0.85 镜像) 计算滚动量，16ms 周期循环；对应本计划 `FileTreeDragState.edgeScrollWork: DispatchWorkItem?` + `startEdgeScroll(direction:speed:)` 方法。
  - `folded_directory_drag_target: Option<FoldedDirectoryDragTarget>` — Auto-fold 链中每一段和每个分隔符各自是独立 drop target；`FoldedDirectoryDragTarget { entry_id, index, is_delimiter_target }`；VSCode 亦有类似行为（`CompressedNavigationController` 处理压缩节点的子段点击）；对应本计划 `FileTreeCellView` 的折叠段独立目标区域标识和 `VisibleEntry.foldedAncestors` 命中检测。
  - `refresh_drag_cursor_style(modifiers)` — `modifiers.alt`（macOS）→ `CursorStyle::DragCopy`，否则 `PointingHand`；对应本计划 `NSApplication.shared.changeWindowsItem` / `NSCursor.operationNotAllowed` 或 `dragCopy` 通过 `NSDraggingInfo.draggingSourceOperationMask` 的 `.copy` 位控制。
  - `drag_onto(selections, target_entry_id, is_file)` — `is_copy_modifier_set`（Alt on macOS）→ `create_paste_path` + `copy_entry`；否则 `disjoint_entries` 去重 → `move_entry`；完成后 `update_visible_entries`；对应本计划 `FileTreeDropExecutor.execute(plan:)` 调 `WorkspaceFileTreeOperations`。
  - `highlight_entry_for_selection_drag` — 单个拖动时，目标是源文件当前父目录 → 返回 `None`（不高亮，不允许 drop on same parent）；目标是文件 → 高亮其父目录；目标是目录 → 高亮自身；对应 `FileTreeDropValidator.resolve(destination:forSingleSource:)` 的"同父不允许"规则。
  - `should_highlight_background_for_selection_drag` — 多选拖动始终高亮根；单选且源在根目录或跨 worktree 时高亮根；对应本计划 `validateDrop` 当目标行 == -1（背景区域）时的处理。
  - `disjoint_entries(selections, cx)` — 去除嵌套源（父已选中则子跳过）；对应 `FileTreeDropValidator.pruneDescendants(_:in:)`。

- **VSCode** `src/vs/workbench/contrib/files/browser/views/explorerViewer.ts` — `FileDragAndDrop` class
  - `onDragOver(data, target, originalEvent)` — 外部文件 drag：`data instanceof NativeDragAndDropData` → 允许 `.copy`；内部 drop：检查 `target?.isDirectory`，调 `containsDragOver` 禁止祖先放到后代；对应 `validateDrop(_:proposedRow:proposedDropOperation:)` 中对 `NSDraggingInfo.draggingPasteboard` 的类型判断分支。
  - `openDelayHandle` — `setTimeout(200ms)` 后展开目录；本计划用 500ms（与 Zed 一致）。
  - `compressedDragOverElement` — 折叠节点拖放时用 `CompressedNavigationController` 定位到最内层；对应 `FileTreeDropValidator.resolveAutoFoldTarget(hoveredRow:touchX:entries:)` 精确命中折叠段。
  - `containsDragOver(sources, target)` — 判断 target 是否是 source 的后代（`target.isDescendantOf(source)`）；对应 `FileTreeDropValidator.isDescendant(candidateID:ofAnyOf:in:)`。
  - `onDrop(data, target, ...)` — 调 `moveFile/copyFile`；外部文件 copy → `fileService.copy`；内部 move → `workspaceEditingService.move`；对应 `FileTreeDropExecutor.execute(plan:)` 的两条路径。

- **旧代码参考** `agentGui/Utilities/WorkspaceTreeDropCoordinator.swift`
  - `collapseNestedSources(in:)` — `O(N log N)` 去重嵌套路径，按路径长度排序后前缀检测；对应 `FileTreeDropValidator.pruneDescendants(_:in:)` 中按 depth 排序后对 `EntryID.url.path` 前缀检测。
  - `isValidDestination(_:destinationDirectory:)` — `destinationPath == sourcePath`（拖入自身）/ `destinationPath.hasPrefix(sourcePath + "/"`（拖入后代）两种禁止情形；对应 `FileTreeDropValidator.validate(plan:in:)` 的两条拒绝规则，升级为基于 `EntryID` 而非裸 URL 字符串。

- 设计文档 `docs/plans/2026-07-15-filetree-rewrite-design.md` §FT-R9

---

## 前置条件

- 已完成 FT-R0 ✅（`EntryID`、`FileEntry`、`FileTreeStore` actor、`VisibleEntry`）
- 已完成 FT-R2 ✅（`FileTreeTableView`、`Coordinator`、`FileTreeCellView`、`FileTreeViewModel`）
- 已完成 FT-R3 ✅（懒加载 `expandDirectory`、loading state）
- 已完成 FT-R4 ✅（增量 diff 更新）
- 已完成 FT-R5 ✅（Auto-fold：`VisibleEntry.foldedAncestors` 含各段 `EntryID`）
- 已完成 FT-R8 ✅（`WorkspaceFileTreeOperations`：`moveItem`、`copyItem`）

当前实现缺口：

| 文件 | 现状 | FT-R9 目标 |
|------|------|-----------|
| `agentGui/Services/FileTreeDropValidator.swift` | 不存在 | 新建：全部验证逻辑 |
| `agentGui/Models/FileTreeDropPlan.swift` | 不存在 | 新建：拖放决策结果 |
| `agentGui/Views/FileTree/FileTreeTableView.swift` | 无 DnD 代理方法 | 新增：pasteboard 读写、validateDrop、acceptDrop 等 |
| `agentGui/ViewModels/FileTreeViewModel.swift` | 无移动/复制操作 | 新增：`moveEntries`、`copyEntries` |
| `agentGui/Services/FileTreeStore.swift` | 无 `refreshMultipleDirectories` | 新增批量刷新方法 |
| `agentGui/Utilities/WorkspaceTreeDropCoordinator.swift` | 旧实现（76 行） | Task 5 中删除 |
| `agentGuiTests/FileTreeDropValidatorTests.swift` | 不存在 | 新建：12 个测试场景 |
| `agentGuiTests/FileTreeDragDropIntegrationTests.swift` | 不存在 | 新建：4 个集成测试 |

---

## Task 1：`FileTreeDropPlan` + `FileTreeDropValidator`

**Files:**
- Create: `agentGui/Models/FileTreeDropPlan.swift`
- Create: `agentGui/Services/FileTreeDropValidator.swift`
- Create: `agentGuiTests/FileTreeDropValidatorTests.swift`

验证逻辑完全在协议/结构体层完成，不依赖任何 UI 或 AppKit，保证可单元测试。

### Step 1：编写预期失败的测试

**新建** `agentGuiTests/FileTreeDropValidatorTests.swift`：

```swift
// agentGuiTests/FileTreeDropValidatorTests.swift
import XCTest
@testable import agentGui

final class FileTreeDropValidatorTests: XCTestCase {

    // 测试用 Store 快照（仅邻接表，不需要 actor）
    // 使用 MockStoreSnapshot 用于同步测试
    private var snapshot: MockStoreSnapshot!

    override func setUp() async throws {
        // 构造目录结构：
        //   root/
        //     src/        (id: "src")
        //       main/     (id: "main")
        //         App.swift (id: "App")
        //     tests/      (id: "tests")
        //       TestA.swift (id: "TestA")
        snapshot = MockStoreSnapshot(
            entries: [
                "root":  FileEntry(id: id("root"), name: "root", isDirectory: true, parentID: nil),
                "src":   FileEntry(id: id("src"),  name: "src",  isDirectory: true, parentID: id("root")),
                "main":  FileEntry(id: id("main"), name: "main", isDirectory: true, parentID: id("src")),
                "App":   FileEntry(id: id("App"),  name: "App.swift", isDirectory: false, parentID: id("main")),
                "tests": FileEntry(id: id("tests"),name: "tests",isDirectory: true, parentID: id("root")),
                "TestA": FileEntry(id: id("TestA"),name: "TestA.swift",isDirectory: false, parentID: id("tests")),
            ],
            children: [
                "root": [id("src"), id("tests")],
                "src":  [id("main")],
                "main": [id("App")],
                "tests":[id("TestA")],
            ]
        )
    }

    // MARK: - 有效拖放

    func testValidate_moveFileToDirectory_returnsNonNilPlan() {
        let plan = FileTreeDropValidator.validate(
            sourceIDs: [id("App")],
            destinationID: id("tests"),
            snapshot: snapshot
        )
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.destinationID, id("tests"))
        XCTAssertEqual(plan?.draggedIDs, [id("App")])
    }

    func testValidate_moveFolderToSibling_returnsNonNilPlan() {
        let plan = FileTreeDropValidator.validate(
            sourceIDs: [id("main")],
            destinationID: id("tests"),
            snapshot: snapshot
        )
        XCTAssertNotNil(plan)
    }

    // MARK: - 无效：拖入自身

    func testValidate_moveToSelf_returnsNil() {
        // 拖入自己本身
        let plan = FileTreeDropValidator.validate(
            sourceIDs: [id("src")],
            destinationID: id("src"),
            snapshot: snapshot
        )
        XCTAssertNil(plan)
    }

    // MARK: - 无效：拖入后代

    func testValidate_moveToDescendant_returnsNil() {
        // 将 src/ 拖入其子目录 main/
        let plan = FileTreeDropValidator.validate(
            sourceIDs: [id("src")],
            destinationID: id("main"),
            snapshot: snapshot
        )
        XCTAssertNil(plan)
    }

    // MARK: - 无效：拖入当前父目录（同父目录，等效于无移动）

    func testValidate_moveToSameParent_returnsNil() {
        // App.swift 当前在 main/，目标也是 main/ → 无意义
        let plan = FileTreeDropValidator.validate(
            sourceIDs: [id("App")],
            destinationID: id("main"),
            snapshot: snapshot
        )
        XCTAssertNil(plan)
    }

    // MARK: - 嵌套去重

    func testValidate_dedupsNestedSources_keepsTopLevel() {
        // 同时拖 src/ 和 main/（main 是 src 的子）→ 应只保留 src
        let plan = FileTreeDropValidator.validate(
            sourceIDs: [id("src"), id("main")],
            destinationID: id("tests"),
            snapshot: snapshot
        )
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.draggedIDs, [id("src")])  // main 被剔除
    }

    // MARK: - 目标不是目录 → 解析到其父目录

    func testValidate_destinationIsFile_resolvesToParentDirectory() {
        // TestA.swift 不是目录，目标应解析为 tests/
        let plan = FileTreeDropValidator.validate(
            sourceIDs: [id("App")],
            destinationID: id("TestA"),   // 文件
            snapshot: snapshot
        )
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.destinationID, id("tests"))  // 解析到父目录
    }

    // MARK: - 多选，部分无效

    func testValidate_multiSelect_someInvalid_keepValid() {
        // [App, src] → tests/: App 合法，src 不合法（其子 main 在 tests 中不存在问题，
        // 但 src 包含 main，经去重后只有 src，且 src 移到 tests 合法）
        // 换个场景：[App, main] → tests/: main 是 App 的祖先，去重后只有 main
        let plan = FileTreeDropValidator.validate(
            sourceIDs: [id("App"), id("main")],
            destinationID: id("tests"),
            snapshot: snapshot
        )
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.draggedIDs, [id("main")])
    }

    // MARK: - 空源

    func testValidate_emptySources_returnsNil() {
        let plan = FileTreeDropValidator.validate(
            sourceIDs: [],
            destinationID: id("tests"),
            snapshot: snapshot
        )
        XCTAssertNil(plan)
    }

    // MARK: - 外部文件拖入（无需 store 查找，只验证目标）

    func testValidate_externalDrop_validDirectory() {
        let externalURLs = [URL(fileURLWithPath: "/tmp/external.txt")]
        let plan = FileTreeDropValidator.validateExternalDrop(
            externalURLs: externalURLs,
            destinationID: id("tests"),
            snapshot: snapshot
        )
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.destinationID, id("tests"))
    }

    func testValidate_externalDrop_emptyURLs_returnsNil() {
        let plan = FileTreeDropValidator.validateExternalDrop(
            externalURLs: [],
            destinationID: id("tests"),
            snapshot: snapshot
        )
        XCTAssertNil(plan)
    }

    // MARK: - isDescendant

    func testIsDescendant_directChild_true() {
        XCTAssertTrue(
            FileTreeDropValidator.isDescendant(id("main"), ofAnyOf: [id("src")], in: snapshot)
        )
    }

    func testIsDescendant_grandChild_true() {
        XCTAssertTrue(
            FileTreeDropValidator.isDescendant(id("App"), ofAnyOf: [id("src")], in: snapshot)
        )
    }

    func testIsDescendant_sibling_false() {
        XCTAssertFalse(
            FileTreeDropValidator.isDescendant(id("tests"), ofAnyOf: [id("src")], in: snapshot)
        )
    }

    // MARK: - Helpers
    private func id(_ raw: String) -> EntryID {
        EntryID(url: URL(fileURLWithPath: "/root/\(raw)"))
    }
}

// MARK: - MockStoreSnapshot
/// 同步快照，供验证器测试使用，不进入 actor 上下文
struct MockStoreSnapshot: StoreSnapshotProtocol {
    var entries: [EntryID: FileEntry]
    var children: [EntryID: [EntryID]]

    func entry(_ id: EntryID) -> FileEntry? { entries[id] }
    func parentID(of id: EntryID) -> EntryID? { entries[id]?.parentID }
    func children(of id: EntryID) -> [EntryID] { children[id] ?? [] }
}
```

**运行测试，确认全部失败（类型不存在）：**
```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/FileTreeDropValidatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

### Step 2：实现 `FileTreeDropPlan`

**新建** `agentGui/Models/FileTreeDropPlan.swift`：

```swift
// agentGui/Models/FileTreeDropPlan.swift
import Foundation

/// 拖放决策结果。由 FileTreeDropValidator 产生，由 FileTreeDropExecutor 消费。
struct FileTreeDropPlan: Sendable, Equatable {
    /// 去重、裁剪嵌套后的源条目 ID 列表（顺序保留拖拽时的视觉顺序）
    let draggedIDs: [EntryID]

    /// 解析后的目标目录 ID。若用户拖到文件行上，会自动提升到该文件的父目录。
    let destinationID: EntryID

    /// `true` = 移动（默认），`false` = 复制（Option 键或外部文件）
    let isMove: Bool

    /// 外部文件 URL（仅外部拖入时非空）
    let externalURLs: [URL]

    init(
        draggedIDs: [EntryID],
        destinationID: EntryID,
        isMove: Bool = true,
        externalURLs: [URL] = []
    ) {
        self.draggedIDs = draggedIDs
        self.destinationID = destinationID
        self.isMove = isMove
        self.externalURLs = externalURLs
    }
}
```

### Step 3：实现 `StoreSnapshotProtocol` + `FileTreeDropValidator`

**新建** `agentGui/Services/FileTreeDropValidator.swift`：

```swift
// agentGui/Services/FileTreeDropValidator.swift
import Foundation

/// 对 FileTreeStore 所需只读访问的最小协议，方便测试使用同步 mock。
protocol StoreSnapshotProtocol {
    func entry(_ id: EntryID) -> FileEntry?
    func parentID(of id: EntryID) -> EntryID?
    func children(of id: EntryID) -> [EntryID]
}

/// 纯函数：验证并生成 FileTreeDropPlan。不依赖 UI，可在任意上下文调用。
enum FileTreeDropValidator {

    // MARK: - 内部拖放验证

    /// - Parameters:
    ///   - sourceIDs: 用户拖动的条目 ID（未去重）
    ///   - destinationID: 鼠标释放行的 EntryID（可能是文件或目录）
    ///   - snapshot: store 的只读快照
    ///   - isCopy: `true` = 复制（Option 键按下）
    /// - Returns: 合法的拖放计划；若无合法操作则 `nil`
    static func validate(
        sourceIDs: [EntryID],
        destinationID: EntryID,
        snapshot: StoreSnapshotProtocol,
        isCopy: Bool = false
    ) -> FileTreeDropPlan? {
        guard !sourceIDs.isEmpty else { return nil }

        // 1. 解析目标目录（文件 → 父目录）
        guard let resolvedDestination = resolveDestination(destinationID, snapshot: snapshot) else {
            return nil
        }

        // 2. 按深度排序（浅 → 深），然后去除嵌套源
        let pruned = pruneDescendants(sourceIDs, in: snapshot)
        guard !pruned.isEmpty else { return nil }

        // 3. 验证每个源相对于目标的合法性
        let valid = pruned.filter { sourceID in
            // 不能拖入自身
            if sourceID == resolvedDestination { return false }
            // 不能拖入后代
            if isDescendant(resolvedDestination, ofAnyOf: [sourceID], in: snapshot) { return false }
            // 不能拖入当前父目录（等价于无移动）
            if snapshot.parentID(of: sourceID) == resolvedDestination && !isCopy { return false }
            return true
        }

        guard !valid.isEmpty else { return nil }
        return FileTreeDropPlan(draggedIDs: valid, destinationID: resolvedDestination, isMove: !isCopy)
    }

    // MARK: - 外部文件拖入验证

    static func validateExternalDrop(
        externalURLs: [URL],
        destinationID: EntryID,
        snapshot: StoreSnapshotProtocol
    ) -> FileTreeDropPlan? {
        guard !externalURLs.isEmpty else { return nil }
        guard let resolvedDestination = resolveDestination(destinationID, snapshot: snapshot) else {
            return nil
        }
        return FileTreeDropPlan(
            draggedIDs: [],
            destinationID: resolvedDestination,
            isMove: false,
            externalURLs: externalURLs
        )
    }

    // MARK: - 工具方法（internal 供测试直接调用）

    /// 若 id 对应文件，返回其父目录 ID；若对应目录，直接返回 id
    static func resolveDestination(_ id: EntryID, snapshot: StoreSnapshotProtocol) -> EntryID? {
        guard let entry = snapshot.entry(id) else { return nil }
        if entry.isDirectory { return id }
        return snapshot.parentID(of: id)
    }

    /// 检查 `candidate` 是否是 `ancestors` 中任意一个的后代（直接或间接）
    static func isDescendant(
        _ candidate: EntryID,
        ofAnyOf ancestors: [EntryID],
        in snapshot: StoreSnapshotProtocol
    ) -> Bool {
        var current = snapshot.parentID(of: candidate)
        while let parentID = current {
            if ancestors.contains(parentID) { return true }
            current = snapshot.parentID(of: parentID)
        }
        return false
    }

    /// 去除嵌套源：若某条目的祖先也在列表中，则移除该条目（保留顶层条目）。
    ///
    /// 算法：按路径深度升序排序后，对每个候选检查其所有祖先是否已在 `kept` 中。
    /// 时间复杂度 O(N * D)，N = 源数量，D = 树深度，实践中 N 很小。
    static func pruneDescendants(_ sourceIDs: [EntryID], in snapshot: StoreSnapshotProtocol) -> [EntryID] {
        // 按深度升序（浅节点先处理）
        let sorted = sourceIDs.sorted { a, b in
            depth(of: a, snapshot: snapshot) < depth(of: b, snapshot: snapshot)
        }

        var kept: [EntryID] = []
        for candidate in sorted {
            if !isDescendant(candidate, ofAnyOf: kept, in: snapshot) {
                kept.append(candidate)
            }
        }
        return kept
    }

    // MARK: - Private

    private static func depth(of id: EntryID, snapshot: StoreSnapshotProtocol) -> Int {
        var depth = 0
        var current = snapshot.parentID(of: id)
        while current != nil {
            depth += 1
            current = current.flatMap { snapshot.parentID(of: $0) }
        }
        return depth
    }
}
```

**修改** `agentGui/Services/FileTreeStore.swift`，使其实现 `StoreSnapshotProtocol`：

```swift
// 在 FileTreeStore actor 中新增（通过 nonisolated 桥接或 actor 方法）

// 选项 A：新增一个 actor 方法，构建同步快照供外部使用
actor FileTreeStore {
    // ...
    func makeSnapshot() -> FileTreeStoreSnapshot {
        FileTreeStoreSnapshot(entries: entries, children: children)
    }
}

// FileTreeStoreSnapshot：Sendable 值类型，供 DropValidator 在非 actor 上下文使用
struct FileTreeStoreSnapshot: StoreSnapshotProtocol, Sendable {
    private let entries: [EntryID: FileEntry]
    private let children: [EntryID: [EntryID]]

    init(entries: [EntryID: FileEntry], children: [EntryID: [EntryID]]) {
        self.entries = entries
        self.children = children
    }

    func entry(_ id: EntryID) -> FileEntry? { entries[id] }
    func parentID(of id: EntryID) -> EntryID? { entries[id]?.parentID }
    func children(of id: EntryID) -> [EntryID] { children[id] ?? [] }
}
```

### Step 4：运行测试，确认全部通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/FileTreeDropValidatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期输出：`Test Suite ... passed`，12 个测试全部通过。

### Step 5：提交

```
git add agentGui/Models/FileTreeDropPlan.swift
git add agentGui/Services/FileTreeDropValidator.swift
git add agentGui/Services/FileTreeStore.swift   # makeSnapshot
git add agentGuiTests/FileTreeDropValidatorTests.swift
git commit -m "FT-R9 Task1: FileTreeDropPlan + FileTreeDropValidator + tests"
```

---

## Task 2：`FileTreeDragState` + NSTableView 拖放注册

**Files:**
- Modify: `agentGui/Views/FileTree/FileTreeTableView.swift`

为 NSTableView Coordinator 增加拖放状态追踪和 pasteboard 类型注册，建立端到端的管道骨架，但不执行实际的文件操作（留给 Task 3）。

### Step 1：编写测试（验证 pasteboard 注册 + 回调不 crash）

在 `agentGuiTests/FileTreeDropValidatorTests.swift` 末尾追加一个集成测试类（或新建文件）：

```swift
// agentGuiTests/FileTreeDragDropIntegrationTests.swift
import XCTest
@testable import agentGui

final class FileTreeDragDropIntegrationTests: XCTestCase {

    func testCoordinator_registeredPasteboardTypes() {
        // 验证 Coordinator 向 NSTableView 注册了内部 DnD 类型 + fileURL 类型
        let vm = FileTreeViewModel(store: FileTreeStore())
        let tableView = NSTableView()
        let coordinator = FileTreeTableView.Coordinator(parent: ???, viewModel: vm)
        coordinator.registerDragTypes(for: tableView)

        let types = tableView.registeredDraggedTypes
        XCTAssertTrue(types.contains(FileTreeTableView.internalDragType))
        XCTAssertTrue(types.contains(.fileURL))
    }

    func testValidateDrop_invalidDrag_returnsEmpty() {
        // 拖拽到自身父目录 → validateDrop 返回 []（NSDragOperationNone）
        // 由于 NSTableView 测试依赖 AppKit 初始化，此测试在 @MainActor 中运行
        // 使用 MockNSDraggingInfo 模拟
        // （具体实现见 Task 3）
    }
}
```

### Step 2：定义 `FileTreeDragState`

在 `agentGui/Views/FileTree/FileTreeTableView.swift` 顶部新增：

```swift
/// 拖动过程中的瞬态状态，存在 Coordinator（非 actor）中。
/// - 生命周期：`draggingSessionWillBegin` 创建，`draggingSession(_:endedAt:)` 销毁。
final class FileTreeDragState {
    /// 当前鼠标悬停行（-1 = 无）
    var hoveredRow: Int = -1

    /// 500ms 悬停展开计时器（光标移出时取消）
    var hoverExpandWork: DispatchWorkItem?

    /// 面板边缘自动滚动计时器（光标离开边缘区域时取消）
    var edgeScrollWork: DispatchWorkItem?

    /// 拖拽源行索引集合（排除已选的 invalid 源的渲染高亮）
    var dragSourceRows: IndexSet = []

    /// 当前 Auto-fold 段命中（若有），用于精确目标解析
    var foldedSegmentTarget: (entryID: EntryID, segmentIndex: Int)?

    /// 是否按住 Option（Copy 模式）
    var isCopyMode: Bool = false

    deinit {
        hoverExpandWork?.cancel()
        edgeScrollWork?.cancel()
    }

    func cancelHoverExpand() {
        hoverExpandWork?.cancel()
        hoverExpandWork = nil
    }

    func cancelEdgeScroll() {
        edgeScrollWork?.cancel()
        edgeScrollWork = nil
    }
}
```

### Step 3：注册 pasteboard 类型 + `pasteboardWriterForRow`

在 Coordinator 类中新增：

```swift
extension FileTreeTableView.Coordinator {

    /// 内部拖放使用的 pasteboard 类型标识
    static let internalDragType = NSPasteboard.PasteboardType(
        rawValue: "com.feint.agentGui.fileTreeEntry"
    )

    /// 注册支持的拖放类型（在 makeNSView 中调用一次）
    func registerDragTypes(for tableView: NSTableView) {
        tableView.registerForDraggedTypes([
            Self.internalDragType,   // 内部路径
            .fileURL,                // 外部文件可直接粘贴为 URL
        ])
        tableView.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy], forLocal: false)
    }

    // MARK: NSTableViewDataSource — 拖拽源

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> NSPasteboardWriting? {
        guard row >= 0, row < entries.count else { return nil }
        let entry = entries[row]

        // 不允许拖拽占位行（FT-R8 内联编辑状态）
        guard !entry.isEditPlaceholder else { return nil }

        let item = NSPasteboardItem()
        // 写入 EntryID（以 URL path 表示）
        item.setString(entry.id.url.path, forType: Self.internalDragType)
        // 同时写 fileURL，让外部应用（如 Finder）可接收
        item.setData(
            entry.id.url.dataRepresentation,
            forType: .fileURL
        )
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forRowIndexes rowIndexes: IndexSet
    ) {
        dragState = FileTreeDragState()
        dragState?.dragSourceRows = rowIndexes
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        dragState?.cancelHoverExpand()
        dragState?.cancelEdgeScroll()
        dragState = nil
        // 清除高亮
        tableView.setDropRow(-1, dropOperation: .on)
    }

    func tableView(_ tableView: NSTableView, updateDraggingItemsForDrag draggingInfo: NSDraggingInfo) {
        // 根据 Option 键状态更新拖拽图像
        // （在 draggingSession(_:movedTo:) 中处理更精确，此处仅标记 isCopyMode）
        let isOptionDown = NSEvent.modifierFlags.contains(.option)
        dragState?.isCopyMode = isOptionDown
    }
}
```

### Step 4：更新 `makeNSView` / `updateNSView` 以传递 dragState 和注册类型

```swift
// 在 FileTreeTableView.makeNSView 中：
coordinator.registerDragTypes(for: tableView)
tableView.allowsMultipleSelection = true
```

### Step 5：运行编译，确认无新增错误

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

### Step 6：提交

```bash
git add agentGui/Views/FileTree/FileTreeTableView.swift
git commit -m "FT-R9 Task2: FileTreeDragState + NSTableView DnD registration & pasteboard writer"
```

---

## Task 3：`validateDrop` + `acceptDrop`（移动/复制核心路径）

**Files:**
- Modify: `agentGui/Views/FileTree/FileTreeTableView.swift`
- Modify: `agentGui/ViewModels/FileTreeViewModel.swift`
- Modify: `agentGui/Services/FileTreeStore.swift`

实现 NSTableView 接收拖放的完整路径：验证 → 高亮目标行 → 提交移动/复制操作。

### Step 1：ViewModel 新增 `moveEntries` + `copyEntries`

**修改** `agentGui/ViewModels/FileTreeViewModel.swift`：

```swift
// FileTreeViewModel.swift 新增：

@Observable @MainActor
final class FileTreeViewModel {
    // ... 现有字段 ...

    // MARK: - DnD 操作

    /// 移动多个条目到目标目录
    func moveEntries(_ sourceIDs: [EntryID], to destinationID: EntryID) async {
        let destinationURL = destinationID.url
        var affectedParents: Set<EntryID> = [destinationID]

        for id in sourceIDs {
            if let parentID = await store.parentID(of: id) {
                affectedParents.insert(parentID)
            }
            do {
                let sourceURL = id.url
                let destURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
                try WorkspaceFileTreeOperations.moveItem(at: sourceURL, to: destURL)
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        // 刷新所有受影响目录
        await store.refreshMultipleDirectories(Array(affectedParents))
        visibleEntries = await store.computeVisibleEntries(
            searchFilter: searchText.isEmpty ? nil : searchText,
            searchMode: searchMode
        )
    }

    /// 复制多个条目到目标目录（Option 拖动或外部文件拖入）
    func copyEntries(_ sourceIDs: [EntryID], to destinationID: EntryID) async {
        let destinationURL = destinationID.url

        for id in sourceIDs {
            do {
                let sourceURL = id.url
                let destURL = resolveNonConflictingURL(
                    source: sourceURL,
                    directory: destinationURL
                )
                try WorkspaceFileTreeOperations.copyItem(at: sourceURL, to: destURL)
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        await store.refreshMultipleDirectories([destinationID])
        visibleEntries = await store.computeVisibleEntries(
            searchFilter: searchText.isEmpty ? nil : searchText,
            searchMode: searchMode
        )
    }

    /// 外部文件拖入（URLs 来自 Finder 等）
    func importExternalFiles(_ urls: [URL], to destinationID: EntryID) async {
        let destinationURL = destinationID.url

        for sourceURL in urls {
            do {
                let destURL = resolveNonConflictingURL(
                    source: sourceURL,
                    directory: destinationURL
                )
                try WorkspaceFileTreeOperations.copyItem(at: sourceURL, to: destURL)
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        await store.refreshMultipleDirectories([destinationID])
        visibleEntries = await store.computeVisibleEntries(
            searchFilter: searchText.isEmpty ? nil : searchText,
            searchMode: searchMode
        )
    }

    // MARK: - Private helpers

    /// 若目标路径已存在文件，自动附加 " copy" / " copy 2" 后缀
    private func resolveNonConflictingURL(source: URL, directory: URL) -> URL {
        let name = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = directory.appendingPathComponent(source.lastPathComponent)
        var ix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let suffix = ix == 1 ? " copy" : " copy \(ix)"
            let newName = ext.isEmpty ? "\(name)\(suffix)" : "\(name)\(suffix).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            ix += 1
        }
        return candidate
    }
}
```

**修改** `agentGui/Services/FileTreeStore.swift` 新增批量刷新：

```swift
actor FileTreeStore {
    // ...

    /// 批量刷新多个目录（先去除后代重复，再并发扫描）
    func refreshMultipleDirectories(_ dirIDs: [EntryID]) async {
        // pruneDescendants 确保只刷新最浅的受影响目录
        let snapshot = makeSnapshot()
        let pruned = FileTreeDropValidator.pruneDescendants(dirIDs, in: snapshot)

        await withTaskGroup(of: Void.self) { group in
            for id in pruned {
                group.addTask { [weak self] in
                    await self?.refreshDirectory(id)
                }
            }
        }
    }
}
```

### Step 2：实现 `validateDrop`

```swift
// agentGui/Views/FileTree/FileTreeTableView.swift — Coordinator 扩展

extension FileTreeTableView.Coordinator: NSTableViewDataSource {

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let pasteboard = info.draggingPasteboard

        // ── 外部文件拖入路径 ──────────────────────────────────────
        if let _ = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true
        ]) as? [URL], !pasteboard.types!.contains(Self.internalDragType) {
            // 外部文件：任意目录 → 允许 copy
            let targetEntry = resolvedDropEntry(row: row)
            tableView.setDropRow(
                resolvedDropRow(row: row, targetEntry: targetEntry),
                dropOperation: .on
            )
            return .copy
        }

        // ── 内部拖放路径 ──────────────────────────────────────────
        guard let dragState = dragState else { return [] }

        // 1. 读取拖拽源 EntryIDs
        let sourceIDs = extractSourceIDs(from: pasteboard)
        guard !sourceIDs.isEmpty else { return [] }

        // 2. 确定目标 EntryID
        let targetEntry = resolvedDropEntry(row: row)
        guard let targetID = targetEntry?.id else {
            // 拖到背景区域 → 目标为根目录
            tableView.setDropRow(-1, dropOperation: .on)
            return dragState.isCopyMode ? .copy : .move
        }

        // 3. 获取 store 快照并验证
        guard let snapshot = viewModel.storeSnapshot else { return [] }
        let isCopy = dragState.isCopyMode || NSEvent.modifierFlags.contains(.option)
        guard let _ = FileTreeDropValidator.validate(
            sourceIDs: sourceIDs,
            destinationID: targetID,
            snapshot: snapshot,
            isCopy: isCopy
        ) else { return [] }

        // 4. 高亮目标行
        let targetRow = resolvedDropRow(row: row, targetEntry: targetEntry)
        tableView.setDropRow(targetRow, dropOperation: .on)

        // 5. 悬停 500ms 自动展开
        if let targetEntry = targetEntry, targetEntry.isDirectory, !targetEntry.isExpanded {
            scheduleHoverExpand(entryID: targetEntry.id, after: 0.5)
        }

        // 6. 面板边缘自动滚动
        updateEdgeScroll(for: info.draggingLocation, in: tableView)

        return isCopy ? .copy : .move
    }

    // MARK: - validateDrop 辅助

    /// 从 pasteboard 读取内部拖拽的 EntryID 列表
    private func extractSourceIDs(from pasteboard: NSPasteboard) -> [EntryID] {
        guard let paths = pasteboard.strings(forType: Self.internalDragType) else { return [] }
        return paths.map { EntryID(url: URL(fileURLWithPath: $0)) }
    }

    /// 给定 proposedRow，返回对应的 VisibleEntry（-1 或越界时返回 nil）
    private func resolvedDropEntry(row: Int) -> VisibleEntry? {
        guard row >= 0, row < entries.count else { return nil }
        return entries[row]
    }

    /// 返回高亮行索引（将 .above 重定向为 .on）
    private func resolvedDropRow(row: Int, targetEntry: VisibleEntry?) -> Int {
        guard let entry = targetEntry else { return -1 }
        if entry.isDirectory { return row }
        // 文件：高亮其父目录行
        guard let parentID = entry.parentID,
              let parentRow = entries.firstIndex(where: { $0.id == parentID }) else { return row }
        return parentRow
    }
}
```

### Step 3：实现 `acceptDrop`

```swift
extension FileTreeTableView.Coordinator: NSTableViewDataSource {

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        // 清理高亮和悬停计时器
        dragState?.cancelHoverExpand()
        tableView.setDropRow(-1, dropOperation: .on)

        let pasteboard = info.draggingPasteboard

        // ── 外部文件拖入 ──────────────────────────────────────────
        if let externalURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
        ) as? [URL],
           !pasteboard.types!.contains(Self.internalDragType),
           let targetEntry = resolvedDropEntry(row: row)
        {
            let targetID = targetEntry.isDirectory
                ? targetEntry.id
                : (targetEntry.parentID ?? targetEntry.id)

            Task { @MainActor in
                await viewModel.importExternalFiles(externalURLs, to: targetID)
            }
            return true
        }

        // ── 内部拖放 ──────────────────────────────────────────────
        let sourceIDs = extractSourceIDs(from: pasteboard)
        guard !sourceIDs.isEmpty else { return false }

        let targetEntry = resolvedDropEntry(row: row)
        let targetID: EntryID
        if let entry = targetEntry {
            targetID = entry.isDirectory
                ? entry.id
                : (entry.parentID ?? entry.id)
        } else {
            // 背景区域 → 根目录
            guard let rootID = entries.first?.id else { return false }
            targetID = rootID
        }

        let isCopy = dragState?.isCopyMode ?? false

        Task { @MainActor in
            if isCopy {
                await viewModel.copyEntries(sourceIDs, to: targetID)
            } else {
                await viewModel.moveEntries(sourceIDs, to: targetID)
            }
        }
        return true
    }
}
```

### Step 4：运行测试，验证编译通过

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

### Step 5：提交

```bash
git add agentGui/Views/FileTree/FileTreeTableView.swift
git add agentGui/ViewModels/FileTreeViewModel.swift
git add agentGui/Services/FileTreeStore.swift
git commit -m "FT-R9 Task3: validateDrop + acceptDrop + moveEntries/copyEntries + importExternalFiles"
```

---

## Task 4：悬停展开（Hover-to-Expand）+ 面板边缘自动滚动

**Files:**
- Modify: `agentGui/Views/FileTree/FileTreeTableView.swift`

将 Task 3 中骨架性的 `scheduleHoverExpand` 和 `updateEdgeScroll` 补全为完整实现。

### Step 1：编写行为描述性测试（无 UI，测逻辑）

```swift
// agentGuiTests/FileTreeDragDropIntegrationTests.swift 追加：

func testHoverExpandState_cancelledOnRowChange() {
    // 验证：悬停在 A 行时创建 work item；移到 B 行时 A 的 work item 已取消
    let state = FileTreeDragState()

    var aExpanded = false
    let workA = DispatchWorkItem { aExpanded = true }
    state.hoverExpandWork = workA
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: workA)

    // 立即取消（模拟移到另一行）
    state.cancelHoverExpand()

    // 等 50ms 确认 A 没有展开
    let exp = expectation(description: "notExpanded")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        XCTAssertFalse(aExpanded, "work item should have been cancelled")
        exp.fulfill()
    }
    wait(for: [exp], timeout: 1.0)
}
```

### Step 2：实现 `scheduleHoverExpand`

```swift
extension FileTreeTableView.Coordinator {

    /// 悬停 `delay` 秒后自动展开 `entryID` 对应的目录。
    /// 若在计时器触发前再次调用（不同 entryID），旧任务被取消。
    func scheduleHoverExpand(entryID: EntryID, after delay: TimeInterval) {
        guard let state = dragState else { return }

        // 同一目录不重复调度
        if state.hoveredRow == entries.firstIndex(where: { $0.id == entryID }) ?? -1 {
            // 已在追踪该行，无需重新调度
            if state.hoverExpandWork != nil { return }
        }

        state.cancelHoverExpand()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                await self.viewModel.expandDirectory(entryID)
            }
        }
        state.hoverExpandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
```

### Step 3：实现 `updateEdgeScroll`

参考 Zed 的边缘滚动策略：距顶/底部 5%（≤0.05）→ 快速 +8pt/frame，10-15%（0.05-0.15）→ 中速 +5pt/frame，镜像适用于底部。

```swift
extension FileTreeTableView.Coordinator {

    /// 检查鼠标是否在面板边缘区域，若是则启动自动滚动循环；否则停止。
    ///
    /// - Parameters:
    ///   - location: 拖拽位置（相对于 tableView 坐标系）
    ///   - tableView: 目标 NSTableView
    func updateEdgeScroll(for location: NSPoint, in tableView: NSTableView) {
        guard let scrollView = tableView.enclosingScrollView else { return }

        let visibleHeight = scrollView.contentView.bounds.height
        guard visibleHeight > 0 else { return }

        // 将屏幕坐标转为 tableView 坐标
        let localPoint = tableView.convert(location, from: nil)
        let visibleRect = scrollView.contentView.documentVisibleRect
        let relativeY = (localPoint.y - visibleRect.minY) / visibleHeight

        // 按比例调整滚动量（负值 = 向上滚动）
        let scrollDelta: CGFloat
        if relativeY <= 0.05 {
            scrollDelta = 8
        } else if relativeY <= 0.15 {
            scrollDelta = 5
        } else if relativeY >= 0.95 {
            scrollDelta = -8
        } else if relativeY >= 0.85 {
            scrollDelta = -5
        } else {
            dragState?.cancelEdgeScroll()
            return
        }

        // 已有滚动任务且方向一致时不重复调度
        if dragState?.edgeScrollWork != nil { return }

        startEdgeScroll(delta: scrollDelta, in: scrollView)
    }

    /// 以 ~16ms 间隔循环滚动 `delta` pt，直到 `dragState.edgeScrollWork` 被取消。
    private func startEdgeScroll(delta: CGFloat, in scrollView: NSScrollView) {
        guard let state = dragState else { return }

        let work = DispatchWorkItem { [weak self, weak scrollView] in
            guard let self = self, let scrollView = scrollView,
                  self.dragState?.edgeScrollWork != nil else { return }

            let current = scrollView.contentView.bounds.origin
            let newY = max(0, min(
                current.y - delta,
                scrollView.contentView.documentRect.height - scrollView.contentView.bounds.height
            ))
            scrollView.contentView.scroll(to: NSPoint(x: current.x, y: newY))
            scrollView.reflectScrolledClipView(scrollView.contentView)

            // 调度下一帧（~16ms）
            self.dragState?.edgeScrollWork = nil   // 允许重新调度
            self.startEdgeScroll(delta: delta, in: scrollView)
        }
        state.edgeScrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: work)
    }
}
```

> **注意**：上面的递归调度风格模仿 Zed 的 `hover_scroll_task` 循环方式。每次触发后将 `edgeScrollWork` 设为 `nil`，然后立即调度新的 work item，使得在 `updateEdgeScroll` 中"已有任务"的判断保持正确。光标离开边缘区域或拖放结束时，`cancelEdgeScroll()` 取消链，循环自然终止。

### Step 4：测试悬停展开 + 边缘滚动行为

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/FileTreeDragDropIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

### Step 5：提交

```bash
git add agentGui/Views/FileTree/FileTreeTableView.swift
git add agentGuiTests/FileTreeDragDropIntegrationTests.swift
git commit -m "FT-R9 Task4: hover-to-expand 500ms + panel-edge auto-scroll 16ms loop"
```

---

## Task 5：Auto-fold 段独立拖放目标 + Option 键 Copy 光标

**Files:**
- Modify: `agentGui/Views/FileTree/FileTreeTableView.swift`
- Modify: `agentGui/Views/FileTree/FileTreeCellView.swift`
- Delete: `agentGui/Utilities/WorkspaceTreeDropCoordinator.swift`

### Step 1：Auto-fold 段命中检测

Zed 对 `FoldedAncestors` 中每一个路径段（`/component/`）和每个分隔符（`/`）都注册了独立的 `on_drag_move` / `on_drop`。在 AppKit 中我们通过计算命中矩形来模拟：

**修改** `agentGui/Views/FileTree/FileTreeCellView.swift`：

```swift
// FileTreeCellView.swift — 新增 Auto-fold 段的命中区域标记

extension FileTreeCellView {

    /// 给定拖拽位置（cell 坐标系），返回命中的折叠段索引（0 = 最外层段）和对应的 EntryID。
    /// 返回 nil 表示未命中任何折叠段（命中普通文件名或 indent spacer）。
    func hitTestFoldedSegment(at point: NSPoint) -> (segmentIndex: Int, entryID: EntryID)? {
        guard let ancestors = currentEntry?.foldedAncestors else { return nil }

        for (index, label) in segmentLabels.enumerated() {
            if label.frame.contains(point) {
                guard index < ancestors.segments.count else { break }
                return (index, ancestors.segments[index].entryID)
            }
        }
        return nil
    }

    /// 文件树 cell 中实际渲染折叠段时存储的各段 NSTextField 列表
    /// （由 `configure(entry:)` 在渲染 foldedAncestors 时填充）
    private(set) var segmentLabels: [NSTextField] = []
}
```

**修改** `agentGui/Views/FileTree/FileTreeTableView.swift` — 在 `validateDrop` 中调用：

```swift
// validateDrop 中——在确定目标行后，检查是否命中了折叠段

// 将拖拽位置转换到 cell 坐标
if let cell = tableView.view(atColumn: 0, row: proposedRow, makeIfNecessary: false) as? FileTreeCellView,
   let hit = cell.hitTestFoldedSegment(at: tableView.convert(info.draggingLocation, from: nil)) {
    // 命中了折叠段 → 该段所对应的 EntryID 成为精确目标
    dragState?.foldedSegmentTarget = (entryID: hit.entryID, segmentIndex: hit.segmentIndex)
    // 验证器用 hit.entryID（而非行级 entryID）进行验证
    // ...
} else {
    dragState?.foldedSegmentTarget = nil
}
```

### Step 2：Option 键 Copy 模式光标

macOS 对 NSDragOperation.copy 会自动在拖拽图像上显示绿色 `+` 角标。只需要确保 `draggingSourceOperationMask` 和 `validateDrop` 返回值的 `.copy` 位正确传递即可：

```swift
// 已在 Task 2 的 registerDragTypes 中设置：
tableView.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
tableView.setDraggingSourceOperationMask([.copy], forLocal: false)

// validateDrop 返回 .copy / .move 由 dragState.isCopyMode 决定
// isCopyMode 在 tableView(_:updateDraggingItemsForDrag:) 中更新：
func tableView(_ tableView: NSTableView, updateDraggingItemsForDrag draggingInfo: NSDraggingInfo) {
    // 读取当前修饰键
    let isOption = NSEvent.modifierFlags.contains(.option)
    if dragState?.isCopyMode != isOption {
        dragState?.isCopyMode = isOption
        // 触发重新验证（重绘高亮）
        tableView.setNeedsDisplay()
    }
}
```

> **注意**：AppKit 的 NSTableView 会在每次拖拽位置变化时自动重新调用 `validateDrop`，因此不需要手动触发重新验证——仅需确保 `isCopyMode` 在 `updateDraggingItemsForDrag` 中同步即可。

### Step 3：删除旧代码

```bash
git rm agentGui/Utilities/WorkspaceTreeDropCoordinator.swift
```

在 Xcode 项目文件中移除引用（或直接在 Xcode 中删除，让 Xcode 自动更新 `.pbxproj`）。

确认旧引用均已清理（搜索 `WorkspaceTreeDropCoordinator`）：

```bash
grep -r "WorkspaceTreeDropCoordinator" agentGui/ --include="*.swift"
# 期望：无输出
```

### Step 4：运行测试套件

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/FileTreeDropValidatorTests \
  -only-testing:agentGuiTests/FileTreeDragDropIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

### Step 5：提交

```bash
git add agentGui/Views/FileTree/FileTreeTableView.swift
git add agentGui/Views/FileTree/FileTreeCellView.swift
git rm agentGui/Utilities/WorkspaceTreeDropCoordinator.swift
git commit -m "FT-R9 Task5: auto-fold segment hit-test + Option-key copy cursor + remove old DropCoordinator"
```

---

## Task 6：拖放视觉反馈 + 最终集成测试

**Files:**
- Modify: `agentGui/Views/FileTree/FileTreeTableView.swift`
- Modify: `agentGui/Views/FileTree/FileTreeTableRowView.swift`（可选：自定义 drop highlight）
- Modify: `agentGuiTests/FileTreeDragDropIntegrationTests.swift`

### Step 1：自定义拖放高亮（可选）

NSTableView 默认已有 drop highlight 样式（蓝色环形边框）。若要匹配 Zed 的 `drag_over_color`（主题 `drop_target_background`），可在 `FileTreeTableRowView` 中重写：

```swift
// FileTreeTableRowView.swift
final class FileTreeTableRowView: NSTableRowView {

    // 当此行被设为 drop target 时，NSTableView 会将 isTargetForDropOperation 设为 true
    // 然后调用 drawDraggingDestinationFeedback(in:)

    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {
        // 使用 accent 半透明填充替代默认蓝色环
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        bounds.fill()
        // 顶部 2pt accent 线
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
    }
}
```

### Step 2：集成测试补全

在 `agentGuiTests/FileTreeDragDropIntegrationTests.swift` 中补充：

```swift
// 测试：移动操作后 visibleEntries 更新（使用 MockFileScanner）
func testMoveEntries_updatesVisibleEntries() async {
    // 构造 vm + store，mock scanner 返回两个目录
    let scanner = MockFileScanner(structure: [
        "/root/src/": ["App.swift"],
        "/root/tests/": ["TestA.swift"]
    ])
    let store = FileTreeStore(scanner: scanner)
    let vm = FileTreeViewModel(store: store)

    await vm.setDirectory(URL(fileURLWithPath: "/root"))
    let initialCount = await vm.visibleEntries.count

    // 将 App.swift 移到 tests/
    // （MockFileScanner 在 scanner.didMove 时更新内部结构）
    scanner.simulateMove(from: "/root/src/App.swift", to: "/root/tests/App.swift")
    await vm.moveEntries([EntryID(url: URL(fileURLWithPath: "/root/src/App.swift"))],
                         to: EntryID(url: URL(fileURLWithPath: "/root/tests")))

    // visibleEntries 不变（2 dirs + 2 files），但 App.swift 应出现在 tests/ 下
    let entries = await vm.visibleEntries
    XCTAssertEqual(entries.count, initialCount)
    let appEntry = entries.first { $0.id.url.lastPathComponent == "App.swift" }
    XCTAssertEqual(appEntry?.parentID, EntryID(url: URL(fileURLWithPath: "/root/tests")))
}

// 测试：拖入自身后代 → acceptDrop 返回 false / ViewModel 不执行移动
func testAcceptDrop_selfDescendant_noMove() async {
    // 验证 validateDrop 返回 [] → acceptDrop 不调用 moveEntries
    var moveCalled = false

    // ... 构造 mock 等，验证 moveCalled == false
    XCTAssertFalse(moveCalled)
}

// 测试：外部文件拖入 → importExternalFiles 被调用
func testAcceptDrop_externalFiles_callsImport() async {
    let externalURLs = [URL(fileURLWithPath: "/tmp/extern.txt")]
    var importedURLs: [URL] = []

    // 通过 spy ViewModel 记录调用
    // ...
    XCTAssertEqual(importedURLs, externalURLs)
}
```

### Step 3：手动冒烟测试（需 Xcode 运行应用）

| 测试场景 | 预期行为 |
|---------|---------|
| 拖动文件到目录 | 文件从原父目录消失，出现在目标目录 |
| Option + 拖动文件 | 光标显示 `+` 角标；源文件保留，目标目录出现副本 |
| 拖动目录到其子目录 | 行为被禁止（光标显示禁止图标，no-op） |
| 拖动文件到其当前父目录 | 被禁止（不产生任何操作） |
| 悬停在折叠目录上 500ms | 目录自动展开 |
| 悬停在 Auto-fold 折叠段 | 精确目标 = 该段对应目录 |
| 拖动到面板顶/底 10% 区域 | 列表自动向上/下滚动 |
| 从 Finder 拖入文件 | 文件被复制到目标目录 |
| 多选拖动（Cmd + 点选） | 所有选中文件一起移动 |
| 拖动父目录时同时选中了其子目录 | 子目录被去重，只移动父目录 |

### Step 4：运行全部测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/FileTreeDropValidatorTests \
  -only-testing:agentGuiTests/FileTreeDragDropIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

### Step 5：最终提交

```bash
git add agentGui/Views/FileTree/FileTreeTableView.swift
git add agentGui/Views/FileTree/FileTreeTableRowView.swift
git add agentGui/Views/FileTree/FileTreeCellView.swift
git add agentGuiTests/FileTreeDragDropIntegrationTests.swift
git commit -m "FT-R9 Task6: drag drop visual feedback + integration tests + smoke test checklist"
```

---

## 新文件清单

| 路径 | 估计行数 | Task |
|------|---------|------|
| `agentGui/Models/FileTreeDropPlan.swift` | ~30 | Task 1 |
| `agentGui/Services/FileTreeDropValidator.swift` | ~120 | Task 1 |
| `agentGuiTests/FileTreeDropValidatorTests.swift` | ~180 | Task 1 |
| `agentGuiTests/FileTreeDragDropIntegrationTests.swift` | ~100 | Task 2–6 |

## 修改文件清单

| 路径 | 主要变更 | Task |
|------|---------|------|
| `agentGui/Views/FileTree/FileTreeTableView.swift` | DragState + pasteboard 注册 + validateDrop + acceptDrop + hover + edge-scroll + auto-fold 命中 | Task 2–6 |
| `agentGui/ViewModels/FileTreeViewModel.swift` | `moveEntries`, `copyEntries`, `importExternalFiles`, `storeSnapshot` 属性 | Task 3 |
| `agentGui/Services/FileTreeStore.swift` | `makeSnapshot()`, `refreshMultipleDirectories(_:)`, `StoreSnapshotProtocol` conformance | Task 1–3 |
| `agentGui/Views/FileTree/FileTreeCellView.swift` | `segmentLabels`, `hitTestFoldedSegment(at:)` | Task 5 |
| `agentGui/Views/FileTree/FileTreeTableRowView.swift` | `drawDraggingDestinationFeedback` | Task 6 |

## 删除文件清单

| 路径 | 行数 | Task |
|------|------|------|
| `agentGui/Utilities/WorkspaceTreeDropCoordinator.swift` | ~76 | Task 5 |

---

## 边界情况与约束

| 场景 | 处理方式 |
|------|---------|
| 多文件夹拖放中包含嵌套（父 + 子同选） | `FileTreeDropValidator.pruneDescendants` 去重，只保留父级 |
| 拖入目标目录已有同名文件 | `resolveNonConflictingURL` 自动添加 " copy" / " copy N" 后缀 |
| 拖放操作执行时文件系统报错 | `errorMessage` 更新，UI 显示错误横幅（已有基础设施） |
| 悬停展开后，光标移走但展开已完成 | 展开已生效，不回滚（符合用户直觉） |
| `dragState` 在 `acceptDrop` 之前被 `draggingSession(endedAt:)` 清除 | `acceptDrop` 单独从 pasteboard 读取所有需要的数据，不依赖 `dragState` |
| Auto-fold 折叠段的拖放目标 | 通过 `hitTestFoldedSegment(at:)` 精确命中，Validator 使用段的真实 EntryID |
| Swift 6 并发：NSTableView 代理在 @MainActor | Coordinator 标记 `@MainActor`；Task 3 的 `moveEntries` / `copyEntries` 通过 `Task { @MainActor in ... }` 在主线程调用 ViewModel |

---

## 验收标准

| 标准 | 验收方式 |
|------|---------|
| `FileTreeDropValidatorTests` 12 个测试全部通过 | `xcodebuild test` |
| `FileTreeDragDropIntegrationTests` 4 个测试全部通过 | `xcodebuild test` |
| 拖拽移动：文件从源目录消失，出现在目标目录 | 手动冒烟 |
| Option 拖动：源文件保留，目标目录出现副本 | 手动冒烟 |
| 拖入后代/自身/同父：光标禁止，无操作 | 手动冒烟 |
| 悬停折叠目录 500ms 自动展开 | 手动冒烟 |
| 面板顶/底边缘拖拽时自动滚动 | 手动冒烟 |
| Auto-fold 折叠段各段可作为独立 drop target | 手动冒烟 |
| 从 Finder 拖入文件被正确复制 | 手动冒烟 |
| `WorkspaceTreeDropCoordinator.swift` 已删除 | `git status` |
| 无新增 Swift 6 并发警告/错误 | `xcodebuild build` |

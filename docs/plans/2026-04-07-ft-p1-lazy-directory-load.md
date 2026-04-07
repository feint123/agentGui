# FT-P1：懒加载子目录 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将文件树的初始扫描从"递归扫描全部层级（depth < 8）"改为"首次只扫描 1 层，目录展开时才按需扫描子项"，使以下指标达标：50,000 文件工作区首次加载时间 < 200ms（从当前 3–8s 降至几乎瞬时）。

**Architecture:** 三层变更——① `FileNode` 模型新增 `childrenLoadState` 枚举（`.notLoaded` / `.loaded`）；② `WorkspaceTreeSnapshotOps.buildNodesShallow` 替换递归 `buildNodes` 成为初始加载入口；③ `WorkspaceTreeRefreshCoordinator.demandLoad(directoryID:)` 在用户展开目录时触发按需扫描。外层 `WorkspaceTreeOutlineView` 通过新回调 `onDemandLoadDirectory` 将展开事件路由到 ViewModel，ViewModel 再调用协调器。整个 FSEvent → debounce → applyPartialUpdate 链路保持不变。

**Tech Stack:** Swift 6.0+, AppKit NSOutlineView, Swift Testing framework (`import Testing`), `@testable import agentGui`

---

## 调研参考：VSCode 与 Zed 的懒加载设计

### VSCode：`AsyncDataTree` + `ExplorerItem._isDirectoryResolved`

- 核心入口：`src/vs/base/browser/ui/tree/asyncDataTree.ts`
  - `AsyncDataTree` 的 `getChildren(node)` 回调在 `TreeModel` 请求节点子树时才被调用（即用户展开时），而非初始化时递归全部节点。
  - 每个 `IAsyncDataSource.hasChildren(element)` 通过文件 stat 中的 `isDirectory` 直接返回，无需先加载子项。
- Explorer 侧：`src/vs/workbench/contrib/files/browser/views/explorerView.ts`
  - `ExplorerItem` 有 `_isDirectoryResolved: boolean` 标记，初始为 `false`。
  - 展开时 `explorerService.resolveFile(item)` → `ExplorerItem.addChild(child)` → 标记 `_isDirectoryResolved = true`。
  - `_isDirectoryResolved == false` 的目录节点在 `hasChildren()` 中仍返回 `true`（即显示展开三角），确保用户可展开。
- 关键模式：**"预知可展开，延迟加载内容"**——即分离 `hasChildren()` 与 `getChildren()` 的调用时机。

### Zed：`Worktree` 条目状态 + 扁平 `VisibleEntry` 列表

- 核心：`crates/worktree/src/worktree.rs`
  - `Worktree` 通过后台线程扫描文件系统，但只在目录被"订阅"（即展开）时才递归扫描子目录。
  - `Entry` 结构体有 `kind: EntryKind`（`File` / `Dir` / `PendingDir`），`PendingDir` 相当于 `.notLoaded`。
- Project Panel：`crates/project_panel/src/project_panel.rs`
  - `VisibleEntriesForWorktree` 计算展开目录的扁平可见列表；未展开目录不计入此列表。
  - 当用户展开 `PendingDir` 时，`project_panel::open_entry` 触发 `worktree.expand_entry(entry_id)` → Worktree 后台扫描该目录 → 推送 `WorktreeUpdateEvent` → Panel 刷新可见列表。
- 关键模式：**"状态机驱动展开"**——目录状态从 `PendingDir` → `Dir`（loaded）单向流转。

### agentGui 映射

| VSCode / Zed 概念 | agentGui 对应实现 |
|---|---|
| `ExplorerItem._isDirectoryResolved = false` | `FileNode.childrenLoadState = .notLoaded` |
| `hasChildren()` 依赖 isDirectory 而非实际子项 | `isItemExpandable` 改为检查 `childrenLoadState` |
| `AsyncDataTree.getChildren(node)` 懒触发 | `outlineViewItemDidExpand` → `onDemandLoadDirectory` |
| `Worktree.expand_entry(id)` 后台扫描 | `WorkspaceTreeRefreshCoordinator.demandLoad(directoryID:)` |
| `WorktreeUpdateEvent` → Panel 刷新 | `onNodesChanged` → ViewModel `rootNodes` → `reloadData` |

---

## 涉及文件概览

| 角色 | 文件 | 变更类型 |
|---|---|---|
| 模型 | `agentGui/Models/FileNode.swift` | 修改 — 新增 `childrenLoadState` |
| 快照操作 | `agentGui/Utilities/WorkspaceTreeRefreshCoordinator.swift`（含 `WorkspaceTreeSnapshotOps`） | 修改 — `buildNodesShallow`、`demandLoad`、`applyPartialUpdate` 更新 |
| 视图 | `agentGui/Views/WorkspaceTree/WorkspaceTreeOutlineView.swift` | 修改 — DataSource 方法 + `onDemandLoadDirectory` 回调 |
| ViewModel | `agentGui/ViewModels/WorkspaceTreeViewModel.swift` | 修改 — `demandLoad` 路由 |
| 测试 | `agentGuiTests/FileNodeLazyLoadTests.swift` | 新建 |
| 测试 | `agentGuiTests/WorkspaceTreeLazyLoadSnapshotOpsTests.swift` | 新建 |
| 测试 | `agentGuiTests/WorkspaceTreeDemandLoadCoordinatorTests.swift` | 新建 |

---

## 快速测试命令

每个任务完成后用以下命令运行本 Feature 的全部测试：

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-p1-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/FileNodeLazyLoadTests \
  -only-testing:agentGuiTests/WorkspaceTreeLazyLoadSnapshotOpsTests \
  -only-testing:agentGuiTests/WorkspaceTreeDemandLoadCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|PASS|FAIL|passed|failed|error:"
```

---

## Task FT-P1-T1：`FileNode` 模型 — 新增 `childrenLoadState`

**目的**：为目录节点引入显式的加载状态，区分"尚未扫描"和"已扫描为空"，为后续懒加载机制提供语义基础。

**Files:**
- Modify: `agentGui/Models/FileNode.swift`
- Create: `agentGuiTests/FileNodeLazyLoadTests.swift`

---

### Step 1: 新建测试文件，写第一批失败断言

新建 `agentGuiTests/FileNodeLazyLoadTests.swift`：

```swift
import Testing
@testable import agentGui

struct FileNodeLazyLoadTests {

    // MARK: - childrenLoadState 基础语义

    @Test func directoryDefaultsToNotLoaded() {
        let node = FileNode(
            id: URL(fileURLWithPath: "/tmp/dir"),
            name: "dir",
            isDirectory: true,
            children: nil,
            childrenLoadState: .notLoaded
        )
        #expect(node.childrenLoadState == .notLoaded)
        #expect(node.isDirectory == true)
    }

    @Test func loadedDirectoryPreservesChildren() {
        let child = FileNode(
            id: URL(fileURLWithPath: "/tmp/dir/file.txt"),
            name: "file.txt",
            isDirectory: false,
            children: nil,
            childrenLoadState: .loaded
        )
        let node = FileNode(
            id: URL(fileURLWithPath: "/tmp/dir"),
            name: "dir",
            isDirectory: true,
            children: [child],
            childrenLoadState: .loaded
        )
        #expect(node.childrenLoadState == .loaded)
        #expect(node.children?.count == 1)
    }

    @Test func fileNodeAlwaysLoaded() {
        let node = FileNode(
            id: URL(fileURLWithPath: "/tmp/file.txt"),
            name: "file.txt",
            isDirectory: false,
            children: nil,
            childrenLoadState: .loaded
        )
        #expect(node.childrenLoadState == .loaded)
        #expect(node.isDirectory == false)
    }

    // MARK: - Hashable / Equatable (ID 驱动)

    @Test func twoNodesWithSameURLAreEqual() {
        let url = URL(fileURLWithPath: "/tmp/dir")
        let a = FileNode(id: url, name: "dir", isDirectory: true, children: nil, childrenLoadState: .notLoaded)
        let b = FileNode(id: url, name: "dir", isDirectory: true, children: [], childrenLoadState: .loaded)
        // FileNode.Hashable 由 id 驱动，childrenLoadState 不影响等价性
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }
}
```

### Step 2: 运行测试，确认编译错误

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-p1-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/FileNodeLazyLoadTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：编译错误，类似 `extra argument 'childrenLoadState' in call` 或 `type 'FileNode' has no member 'childrenLoadState'`。

### Step 3: 修改 `FileNode.swift` — 新增 `childrenLoadState`

将 `agentGui/Models/FileNode.swift` 替换为：

```swift
import Foundation

struct FileNode: Identifiable, Hashable {
    let id: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?

    /// 目录加载状态。文件节点固定为 `.loaded`，目录节点初次构建时为 `.notLoaded`，
    /// 扫描完成后为 `.loaded`。
    enum ChildrenLoadState: Hashable {
        case notLoaded  // 目录，尚未扫描子项
        case loaded     // 已扫描（children 反映真实状态，可能为空 []）
    }
    var childrenLoadState: ChildrenLoadState

    // MARK: - 便捷初始化（保持向后兼容，childrenLoadState 有默认值）

    init(id: URL, name: String, isDirectory: Bool, children: [FileNode]?, childrenLoadState: ChildrenLoadState = .loaded) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
        self.childrenLoadState = childrenLoadState
    }
}

// MARK: - Hashable：仅由 id（URL）决定，childrenLoadState 不参与哈希/等价判断
// 这与 NSOutlineView 通过 id 追踪节点状态的方式一致。
extension FileNode {
    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension FileNode {
    var optionalChildren: [FileNode]? {
        guard isDirectory else { return nil }
        return children
    }
}
```

> **设计说明**：`childrenLoadState` 默认为 `.loaded`，使所有现有调用站（`FileNode(id:name:isDirectory:children:)`）无需修改即可编译通过。`Hashable` 与 `Equatable` 仅由 `id` 驱动——这与 NSOutlineView 按对象标识追踪展开节点的行为一致，也确保 "内容相同但加载状态不同的两个节点" 在树中被视为同一节点。

### Step 4: 运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-p1-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/FileNodeLazyLoadTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|passed|failed"
```

期望：所有 4 个测试 PASS。

### Step 5: Commit

```
git add agentGui/Models/FileNode.swift agentGuiTests/FileNodeLazyLoadTests.swift
git commit -m "ft-p1: add childrenLoadState to FileNode"
```

---

## Task FT-P1-T2：`WorkspaceTreeSnapshotOps` — 浅扫描与按需加载支持

**目的**：
1. 新增 `buildNodesShallow(at:)` — 只扫描 1 层，子目录标记为 `.notLoaded`。
2. 修复 `mergeNodes` — 新出现的目录不再递归扫描，改为 `.notLoaded`。
3. 修复 `applyPartialUpdate` — 跳过 `.notLoaded` 目录内的路径（未展开则不更新）。
4. 新增 `replaceNode(in:id:transform:)` — 在树中找到指定 URL 的节点并替换（供 `demandLoad` 使用）。

**Files:**
- Modify: `agentGui/Utilities/WorkspaceTreeRefreshCoordinator.swift`（`WorkspaceTreeSnapshotOps` 部分）
- Create: `agentGuiTests/WorkspaceTreeLazyLoadSnapshotOpsTests.swift`

---

### Step 1: 新建测试文件，写失败断言

新建 `agentGuiTests/WorkspaceTreeLazyLoadSnapshotOpsTests.swift`：

```swift
import Foundation
import Testing
@testable import agentGui

struct WorkspaceTreeLazyLoadSnapshotOpsTests {

    // MARK: - buildNodesShallow

    @Test func buildNodesShallowMarksSubdirectoriesAsNotLoaded() throws {
        // 准备：创建临时目录结构
        //   tmpRoot/
        //     file.txt
        //     subdir/
        //       nested.txt  ← 不应被扫描
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-p1-shallow-\(Int.random(in: 1000...9999))")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let fileURL = tmpRoot.appendingPathComponent("file.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let subdirURL = tmpRoot.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
        let nestedURL = subdirURL.appendingPathComponent("nested.txt")
        try "nested".write(to: nestedURL, atomically: true, encoding: .utf8)

        // 执行
        let nodes = WorkspaceTreeSnapshotOps.buildNodesShallow(at: tmpRoot)

        // 断言：应扫到 2 个节点（subdir + file.txt）
        #expect(nodes.count == 2)

        let dirNode = nodes.first(where: { $0.isDirectory })
        #expect(dirNode != nil)
        #expect(dirNode?.childrenLoadState == .notLoaded)
        // 关键：子目录的 children 应为 nil（未扫描），而非包含 nested.txt
        #expect(dirNode?.children == nil)

        let fileNode = nodes.first(where: { !$0.isDirectory })
        #expect(fileNode != nil)
        #expect(fileNode?.childrenLoadState == .loaded)
    }

    // MARK: - mergeNodes — 新目录不触发递归扫描

    @Test func mergeNodesCreatesNotLoadedNodeForNewDirectory() throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-p1-merge-\(Int.random(in: 1000...9999))")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        // 新目录（existing 中不存在）
        let newDirURL = tmpRoot.appendingPathComponent("newdir")
        try FileManager.default.createDirectory(at: newDirURL, withIntermediateDirectories: true)
        try "file".write(to: newDirURL.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)

        let freshScan: [WorkspaceTreeShallowEntry] = [
            (name: "newdir", url: newDirURL, isDirectory: true)
        ]
        let existing: [FileNode] = []

        let merged = WorkspaceTreeSnapshotOps.mergeNodes(existing: existing, freshScan: freshScan)

        #expect(merged.count == 1)
        let dirNode = merged[0]
        #expect(dirNode.isDirectory == true)
        // 新目录应被标记为 .notLoaded，child.txt 不应出现在 children 中
        #expect(dirNode.childrenLoadState == .notLoaded)
        #expect(dirNode.children == nil)
    }

    @Test func mergeNodesPreservesLoadedStateForExistingNode() {
        let url = URL(fileURLWithPath: "/tmp/existing-dir")
        let child = FileNode(id: url.appendingPathComponent("file.txt"), name: "file.txt", isDirectory: false, children: nil)
        let existingNode = FileNode(id: url, name: "existing-dir", isDirectory: true, children: [child], childrenLoadState: .loaded)

        let freshScan: [WorkspaceTreeShallowEntry] = [
            (name: "existing-dir", url: url, isDirectory: true)
        ]

        let merged = WorkspaceTreeSnapshotOps.mergeNodes(existing: [existingNode], freshScan: freshScan)

        #expect(merged.count == 1)
        // 已加载的节点（含其 children）应被完整保留
        #expect(merged[0].childrenLoadState == .loaded)
        #expect(merged[0].children?.count == 1)
    }

    // MARK: - applyPartialUpdate — 跳过 notLoaded 节点

    @Test func applyPartialUpdateSkipsNotLoadedDirectory() {
        // 树结构：root/ → notLoadedDir/ （.notLoaded）
        // FSEvent 来自 notLoadedDir 内部
        let rootURL = URL(fileURLWithPath: "/tmp/root")
        let notLoadedURL = rootURL.appendingPathComponent("notLoadedDir")
        let deepURL = notLoadedURL.appendingPathComponent("deep.txt")

        let notLoadedNode = FileNode(id: notLoadedURL, name: "notLoadedDir", isDirectory: true, children: nil, childrenLoadState: .notLoaded)
        let rootNodes = [notLoadedNode]

        let updated = WorkspaceTreeSnapshotOps.applyPartialUpdate(to: rootNodes, at: deepURL.deletingLastPathComponent())

        // notLoaded 节点不应被修改
        #expect(updated[0].childrenLoadState == .notLoaded)
        #expect(updated[0].children == nil)
    }

    // MARK: - replaceNode

    @Test func replaceNodeUpdatesTargetInFlatTree() {
        let url = URL(fileURLWithPath: "/tmp/dir")
        let original = FileNode(id: url, name: "dir", isDirectory: true, children: nil, childrenLoadState: .notLoaded)

        let loaded = FileNode(id: url, name: "dir", isDirectory: true, children: [], childrenLoadState: .loaded)
        let updated = WorkspaceTreeSnapshotOps.replaceNode(in: [original], id: url) { _ in loaded }

        #expect(updated[0].childrenLoadState == .loaded)
    }

    @Test func replaceNodeUpdatesTargetInNestedTree() {
        let rootURL = URL(fileURLWithPath: "/tmp/root")
        let nestedURL = rootURL.appendingPathComponent("nested")

        let nested = FileNode(id: nestedURL, name: "nested", isDirectory: true, children: nil, childrenLoadState: .notLoaded)
        let root = FileNode(id: rootURL, name: "root", isDirectory: true, children: [nested], childrenLoadState: .loaded)

        let loadedNested = FileNode(id: nestedURL, name: "nested", isDirectory: true, children: [], childrenLoadState: .loaded)
        let updated = WorkspaceTreeSnapshotOps.replaceNode(in: [root], id: nestedURL) { _ in loadedNested }

        #expect(updated[0].children?[0].childrenLoadState == .loaded)
    }
}
```

### Step 2: 运行测试，确认编译错误（缺少新方法）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-p1-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/WorkspaceTreeLazyLoadSnapshotOpsTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：编译错误，提示 `buildNodesShallow`、`replaceNode` 不存在。

### Step 3: 在 `WorkspaceTreeSnapshotOps` 中实现新方法

在 `WorkspaceTreeRefreshCoordinator.swift` 的 `enum WorkspaceTreeSnapshotOps` 中进行以下修改：

**3a. 新增 `buildNodesShallow`（紧接现有 `buildNodes` 之后）：**

```swift
/// 浅扫描：只扫描 1 层，子目录标记为 .notLoaded，不递归。
/// 初始加载和按需加载的"扫描该目录 1 层"逻辑均由此方法驱动。
static func buildNodesShallow(at url: URL) -> [FileNode] {
    shallowScan(at: url).map { entry in
        if entry.isDirectory {
            return FileNode(
                id: entry.url,
                name: entry.name,
                isDirectory: true,
                children: nil,
                childrenLoadState: .notLoaded
            )
        }
        return FileNode(id: entry.url, name: entry.name, isDirectory: false, children: nil)
    }
}
```

**3b. 修改 `mergeNodes` — 新目录不再递归扫描：**

将 `mergeNodes` 中的：

```swift
        if item.isDirectory {
            let children = buildNodes(at: item.url, depth: 0)
            return FileNode(id: item.url, name: item.name, isDirectory: true, children: children)
        }
```

替换为：

```swift
        if item.isDirectory {
            // 新出现的目录标记为 .notLoaded，等待用户展开时按需扫描。
            // 不调用 buildNodes 以避免递归扫描带来的卡顿。
            return FileNode(id: item.url, name: item.name, isDirectory: true, children: nil, childrenLoadState: .notLoaded)
        }
```

**3c. 修改 `applyPartialUpdate` — 跳过 `.notLoaded` 目录：**

将 `applyPartialUpdate` 中对子目录递归的分支：

```swift
            if targetPath.hasPrefix(nodePath + "/") {
                let updatedChildren = applyPartialUpdate(to: node.children ?? [], at: targetURL)
                return FileNode(id: node.id, name: node.name, isDirectory: true, children: updatedChildren)
            }
```

替换为：

```swift
            if targetPath.hasPrefix(nodePath + "/") {
                // 尚未加载的目录：FSEvent 到来时无需更新，用户展开时会触发按需扫描。
                if node.childrenLoadState == .notLoaded {
                    return node
                }
                let updatedChildren = applyPartialUpdate(to: node.children ?? [], at: targetURL)
                return FileNode(id: node.id, name: node.name, isDirectory: true, children: updatedChildren, childrenLoadState: node.childrenLoadState)
            }
```

同时将 `applyPartialUpdate` 中的目标节点刷新分支：

```swift
            if nodePath == targetPath {
                let freshScan = shallowScan(at: node.id)
                let mergedNodes = mergeNodes(existing: node.children ?? [], freshScan: freshScan)
                return FileNode(id: node.id, name: node.name, isDirectory: true, children: mergedNodes)
            }
```

替换为（补充 `childrenLoadState: .loaded`）：

```swift
            if nodePath == targetPath {
                let freshScan = shallowScan(at: node.id)
                let mergedNodes = mergeNodes(existing: node.children ?? [], freshScan: freshScan)
                return FileNode(id: node.id, name: node.name, isDirectory: true, children: mergedNodes, childrenLoadState: .loaded)
            }
```

**3d. 新增 `replaceNode(in:id:transform:)`（在 `private static func filter` 之前）：**

```swift
/// 在树中递归找到 id 匹配的节点，用 transform 的返回值替换它。
/// 若树中不存在该 id，返回原树不变。
/// 只遍历 childrenLoadState == .loaded 的目录。
static func replaceNode(in nodes: [FileNode], id: URL, transform: (FileNode) -> FileNode) -> [FileNode] {
    let targetPath = id.standardizedFileURL.path
    return nodes.map { node in
        let nodePath = node.id.standardizedFileURL.path
        if nodePath == targetPath {
            return transform(node)
        }
        guard node.isDirectory, node.childrenLoadState == .loaded, let children = node.children else {
            return node
        }
        let updatedChildren = replaceNode(in: children, id: id, transform: transform)
        return FileNode(id: node.id, name: node.name, isDirectory: true, children: updatedChildren, childrenLoadState: .loaded)
    }
}
```

### Step 4: 运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-p1-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/WorkspaceTreeLazyLoadSnapshotOpsTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|passed|failed"
```

期望：所有 6 个测试 PASS。

### Step 5: Commit

```
git add agentGui/Utilities/WorkspaceTreeRefreshCoordinator.swift \
        agentGuiTests/WorkspaceTreeLazyLoadSnapshotOpsTests.swift
git commit -m "ft-p1: add buildNodesShallow, replaceNode; fix mergeNodes/applyPartialUpdate for lazy load"
```

---

## Task FT-P1-T3：`WorkspaceTreeRefreshCoordinator` — 使用浅扫描 + `demandLoad`

**目的**：
1. 将初始加载（`scheduleFullReload`）从 `buildNodes`（递归）换为 `buildNodesShallow`（1 层）。
2. 新增 `demandLoad(directoryID:)` 公开方法：扫描指定目录的 1 层，更新树中对应节点，触发 `onNodesChanged`。

**Files:**
- Modify: `agentGui/Utilities/WorkspaceTreeRefreshCoordinator.swift`（协调器主体部分）
- Create: `agentGuiTests/WorkspaceTreeDemandLoadCoordinatorTests.swift`

---

### Step 1: 新建测试文件，写失败断言

新建 `agentGuiTests/WorkspaceTreeDemandLoadCoordinatorTests.swift`：

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct WorkspaceTreeDemandLoadCoordinatorTests {

    // MARK: - 初始加载：根目录只有 1 层，子目录为 .notLoaded

    @Test func initialLoadOnlyScansOneLevel() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-p1-coord-\(Int.random(in: 1000...9999))")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        // 创建：root/file.txt 和 root/subdir/nested.txt
        try "root".write(to: tmpRoot.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let subdirURL = tmpRoot.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
        try "nested".write(to: subdirURL.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)

        var receivedNodes: [FileNode] = []
        let coordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: .init { _, _ in nil },  // 禁用 FSEvent 监听
            buildNodes: { url in WorkspaceTreeSnapshotOps.buildNodesShallow(at: url) }
        )
        coordinator.onNodesChanged = { nodes, _ in receivedNodes = nodes }

        coordinator.setDirectory(tmpRoot)

        // 等待异步扫描完成
        try await Task.sleep(nanoseconds: 300_000_000)

        // 应扫到 2 个节点（subdir + file.txt），subdir 为 .notLoaded
        #expect(receivedNodes.count == 2)
        let subdirNode = receivedNodes.first(where: { $0.isDirectory })
        #expect(subdirNode?.childrenLoadState == .notLoaded)
        #expect(subdirNode?.children == nil)
    }

    // MARK: - demandLoad：展开后子节点出现

    @Test func demandLoadExpandsNotLoadedDirectory() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-p1-demand-\(Int.random(in: 1000...9999))")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let subdirURL = tmpRoot.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
        try "child".write(to: subdirURL.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)

        var receivedNodes: [FileNode] = []
        let coordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: .init { _, _ in nil },
            buildNodes: { url in WorkspaceTreeSnapshotOps.buildNodesShallow(at: url) }
        )
        coordinator.onNodesChanged = { nodes, _ in receivedNodes = nodes }

        coordinator.setDirectory(tmpRoot)
        try await Task.sleep(nanoseconds: 300_000_000)

        // 初始：subdir 为 .notLoaded
        let notLoadedNode = receivedNodes.first(where: { $0.isDirectory })
        #expect(notLoadedNode?.childrenLoadState == .notLoaded)

        // 触发按需加载
        coordinator.demandLoad(directoryID: subdirURL)
        try await Task.sleep(nanoseconds: 300_000_000)

        // demandLoad 后：subdir 应变为 .loaded，且包含 child.txt
        let loadedNode = receivedNodes.first(where: { $0.isDirectory })
        #expect(loadedNode?.childrenLoadState == .loaded)
        #expect(loadedNode?.children?.count == 1)
        #expect(loadedNode?.children?.first?.name == "child.txt")
    }

    // MARK: - demandLoad：对已加载节点无副作用

    @Test func demandLoadOnAlreadyLoadedNodeIsNoop() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-p1-noop-\(Int.random(in: 1000...9999))")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let subdirURL = tmpRoot.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
        try "child".write(to: subdirURL.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)

        var callCount = 0
        let coordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: .init { _, _ in nil },
            buildNodes: { url in WorkspaceTreeSnapshotOps.buildNodesShallow(at: url) }
        )
        coordinator.onNodesChanged = { _, _ in callCount += 1 }

        coordinator.setDirectory(tmpRoot)
        try await Task.sleep(nanoseconds: 300_000_000)
        coordinator.demandLoad(directoryID: subdirURL)
        try await Task.sleep(nanoseconds: 300_000_000)

        let countAfterFirstLoad = callCount

        // 再次 demandLoad 同一目录（此时已是 .loaded）
        coordinator.demandLoad(directoryID: subdirURL)
        try await Task.sleep(nanoseconds: 300_000_000)

        // onNodesChanged 会被再次调用（更新内容），但不应崩溃或出错
        // 子项数量应保持一致
        #expect(callCount >= countAfterFirstLoad)
    }
}
```

### Step 2: 运行测试，确认编译错误（缺少 `demandLoad`）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-p1-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/WorkspaceTreeDemandLoadCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：编译错误，提示 `'WorkspaceTreeRefreshCoordinator' has no member 'demandLoad'`。

### Step 3: 修改协调器

**3a. 修改 `scheduleFullReload`：从 `buildNodesClosure` 改为 `buildNodesShallow` 直调**

在 `WorkspaceTreeRefreshCoordinator` 的 `scheduleFullReload` 中，将：

```swift
    private func scheduleFullReload(for url: URL, generation: Int) {
        let buildNodes = buildNodesClosure
        scanTask?.cancel()
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let nodes = await buildNodes(url)
```

替换为：

```swift
    private func scheduleFullReload(for url: URL, generation: Int) {
        scanTask?.cancel()
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let nodes = await WorkspaceTreeSnapshotOps.buildNodesShallow(at: url)
```

> **注意**：`buildNodesClosure` 参数在 `init` 中仍保留（供测试注入），但默认实现改为调用 `buildNodesShallow`。检查 `init` 的默认实现：
>
> ```swift
> buildNodes: @escaping @Sendable (URL) async -> [FileNode] = { url in
>     WorkspaceTreeSnapshotOps.buildNodesShallow(at: url)
> },
> ```
>
> 将原来的 `WorkspaceTreeSnapshotOps.buildNodes(at: url, depth: 0)` 修改为 `WorkspaceTreeSnapshotOps.buildNodesShallow(at: url)`。

**3b. 在 `WorkspaceTreeRefreshCoordinator` 中新增 `demandLoad(directoryID:)`（紧接 `refreshDirectories` 之后）：**

```swift
    /// 按需加载指定目录的 1 层子项。
    /// 当 NSOutlineView 展开一个 .notLoaded 目录时，由 ViewModel 调用此方法。
    /// 扫描完成后通过 onNodesChanged 推送更新。
    func demandLoad(directoryID: URL) {
        let targetURL = directoryID.standardizedFileURL
        let snapshot = currentNodes
        let generation = self.generation
        let shallowScan = shallowScanClosure

        scanTask?.cancel()
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }

            // 扫描目标目录的 1 层子项
            let freshEntries = await shallowScan(targetURL)
            let freshChildren: [FileNode] = freshEntries.map { entry in
                if entry.isDirectory {
                    return FileNode(id: entry.url, name: entry.name, isDirectory: true, children: nil, childrenLoadState: .notLoaded)
                }
                return FileNode(id: entry.url, name: entry.name, isDirectory: false, children: nil)
            }

            guard !Task.isCancelled else { return }

            // 在树中找到目标节点并替换为 .loaded 状态
            let updated = WorkspaceTreeSnapshotOps.replaceNode(in: snapshot, id: targetURL) { node in
                FileNode(id: node.id, name: node.name, isDirectory: true, children: freshChildren, childrenLoadState: .loaded)
            }

            await MainActor.run {
                guard let self, self.generation == generation else { return }
                self.currentNodes = updated
                self.onNodesChanged?(updated, false)
            }
        }
    }
```

### Step 4: 运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-p1-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/WorkspaceTreeDemandLoadCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|passed|failed"
```

期望：所有 3 个测试 PASS。

### Step 5: 运行全部 FT-P1 测试（回归验证）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-p1-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/FileNodeLazyLoadTests \
  -only-testing:agentGuiTests/WorkspaceTreeLazyLoadSnapshotOpsTests \
  -only-testing:agentGuiTests/WorkspaceTreeDemandLoadCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|passed|failed"
```

期望：3 个测试套件全部通过，无失败。

### Step 6: Commit

```
git add agentGui/Utilities/WorkspaceTreeRefreshCoordinator.swift \
        agentGuiTests/WorkspaceTreeDemandLoadCoordinatorTests.swift
git commit -m "ft-p1: coordinator uses shallow initial load, adds demandLoad(directoryID:)"
```

---

## Task FT-P1-T4：`WorkspaceTreeOutlineView` — DataSource 懒加载 + 展开触发

**目的**：更新 NSOutlineView DataSource 方法，使 `.notLoaded` 目录：
1. 显示展开三角（`isItemExpandable` / `shouldShowOutlineCellForItem`）。
2. 展开时行数为 0（无占位行），触发按需加载回调。
3. `outlineViewItemDidExpand` 时若节点为 `.notLoaded`，调用 `onDemandLoadDirectory`。

**Files:**
- Modify: `agentGui/Views/WorkspaceTree/WorkspaceTreeOutlineView.swift`

> **注意**：本任务是 UI / AppKit 层，没有对应单元测试。行为验证通过"在模拟器中打开大型目录"手动测试完成（见 Step 3）。

---

### Step 1: 修改 `WorkspaceTreeOutlineView` 结构体 — 新增 `onDemandLoadDirectory` 回调

在 `WorkspaceTreeOutlineView` 的属性列表中，在 `actions: ActionHandlers` 之后新增：

```swift
    let onDemandLoadDirectory: ((URL) -> Void)?
```

同时在 `makeNSView` 和 `updateNSView` 中不需要额外处理（回调通过 `parent` 透传到 `Coordinator`）。

### Step 2: 修改 `Coordinator` 的四个关键 DataSource/Delegate 方法

**2a. `isItemExpandable` — `.notLoaded` 目录始终可展开：**

将：

```swift
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = fileNode(from: item) else { return false }
            return node.isDirectory && !(node.children ?? []).isEmpty
        }
```

替换为：

```swift
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = fileNode(from: item) else { return false }
            guard node.isDirectory else { return false }
            // .notLoaded 目录：内容未知，显示展开三角（与 VSCode ExplorerItem.hasChildren() 一致）
            if node.childrenLoadState == .notLoaded { return true }
            return !(node.children ?? []).isEmpty
        }
```

**2b. `shouldShowOutlineCellForItem` — 同步修改：**

将：

```swift
        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            guard let node = fileNode(from: item) else { return false }
            return node.isDirectory && !(node.children ?? []).isEmpty
        }
```

替换为：

```swift
        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            guard let node = fileNode(from: item) else { return false }
            guard node.isDirectory else { return false }
            if node.childrenLoadState == .notLoaded { return true }
            return !(node.children ?? []).isEmpty
        }
```

**2c. `outlineViewItemDidExpand` — 触发按需加载：**

将：

```swift
        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
            expandedIDs.insert(node.id.standardizedFileURL)
        }
```

替换为：

```swift
        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
            expandedIDs.insert(node.id.standardizedFileURL)
            // 若该目录尚未加载，触发按需扫描
            if node.childrenLoadState == .notLoaded {
                parent.onDemandLoadDirectory?(node.id.standardizedFileURL)
            }
        }
```

### Step 3: 手动验证（可选 Smoke Test）

在 Xcode 中运行 app，打开一个包含多级子目录的工作区（如 agentGui 自身），观察：
- 文件树应在 < 200ms 内显示根目录的 1 层内容
- 点击子目录展开三角 → 短暂无子项（< 300ms）→ 子项出现
- 再次展开同一目录 → 立即显示（已加载的 `.loaded` 状态）
- 展开后关闭工作区再重新打开 → 重新触发浅扫描（符合预期）

### Step 4: Commit

```
git add agentGui/Views/WorkspaceTree/WorkspaceTreeOutlineView.swift
git commit -m "ft-p1: OutlineView DataSource supports .notLoaded expand + onDemandLoadDirectory"
```

---

## Task FT-P1-T5：`WorkspaceTreeViewModel` — 路由 `demandLoad`

**目的**：将 `onDemandLoadDirectory` 回调从 OutlineView 路由到 `WorkspaceTreeRefreshCoordinator.demandLoad(directoryID:)`，完成端到端的懒加载闭环。

**Files:**
- Modify: `agentGui/ViewModels/WorkspaceTreeViewModel.swift`
- Modify: `agentGui/Views/WorkspacePanelView.swift`（或调用 `WorkspaceTreeOutlineView` 的父视图）

---

### Step 1: 在 `WorkspaceTreeViewModel` 中新增 `demandLoad` 方法

在 `WorkspaceTreeViewModel` 的公开方法区域新增：

```swift
    func demandLoadDirectory(_ url: URL) {
        refreshCoordinator.demandLoad(directoryID: url)
    }
```

### Step 2: 找到 `WorkspaceTreeOutlineView` 的构造位置

用以下搜索定位：

```bash
grep -rn "WorkspaceTreeOutlineView(" \
  /Volumes/T7/文稿/Projects/agentGui/agentGui/ 2>/dev/null
```

在找到的父视图中，将 `WorkspaceTreeOutlineView` 的初始化调用补充 `onDemandLoadDirectory` 参数：

```swift
WorkspaceTreeOutlineView(
    nodes: viewModel.filteredNodes,
    selectionIDs: viewModel.selectedTreeNodeIDs,
    primarySelectionID: viewModel.primarySelectionID,
    inlineEdit: viewModel.inlineEdit,
    expandsMatchingBranches: viewModel.treeSearchText.isEmpty == false,
    gitChangeProvider: viewModel.gitChangeProvider,
    onSelectionChange: { ids, primary in viewModel.setSelection(ids: ids, primary: primary) },
    actions: viewModel.actionHandlers,
    onDemandLoadDirectory: { url in viewModel.demandLoadDirectory(url) }  // ← 新增
)
```

### Step 3: 编译确认无错误

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-p1-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

期望：`BUILD SUCCEEDED`，无 error。

### Step 4: 运行全部 FT-P1 单元测试（最终验收）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-p1-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/FileNodeLazyLoadTests \
  -only-testing:agentGuiTests/WorkspaceTreeLazyLoadSnapshotOpsTests \
  -only-testing:agentGuiTests/WorkspaceTreeDemandLoadCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|passed|failed"
```

期望：13 个测试全部 PASS。

### Step 5: Smoke 回归（现有测试不应退化）

如果项目有现有的文件树相关测试，在此处运行确认不退化。同时可运行 Quality Smoke：

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-p1-derived \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite.*started|passed|failed" | tail -20
```

### Step 6: Final Commit

```
git add agentGui/ViewModels/WorkspaceTreeViewModel.swift
git add agentGui/Views/  # 包含父视图文件
git commit -m "ft-p1: wire demandLoad through ViewModel, complete lazy directory load"
```

---

## 边界情况与已知约束

### 1. `buildNodes` 在现有代码中的其他调用

`WorkspaceTreeSnapshotOps.buildNodes(at:depth:)` 仍留在代码中，供 `applyPartialUpdate` 内的 `mergeNodes` 路径使用。在 FT-P1 范围内无需删除它。如后续发现其他引用仍在递归扫描，按需修改。

### 2. FSEvent 到 `.notLoaded` 目录内部的路径

`applyPartialUpdate` 已在 Task T2 中更新，跳过 `.notLoaded` 目录。这意味着：若用户未展开某目录，该目录内发生的文件变化不会主动更新到树中。这是**预期行为**——待用户展开时，`demandLoad` 会拿到最新文件系统状态。

### 3. 搜索（`filterNodes`）与 `.notLoaded` 目录

`WorkspaceTreeSnapshotOps.filterNodes` 遍历 `node.children ?? []`，对 `.notLoaded` 目录（`children == nil`）的行为与"空目录"一致——搜索不展示其内容。这是 Filter 模式的当前行为，不在本 Feature 范围内改变（FT-U4 会引入 Highlight 模式来解决）。

### 4. `demandLoad` 与 `scanTask` 竞争

`demandLoad` 与 `refreshDirectories` 共享 `scanTask`（后来的任务取消前一个）。在大型项目中快速展开多个目录时，只有最后一个展开操作的扫描会完成。可以在后续迭代中为每个目录维护独立的 `scanTask`，当前阶段不在范围内。

### 5. 不影响 VoiceOver

`isItemExpandable` 基于 `childrenLoadState` 返回 `true` 时，VoiceOver 会将目录朗读为"可展开"，这与 `.loaded` 的目录行为一致，无障碍体验不退化。

---

## 成功指标

| 指标 | 方法 | 目标 |
|---|---|---|
| 首次加载时间（50,000 文件工作区） | 在 linux kernel 或类似大型 monorepo 上计时 | < 200ms |
| 单元测试通过率 | FT-P1 专用测试套件 | 13/13 |
| 现有测试退化 | 全量 test suite | 0 new failures |
| 内存占用（50,000 文件工作区，全折叠） | Xcode Memory Debugger | < 50MB（仅根目录节点） |

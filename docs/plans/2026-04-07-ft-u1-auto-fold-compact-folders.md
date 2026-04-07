# FT-U1：Auto-fold（单子目录压缩显示）实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 `src/main/java/com/example/` 这类单子目录链在文件树中压缩为一个节点显示
"src / main / java / com / example"，降低嵌套路径的视觉噪音，模拟 VSCode `explorer.compactFolders`。

**Architecture:** 三层变更——① `FileNode` 新增 `foldedSegments: [String]`（各段名称）和 `foldedTerminalURL: URL?`（链尾真实目录），`id` 保持为链头 URL 以兼容现有 FSEvent 路由；② `WorkspaceTreeSnapshotOps` 新增 `compactSingleChildChain(startingAt:)` 工具函数和 `findNode(in:id:)` 辅助函数，`buildNodesShallow` 接受 `compactFolders: Bool` 参数在初始加载时自动压缩；③ `WorkspaceTreeRefreshCoordinator.demandLoad` 在执行前用 `findNode` 从快照中取出 `foldedTerminalURL`，将实际扫描目标改为链尾目录，同时对新扫到的子目录也应用折叠逻辑。`WorkspaceTreeRowContent` 检测到 `foldedSegments.count > 1` 时以带灰色"/"分隔符的分段样式渲染；`AppSettings` 新增 `compactFolders: Bool = true` 持久化开关。现有 `onDemandLoadDirectory` 回调签名**不变**，FSEvent 链路**不变**。

**Tech Stack:** Swift 6.0+, AppKit NSOutlineView, SwiftData `@Model`, Swift Testing (`import Testing`), `@testable import agentGui`

---

## 调研参考：VSCode 与 Zed 的 Auto-fold 设计

### VSCode — `ExplorerCompressionDelegate`

来源：`src/vs/workbench/contrib/files/browser/views/explorerViewer.ts`

```ts
// isIncompressible：以下情况节点不可被压缩
function isIncompressible(stat: ExplorerItem): boolean {
  return !stat.isDirectory              // 文件不压缩
    || stat.isRoot                       // 根节点不压缩
    || stat.children.size > 1           // 多子项目录不压缩
    || stat.children.size === 0         // 空目录不压缩
    || stat.isSymbolicLink              // 符号链接不压缩
    || stat.name === '.'               // 当前目录
    || stat.children.values().every(c => !c.isDirectory); // 所有子项均为文件
}
```

- `CompressibleObjectTree` 使用 `CompressedObjectTreeModel` 跟踪每条压缩链。
- 压缩链中最后（最深）的节点作为树节点 ID（`stat.resource`），中间节点存入 `compressedNodes` 数组。
- "a / b / c" 通过 `CompressedNavigationController` 实现各段点击可导航。
- **VSCode 的 ID 策略**：使用最深（innermost）节点 URI。

### Zed — `FoldedAncestors`

来源：`crates/project_panel/src/project_panel.rs`

```rust
// fold_point：在单子目录链中找到可折叠到的最深点
fn fold_point(entry: &Entry, snapshot: &Snapshot) -> Option<ProjectEntryId> {
    let children: Vec<_> = snapshot.child_entries(entry.id).collect();
    if children.len() == 1 && children[0].kind == EntryKind::Dir {
        Some(children[0].id)
    } else {
        None
    }
}
```

- `folds: HashMap<ProjectEntryId, Vec<String>>` — 折叠根 ID 映射到段名称列表。
- 渲染时若 entry 在 folds 中，显示 `"aaa / bbb / ccc"` 样式标签。
- 关键差异：Zed 使用**最外层**（outermost）节点 ID 作为代表，保留其在列表中的位置。
- **agentGui 选用 Zed 策略**：`id = 链头 URL`，兼容现有 FSEvent → `applyPartialUpdate` ID 匹配路径。

### agentGui 映射表

| VSCode / Zed 概念 | agentGui 对应 |
|---|---|
| `isIncompressible` 检测 | `compactSingleChildChain(startingAt:)` 返回 `nil` 表示不压缩 |
| 压缩链节点组 `[a, b, c]` | `foldedSegments: [String]` |
| innermost 节点（VSCode）/ outermost 节点（Zed）| `id = 链头 URL`；`foldedTerminalURL = 链尾 URL` |
| `Worktree.expand_entry` 扫链尾 | `demandLoad` 读 `foldedTerminalURL` 作为 `shallowScan` 目标 |
| `CompressedNavigationController` 段点击 | （FT-U1 简化版：整行点击展开，段点击导航留作后续） |

---

## 已知限制（初版可接受）

1. **FSEvent 结构破坏**：若通过终端在折叠链的中间目录（如 `src/main`）新增文件，导致链结构失效，该节点刷新需等到下次全量 reload（与 VSCode Explorer 一致）。
2. **新增目录不自动折叠**：FSEvent 触发 `mergeNodes` 新增的目录为 `.notLoaded`，未应用折叠，需展开一次 demandLoad 后才能体现折叠（可在 FT-P2 批量优化时一并处理）。
3. **VoiceOver 兼容**：初版不检测 `NSWorkspace.shared.isVoiceOverEnabled`，留作后续。

---

## 涉及文件概览

| 角色 | 文件 | 变更类型 |
|---|---|---|
| 模型 | `agentGui/Models/FileNode.swift` | 修改 — 新增 `foldedSegments`, `foldedTerminalURL` |
| 快照工具 | `agentGui/Utilities/WorkspaceTreeRefreshCoordinator.swift`（含 `WorkspaceTreeSnapshotOps`） | 修改 — 新增 `compactSingleChildChain`, `findNode`；修改 `buildNodesShallow`, `demandLoad`, `applyPartialUpdate` |
| 视图行 | `agentGui/Views/WorkspaceTree/WorkspaceTreeRowContent.swift` | 修改 — 折叠路径分段渲染 |
| 协调器属性 | `agentGui/Utilities/WorkspaceTreeRefreshCoordinator.swift` | 修改 — 新增 `compactFolders: Bool` |
| 设置模型 | `agentGui/Models/AppSettings.swift` | 修改 — 新增 `compactFolders: Bool` |
| ViewModel | `agentGui/ViewModels/WorkspaceTreeViewModel.swift` | 修改 — 新增 `compactFolders` 转发属性 |
| 面板视图 | `agentGui/Views/WorkspacePanelView.swift` | 修改 — 读取 `settings.compactFolders` 传入 ViewModel |
| 测试 | `agentGuiTests/FileNodeAutoFoldTests.swift` | 新建 |
| 测试 | `agentGuiTests/WorkspaceTreeAutoFoldSnapshotTests.swift` | 新建 |
| 测试 | `agentGuiTests/WorkspaceTreeAutoFoldDemandLoadTests.swift` | 新建 |

---

## 快速测试命令

每个任务完成后用以下命令运行本 Feature 的全部测试：

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-u1-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/FileNodeAutoFoldTests \
  -only-testing:agentGuiTests/WorkspaceTreeAutoFoldSnapshotTests \
  -only-testing:agentGuiTests/WorkspaceTreeAutoFoldDemandLoadTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|PASS|FAIL|passed|failed|error:"
```

---

## Task FT-U1-T1：`FileNode` 新增折叠字段

**目的**：为 `FileNode` 添加两个新属性以表达"压缩显示状态"，所有调用处保持向后兼容（两字段均有默认值）。

**Files:**
- Modify: `agentGui/Models/FileNode.swift`
- Create: `agentGuiTests/FileNodeAutoFoldTests.swift`

---

### Step 1: 新建测试文件，写失败断言

新建 `agentGuiTests/FileNodeAutoFoldTests.swift`：

```swift
import Testing
@testable import agentGui

struct FileNodeAutoFoldTests {

    // MARK: - 基础折叠字段

    @Test func nonFoldedNodeHasEmptySegments() {
        let node = FileNode(
            id: URL(fileURLWithPath: "/tmp/src"),
            name: "src",
            isDirectory: true,
            children: nil
        )
        #expect(node.foldedSegments.isEmpty)
        #expect(node.foldedTerminalURL == nil)
    }

    @Test func foldedNodeHasSegments() {
        let node = FileNode(
            id: URL(fileURLWithPath: "/tmp/src"),
            name: "src",
            isDirectory: true,
            children: nil,
            childrenLoadState: .notLoaded,
            foldedSegments: ["src", "main", "java"],
            foldedTerminalURL: URL(fileURLWithPath: "/tmp/src/main/java")
        )
        #expect(node.foldedSegments == ["src", "main", "java"])
        #expect(node.foldedTerminalURL?.path == "/tmp/src/main/java")
    }

    @Test func isFoldedReturnsTrueWhenSegmentsCountGT1() {
        let folded = FileNode(
            id: URL(fileURLWithPath: "/tmp/a"),
            name: "a",
            isDirectory: true,
            children: nil,
            foldedSegments: ["a", "b"],
            foldedTerminalURL: URL(fileURLWithPath: "/tmp/a/b")
        )
        let plain = FileNode(
            id: URL(fileURLWithPath: "/tmp/a"),
            name: "a",
            isDirectory: true,
            children: nil
        )
        #expect(folded.isFolded == true)
        #expect(plain.isFolded == false)
    }

    @Test func foldDisplayPathJoinsSegmentsWithSlash() {
        let node = FileNode(
            id: URL(fileURLWithPath: "/tmp/src"),
            name: "src",
            isDirectory: true,
            children: nil,
            foldedSegments: ["src", "main", "java"],
            foldedTerminalURL: URL(fileURLWithPath: "/tmp/src/main/java")
        )
        // "src / main / java"（两侧有空格的 /）
        #expect(node.foldDisplayPath == "src / main / java")
    }

    // MARK: - Hashable / Equatable 不受折叠字段影响

    @Test func hashableIgnoresFoldFields() {
        let url = URL(fileURLWithPath: "/tmp/src")
        let plain = FileNode(id: url, name: "src", isDirectory: true, children: nil)
        let folded = FileNode(
            id: url, name: "src", isDirectory: true, children: nil,
            foldedSegments: ["src", "main"], foldedTerminalURL: URL(fileURLWithPath: "/tmp/src/main")
        )
        #expect(plain == folded)
        #expect(plain.hashValue == folded.hashValue)
    }

    // MARK: - 默认值向后兼容（现有调用处不传新字段也能编译）

    @Test func legacyInitUsesDefaults() {
        // 使用旧签名（不传 foldedSegments / foldedTerminalURL）
        let node = FileNode(
            id: URL(fileURLWithPath: "/tmp/x"),
            name: "x",
            isDirectory: false,
            children: nil
        )
        #expect(node.foldedSegments.isEmpty)
        #expect(node.foldedTerminalURL == nil)
    }
}
```

### Step 2: 运行测试，确认编译错误

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-u1-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/FileNodeAutoFoldTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：编译失败，提示 `extra argument 'foldedSegments' in call` 或 `type 'FileNode' has no member 'foldedSegments'`。

### Step 3: 修改 `FileNode.swift`，新增折叠字段

在 `agentGui/Models/FileNode.swift` 中，在 `var childrenLoadState: ChildrenLoadState` 之后添加：

```swift
    // MARK: - Auto-fold (FT-U1)

    /// 折叠链各段名称。非空（count > 1）时表示该节点是一条压缩的单子目录链。
    /// 例如 src → src/main → src/main/java 压缩后为 ["src", "main", "java"]。
    /// 空数组表示普通目录节点。
    var foldedSegments: [String]

    /// 折叠链最内层目录的 URL，即实际存放子项的目录。
    /// 展开时 demandLoad 将扫描此 URL 而非 id（链头 URL）。
    var foldedTerminalURL: URL?
```

更新 `init` 签名，为新字段添加默认值：

```swift
    init(
        id: URL,
        name: String,
        isDirectory: Bool,
        children: [FileNode]?,
        childrenLoadState: ChildrenLoadState = .loaded,
        foldedSegments: [String] = [],
        foldedTerminalURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
        self.childrenLoadState = childrenLoadState
        self.foldedSegments = foldedSegments
        self.foldedTerminalURL = foldedTerminalURL
    }
```

在文件末尾的 `extension FileNode` 区域（`optionalChildren` 之后）追加以下计算属性：

```swift
extension FileNode {
    // MARK: - Auto-fold helpers (FT-U1)

    /// 是否为压缩折叠节点：foldedSegments 包含超过 1 个段。
    var isFolded: Bool {
        foldedSegments.count > 1
    }

    /// 折叠路径显示字符串，各段以" / "拼接。普通节点返回 `name`。
    var foldDisplayPath: String {
        isFolded ? foldedSegments.joined(separator: " / ") : name
    }
}
```

### Step 4: 运行测试，确认全部通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-u1-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/FileNodeAutoFoldTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:"
```

期望：`Test Suite ... passed`，0 failures。

### Step 5: 确认全量编译无回归

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

期望：`BUILD SUCCEEDED`。

### Step 6: 提交

```bash
git add agentGui/Models/FileNode.swift agentGuiTests/FileNodeAutoFoldTests.swift
git commit -m "ft-u1: FileNode add foldedSegments, foldedTerminalURL, isFolded, foldDisplayPath"
```

---

## Task FT-U1-T2：`WorkspaceTreeSnapshotOps` — 新增 `compactSingleChildChain` 和 `findNode`

**目的**：提供两个纯静态工具函数——① 沿单子目录链追踪直到非单子结构，返回段列表和链尾 URL；② 在节点树中按 ID 查找节点（用于 demandLoad 取出 `foldedTerminalURL`）。

**Files:**
- Modify: `agentGui/Utilities/WorkspaceTreeRefreshCoordinator.swift`（`WorkspaceTreeSnapshotOps` 部分）
- Create: `agentGuiTests/WorkspaceTreeAutoFoldSnapshotTests.swift`

---

### Step 1: 新建测试文件，写失败断言

新建 `agentGuiTests/WorkspaceTreeAutoFoldSnapshotTests.swift`：

```swift
import Foundation
import Testing
@testable import agentGui

struct WorkspaceTreeAutoFoldSnapshotTests {

    // MARK: - compactSingleChildChain

    /// 辅助：在 tmp 下创建目录结构
    private func makeTmpDir(_ suffix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-u1-snap-\(suffix)-\(Int.random(in: 1000...9999))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func singleChildChainFoldsCorrectly() throws {
        // 创建 root/a/b/c/（每层只有 1 个子目录）
        let root = try makeTmpDir("chain3")
        defer { try? FileManager.default.removeItem(at: root) }

        let a = root.appendingPathComponent("a")
        let b = a.appendingPathComponent("b")
        let c = b.appendingPathComponent("c")
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)

        let result = WorkspaceTreeSnapshotOps.compactSingleChildChain(startingAt: a)
        #expect(result != nil)
        #expect(result?.segments == ["a", "b", "c"])
        #expect(result?.terminalURL.standardizedFileURL == c.standardizedFileURL)
    }

    @Test func directoryWithMultipleChildrenNotFolded() throws {
        // 创建 root/a/（含 b/ 和 c/ 两个子目录）→ 不折叠
        let root = try makeTmpDir("multi")
        defer { try? FileManager.default.removeItem(at: root) }

        let a = root.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: a.appendingPathComponent("b"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: a.appendingPathComponent("c"), withIntermediateDirectories: true)

        let result = WorkspaceTreeSnapshotOps.compactSingleChildChain(startingAt: a)
        #expect(result == nil)
    }

    @Test func directoryWithFileChildNotFolded() throws {
        // 创建 root/a/ 含一个文件（而非目录）→ 不折叠
        let root = try makeTmpDir("filechild")
        defer { try? FileManager.default.removeItem(at: root) }

        let a = root.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try "hello".write(to: a.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let result = WorkspaceTreeSnapshotOps.compactSingleChildChain(startingAt: a)
        #expect(result == nil)
    }

    @Test func emptyDirectoryNotFolded() throws {
        // 创建空目录 root/a/ → 不折叠
        let root = try makeTmpDir("empty")
        defer { try? FileManager.default.removeItem(at: root) }

        let a = root.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)

        let result = WorkspaceTreeSnapshotOps.compactSingleChildChain(startingAt: a)
        #expect(result == nil)
    }

    @Test func chainStopsAtNonSingleChildDir() throws {
        // 创建 root/a/b/（b 含 c/ 和 d/ 两个子目录）→ 折叠到 b，segments = ["a","b"]
        let root = try makeTmpDir("stop")
        defer { try? FileManager.default.removeItem(at: root) }

        let a = root.appendingPathComponent("a")
        let b = a.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: b.appendingPathComponent("c"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b.appendingPathComponent("d"), withIntermediateDirectories: true)

        let result = WorkspaceTreeSnapshotOps.compactSingleChildChain(startingAt: a)
        #expect(result != nil)
        #expect(result?.segments == ["a", "b"])
        #expect(result?.terminalURL.standardizedFileURL == b.standardizedFileURL)
    }

    @Test func chainMixedWithFileInTerminalIsAllowed() throws {
        // a/ -> b/（b 含 file.txt 和 subdir/）→ b 有 2 个可见条目，链止于 b，segments = ["a","b"]
        let root = try makeTmpDir("mixterm")
        defer { try? FileManager.default.removeItem(at: root) }

        let a = root.appendingPathComponent("a")
        let b = a.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try "x".write(to: b.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: b.appendingPathComponent("sub"), withIntermediateDirectories: true)

        // b 有 2 条目 → 链止于 b
        let result = WorkspaceTreeSnapshotOps.compactSingleChildChain(startingAt: a)
        #expect(result?.segments == ["a", "b"])
        #expect(result?.terminalURL.standardizedFileURL == b.standardizedFileURL)
    }

    // MARK: - buildNodesShallow with compactFolders

    @Test func buildNodesShallowFoldsChain() throws {
        let root = try makeTmpDir("build")
        defer { try? FileManager.default.removeItem(at: root) }

        // src → src/main → src/main/java（链）
        let java = root.appendingPathComponent("src/main/java")
        try FileManager.default.createDirectory(at: java, withIntermediateDirectories: true)
        // 同级文件，不是链的一部分
        try "top".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let nodes = WorkspaceTreeSnapshotOps.buildNodesShallow(at: root, compactFolders: true)

        let srcNode = nodes.first(where: { $0.name == "src" })
        #expect(srcNode != nil)
        #expect(srcNode?.isFolded == true)
        #expect(srcNode?.foldedSegments == ["src", "main", "java"])
        #expect(srcNode?.foldedTerminalURL?.standardizedFileURL == java.standardizedFileURL)
        #expect(srcNode?.childrenLoadState == .notLoaded)
    }

    @Test func buildNodesShallowDisabledDoesNotFold() throws {
        let root = try makeTmpDir("nofold")
        defer { try? FileManager.default.removeItem(at: root) }

        let java = root.appendingPathComponent("src/main/java")
        try FileManager.default.createDirectory(at: java, withIntermediateDirectories: true)

        let nodes = WorkspaceTreeSnapshotOps.buildNodesShallow(at: root, compactFolders: false)

        let srcNode = nodes.first(where: { $0.name == "src" })
        #expect(srcNode?.isFolded == false)
        #expect(srcNode?.foldedSegments.isEmpty == true)
    }

    @Test func buildNodesShallowMultiChildDirNotFolded() throws {
        let root = try makeTmpDir("multi2")
        defer { try? FileManager.default.removeItem(at: root) }

        // src/（含 main/ 和 test/ 两个子目录）→ 不折叠
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("main"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("test"), withIntermediateDirectories: true)

        let nodes = WorkspaceTreeSnapshotOps.buildNodesShallow(at: root, compactFolders: true)
        let srcNode = nodes.first(where: { $0.name == "src" })
        #expect(srcNode?.isFolded == false)
    }

    // MARK: - findNode

    @Test func findNodeLocatesTopLevel() {
        let url = URL(fileURLWithPath: "/tmp/src")
        let node = FileNode(id: url, name: "src", isDirectory: true, children: nil)
        let tree = [node]

        let found = WorkspaceTreeSnapshotOps.findNode(in: tree, id: url)
        #expect(found?.id == url)
    }

    @Test func findNodeLocatesNested() {
        let childURL = URL(fileURLWithPath: "/tmp/src/main")
        let child = FileNode(id: childURL, name: "main", isDirectory: true, children: nil)
        let parent = FileNode(
            id: URL(fileURLWithPath: "/tmp/src"),
            name: "src",
            isDirectory: true,
            children: [child],
            childrenLoadState: .loaded
        )
        let tree = [parent]

        let found = WorkspaceTreeSnapshotOps.findNode(in: tree, id: childURL)
        #expect(found?.id == childURL)
    }

    @Test func findNodeReturnsNilForUnknownID() {
        let tree: [FileNode] = []
        let found = WorkspaceTreeSnapshotOps.findNode(in: tree, id: URL(fileURLWithPath: "/tmp/x"))
        #expect(found == nil)
    }
}
```

### Step 2: 运行测试，确认编译错误

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-u1-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/WorkspaceTreeAutoFoldSnapshotTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：编译失败，提示 `compactSingleChildChain`, `findNode` 不存在，`buildNodesShallow` 参数错误。

### Step 3: 在 `WorkspaceTreeSnapshotOps` 末尾新增两个工具函数

找到 `WorkspaceTreeRefreshCoordinator.swift` 中 `enum WorkspaceTreeSnapshotOps {` 区块，
在 `buildNodes(at:depth:)` 之后（`shouldIncludeInTree` 之前，或文件末尾均可）添加：

```swift
    // MARK: - FT-U1: Auto-fold 工具

    /// 从 `startURL` 沿单子目录链追踪，返回所有段名称和链尾 URL。
    ///
    /// 条件：该目录仅有一个可见子项，且该子项为目录。
    /// - 若链长度 == 1（`startURL` 自身无单子子目录）→ 返回 `nil`（不折叠）。
    /// - 若追踪链长度 >= 2 → 返回 `(segments, terminalURL)`。
    ///
    /// 性能：每步调用 `shallowScan`（I/O）。链深度通常 2–6，可接受。
    static func compactSingleChildChain(startingAt startURL: URL) -> (segments: [String], terminalURL: URL)? {
        var segments: [String] = [startURL.lastPathComponent]
        var current = startURL

        while true {
            let entries = shallowScan(at: current)
            // 可折叠条件：恰好 1 个可见条目，且该条目是目录
            guard entries.count == 1, let onlyChild = entries.first, onlyChild.isDirectory else {
                break
            }
            current = onlyChild.url
            segments.append(onlyChild.name)
        }

        guard segments.count > 1 else { return nil }
        return (segments: segments, terminalURL: current)
    }

    /// 在节点树中按 `id` 查找节点。
    /// 只递归进入 `childrenLoadState == .loaded` 的节点（未加载的子树不遍历）。
    /// 复杂度 O(已加载节点数)。
    static func findNode(in nodes: [FileNode], id: URL) -> FileNode? {
        let targetPath = id.standardizedFileURL.path
        for node in nodes {
            if node.id.standardizedFileURL.path == targetPath { return node }
            guard node.isDirectory,
                  node.childrenLoadState == .loaded,
                  let children = node.children else { continue }
            if let found = findNode(in: children, id: id) { return found }
        }
        return nil
    }
```

### Step 4: 修改 `buildNodesShallow` — 新增 `compactFolders` 参数

找到 `buildNodesShallow(at:)` 函数，替换整体实现：

```swift
    /// 浅扫描：只扫描 1 层，子目录标记为 .notLoaded，不递归。
    /// - `compactFolders`：若为 `true`，对单子目录链应用折叠压缩（FT-U1）。
    static func buildNodesShallow(at url: URL, compactFolders: Bool = true) -> [FileNode] {
        shallowScan(at: url).map { entry in
            if entry.isDirectory {
                if compactFolders,
                   let chain = compactSingleChildChain(startingAt: entry.url) {
                    return FileNode(
                        id: entry.url,
                        name: entry.name,
                        isDirectory: true,
                        children: nil,
                        childrenLoadState: .notLoaded,
                        foldedSegments: chain.segments,
                        foldedTerminalURL: chain.terminalURL
                    )
                }
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

### Step 5: 运行测试，确认全部通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-u1-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/WorkspaceTreeAutoFoldSnapshotTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:"
```

期望：全部通过。

### Step 6: 提交

```bash
git add agentGui/Utilities/WorkspaceTreeRefreshCoordinator.swift \
        agentGuiTests/WorkspaceTreeAutoFoldSnapshotTests.swift
git commit -m "ft-u1: add compactSingleChildChain, findNode; buildNodesShallow supports compactFolders"
```

---

## Task FT-U1-T3：`WorkspaceTreeRefreshCoordinator` — `compactFolders` 属性 + `demandLoad` 升级

**目的**：① 在协调器上暴露 `compactFolders: Bool` 属性，使其在 `scheduleFullReload` 和 `demandLoad` 中均使用折叠逻辑；② `demandLoad` 在扫描前通过 `findNode` 取出 `foldedTerminalURL`，对链尾进行扫描，并对新子目录也应用折叠；③ 修复 `applyPartialUpdate` 和 `replaceNode` 中丢失 `foldedSegments / foldedTerminalURL` 的 `FileNode` 构造调用。

**Files:**
- Modify: `agentGui/Utilities/WorkspaceTreeRefreshCoordinator.swift`
- Create: `agentGuiTests/WorkspaceTreeAutoFoldDemandLoadTests.swift`

---

### Step 1: 新建测试文件，写失败断言

新建 `agentGuiTests/WorkspaceTreeAutoFoldDemandLoadTests.swift`：

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct WorkspaceTreeAutoFoldDemandLoadTests {

    private func makeTmpDir(_ suffix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-u1-demandload-\(suffix)-\(Int.random(in: 1000...9999))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - 初始加载：折叠链节点出现

    @Test func initialLoadCreatesAutoFoldedNode() async throws {
        // root/src/main/java/（每层只有 1 个子目录）→ 初始扫描结果应有 1 个折叠节点
        let root = try makeTmpDir("init")
        defer { try? FileManager.default.removeItem(at: root) }

        let java = root.appendingPathComponent("src/main/java")
        try FileManager.default.createDirectory(at: java, withIntermediateDirectories: true)

        var receivedNodes: [FileNode] = []
        let coordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: .init { _, _ in nil }
        )
        coordinator.compactFolders = true
        coordinator.onNodesChanged = { nodes, _ in receivedNodes = nodes }

        coordinator.setDirectory(root)
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(receivedNodes.count == 1)
        let srcNode = receivedNodes.first
        #expect(srcNode?.isFolded == true)
        #expect(srcNode?.foldedSegments == ["src", "main", "java"])
        #expect(srcNode?.foldedTerminalURL?.standardizedFileURL.path == java.standardizedFileURL.path)
        #expect(srcNode?.childrenLoadState == .notLoaded)
    }

    @Test func initialLoadDisabledDoesNotFold() async throws {
        let root = try makeTmpDir("nofold")
        defer { try? FileManager.default.removeItem(at: root) }

        let java = root.appendingPathComponent("src/main/java")
        try FileManager.default.createDirectory(at: java, withIntermediateDirectories: true)

        var receivedNodes: [FileNode] = []
        let coordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: .init { _, _ in nil }
        )
        coordinator.compactFolders = false
        coordinator.onNodesChanged = { nodes, _ in receivedNodes = nodes }

        coordinator.setDirectory(root)
        try await Task.sleep(nanoseconds: 300_000_000)

        let srcNode = receivedNodes.first(where: { $0.name == "src" })
        #expect(srcNode?.isFolded == false)
    }

    // MARK: - demandLoad 展开折叠节点：扫描链尾

    @Test func demandLoadFoldedNodeScansTerminalURL() async throws {
        // root/src/main/java/ 含 App.swift
        let root = try makeTmpDir("fold-expand")
        defer { try? FileManager.default.removeItem(at: root) }

        let java = root.appendingPathComponent("src/main/java")
        try FileManager.default.createDirectory(at: java, withIntermediateDirectories: true)
        try "class App {}".write(to: java.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)

        var receivedNodes: [FileNode] = []
        let coordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: .init { _, _ in nil }
        )
        coordinator.compactFolders = true
        coordinator.onNodesChanged = { nodes, _ in receivedNodes = nodes }

        coordinator.setDirectory(root)
        try await Task.sleep(nanoseconds: 300_000_000)

        // 展开折叠节点（传入 id = src URL）
        let srcURL = root.appendingPathComponent("src")
        coordinator.demandLoad(directoryID: srcURL)
        try await Task.sleep(nanoseconds: 300_000_000)

        // src 节点应变为 .loaded，子项为 java/ 下的 App.swift
        let srcNode = receivedNodes.first(where: { $0.id.standardizedFileURL == srcURL.standardizedFileURL })
        #expect(srcNode?.childrenLoadState == .loaded)
        #expect(srcNode?.children?.count == 1)
        #expect(srcNode?.children?.first?.name == "App.swift")
        // 折叠字段应被保留
        #expect(srcNode?.isFolded == true)
        #expect(srcNode?.foldedSegments == ["src", "main", "java"])
    }

    @Test func demandLoadNonFoldedNodeWorksAsUsual() async throws {
        // 普通目录展开不受影响
        let root = try makeTmpDir("plain")
        defer { try? FileManager.default.removeItem(at: root) }

        let subdir = root.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "x".write(to: subdir.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)

        var receivedNodes: [FileNode] = []
        let coordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: .init { _, _ in nil }
        )
        coordinator.compactFolders = true
        coordinator.onNodesChanged = { nodes, _ in receivedNodes = nodes }
        coordinator.setDirectory(root)
        try await Task.sleep(nanoseconds: 300_000_000)

        coordinator.demandLoad(directoryID: subdir)
        try await Task.sleep(nanoseconds: 300_000_000)

        let subdirNode = receivedNodes.first(where: { $0.name == "subdir" })
        #expect(subdirNode?.childrenLoadState == .loaded)
        #expect(subdirNode?.children?.count == 1)
        #expect(subdirNode?.isFolded == false)
    }

    @Test func demandLoadChildDirsAlsoGetFolded() async throws {
        // root/src/main/java/ 下有 com/example/（单子链）
        let root = try makeTmpDir("nested-fold")
        defer { try? FileManager.default.removeItem(at: root) }

        let example = root.appendingPathComponent("src/main/java/com/example")
        try FileManager.default.createDirectory(at: example, withIntermediateDirectories: true)
        try "class A {}".write(to: example.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)

        var receivedNodes: [FileNode] = []
        let coordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: .init { _, _ in nil }
        )
        coordinator.compactFolders = true
        coordinator.onNodesChanged = { nodes, _ in receivedNodes = nodes }
        coordinator.setDirectory(root)
        try await Task.sleep(nanoseconds: 300_000_000)

        // 展开 src（折叠链链头）
        let srcURL = root.appendingPathComponent("src")
        coordinator.demandLoad(directoryID: srcURL)
        try await Task.sleep(nanoseconds: 300_000_000)

        // java/ 下的 com/ 也应被折叠为 com/example
        let srcNode = receivedNodes.first(where: { $0.id.standardizedFileURL == srcURL.standardizedFileURL })
        let comNode = srcNode?.children?.first(where: { $0.name == "com" })
        #expect(comNode?.isFolded == true)
        #expect(comNode?.foldedSegments == ["com", "example"])
    }
}
```

### Step 2: 运行测试，确认失败（协调器行为不正确）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-u1-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/WorkspaceTreeAutoFoldDemandLoadTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

期望：编译失败（`coordinator.compactFolders` 不存在）或测试失败（折叠节点未创建）。

### Step 3: 在 `WorkspaceTreeRefreshCoordinator` 中新增 `compactFolders` 属性

在 `WorkspaceTreeRefreshCoordinator` 类定义的 `private var scanTask` 附近，添加：

```swift
    /// Auto-fold 开关（FT-U1）。与 AppSettings.compactFolders 同步，由 ViewModel 赋值。
    var compactFolders: Bool = true
```

### Step 4: 修改 `scheduleFullReload` — 传入 `compactFolders`

将 `scheduleFullReload` 方法中的：
```swift
let nodes = await WorkspaceTreeSnapshotOps.buildNodesShallow(at: url)
```
替换为（在 Task.detached 块外先捕获 `shouldCompact`，再传入）：

```swift
private func scheduleFullReload(for url: URL, generation: Int) {
    let shouldCompact = compactFolders          // ← 捕获（Sendable Bool）
    scanTask?.cancel()
    scanTask = Task.detached(priority: .userInitiated) { [weak self] in
        let nodes = await WorkspaceTreeSnapshotOps.buildNodesShallow(at: url, compactFolders: shouldCompact)
        guard !Task.isCancelled else { return }
        await MainActor.run {
            guard let self, self.generation == generation, self.currentDirectory == url else { return }
            self.currentNodes = nodes
            self.onNodesChanged?(nodes, false)
        }
    }
}
```

### Step 5: 修改 `demandLoad` — 扫描链尾 + 子节点应用折叠 + 保留折叠字段

将 `demandLoad(directoryID:)` 方法完整替换为：

```swift
    /// 按需加载指定目录的 1 层子项。
    /// 若该节点是折叠节点（foldedTerminalURL 非空），则扫描链尾目录而非 id 所在目录。
    /// 扫描完成后通过 onNodesChanged 推送更新。
    func demandLoad(directoryID: URL) {
        let nodeID = directoryID.standardizedFileURL
        let snapshot = currentNodes
        let generation = self.generation
        let shallowScan = shallowScanClosure
        let shouldCompact = compactFolders

        // 从快照中取出该节点，获取真正的扫描目标（folded 节点扫链尾，普通节点扫自身）
        let existingNode = WorkspaceTreeSnapshotOps.findNode(in: snapshot, id: nodeID)
        let scanURL = existingNode?.foldedTerminalURL?.standardizedFileURL ?? nodeID

        scanTask?.cancel()
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }

            // 扫描目标目录（链尾）的 1 层子项
            let freshEntries = await shallowScan(scanURL)
            let freshChildren: [FileNode] = freshEntries.map { entry in
                if entry.isDirectory {
                    // 子目录也应用折叠（FT-U1）
                    if shouldCompact,
                       let chain = WorkspaceTreeSnapshotOps.compactSingleChildChain(startingAt: entry.url) {
                        return FileNode(
                            id: entry.url,
                            name: entry.name,
                            isDirectory: true,
                            children: nil,
                            childrenLoadState: .notLoaded,
                            foldedSegments: chain.segments,
                            foldedTerminalURL: chain.terminalURL
                        )
                    }
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

            guard !Task.isCancelled else { return }

            // 在树中找到目标节点（以 nodeID 查找），替换为 .loaded 状态，保留折叠字段
            let updated = WorkspaceTreeSnapshotOps.replaceNode(in: snapshot, id: nodeID) { node in
                FileNode(
                    id: node.id,
                    name: node.name,
                    isDirectory: true,
                    children: freshChildren,
                    childrenLoadState: .loaded,
                    foldedSegments: node.foldedSegments,       // ← 保留
                    foldedTerminalURL: node.foldedTerminalURL  // ← 保留
                )
            }

            await MainActor.run {
                guard let self, self.generation == generation else { return }
                self.currentNodes = updated
                self.onNodesChanged?(updated, false)
            }
        }
    }
```

### Step 6: 修复 `applyPartialUpdate` — 保留折叠字段

在 `applyPartialUpdate` 中，找到两处 `FileNode(id: node.id, name: node.name, isDirectory: true, ...)` 构造调用，均补充 `foldedSegments` 和 `foldedTerminalURL` 的透传：

**第一处**（`nodePath == targetPath` 分支，扫到最终目标时）：
```swift
return FileNode(
    id: node.id, name: node.name, isDirectory: true,
    children: mergedNodes, childrenLoadState: .loaded,
    foldedSegments: node.foldedSegments,
    foldedTerminalURL: node.foldedTerminalURL
)
```

**第二处**（`targetPath.hasPrefix(nodePath + "/")` 分支，向下递归时）：
```swift
return FileNode(
    id: node.id, name: node.name, isDirectory: true,
    children: updatedChildren, childrenLoadState: node.childrenLoadState,
    foldedSegments: node.foldedSegments,
    foldedTerminalURL: node.foldedTerminalURL
)
```

### Step 7: 运行所有三个测试套件

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-u1-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/FileNodeAutoFoldTests \
  -only-testing:agentGuiTests/WorkspaceTreeAutoFoldSnapshotTests \
  -only-testing:agentGuiTests/WorkspaceTreeAutoFoldDemandLoadTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|passed|failed|error:"
```

期望：全部通过。

### Step 8: 回归既有 Demand Load 测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-u1-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/WorkspaceTreeDemandLoadCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:"
```

期望：全部通过（`demandLoad(directoryID:)` 签名未变，向后兼容）。

### Step 9: 提交

```bash
git add agentGui/Utilities/WorkspaceTreeRefreshCoordinator.swift \
        agentGuiTests/WorkspaceTreeAutoFoldDemandLoadTests.swift
git commit -m "ft-u1: coordinator compactFolders property, demandLoad scans foldedTerminalURL, fold children, preserve fold fields"
```

---

## Task FT-U1-T4：`AppSettings` + `WorkspaceTreeViewModel` — 持久化开关接线

**目的**：① 在 `AppSettings` SwiftData 模型中新增 `compactFolders: Bool = true`；② 在 `WorkspaceTreeViewModel` 新增 `compactFolders` 转发属性，设置时同步到内部协调器；③ 在 `WorkspacePanelView` 中从设置读取该值并赋给 ViewModel。

**Files:**
- Modify: `agentGui/Models/AppSettings.swift`
- Modify: `agentGui/ViewModels/WorkspaceTreeViewModel.swift`
- Modify: `agentGui/Views/WorkspacePanelView.swift`

---

### Step 1: 在 `AppSettings.swift` 添加字段

在 `AppSettings` 中，找到 `var memoryEnabled: Bool = true` 附近任意已有的 `var` 属性之后，
新增（保持 SwiftData 持久化，默认 `true`）：

```swift
    /// 文件树 Auto-fold：自动压缩单子目录链（FT-U1）
    var compactFolders: Bool = true
```

### Step 2: 在 `WorkspaceTreeViewModel` 添加 `compactFolders` 转发属性

在 `WorkspaceTreeViewModel` 类中，找到现有的其他 `var` 属性（如 `var treeSearchText`），
新增：

```swift
    /// 与 AppSettings.compactFolders 同步，设置时同步到 refreshCoordinator。
    var compactFolders: Bool = true {
        didSet {
            refreshCoordinator.compactFolders = compactFolders
        }
    }
```

### Step 3: 在 `WorkspacePanelView` 中接线

在 `WorkspacePanelView` 中，找到 `WorkspaceTreeView(...)` 的调用块所在的 `treeContent` 或父视图，
在 `coordinator` 或 `treeViewModel` 初始化后（`.onAppear` 或视图 `init`，根据现有代码模式选择合适位置）
读取设置并赋值：

```swift
// 在 WorkspaceTreeView 调用块之前，或视图 body 顶层：
let _ = treeViewModel.compactFolders  // 触发 Swift Observable 跟踪
```

找到当前 `WorkspacePanelView` 中访问 `modelContext` / `persistenceCoordinator` 的位置（如 `chooseDirectory` 或 `triggerWorkspaceLSPBootstrap`），
在已有的 `AppSettings.getOrCreate(...)` call 处，加一行：

寻找 `WorkspacePanelView` body 中的 `treeContent` 区域，在 `.task` 或 `.onAppear` 修饰符追加以下同步（若已有 `.task` 修饰符则追加到其中，否则新增）：

```swift
.task {
    let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
    treeViewModel.compactFolders = settings.compactFolders
}
```

> **注意**：`treeContent` 是一个 `@ViewBuilder var`，`.task` 应附加在 `treeContent` 的 ScrollView 或顶层容器上，不要附在内部子视图上。若 `WorkspacePanelView` 已有一个 `.task` 块（如 LSP bootstrap），将 `treeViewModel.compactFolders = settings.compactFolders` 一行追加到该块内即可。

### Step 4: 确认编译和已有测试通过

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

期望：`BUILD SUCCEEDED`（若有 AppSettings 迁移版本号需求，参见 Step 5）。

### Step 5: SwiftData Schema 迁移（若项目强制版本）

如果项目中有 `PersistenceSchema.currentVersion` 枚举需要递增，请检查
`agentGui/Models/AppSettings.swift` 中的 `persistenceSchemaVersion` 声明并按项目约定递增版本号。

若无版本控制（初始阶段），直接添加属性即可，SwiftData 会自动 migrate。

### Step 6: 提交

```bash
git add agentGui/Models/AppSettings.swift \
        agentGui/ViewModels/WorkspaceTreeViewModel.swift \
        agentGui/Views/WorkspacePanelView.swift
git commit -m "ft-u1: AppSettings.compactFolders, ViewModel forwarding, panel wiring"
```

---

## Task FT-U1-T5：`WorkspaceTreeRowContent` — 折叠路径分段渲染

**目的**：当 `node.isFolded == true` 时，将文件名文本替换为分段渲染的 `"seg1 / seg2 / seg3"` 样式（各 `/` 分隔符用灰色次要文本颜色显示），以视觉区分折叠节点与普通目录。

**Files:**
- Modify: `agentGui/Views/WorkspaceTree/WorkspaceTreeRowContent.swift`

---

### Step 1: 理解当前渲染逻辑

打开 `WorkspaceTreeRowContent.swift`，定位文件名渲染部分（`else` 分支，即非内联编辑时）：

```swift
} else {
    Text(node.name)
        .font(.system(size: 12))
        .foregroundStyle(isSelected ? Color.accentColor : .primary)
        .lineLimit(1)
}
```

### Step 2: 替换为折叠感知的渲染

将上述 `else` 分支替换为：

```swift
} else if node.isFolded {
    // FT-U1：折叠路径分段渲染 — "src / main / java"
    foldedLabel
} else {
    Text(node.name)
        .font(.system(size: 12))
        .foregroundStyle(isSelected ? Color.accentColor : .primary)
        .lineLimit(1)
}
```

并在 `WorkspaceTreeRowContent` 末尾（`iconColor` 等计算属性之后）新增：

```swift
    // MARK: - Auto-fold rendering (FT-U1)

    /// 折叠链分段标签："src / main / java"，"/"呈灰色，其余段与普通目录样式一致。
    @ViewBuilder
    private var foldedLabel: some View {
        HStack(spacing: 0) {
            ForEach(Array(node.foldedSegments.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Text(" / ")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)   // 灰色分隔符
                }
                Text(segment)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }
```

### Step 3: 确认编译

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

期望：`BUILD SUCCEEDED`。

### Step 4: 更新 `accessibilityIdentifier` 中文件名读取

在 `body` 末尾的 `.accessibilityIdentifier(...)` 调用中，文件夹的 identifier
目前用 `node.name`，折叠节点应也使用 `node.name`（链头目录名）。当前实现已正确，无需修改。

如需让 UI 测试能识别折叠状态，可选择性追加：
```swift
.accessibilityValue(node.isFolded ? "folded" : "")
```
（可选，不强制要求）

### Step 5: 运行全量 FT-U1 测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-u1-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/FileNodeAutoFoldTests \
  -only-testing:agentGuiTests/WorkspaceTreeAutoFoldSnapshotTests \
  -only-testing:agentGuiTests/WorkspaceTreeAutoFoldDemandLoadTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|passed|failed|error:"
```

期望：全部通过。

### Step 6: 提交

```bash
git add agentGui/Views/WorkspaceTree/WorkspaceTreeRowContent.swift
git commit -m "ft-u1: WorkspaceTreeRowContent folded segment label rendering"
```

---

## Task FT-U1-T6：回归验证 + 整体收尾

**目的**：运行全量测试回归，确认 FT-U1 不破坏已有功能。标记已知限制并确认接入 Xcode Tasks。

**Files:**
- 无需修改（纯验证）

---

### Step 1: 全量回归测试（现有文件树相关套件）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-ft-u1-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/FileNodeAutoFoldTests \
  -only-testing:agentGuiTests/WorkspaceTreeAutoFoldSnapshotTests \
  -only-testing:agentGuiTests/WorkspaceTreeAutoFoldDemandLoadTests \
  -only-testing:agentGuiTests/FileNodeLazyLoadTests \
  -only-testing:agentGuiTests/WorkspaceTreeLazyLoadSnapshotOpsTests \
  -only-testing:agentGuiTests/WorkspaceTreeDemandLoadCoordinatorTests \
  -only-testing:agentGuiTests/WorkspaceTreeRefreshTargetsPruningTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|passed|failed|error:"
```

期望：所有套件均 `passed`，0 failures。

### Step 2: 手动验证（可选，推荐）

用 Xcode 在模拟器或真机上运行 App，打开一个有深层单子目录结构的工作区（如 agentGui 自身的 `src/main` 或 Java/Kotlin 项目），验证：
1. 初始加载后单子目录链显示为 `"a / b / c"` 格式。
2. 点击折叠节点展开后，在链尾目录的子项正确显示。
3. 展开后的子目录若仍为单子链，继续显示折叠格式。
4. 多子目录（如根目录下有多个子文件夹）正常显示，不被折叠。
5. 搜索文本非空时，折叠节点按 `foldDisplayPath`（"src / main / java"）参与过滤。

> **搜索过滤兼容性检查**：打开 `WorkspaceTreeSnapshotOps.filterNodes` 或 `WorkspaceTreeViewModel.filteredNodes()`，确认搜索查询是否与 `node.name`（链头名称）匹配。若需让搜索匹配全路径，需修改 filter 逻辑使用 `node.foldDisplayPath`。

### Step 3: 搜索过滤兼容性修复（如有需要）

若 `filterNodes` 目前只比较 `node.name`，对折叠节点应同时包含 `foldDisplayPath` 进行匹配。
找到 `WorkspaceTreeSnapshotOps.filterNodes` 中的字符串比较行，修改为：

```swift
// 原来：query 与 node.name 匹配
// 修改后：若节点为折叠节点，同时尝试 foldDisplayPath（全路径）匹配

private static func filter(node: FileNode, query: String) -> FileNode? {
    let nameMatch = node.name.localizedCaseInsensitiveContains(query)
    let foldPathMatch = node.isFolded && node.foldDisplayPath.localizedCaseInsensitiveContains(query)

    if node.isDirectory {
        // 递归过滤子节点（仅 .loaded 节点有子项）
        if let children = node.children {
            let matchedChildren = children.compactMap { filter(node: $0, query: query) }
            if !matchedChildren.isEmpty {
                return FileNode(
                    id: node.id, name: node.name, isDirectory: true,
                    children: matchedChildren, childrenLoadState: node.childrenLoadState,
                    foldedSegments: node.foldedSegments, foldedTerminalURL: node.foldedTerminalURL
                )
            }
        }
        return (nameMatch || foldPathMatch) ? node : nil
    } else {
        return nameMatch ? node : nil
    }
}
```

> 根据实际 `filter` 函数实现按需调整，上方仅为示意。

### Step 4: 最终提交

```bash
git add -A
git commit -m "ft-u1: Auto-fold compact folders complete — search filter compat, regression clean"
```

---

## 补充：`tasks.json` 可选接入

如需为 FT-U1 添加独立的 VS Code 测试任务，在 `.vscode/tasks.json` 增加：

```json
{
    "label": "FT-U1 Auto-fold Tests",
    "type": "shell",
    "command": "xcodebuild",
    "args": [
        "test",
        "-project", "agentGui.xcodeproj",
        "-scheme", "agentGui",
        "-destination", "platform=macOS",
        "-parallel-testing-enabled", "NO",
        "-derivedDataPath", "/tmp/agentGui-ft-u1-derived",
        "-only-testing:agentGuiTests/FileNodeAutoFoldTests",
        "-only-testing:agentGuiTests/WorkspaceTreeAutoFoldSnapshotTests",
        "-only-testing:agentGuiTests/WorkspaceTreeAutoFoldDemandLoadTests",
        "CODE_SIGNING_ALLOWED=NO"
    ],
    "isBackground": false,
    "group": "test"
}
```

---

## 总结

| Task | 涉及修改 | 关键产出 |
|---|---|---|
| T1 | `FileNode.swift` | `foldedSegments`, `foldedTerminalURL`, `isFolded`, `foldDisplayPath` |
| T2 | `WorkspaceTreeRefreshCoordinator.swift` | `compactSingleChildChain`, `findNode`, `buildNodesShallow(compactFolders:)` |
| T3 | `WorkspaceTreeRefreshCoordinator.swift` | `compactFolders` 属性, `demandLoad` 升级, `applyPartialUpdate` 保留字段 |
| T4 | `AppSettings`, `WorkspaceTreeViewModel`, `WorkspacePanelView` | 持久化开关接线 |
| T5 | `WorkspaceTreeRowContent.swift` | "a / b / c" 分段渲染 |
| T6 | 回归验证 + 搜索过滤兼容 | 全量测试通过 |

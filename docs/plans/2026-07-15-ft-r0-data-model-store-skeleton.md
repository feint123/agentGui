# FT-R0：数据模型 + FileTreeStore 骨架 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 建立新的扁平化文件树数据模型和核心 Actor，提供完整的 CRUD 原语和 `computeVisibleEntries`，可独立编译和测试，不依赖任何渲染层。

**Architecture:**
- `FileEntry` / `VisibleEntry` 等值类型模型完全 `Sendable`，安全跨 actor 传递。
- `FileTreeStore` 以 Swift actor 封装全部树状态，所有写操作均在 actor 内串行执行。
- `FileScanning` 协议抽象文件系统，测试时注入 `MockFileScanner`，产品代码使用 `RealFileScanner`。

**Tech Stack:** Swift 6.0+, Foundation, SwiftUI Preview (无), XCTest

**参考来源：**
- Zed `project_panel.rs` — `VisibleEntriesForWorktree`、`State.ancestors`（`FoldedAncestors`）、`update_visible_entries` 后台 spawn 模式、`auto_fold_dirs` 单子目录链检测
- VSCode `explorerView.ts` — `compactFolders` / `isCompressionEnabled`、`ExplorerCompressionDelegate`、`setTreeInput` 异步流程
- 旧代码 `FileNode.swift` — `childrenLoadState`（`.notLoaded` / `.loaded`）保留语义，改为 `FileEntry.loadState`

---

## 前置条件

读者在开始前应了解：
- `agentGui/Models/FileNode.swift`（旧模型，理解 `foldedSegments` 的含义）
- `agentGui/ViewModels/WorkspaceTreeViewModel.swift`（了解目前的调用方式）
- `docs/plans/2026-07-15-filetree-rewrite-design.md` 第二章（目标数据类型定义）

---

## Task 1：创建 `EntryID` + `FileEntry` + `LoadState`

**Files:**
- Create: `agentGui/Models/FileEntry.swift`
- Test: `agentGuiTests/FileTreeStoreTests.swift`（本 task 先创建测试文件）

### Step 1：在测试文件里写第一个构造断言

```swift
// agentGuiTests/FileTreeStoreTests.swift
import XCTest
@testable import agentGui

final class FileTreeStoreTests: XCTestCase {

    // MARK: - FileEntry
    func testEntryID_equalityByURL() {
        let url = URL(fileURLWithPath: "/tmp/foo")
        let a = EntryID(url: url)
        let b = EntryID(url: url)
        XCTAssertEqual(a, b)
    }

    func testFileEntry_defaultLoadState_notLoaded() {
        let entry = FileEntry(
            id: EntryID(url: URL(fileURLWithPath: "/tmp/dir")),
            name: "dir",
            isDirectory: true,
            parentID: nil
        )
        XCTAssertEqual(entry.loadState, .notLoaded)
    }
}
```

### Step 2：运行测试，预期编译失败（`EntryID`、`FileEntry` 尚不存在）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FileTreeStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`error: cannot find type 'EntryID'`

### Step 3：实现 `FileEntry.swift`

```swift
// agentGui/Models/FileEntry.swift
import Foundation

/// 文件树条目唯一标识符，以 URL 为键。
struct EntryID: Hashable, Sendable, Comparable {
    let url: URL

    static func < (lhs: EntryID, rhs: EntryID) -> Bool {
        lhs.url.path < rhs.url.path
    }
}

/// 文件树中一个条目的值类型快照（目录或文件）。
/// 不持有 children，由 `FileTreeStore.children` 邻接表管理。
struct FileEntry: Sendable {
    let id: EntryID
    let name: String
    let isDirectory: Bool
    let parentID: EntryID?
    var loadState: LoadState

    init(
        id: EntryID,
        name: String,
        isDirectory: Bool,
        parentID: EntryID?,
        loadState: LoadState = .notLoaded
    ) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.parentID = parentID
        self.loadState = loadState
    }

    enum LoadState: Equatable, Sendable {
        case notLoaded   // 目录：尚未扫描子条目
        case loading     // 正在扫描
        case loaded      // 已扫描（children 存储在 Store 中）
    }
}
```

> **设计说明（对比旧 `FileNode`）：**
> - 旧：`children: [FileNode]?` 递归嵌套，更新一个节点需遍历整棵树。
> - 新：`children` 存储在 Actor 的 `[EntryID: [EntryID]]` 邻接表中，更新 O(1)。
> - 旧：`foldedSegments: [String]` 存在模型里（持久化）。
> - 新：Auto-fold 只在 `computeVisibleEntries` 计算，不存入 `FileEntry`。
> - Zed 的 `Entry`（`worktree/src/worktree.rs`）同样是扁平 arena 存储，仅通过 `path` 反推父子关系；新设计额外保存 `parentID` 以支持 O(1) 向上查找。

### Step 4：运行测试，验证通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FileTreeStoreTests/testEntryID_equalityByURL \
  -only-testing:agentGuiTests/FileTreeStoreTests/testFileEntry_defaultLoadState_notLoaded \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：`** TEST SUCCEEDED **`

### Step 5：提交

```
git add agentGui/Models/FileEntry.swift agentGuiTests/FileTreeStoreTests.swift
git commit -m "FT-R0 task1: EntryID + FileEntry + LoadState"
```

---

## Task 2：创建 `VisibleEntry` + `FoldedAncestors`

**Files:**
- Create: `agentGui/Models/VisibleEntry.swift`

### Step 1：先在测试文件中追加断言

```swift
// 追加到 FileTreeStoreTests
func testVisibleEntry_identifiableById() {
    let id = EntryID(url: URL(fileURLWithPath: "/tmp/file.txt"))
    let entry = VisibleEntry(
        id: id,
        name: "file.txt",
        isDirectory: false,
        depth: 1,
        isExpanded: false,
        foldedAncestors: nil,
        gitSummary: nil,
        diagnosticSeverity: nil,
        isIgnored: false
    )
    XCTAssertEqual(entry.id, id)
}

func testFoldedAncestors_segments() {
    let seg1 = FoldedAncestors.FoldedSegment(
        name: "src",
        entryID: EntryID(url: URL(fileURLWithPath: "/tmp/src"))
    )
    let seg2 = FoldedAncestors.FoldedSegment(
        name: "main",
        entryID: EntryID(url: URL(fileURLWithPath: "/tmp/src/main"))
    )
    let fa = FoldedAncestors(
        segments: [seg1, seg2],
        terminalID: seg2.entryID
    )
    XCTAssertEqual(fa.segments.count, 2)
    XCTAssertEqual(fa.terminalID, seg2.entryID)
}
```

### Step 2：运行，预期失败

### Step 3：实现 `VisibleEntry.swift`

```swift
// agentGui/Models/VisibleEntry.swift
import Foundation

/// 可见行的渲染快照——每一行对应一个 `VisibleEntry`。
/// 由 `FileTreeStore.computeVisibleEntries()` 在后台线程生成，
/// 经 `@MainActor` 推送到 `FileTreeViewModel.visibleEntries`。
struct VisibleEntry: Identifiable, Equatable, Sendable {
    let id: EntryID
    let name: String
    let isDirectory: Bool
    let depth: Int
    let isExpanded: Bool
    /// 非 nil 表示该节点是 Auto-fold 链的"叶节点"，需渲染多段路径。
    /// 参考 Zed `FoldedAncestors`（project_panel.rs）的 `ancestors` vec。
    let foldedAncestors: FoldedAncestors?
    let gitSummary: GitSummary?
    let diagnosticSeverity: DiagSeverity?
    let isIgnored: Bool
}

/// 单子目录压缩链的描述，对应 Zed 的 `FoldedAncestors.ancestors`。
///
/// 例如 src → src/main → src/main/java 压缩后:
///   segments = [("src", id_src), ("main", id_main), ("java", id_java)]
///   terminalID = id_java
///
/// 与旧 `FileNode.foldedSegments: [String]` 的区别：
/// - 每段携带 `entryID`，支持点击任意段展开（Zed 风格）
/// - 不在模型中持久化，仅在 computeVisibleEntries() 时计算
struct FoldedAncestors: Equatable, Sendable {
    let segments: [FoldedSegment]
    let terminalID: EntryID

    struct FoldedSegment: Equatable, Sendable {
        let name: String
        let entryID: EntryID
    }
}
```

> **设计参考（Zed）：**
> `FoldedAncestors` 结构直接参考 Zed `project_panel.rs` 中的同名结构，但去掉了
> `current_ancestor_depth`（渲染层交互深度），将其移至 `FileTreeViewModel`
> 层管理，保持 Store 数据与视图交互状态分离。

### Step 4：运行测试，验证通过

### Step 5：提交

```
git add agentGui/Models/VisibleEntry.swift
git commit -m "FT-R0 task2: VisibleEntry + FoldedAncestors"
```

---

## Task 3：创建 `GitSummary` + `DiagSeverity` + `SortOrder`

**Files:**
- Create: `agentGui/Models/GitSummary.swift`
- Create: `agentGui/Models/DiagSeverity.swift`
- Create: `agentGui/Models/SortOrder.swift`

### Step 1：测试枚举可比较，高优先级 < 低优先级

```swift
// 追加到 FileTreeStoreTests
func testGitSummary_comparableOrder() {
    // conflict 最高优先级（最小值），added 最低
    XCTAssertLessThan(GitSummary.conflict, GitSummary.added)
    XCTAssertLessThan(GitSummary.modified, GitSummary.staged)
}

func testDiagSeverity_comparableOrder() {
    XCTAssertLessThan(DiagSeverity.error, DiagSeverity.warning)
    XCTAssertLessThan(DiagSeverity.warning, DiagSeverity.hint)
}
```

### Step 2：运行，预期失败

### Step 3：实现三个枚举

```swift
// agentGui/Models/GitSummary.swift
import Foundation

/// Git 状态优先级（Comparable：值越小优先级越高）。
/// 对应 Zed `git::status::GitSummary` 的聚合优先级概念。
enum GitSummary: Int, Comparable, Sendable, CaseIterable {
    case conflict   = 0   // 冲突（最高优先级）
    case untracked  = 1   // 未跟踪
    case deleted    = 2   // 已删除
    case modified   = 3   // 已修改（未暂存）
    case staged     = 4   // 已暂存
    case added      = 5   // 新增（最低优先级）

    static func < (lhs: GitSummary, rhs: GitSummary) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
```

```swift
// agentGui/Models/DiagSeverity.swift
import Foundation

/// LSP 诊断严重度（Comparable：error 最严重）。
enum DiagSeverity: Int, Comparable, Sendable, CaseIterable {
    case error   = 0
    case warning = 1
    case hint    = 2

    static func < (lhs: DiagSeverity, rhs: DiagSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
```

```swift
// agentGui/Models/SortOrder.swift
import Foundation

/// 文件树排序方式。对应 VSCode `explorer.sortOrder` 配置项。
enum SortOrder: Sendable, CaseIterable {
    case nameAsc        // 名称升序（默认：目录优先）
    case nameDesc       // 名称降序
    case directoriesFirst // 等同 nameAsc，目录永远排在文件前
    case mixed          // 目录和文件混排（VSCode `mixed` 模式）
}
```

### Step 4：运行测试，验证通过

### Step 5：提交

```
git add agentGui/Models/GitSummary.swift agentGui/Models/DiagSeverity.swift agentGui/Models/SortOrder.swift
git commit -m "FT-R0 task3: GitSummary + DiagSeverity + SortOrder"
```

---

## Task 4：创建 `FileTreeSelection`

**Files:**
- Create: `agentGui/Models/FileTreeSelection.swift`

### Step 1：测试

```swift
// 追加到 FileTreeStoreTests
func testFileTreeSelection_defaultEmpty() {
    let sel = FileTreeSelection()
    XCTAssertNil(sel.primary)
    XCTAssertTrue(sel.selected.isEmpty)
    XCTAssertNil(sel.anchor)
}

func testFileTreeSelection_selectEntry() {
    let id = EntryID(url: URL(fileURLWithPath: "/tmp/a"))
    var sel = FileTreeSelection()
    sel.primary = id
    sel.selected = [id]
    XCTAssertEqual(sel.primary, id)
    XCTAssertEqual(sel.selected.count, 1)
}
```

> **注意：** `selected` 使用标准 `[EntryID]`（保序数组），不引入第三方 `OrderedSet`，
> 重复项在插入时手动去重，避免依赖。

### Step 2：运行，预期失败

### Step 3：实现

```swift
// agentGui/Models/FileTreeSelection.swift
import Foundation

/// 键盘/鼠标选择状态。存储在 `FileTreeViewModel`（@MainActor），不入 Store。
///
/// 对比旧 `WorkspaceTreeViewModel`:
/// - 旧：`selectedTreeNodeID: URL?` + `selectedTreeNodeIDs: Set<URL>`（无序）
/// - 新：`primary` + `selected: [EntryID]`（保序，支持多选拖拽顺序）
///         + `anchor: EntryID?`（支持 Shift-click 范围选择）
struct FileTreeSelection: Sendable {
    var primary: EntryID?
    var selected: [EntryID] = []
    var anchor: EntryID?

    /// 将条目插入选中集合（保序，幂等）。
    mutating func add(_ id: EntryID) {
        if !selected.contains(id) {
            selected.append(id)
        }
        primary = id
    }

    /// 切换单选（Cmd+Click）。
    mutating func toggle(_ id: EntryID) {
        if let idx = selected.firstIndex(of: id) {
            selected.remove(at: idx)
            primary = selected.last
        } else {
            add(id)
        }
    }

    /// 设置单一主选项（普通 Click）。
    mutating func setSingle(_ id: EntryID) {
        selected = [id]
        primary = id
        anchor = id
    }

    var isEmpty: Bool { selected.isEmpty }
}
```

### Step 4：运行测试，验证通过

### Step 5：提交

```
git add agentGui/Models/FileTreeSelection.swift
git commit -m "FT-R0 task4: FileTreeSelection"
```

---

## Task 5：创建 `FileScanning` 协议 + `RealFileScanner`

**Files:**
- Create: `agentGui/Services/FileScanning.swift`

### Step 1：测试 Mock Scanner

```swift
// 追加到 FileTreeStoreTests

// MARK: - Mock Scanner（测试辅助）
final class MockFileScanner: FileScanning, @unchecked Sendable {
    var stubbedEntries: [URL: [ScannedEntry]] = [:]

    func shallowScan(directory: URL) async throws -> [ScannedEntry] {
        return stubbedEntries[directory.standardizedFileURL] ?? []
    }

    func isDirectory(_ url: URL) async -> Bool {
        return stubbedEntries[url.standardizedFileURL] != nil
    }
}

func testScannedEntry_hasRequiredFields() {
    let entry = ScannedEntry(
        url: URL(fileURLWithPath: "/tmp/a.txt"),
        name: "a.txt",
        isDirectory: false
    )
    XCTAssertEqual(entry.name, "a.txt")
    XCTAssertFalse(entry.isDirectory)
}
```

### Step 2：运行，预期失败

### Step 3：实现

```swift
// agentGui/Services/FileScanning.swift
import Foundation

/// 文件系统浅扫描结果条目。
struct ScannedEntry: Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
}

/// 文件系统扫描抽象。
/// 产品代码使用 `RealFileScanner`；测试注入 `MockFileScanner`。
///
/// 参考 Zed `project_panel.rs` 中对 Worktree / Project 的依赖注入模式：
/// ProjectPanel 通过 Entity<Project> 访问文件系统，
/// 我们通过协议实现同等的可测试性隔离。
protocol FileScanning: Sendable {
    func shallowScan(directory: URL) async throws -> [ScannedEntry]
    func isDirectory(_ url: URL) async -> Bool
}

/// 实现：读取真实磁盘。
struct RealFileScanner: FileScanning {
    func shallowScan(directory: URL) async throws -> [ScannedEntry] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        )
        return contents.map { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return ScannedEntry(
                url: url.standardizedFileURL,
                name: url.lastPathComponent,
                isDirectory: isDir
            )
        }
    }

    func isDirectory(_ url: URL) async -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }
}
```

### Step 4：运行测试，验证通过

### Step 5：提交

```
git add agentGui/Services/FileScanning.swift
git commit -m "FT-R0 task5: FileScanning protocol + RealFileScanner"
```

---

## Task 6：创建 `FileTreeStore` Actor 骨架（setRoot + expandDirectory + collapseDirectory）

**Files:**
- Create: `agentGui/Services/FileTreeStore.swift`

### Step 1：写三个核心测试

```swift
// 追加到 FileTreeStoreTests

// MARK: - FileTreeStore

func makeStore(entries: [URL: [ScannedEntry]] = [:]) -> FileTreeStore {
    let scanner = MockFileScanner()
    scanner.stubbedEntries = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.key.standardizedFileURL, $0.value) }
    )
    return FileTreeStore(scanner: scanner)
}

func testSetRoot_createsRootEntries() async throws {
    let root = URL(fileURLWithPath: "/tmp/project")
    let store = makeStore(entries: [
        root: [
            ScannedEntry(url: root.appendingPathComponent("src"), name: "src", isDirectory: true),
            ScannedEntry(url: root.appendingPathComponent("README.md"), name: "README.md", isDirectory: false),
        ]
    ])

    await store.setRoot(root)

    let visible = await store.computeVisibleEntries()
    // Root level 仅展示根目录的直接子项（根目录本身展开，但不作为独立行）
    XCTAssertEqual(visible.count, 2)
    let names = Set(visible.map(\.name))
    XCTAssertTrue(names.contains("src"))
    XCTAssertTrue(names.contains("README.md"))
}

func testComputeVisibleEntries_unexpandedDirHidesChildren() async throws {
    let root = URL(fileURLWithPath: "/tmp/project")
    let srcURL = root.appendingPathComponent("src")
    let store = makeStore(entries: [
        root: [
            ScannedEntry(url: srcURL, name: "src", isDirectory: true),
        ],
        srcURL: [
            ScannedEntry(url: srcURL.appendingPathComponent("main.swift"), name: "main.swift", isDirectory: false),
        ]
    ])

    await store.setRoot(root)
    // src 目录未展开，children 不可见
    let visible = await store.computeVisibleEntries()
    XCTAssertEqual(visible.count, 1)
    XCTAssertEqual(visible.first?.name, "src")
}

func testExpandDirectory_loadsAndShowsChildren() async throws {
    let root = URL(fileURLWithPath: "/tmp/project")
    let srcURL = root.appendingPathComponent("src")
    let store = makeStore(entries: [
        root: [ScannedEntry(url: srcURL, name: "src", isDirectory: true)],
        srcURL: [
            ScannedEntry(url: srcURL.appendingPathComponent("main.swift"),
                         name: "main.swift", isDirectory: false),
        ]
    ])

    await store.setRoot(root)
    let srcID = EntryID(url: srcURL.standardizedFileURL)
    try await store.expandDirectory(srcID)

    let visible = await store.computeVisibleEntries()
    XCTAssertEqual(visible.count, 2)
    let names = visible.map(\.name)
    XCTAssertTrue(names.contains("src"))
    XCTAssertTrue(names.contains("main.swift"))
}

func testCollapseDirectory_hidesChildren() async throws {
    let root = URL(fileURLWithPath: "/tmp/project")
    let srcURL = root.appendingPathComponent("src")
    let store = makeStore(entries: [
        root: [ScannedEntry(url: srcURL, name: "src", isDirectory: true)],
        srcURL: [
            ScannedEntry(url: srcURL.appendingPathComponent("main.swift"),
                         name: "main.swift", isDirectory: false),
        ]
    ])

    await store.setRoot(root)
    let srcID = EntryID(url: srcURL.standardizedFileURL)
    try await store.expandDirectory(srcID)
    await store.collapseDirectory(srcID)

    let visible = await store.computeVisibleEntries()
    XCTAssertEqual(visible.count, 1)
    XCTAssertEqual(visible.first?.name, "src")
}

func testEntryLookup_O1ById() async throws {
    let root = URL(fileURLWithPath: "/tmp/project")
    let readmeURL = root.appendingPathComponent("README.md")
    let store = makeStore(entries: [
        root: [ScannedEntry(url: readmeURL, name: "README.md", isDirectory: false)]
    ])

    await store.setRoot(root)
    let readmeID = EntryID(url: readmeURL.standardizedFileURL)
    let entry = await store.entry(for: readmeID)
    XCTAssertNotNil(entry)
    XCTAssertEqual(entry?.name, "README.md")
}
```

### Step 2：运行，预期编译失败

### Step 3：实现 `FileTreeStore.swift`

```swift
// agentGui/Services/FileTreeStore.swift
import Foundation

/// 文件树核心 Actor。
///
/// 架构决策（参考 Zed project_panel.rs + VSCode explorerView.ts）：
/// - **扁平索引（entries + children）**：O(1) 条目查找，避免递归树遍历。
///   Zed 的 Worktree 同样以扁平 Arena（`HashMap<ProjectEntryId, Entry>`）存储。
/// - **邻接表（children）**：`[EntryID: [EntryID]]` 排序后的子节点列表，
///   更新单目录不影响其他节点。
/// - **expandedIDs**：仅跟踪已展开目录 ID（Set），不嵌入 Entry 本身。
///   VSCode `ExplorerView` 通过 `IAsyncDataTreeViewState` 存储展开状态，设计思路相同。
/// - **setRoot**：仅执行浅扫描（根级一层），深层目录按需懒加载（FT-R3）。
///   VSCode `explorerView.ts` 的 `setTreeInput` 也是先 setInput 再按需 expand。
actor FileTreeStore {

    // MARK: - 存储

    /// 所有已知条目的 O(1) 索引。
    private var entries: [EntryID: FileEntry] = [:]

    /// 邻接表：parentID → 已排序 childIDs（按名称升序，目录优先）。
    private var children: [EntryID: [EntryID]] = [:]

    /// 根级条目 ID 列表（对应 Zed 的 worktree 根节点列表）。
    private var rootIDs: [EntryID] = []

    /// 已展开目录的 ID 集合。
    private var expandedIDs: Set<EntryID> = []

    private let scanner: FileScanning

    // MARK: - Init

    init(scanner: FileScanning = RealFileScanner()) {
        self.scanner = scanner
    }

    // MARK: - 公开 API

    /// 设置工作区根目录，执行浅扫描并重建索引。
    func setRoot(_ url: URL) async {
        let rootURL = url.standardizedFileURL
        entries = [:]
        children = [:]
        rootIDs = []
        expandedIDs = []

        guard let scanned = try? await scanner.shallowScan(directory: rootURL) else { return }

        var childIDs: [EntryID] = []
        for item in scanned {
            let id = EntryID(url: item.url.standardizedFileURL)
            let entry = FileEntry(
                id: id,
                name: item.name,
                isDirectory: item.isDirectory,
                parentID: nil,    // 根级条目无父
                loadState: item.isDirectory ? .notLoaded : .loaded
            )
            entries[id] = entry
            childIDs.append(id)
        }
        rootIDs = sortedIDs(childIDs)
    }

    /// 展开目录：若尚未加载则触发浅扫描，将 ID 加入 expandedIDs。
    func expandDirectory(_ id: EntryID) async throws {
        guard let entry = entries[id], entry.isDirectory else { return }
        expandedIDs.insert(id)

        guard entry.loadState == .notLoaded else { return }

        // 标记 loading
        entries[id]?.loadState = .loading
        let scanned = try await scanner.shallowScan(directory: id.url)

        var childIDs: [EntryID] = []
        for item in scanned {
            let childIDVal = EntryID(url: item.url.standardizedFileURL)
            let childEntry = FileEntry(
                id: childIDVal,
                name: item.name,
                isDirectory: item.isDirectory,
                parentID: id,
                loadState: item.isDirectory ? .notLoaded : .loaded
            )
            entries[childIDVal] = childEntry
            childIDs.append(childIDVal)
        }
        children[id] = sortedIDs(childIDs)
        entries[id]?.loadState = .loaded
    }

    /// 折叠目录：从 expandedIDs 移除，不卸载 children（保留缓存）。
    func collapseDirectory(_ id: EntryID) {
        expandedIDs.remove(id)
    }

    /// O(1) 查找条目。
    func entry(for id: EntryID) -> FileEntry? {
        entries[id]
    }

    // MARK: - computeVisibleEntries
    //
    // 核心热路径：DFS 遍历 rootIDs，生成 [VisibleEntry]。
    // 参考 Zed update_visible_entries（project_panel.rs）的 background_spawn 模式：
    // 计算在后台线程，结果推送回主线程。
    // 本 Actor 方法在 actor executor 上运行（等同于后台线程），
    // 调用方在 FileTreeViewModel 中用 Task { @MainActor in ... } 接收结果。

    func computeVisibleEntries(
        searchFilter: String? = nil
    ) -> [VisibleEntry] {
        var result: [VisibleEntry] = []
        dfs(ids: rootIDs, depth: 0, result: &result, searchFilter: searchFilter)
        return result
    }

    // MARK: - 私有

    private func dfs(
        ids: [EntryID],
        depth: Int,
        result: inout [VisibleEntry],
        searchFilter: String?
    ) {
        for id in ids {
            guard let entry = entries[id] else { continue }

            // 搜索过滤（简单前缀匹配，FT-R10 实现模糊搜索）
            if let filter = searchFilter, !filter.isEmpty {
                if !entry.name.localizedCaseInsensitiveContains(filter) {
                    continue
                }
            }

            let isExpanded = entry.isDirectory && expandedIDs.contains(id)
            let visible = VisibleEntry(
                id: id,
                name: entry.name,
                isDirectory: entry.isDirectory,
                depth: depth,
                isExpanded: isExpanded,
                foldedAncestors: nil,   // Auto-fold 在 FT-R5 实现
                gitSummary: nil,         // Git badge 在 FT-R7 实现
                diagnosticSeverity: nil, // Diag badge 在 FT-R14 实现
                isIgnored: false         // .gitignore 在 FT-R6 实现
            )
            result.append(visible)

            if isExpanded, let childIDs = children[id] {
                dfs(ids: childIDs, depth: depth + 1, result: &result, searchFilter: searchFilter)
            }
        }
    }

    /// 按目录优先、名称升序排列 EntryID 列表。
    /// 参考 Zed `par_sort_worktree_entries_with_mode` / VSCode `FileSorter`。
    private func sortedIDs(_ ids: [EntryID]) -> [EntryID] {
        ids.sorted { a, b in
            let entryA = entries[a]
            let entryB = entries[b]
            let aIsDir = entryA?.isDirectory ?? false
            let bIsDir = entryB?.isDirectory ?? false
            if aIsDir != bIsDir { return aIsDir }  // 目录优先
            let nameA = entryA?.name ?? a.url.lastPathComponent
            let nameB = entryB?.name ?? b.url.lastPathComponent
            return nameA.localizedStandardCompare(nameB) == .orderedAscending
        }
    }
}
```

### Step 4：运行全部 Store 测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FileTreeStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`** TEST SUCCEEDED **`（6 个测试全通过）

### Step 5：提交

```
git add agentGui/Services/FileTreeStore.swift
git commit -m "FT-R0 task6: FileTreeStore actor - setRoot + expand + collapse + computeVisibleEntries"
```

---

## Task 7：补充边界测试 + 验证并发安全

**Files:**
- Modify: `agentGuiTests/FileTreeStoreTests.swift`

### Step 1：追加边界测试

```swift
// 追加到 FileTreeStoreTests

/// 空目录不报错，返回 0 行
func testSetRoot_emptyDirectory_returnsEmpty() async throws {
    let root = URL(fileURLWithPath: "/tmp/empty")
    let store = makeStore(entries: [root: []])
    await store.setRoot(root)
    let visible = await store.computeVisibleEntries()
    XCTAssertEqual(visible.count, 0)
}

/// 展开不存在的 ID 不崩溃
func testExpandDirectory_unknownID_doesNotCrash() async throws {
    let store = makeStore()
    let fakeID = EntryID(url: URL(fileURLWithPath: "/nonexistent"))
    try await store.expandDirectory(fakeID)   // 应静默通过
}

/// computeVisibleEntries 目录优先于文件
func testComputeVisibleEntries_directoriesBeforeFiles() async throws {
    let root = URL(fileURLWithPath: "/tmp/project")
    let dirURL = root.appendingPathComponent("src")
    let fileURL = root.appendingPathComponent("a.txt")
    let store = makeStore(entries: [
        root: [
            ScannedEntry(url: fileURL, name: "a.txt", isDirectory: false),
            ScannedEntry(url: dirURL, name: "src", isDirectory: true),
        ]
    ])
    await store.setRoot(root)
    let visible = await store.computeVisibleEntries()
    XCTAssertEqual(visible.count, 2)
    XCTAssertEqual(visible[0].name, "src")    // 目录排前
    XCTAssertEqual(visible[1].name, "a.txt")
}

/// depth 字段正确
func testComputeVisibleEntries_depth() async throws {
    let root = URL(fileURLWithPath: "/tmp/project")
    let srcURL = root.appendingPathComponent("src")
    let mainURL = srcURL.appendingPathComponent("main.swift")
    let store = makeStore(entries: [
        root: [ScannedEntry(url: srcURL, name: "src", isDirectory: true)],
        srcURL: [ScannedEntry(url: mainURL, name: "main.swift", isDirectory: false)],
    ])
    await store.setRoot(root)
    let srcID = EntryID(url: srcURL.standardizedFileURL)
    try await store.expandDirectory(srcID)
    let visible = await store.computeVisibleEntries()
    let depths = visible.map(\.depth)
    XCTAssertEqual(depths, [0, 1])   // src=0, main.swift=1
}

/// searchFilter 过滤名称
func testComputeVisibleEntries_searchFilter() async throws {
    let root = URL(fileURLWithPath: "/tmp/project")
    let store = makeStore(entries: [
        root: [
            ScannedEntry(url: root.appendingPathComponent("ContentView.swift"),
                         name: "ContentView.swift", isDirectory: false),
            ScannedEntry(url: root.appendingPathComponent("AppMain.swift"),
                         name: "AppMain.swift", isDirectory: false),
        ]
    ])
    await store.setRoot(root)
    let visible = await store.computeVisibleEntries(searchFilter: "Content")
    XCTAssertEqual(visible.count, 1)
    XCTAssertEqual(visible.first?.name, "ContentView.swift")
}
```

### Step 2：运行所有测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FileTreeStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：所有测试通过

### Step 3：静态 actor 隔离检查（构建不带测试）

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "warning:|error:" | head -30
```

确认：无 `Sendable` / actor-isolation 相关 warning。

### Step 4：提交

```
git add agentGuiTests/FileTreeStoreTests.swift
git commit -m "FT-R0 task7: edge case + concurrent safety tests"
```

---

## Task 8：将新文件注册到 Xcode 项目（pbxproj）

> 如果 Xcode 尚未自动将新建文件加入编译目标，需手动操作或用脚本确认。
> 新建文件在本机的 Xcode 中通过菜单 **File → Add Files to agentGui** 添加，
> 或通过 `agentGui.xcodeproj/project.pbxproj` 确认以下文件已在 `sources` section：
> - `agentGui/Models/FileEntry.swift`
> - `agentGui/Models/VisibleEntry.swift`
> - `agentGui/Models/GitSummary.swift`
> - `agentGui/Models/DiagSeverity.swift`
> - `agentGui/Models/SortOrder.swift`
> - `agentGui/Models/FileTreeSelection.swift`
> - `agentGui/Services/FileScanning.swift`
> - `agentGui/Services/FileTreeStore.swift`
> - `agentGuiTests/FileTreeStoreTests.swift`

### Step 1：验证完整测试通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ft-r0-derived \
  -only-testing:agentGuiTests/FileTreeStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

预期：`** TEST SUCCEEDED **`

### Step 2：提交最终

```
git add agentGui.xcodeproj/project.pbxproj
git commit -m "FT-R0: register new files in Xcode project"
```

---

## 完成检查清单

完成 FT-R0 后，以下内容应全部就绪：

- [ ] `EntryID`、`FileEntry`、`LoadState` — 可独立编译，`Sendable`
- [ ] `VisibleEntry`、`FoldedAncestors` — 可独立编译，`Sendable`
- [ ] `GitSummary`、`DiagSeverity`、`SortOrder` — `Comparable` 枚举
- [ ] `FileTreeSelection` — 含 `primary`、`selected`（保序）、`anchor`
- [ ] `FileScanning` 协议 + `RealFileScanner` + `MockFileScanner`（测试内）
- [ ] `FileTreeStore` actor — `setRoot`、`expandDirectory`、`collapseDirectory`、`computeVisibleEntries`、`entry(for:)`
- [ ] `FileTreeStoreTests` — 11 个测试全通过，无 Swift 6 actor-isolation warning
- [ ] 旧代码（`FileNode.swift`、`WorkspaceTreeViewModel.swift` 等）**不删除**（在 FT-R2 之后删除）

---

## 下一步（FT-R1）

FSEvent 观察器：`FSEventObserver` (Sendable) 监听目录变更，
调用 `FileTreeStore.applyFSEvents(_:scanner:)` 触发增量更新算法。
详见设计文档 Section 3.2。

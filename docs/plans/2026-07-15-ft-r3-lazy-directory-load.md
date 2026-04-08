# FT-R3：懒加载目录 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 完成目录节点的按需懒加载——展开时异步扫描子项、显示 loading spinner、扫描失败后恢复 `.notLoaded` 状态，并将错误传播到 ViewModel 层。

**Architecture:**
- `VisibleEntry` 增加 `loadState: FileEntry.LoadState` 字段，Cell 层据此决定是否渲染 `NSProgressIndicator`。
- `FileTreeStore.expandDirectory` 包裹 do/catch：失败时回退 `.notLoaded` + 移出 `expandedIDs`，再 rethrow。
- `FileTreeCellView` 用 `NSProgressIndicator` 替换展开箭头来指示加载中；加载完成后还原。
- `FileTreeViewModel` 新增 `errorMessage: String?` 属性，捕获 `expandDirectory` 抛出的错误并对外曝露。

**Tech Stack:** Swift 6.0+, AppKit (`NSProgressIndicator`), XCTest

**参考来源：**
- VSCode [`asyncDataTree.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/base/browser/ui/tree/asyncDataTree.ts)：
  - `asyncDataTree._updateChildren()` → `IAsyncDataTreeNode.slow`：当异步子节点加载超时时，节点切换到 `slow` 状态并显示 Twistie spinner。
  - `AsyncDataTreeRenderer.renderTwistie()` 检查 `element.slow` → 返回 `ThemeIcon.Loading`，而非展开箭头，对应本计划的"spinner 替换展开箭头"设计。
  - `asyncDataTree.setCollapsible(element, false)` 返回后立即 `tree.expand(node)`，说明 VSCode 在子节点加载完成前不允许 collapse（避免状态不一致），本计划在 `.loading` 时同样禁用展开箭头点击。
- Zed [`project_panel.rs`](https://github.com/zed-industries/zed/blob/main/crates/project_panel/src/project_panel.rs)：
  - `EntryDetails { is_dir_scanning: bool }`：扁平条目显式携带 scanning 标记，直接映射到本计划的 `VisibleEntry.loadState == .loading`。
  - `render_entry()` 中 `if details.is_dir_scanning { render_loading_indicator() } else { render_disclosure() }` — 本计划 `FileTreeCellView.configure()` 完全沿用该思路。
  - `ProjectPanel.fetch_directory_contents()` 错误路径：失败后调用 `worktree.forget_entry(id)` + 不加入 `expanded_entries`，对应本计划的 `revert to .notLoaded` 逻辑。
- 设计文档 `docs/plans/2026-07-15-filetree-rewrite-design.md` §FT-R3

---

## 前置条件

- 已完成 FT-R0 ✅（`FileEntry.LoadState`, `FileTreeStore`, `FileScanning` 协议存在）
- 已完成 FT-R1 ✅（`FSEventObserver` 集成到 `FileTreeStore`）
- 已完成 FT-R2 ✅（`FileTreeTableView`, `FileTreeCellView`, `FileTreeViewModel` 存在）

当前实现状态：

| 文件 | 现状 | FT-R3 缺口 |
|------|------|-----------|
| `agentGui/Services/FileTreeStore.swift` | `expandDirectory` 有 loading 状态切换，但无 do/catch 错误回退 | 需补 catch 块 |
| `agentGui/Models/VisibleEntry.swift` | 无 `loadState` 字段 | 需新增字段 |
| `agentGui/Views/FileTree/FileTreeCellView.swift` | 无 `NSProgressIndicator` | 需添加 spinner |
| `agentGui/ViewModels/FileTreeViewModel.swift` | 无 `errorMessage`，`toggleDirectory` 吞掉错误（`try?`） | 需暴露 error |
| `agentGuiTests/FileTreeStoreTests.swift` | 有 happy-path 测试，无错误路径 | 需新增错误场景 |

---

## Task 1：`MockFileScanner` 支持错误注入

**Files:**
- Modify: `agentGuiTests/FileTreeStoreTests.swift:279-296`（MockFileScanner 末尾）

无 `stubbedError` 的 Mock 无法测 `expandDirectory` 错误回退，所有后续测试依赖此步。

### Step 1：写一个预期失败的测试确认需要 stubbedError

```swift
// 在 FileTreeStoreTests.swift 末尾临时添加（稍后修正）
func testExpandDirectory_scanFailure_revertsToNotLoaded_PLACEHOLDER() async throws {
    // 预期此测试编译失败，因为 MockFileScanner 还没有 stubbedError
    // let scanner = MockFileScanner()
    // scanner.stubbedError = ...  // ← 编译错误，确认需要修改 Mock
    XCTFail("placeholder: MockFileScanner 需要 stubbedError 字段")
}
```

运行确认用例输出 FAIL（而非编译错误）。

### Step 2：扩展 `MockFileScanner`，添加 stubbedError

在 `agentGuiTests/FileTreeStoreTests.swift` 的 `MockFileScanner` 定义中：

```swift
final class MockFileScanner: FileScanning, @unchecked Sendable {
    var stubbedEntries: [URL: [ScannedEntry]] = [:]
    var onShallowScan: ((URL) -> Void)?
    // 新增：
    var stubbedError: Error?                       // 若非 nil，所有 shallowScan 调用均抛出此错误
    var stubbedErrorForURLs: [URL: Error] = [:]    // 细粒度：仅特定目录抛错

    func stub(directory: URL, entries: [ScannedEntry]) {
        stubbedEntries[directory.standardizedFileURL] = entries
    }

    func shallowScan(directory: URL) async throws -> [ScannedEntry] {
        onShallowScan?(directory)
        // 细粒度错误优先，其次全局错误
        if let err = stubbedErrorForURLs[directory.standardizedFileURL] { throw err }
        if let err = stubbedError { throw err }
        return stubbedEntries[directory.standardizedFileURL] ?? []
    }

    func isDirectory(_ url: URL) async -> Bool {
        return stubbedEntries[url.standardizedFileURL] != nil
    }
}
```

### Step 3：删除 placeholder 测试，运行现有测试确认 PASS

```bash
xcodebuild test -project agentGui.xcodeproj \
  -scheme agentGui -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ftr3-task1 \
  -only-testing:agentGuiTests/FileTreeStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：所有现有测试 PASS，无新失败。

### Step 4：提交

```bash
git add agentGuiTests/FileTreeStoreTests.swift
git commit -m "test(FT-R3): add stubbedError support to MockFileScanner"
```

---

## Task 2：`FileTreeStore.expandDirectory` — 错误回退

**Files:**
- Modify: `agentGui/Services/FileTreeStore.swift`（`expandDirectory` 方法体）

### Step 1：写失败测试（文件 `agentGuiTests/FileTreeStoreLazyLoadTests.swift`）

**新建** `agentGuiTests/FileTreeStoreLazyLoadTests.swift`：

```swift
// agentGuiTests/FileTreeStoreLazyLoadTests.swift
import XCTest
@testable import agentGui

final class FileTreeStoreLazyLoadTests: XCTestCase {

    // MARK: - 辅助

    struct ScanError: Error, Equatable {}

    func makeStore(
        entries: [URL: [ScannedEntry]] = [:],
        scanError: Error? = nil
    ) -> (FileTreeStore, MockFileScanner) {
        let scanner = MockFileScanner()
        scanner.stubbedEntries = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.key.standardizedFileURL, $0.value) }
        )
        scanner.stubbedError = scanError
        let store = FileTreeStore(scanner: scanner)
        return (store, scanner)
    }

    // MARK: - setRoot allDirsNotLoaded

    func testSetRoot_allDirectoriesMarkedNotLoaded() async throws {
        let root = URL(fileURLWithPath: "/tmp/p")
        let (store, _) = makeStore(entries: [
            root: [
                ScannedEntry(url: root.appendingPathComponent("src"), name: "src", isDirectory: true),
                ScannedEntry(url: root.appendingPathComponent("README.md"), name: "README.md", isDirectory: false),
            ]
        ])
        await store.setRoot(root)
        let visible = await store.computeVisibleEntries()
        // src 是目录，loadState 应为 .notLoaded
        let srcEntry = visible.first { $0.name == "src" }
        XCTAssertNotNil(srcEntry)
        XCTAssertEqual(srcEntry?.loadState, .notLoaded)
        // README.md 是文件，loadState 应为 .loaded
        let readmeEntry = visible.first { $0.name == "README.md" }
        XCTAssertEqual(readmeEntry?.loadState, .loaded)
    }

    // MARK: - expandDirectory happy path（已在 FileTreeStoreTests 覆盖，此处仅验证 loadState 变化）

    func testExpandDirectory_loadStateBecomesLoaded() async throws {
        let root = URL(fileURLWithPath: "/tmp/p")
        let srcURL = root.appendingPathComponent("src")
        let (store, _) = makeStore(entries: [
            root: [ScannedEntry(url: srcURL, name: "src", isDirectory: true)],
            srcURL: [ScannedEntry(url: srcURL.appendingPathComponent("a.swift"), name: "a.swift", isDirectory: false)],
        ])
        await store.setRoot(root)

        let srcID = EntryID(url: srcURL.standardizedFileURL)

        // 展开前 loadState = .notLoaded
        let beforeExpand = await store.entry(for: srcID)
        XCTAssertEqual(beforeExpand?.loadState, .notLoaded)

        try await store.expandDirectory(srcID)

        // 展开后 loadState = .loaded
        let afterExpand = await store.entry(for: srcID)
        XCTAssertEqual(afterExpand?.loadState, .loaded)
    }

    // MARK: - expandDirectory alreadyLoaded noIO

    func testExpandDirectory_alreadyLoaded_doesNotRescan() async throws {
        let root = URL(fileURLWithPath: "/tmp/p")
        let srcURL = root.appendingPathComponent("src")
        var scanCount = 0

        let scanner = MockFileScanner()
        scanner.stubbedEntries = [
            root.standardizedFileURL: [ScannedEntry(url: srcURL, name: "src", isDirectory: true)],
            srcURL.standardizedFileURL: [ScannedEntry(url: srcURL.appendingPathComponent("a.swift"),
                                                      name: "a.swift", isDirectory: false)],
        ]
        scanner.onShallowScan = { _ in scanCount += 1 }
        let store = FileTreeStore(scanner: scanner)

        await store.setRoot(root)
        let srcID = EntryID(url: srcURL.standardizedFileURL)
        let scanCountAfterSetRoot = scanCount  // setRoot 扫描 1 次（根目录）

        try await store.expandDirectory(srcID)
        XCTAssertEqual(scanCount, scanCountAfterSetRoot + 1, "第一次展开应扫描 1 次")

        // 第二次展开 — 已 loaded，不应再扫描
        try await store.expandDirectory(srcID)
        XCTAssertEqual(scanCount, scanCountAfterSetRoot + 1, "二次展开不应触发扫描")
    }

    // MARK: - expandDirectory 失败回退（核心 FT-R3 新增逻辑）

    func testExpandDirectory_scanFailure_revertsLoadStateToNotLoaded() async throws {
        let root = URL(fileURLWithPath: "/tmp/p")
        let srcURL = root.appendingPathComponent("src")
        let (store, scanner) = makeStore(entries: [
            root: [ScannedEntry(url: srcURL, name: "src", isDirectory: true)],
        ])
        await store.setRoot(root)

        // 注入错误（在 setRoot 之后，避免破坏 setRoot 自身的扫描）
        scanner.stubbedErrorForURLs[srcURL.standardizedFileURL] = ScanError()

        let srcID = EntryID(url: srcURL.standardizedFileURL)

        // 展开应抛出错误
        do {
            try await store.expandDirectory(srcID)
            XCTFail("应抛出错误")
        } catch {
            // 符合预期
        }

        // 错误后：loadState 回退到 notLoaded
        let entry = await store.entry(for: srcID)
        XCTAssertEqual(entry?.loadState, .notLoaded)

        // 错误后：目录不应被列为已展开（children 不可见）
        let visible = await store.computeVisibleEntries()
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.name, "src")
    }

    func testExpandDirectory_scanFailure_dirRemovedFromExpandedIDs() async throws {
        let root = URL(fileURLWithPath: "/tmp/p")
        let srcURL = root.appendingPathComponent("src")
        let (store, scanner) = makeStore(entries: [
            root: [ScannedEntry(url: srcURL, name: "src", isDirectory: true)],
        ])
        await store.setRoot(root)
        scanner.stubbedErrorForURLs[srcURL.standardizedFileURL] = ScanError()

        let srcID = EntryID(url: srcURL.standardizedFileURL)
        try? await store.expandDirectory(srcID)  // 忽略错误

        // expanded 状态应回退
        let isExpanded = await store.isExpanded(srcID)
        XCTAssertFalse(isExpanded)
    }

    // MARK: - computeVisibleEntries 暴露 loadState

    func testComputeVisibleEntries_notLoadedDir_hasNotLoadedState() async {
        let root = URL(fileURLWithPath: "/tmp/p")
        let srcURL = root.appendingPathComponent("src")
        let (store, _) = makeStore(entries: [
            root: [ScannedEntry(url: srcURL, name: "src", isDirectory: true)],
        ])
        await store.setRoot(root)
        let visible = await store.computeVisibleEntries()
        XCTAssertEqual(visible.first?.loadState, .notLoaded)
    }
}
```

### Step 2：运行测试确认失败

```bash
xcodebuild test -project agentGui.xcodeproj \
  -scheme agentGui -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ftr3-task2 \
  -only-testing:agentGuiTests/FileTreeStoreLazyLoadTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAILED|error:|VisibleEntry"
```

预期：编译错误（`VisibleEntry` 无 `loadState` 字段）或多个测试 FAIL。

### Step 3：修复 `VisibleEntry`，添加 `loadState` 字段

修改 `agentGui/Models/VisibleEntry.swift`：

```swift
struct VisibleEntry: Identifiable, Equatable, Sendable {
    let id: EntryID
    let name: String
    let isDirectory: Bool
    let depth: Int
    let isExpanded: Bool
    /// 目录的加载状态——Cell 据此决定是否显示 NSProgressIndicator。
    /// 参考 Zed `EntryDetails.is_dir_scanning`（project_panel.rs）。
    let loadState: FileEntry.LoadState          // ← 新增
    let foldedAncestors: FoldedAncestors?
    let gitSummary: GitSummary?
    let diagnosticSeverity: DiagSeverity?
    let isIgnored: Bool
}
```

### Step 4：修复 `FileTreeStore.dfs`，传递 `loadState`

在 `agentGui/Services/FileTreeStore.swift` 的 `dfs` 方法中，构建 `VisibleEntry` 处添加 `loadState`：

```swift
// 原代码：
let visible = VisibleEntry(
    id: id,
    name: entry.name,
    isDirectory: entry.isDirectory,
    depth: depth,
    isExpanded: isExpanded,
    foldedAncestors: nil,
    gitSummary: nil,
    diagnosticSeverity: nil,
    isIgnored: false
)

// 修改为：
let visible = VisibleEntry(
    id: id,
    name: entry.name,
    isDirectory: entry.isDirectory,
    depth: depth,
    isExpanded: isExpanded,
    loadState: entry.loadState,     // ← 新增
    foldedAncestors: nil,
    gitSummary: nil,
    diagnosticSeverity: nil,
    isIgnored: false
)
```

### Step 5：修复其他 `VisibleEntry` 构造点（测试文件）

全局搜索 `VisibleEntry(` 调用，为所有调用补全 `loadState:` 参数：

涉及文件：
- `agentGuiTests/FileTreeStoreTests.swift`（`testVisibleEntry_identifiableById` 内的直接构造）

```swift
// 修改前
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

// 修改后
let entry = VisibleEntry(
    id: id,
    name: "file.txt",
    isDirectory: false,
    depth: 1,
    isExpanded: false,
    loadState: .loaded,    // ← 新增，文件默认 .loaded
    foldedAncestors: nil,
    gitSummary: nil,
    diagnosticSeverity: nil,
    isIgnored: false
)
```

### Step 6：修复 `FileTreeStore.expandDirectory`，添加错误回退

在 `agentGui/Services/FileTreeStore.swift` 中，将 `expandDirectory` 的扫描部分改为 do/catch：

```swift
/// 展开目录：若尚未加载则触发浅扫描，将 ID 加入 expandedIDs。
///
/// 错误处理（参考 Zed `fetch_directory_contents()` 失败路径）：
/// - 扫描失败时：重置 loadState 为 .notLoaded，从 expandedIDs 移除，再 rethrow。
/// - 这确保目录在 UI 侧仍可再次点击展开，且 visibleEntries 不会出现悬空的 .loading 行。
func expandDirectory(_ id: EntryID) async throws {
    guard let entry = entries[id], entry.isDirectory else { return }
    expandedIDs.insert(id)

    guard entry.loadState == .notLoaded else { return }

    // 标记 loading，触发 UI spinner
    entries[id]?.loadState = .loading

    do {
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
    } catch {
        // 扫描失败：回退状态，确保 UI 一致性
        entries[id]?.loadState = .notLoaded
        expandedIDs.remove(id)
        throw error
    }
}
```

### Step 7：运行测试确认 PASS

```bash
xcodebuild test -project agentGui.xcodeproj \
  -scheme agentGui -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ftr3-task2 \
  -only-testing:agentGuiTests/FileTreeStoreLazyLoadTests \
  -only-testing:agentGuiTests/FileTreeStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`FileTreeStoreLazyLoadTests` 全部 PASS，`FileTreeStoreTests` 无回归。

### Step 8：提交

```bash
git add agentGui/Models/VisibleEntry.swift \
        agentGui/Services/FileTreeStore.swift \
        agentGuiTests/FileTreeStoreLazyLoadTests.swift \
        agentGuiTests/FileTreeStoreTests.swift
git commit -m "feat(FT-R3): VisibleEntry.loadState + expandDirectory error recovery"
```

---

## Task 3：`FileTreeCellView` — loading spinner

**Files:**
- Modify: `agentGui/Views/FileTree/FileTreeCellView.swift`

目标：当 `VisibleEntry.loadState == .loading` 时，将展开箭头替换为旋转 `NSProgressIndicator`（16×16 spinning），对标 Zed `render_entry()` 的 `is_dir_scanning` 分支，以及 VSCode `AsyncDataTreeRenderer.renderTwistie()` 的 `ThemeIcon.Loading` 逻辑。

### Step 1：写 UI 集成测试（如果 CI 有 UI 测试配置）

如果项目已有 UI 测试基础（`agentGuiUITests`），可跳过此步直接到 Step 2。  
否则，在 `agentGuiTests/FileTreeCellViewTests.swift` 中写简单快照测试验证配置逻辑（可选）。

### Step 2：添加 `NSProgressIndicator` 到 `FileTreeCellView`

在 `buildLayout()` 方法中添加 spinner，约束与 `disclosureButton` 完全重叠：

```swift
// 在 private let disclosureButton = NSButton() 下方添加：
private let loadingSpinner: NSProgressIndicator = {
    let p = NSProgressIndicator()
    p.style = .spinning
    p.isIndeterminate = true
    p.controlSize = .small    // 16pt，与 disclosureButton 相同宽高
    p.isHidden = true
    p.translatesAutoresizingMaskIntoConstraints = false
    return p
}()
```

在 `buildLayout()` 中，`addSubview(disclosureButton)` 之后：

```swift
addSubview(loadingSpinner)
```

在 `NSLayoutConstraint.activate([...])` 中追加 spinner 约束（与 disclosureButton 完全对齐）：

```swift
// loadingSpinner：与 disclosureButton 完全重叠（spinner 替代展开箭头）
loadingSpinner.leadingAnchor.constraint(equalTo: disclosureButton.leadingAnchor),
loadingSpinner.centerYAnchor.constraint(equalTo: disclosureButton.centerYAnchor),
loadingSpinner.widthAnchor.constraint(equalToConstant: 16),
loadingSpinner.heightAnchor.constraint(equalToConstant: 16),
```

### Step 3：在 `configure()` 中切换 spinner 与展开箭头

在 `configure(entry:isSelected:onToggle:)` 的展开箭头配置块修改如下：

```swift
// 2. 展开/折叠按钮 & loading spinner
// 参考：
//   Zed project_panel.rs `render_entry()` — `if details.is_dir_scanning { spinner } else { chevron }`
//   VSCode asyncDataTree.ts `renderTwistie()` — `.slow` 状态显示 ThemeIcon.Loading
if entry.isDirectory {
    switch entry.loadState {
    case .loading:
        // 扫描中：隐藏展开箭头，显示 spinner，禁用交互
        disclosureButton.isHidden = true
        loadingSpinner.isHidden = false
        loadingSpinner.startAnimation(nil)
        // 加载中不允许二次点击展开（避免重复触发扫描）
        disclosureButton.isEnabled = false
    case .notLoaded, .loaded:
        // 正常状态：显示展开箭头，隐藏 spinner
        loadingSpinner.stopAnimation(nil)
        loadingSpinner.isHidden = true
        disclosureButton.isHidden = false
        disclosureButton.isEnabled = true
        let symbolName = entry.isExpanded ? "chevron.down" : "chevron.right"
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        disclosureButton.image = NSImage(systemSymbolName: symbolName,
                                         accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
} else {
    loadingSpinner.stopAnimation(nil)
    loadingSpinner.isHidden = true
    disclosureButton.isHidden = true
    disclosureButton.isEnabled = true
}
```

### Step 4：编译验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：Build succeeded，无警告新增。

### Step 5：提交

```bash
git add agentGui/Views/FileTree/FileTreeCellView.swift
git commit -m "feat(FT-R3): FileTreeCellView loading spinner via NSProgressIndicator"
```

---

## Task 4：`FileTreeViewModel` — 错误暴露

**Files:**
- Modify: `agentGui/ViewModels/FileTreeViewModel.swift`
- Modify: `agentGuiTests/FileTreeViewModelTests.swift`

目标：如果目录扫描失败，ViewModel 将错误字符串写入 `errorMessage`，SwiftUI 层可绑定呈现 alert 或 inline 提示。

### Step 1：写失败测试

在 `agentGuiTests/FileTreeViewModelTests.swift` 末尾追加：

```swift
// MARK: - FT-R3 懒加载 + 错误处理

func testToggleDirectory_scanFailure_setsErrorMessage() async throws {
    let root = URL(fileURLWithPath: "/tmp/p")
    let srcURL = root.appendingPathComponent("src")

    let scanner = MockFileScanner()
    scanner.stubbedEntries = [
        root.standardizedFileURL: [ScannedEntry(url: srcURL, name: "src", isDirectory: true)],
    ]
    let store = FileTreeStore(scanner: scanner)
    let vm = FileTreeViewModel(store: store)

    await vm.setDirectory(root)
    XCTAssertNil(vm.errorMessage)

    // 在 setRoot 完成后注入错误（仅 src 目录扫描失败）
    scanner.stubbedErrorForURLs[srcURL.standardizedFileURL] = NSError(
        domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Permission denied"]
    )

    let srcID = EntryID(url: srcURL.standardizedFileURL)
    await vm.toggleDirectory(srcID)

    // 错误信息应被捕获
    XCTAssertNotNil(vm.errorMessage)
    XCTAssertTrue(vm.errorMessage?.contains("Permission denied") == true)

    // visibleEntries 仍只暴露 src 本身（无子节点）
    XCTAssertEqual(vm.visibleEntries.count, 1)
}

func testToggleDirectory_clearErrorOnSuccess() async throws {
    let root = URL(fileURLWithPath: "/tmp/p")
    let srcURL = root.appendingPathComponent("src")

    let scanner = MockFileScanner()
    scanner.stubbedEntries = [
        root.standardizedFileURL: [ScannedEntry(url: srcURL, name: "src", isDirectory: true)],
        srcURL.standardizedFileURL: [
            ScannedEntry(url: srcURL.appendingPathComponent("a.swift"), name: "a.swift", isDirectory: false)
        ],
    ]
    let store = FileTreeStore(scanner: scanner)
    let vm = FileTreeViewModel(store: store)

    await vm.setDirectory(root)

    // 设置一个先存的错误
    vm.errorMessage = "old error"

    let srcID = EntryID(url: srcURL.standardizedFileURL)
    await vm.toggleDirectory(srcID)

    // 成功展开后，errorMessage 应被清除
    XCTAssertNil(vm.errorMessage)
    XCTAssertEqual(vm.visibleEntries.count, 2)
}
```

### Step 2：运行测试确认失败

```bash
xcodebuild test -project agentGui.xcodeproj \
  -scheme agentGui -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ftr3-task4 \
  -only-testing:agentGuiTests/FileTreeViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAILED|error:"
```

预期：`testToggleDirectory_scanFailure_setsErrorMessage` 和 `testToggleDirectory_clearErrorOnSuccess` 失败（`errorMessage` 属性不存在）。

### Step 3：修改 `FileTreeViewModel`

在 `agentGui/ViewModels/FileTreeViewModel.swift` 中：

**（a）新增 `errorMessage` 属性**（在现有 `var selection` 之后）：

```swift
/// 最近一次目录扫描失败的本地化描述。
/// 参考 VSCode ExplorerView 的 `tree.setInput(null)` 错误恢复模式。
var errorMessage: String? = nil
```

**（b）修改 `toggleDirectory`**，将 `try?` 改为 do/catch：

```swift
/// 切换目录展开/折叠状态，更新 visibleEntries 快照。
///
/// 展开失败（扫描错误）时：
/// - `errorMessage` 设为本地化错误描述（Zed 在 status_bar 显示错误，本实现由调用层绑定）
/// - visibleEntries 维持原状（FileTreeStore 已完成回退）
func toggleDirectory(_ id: EntryID) async {
    if await store.isExpanded(id) {
        await store.collapseDirectory(id)
        errorMessage = nil
    } else {
        do {
            try await store.expandDirectory(id)
            errorMessage = nil   // 成功展开后清除上次错误
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    visibleEntries = await store.computeVisibleEntries()
}
```

### Step 4：运行测试确认 PASS

```bash
xcodebuild test -project agentGui.xcodeproj \
  -scheme agentGui -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ftr3-task4 \
  -only-testing:agentGuiTests/FileTreeViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：所有 `FileTreeViewModelTests` PASS，无回归。

### Step 5：提交

```bash
git add agentGui/ViewModels/FileTreeViewModel.swift \
        agentGuiTests/FileTreeViewModelTests.swift
git commit -m "feat(FT-R3): FileTreeViewModel.errorMessage + toggleDirectory error surface"
```

---

## Task 5：全量回归测试

确认 FT-R3 所有改动不破坏已有测试：

```bash
xcodebuild test -project agentGui.xcodeproj \
  -scheme agentGui -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ftr3-regression \
  -only-testing:agentGuiTests/FileTreeStoreTests \
  -only-testing:agentGuiTests/FileTreeStoreLazyLoadTests \
  -only-testing:agentGuiTests/FileTreeStoreFSEventTests \
  -only-testing:agentGuiTests/FileTreeViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：全部 PASS。

### Step 1 — 如有失败，对照以下已知风险点排查

| 风险 | 排查方式 |
|------|---------|
| `VisibleEntry` 初始化调用遗漏 `loadState:` | `grep -r "VisibleEntry(" agentGuiTests/` 检查所有调用 |
| `MockFileScanner.stubbedError` 影响 setRoot | 测试中应在 `setRoot` 之后再注入 `stubbedErrorForURLs` |
| `loadingSpinner.startAnimation` 在非主线程调用 | Cell 的 `configure` 由 `Coordinator.tableView(_:viewFor:row:)` 在主线程调用，无需修改 |

### Step 2 — 提交

```bash
git add -A
git commit -m "test(FT-R3): full regression pass — lazy directory load complete"
```

---

## 完成标准 Checklist

- [ ] `VisibleEntry.loadState: FileEntry.LoadState` 字段存在
- [ ] `FileTreeStore.computeVisibleEntries` 正确填充 `loadState`
- [ ] `FileTreeStore.expandDirectory` 失败时 loadState 回退到 `.notLoaded`，并从 `expandedIDs` 移除
- [ ] `FileTreeCellView` 在 `.loading` 时显示 `NSProgressIndicator`，在其他状态显示展开箭头
- [ ] `FileTreeViewModel.errorMessage` 在扫描失败时包含错误描述，成功时清空
- [ ] `MockFileScanner` 支持 `stubbedError: Error?` 和 `stubbedErrorForURLs: [URL: Error]`
- [ ] `FileTreeStoreLazyLoadTests` 全部 PASS（5 个用例）
- [ ] `FileTreeViewModelTests` 新增 2 个 FT-R3 用例全部 PASS
- [ ] 所有 FT-R0 / FT-R1 / FT-R2 已有用例无回归

---

## 估计规模

| 类型 | 行数 |
|------|------|
| `VisibleEntry.loadState` 字段 | ~3 行 |
| `FileTreeStore.expandDirectory` do/catch | ~10 行（净增） |
| `FileTreeStore.dfs` loadState 传递 | ~2 行 |
| `FileTreeCellView` spinner | ~30 行 |
| `FileTreeViewModel.errorMessage` | ~15 行 |
| `FileTreeStoreLazyLoadTests` | ~130 行 |
| `FileTreeViewModelTests` 新增 | ~60 行 |
| `MockFileScanner` 扩展 | ~8 行 |
| **合计** | **~258 行** |

// agentGuiTests/FileTreeDiffUpdateTests.swift
import XCTest
@testable import agentGui

@MainActor
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
        let vm = FileTreeViewModel(store: store)

        await vm.setDirectory(root)
        let beforeCount = vm.visibleEntries.count
        XCTAssertEqual(beforeCount, 2)  // src + README.md

        let srcID = EntryID(url: srcURL.standardizedFileURL)
        await vm.toggleDirectory(srcID)

        let afterCount = vm.visibleEntries.count
        XCTAssertEqual(afterCount, 4)  // src + main.swift + util.swift + README.md

        // diff 应为 2 行插入（main.swift, util.swift），无删除
        let snapshot = vm.visibleEntries
        let beforeEntries = Array(snapshot.prefix(beforeCount))
        let diff = FileTreeDiff.compute(
            from: beforeEntries,
            to: snapshot
        )
        XCTAssertFalse(diff.shouldFullReload)
        XCTAssertEqual(diff.insertions.count, 2)
        XCTAssertTrue(diff.removals.isEmpty)
    }
}

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

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

    func makeStore() -> FileTreeStore {
        FileTreeStore(scanner: MockFileScanner())
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

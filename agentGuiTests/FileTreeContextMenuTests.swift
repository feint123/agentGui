// agentGuiTests/FileTreeContextMenuTests.swift
import XCTest
@testable import agentGui

final class FileTreeContextMenuTests: XCTestCase {

    // MARK: - 菜单结构验证（无需 UI，只检查 NSMenuItem 数量和 title）

    func testMenu_noSelection_showsNewItemsOnly() {
        var newFileCalled = false
        let config = FileTreeContextMenu.Config(
            targetEntry: nil,
            selectedEntries: [],
            isRoot: false,
            rootURL: URL(fileURLWithPath: "/project"),
            onNewFile: { newFileCalled = true },
            onNewFolder: {},
            onRename: {},
            onDelete: {},
            onRevealInFinder: {},
            onCopyPath: {},
            onPreviewDiff: nil
        )
        let menu = FileTreeContextMenu.build(config)
        // 无选中时：新建文件、新建文件夹（2 项） + 分隔符 + Reveal + CopyPath（2 项）= 5 项
        XCTAssertEqual(menu.items.count, 5)
        XCTAssertEqual(menu.items[0].title, "新建文件")
        XCTAssertEqual(menu.items[1].title, "新建文件夹")
        XCTAssertTrue(menu.items[2].isSeparatorItem)
    }

    func testMenu_singleFileSelection_showsAllItems() {
        let config = FileTreeContextMenu.Config(
            targetEntry: makeFileEntry(),
            selectedEntries: [makeFileEntry()],
            isRoot: false,
            rootURL: URL(fileURLWithPath: "/project"),
            onNewFile: {}, onNewFolder: {}, onRename: {}, onDelete: {},
            onRevealInFinder: {}, onCopyPath: {}, onPreviewDiff: nil
        )
        let menu = FileTreeContextMenu.build(config)
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("重命名"))
        XCTAssertTrue(titles.contains("删除"))
        XCTAssertTrue(titles.contains("在访达中显示"))
        XCTAssertTrue(titles.contains("复制相对路径"))
    }

    func testMenu_multipleSelection_renameItemDisabled() {
        let entry1 = makeFileEntry(name: "A.swift")
        let entry2 = makeFileEntry(name: "B.swift")
        let config = FileTreeContextMenu.Config(
            targetEntry: entry1,
            selectedEntries: [entry1, entry2],
            isRoot: false,
            rootURL: URL(fileURLWithPath: "/project"),
            onNewFile: {}, onNewFolder: {}, onRename: {}, onDelete: {},
            onRevealInFinder: {}, onCopyPath: {}, onPreviewDiff: nil
        )
        let menu = FileTreeContextMenu.build(config)
        let renameItem = menu.items.first { $0.title == "重命名" }
        XCTAssertNotNil(renameItem)
        XCTAssertFalse(renameItem!.isEnabled)
    }

    func testMenu_rootDirectory_noRenameOrDelete() {
        let config = FileTreeContextMenu.Config(
            targetEntry: makeDirEntry(name: "project"),
            selectedEntries: [makeDirEntry(name: "project")],
            isRoot: true,
            rootURL: URL(fileURLWithPath: "/project"),
            onNewFile: {}, onNewFolder: {}, onRename: {}, onDelete: {},
            onRevealInFinder: {}, onCopyPath: {}, onPreviewDiff: nil
        )
        let menu = FileTreeContextMenu.build(config)
        let titles = menu.items.map(\.title)
        XCTAssertFalse(titles.contains("重命名"))
        XCTAssertFalse(titles.contains("删除"))
    }

    func testMenu_gitChangedFile_showsPreviewDiff() {
        var diffCalled = false
        let config = FileTreeContextMenu.Config(
            targetEntry: makeFileEntry(),
            selectedEntries: [makeFileEntry()],
            isRoot: false,
            rootURL: URL(fileURLWithPath: "/project"),
            onNewFile: {}, onNewFolder: {}, onRename: {}, onDelete: {},
            onRevealInFinder: {}, onCopyPath: {},
            onPreviewDiff: { diffCalled = true }   // 非 nil → 显示该项
        )
        let menu = FileTreeContextMenu.build(config)
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("查看 Diff"))
        _ = diffCalled  // suppress unused warning
    }

    func testMenu_noGitChange_noPreviewDiff() {
        let config = FileTreeContextMenu.Config(
            targetEntry: makeFileEntry(),
            selectedEntries: [makeFileEntry()],
            isRoot: false,
            rootURL: URL(fileURLWithPath: "/project"),
            onNewFile: {}, onNewFolder: {}, onRename: {}, onDelete: {},
            onRevealInFinder: {}, onCopyPath: {},
            onPreviewDiff: nil    // nil → 不显示
        )
        let menu = FileTreeContextMenu.build(config)
        let titles = menu.items.map(\.title)
        XCTAssertFalse(titles.contains("查看 Diff"))
    }

    func testMenu_newFileClosure_invoked() {
        var called = false
        let config = FileTreeContextMenu.Config(
            targetEntry: nil, selectedEntries: [], isRoot: false,
            rootURL: URL(fileURLWithPath: "/project"),
            onNewFile: { called = true },
            onNewFolder: {}, onRename: {}, onDelete: {},
            onRevealInFinder: {}, onCopyPath: {}, onPreviewDiff: nil
        )
        let menu = FileTreeContextMenu.build(config)
        // 直接触发第一项 action（HandlerInterceptor）
        let firstItem = menu.items[0]
        _ = firstItem.target?.perform(firstItem.action)
        XCTAssertTrue(called)
    }

    // MARK: - Helpers

    private func makeFileEntry(name: String = "File.swift") -> VisibleEntry {
        VisibleEntry(
            id: EntryID(url: URL(fileURLWithPath: "/project/\(name)")),
            name: name, isDirectory: false, depth: 1,
            isExpanded: false, loadState: .loaded,
            foldedAncestors: nil, gitSummary: nil,
            diagnosticSeverity: nil, isIgnored: false
        )
    }

    private func makeDirEntry(name: String = "src") -> VisibleEntry {
        VisibleEntry(
            id: EntryID(url: URL(fileURLWithPath: "/project/\(name)")),
            name: name, isDirectory: true, depth: 1,
            isExpanded: false, loadState: .loaded,
            foldedAncestors: nil, gitSummary: nil,
            diagnosticSeverity: nil, isIgnored: false
        )
    }
}

// MARK: - Coordinator 集成测试（无需显示窗口）

final class FileTreeContextMenuCoordinatorTests: XCTestCase {

    func testBuildContextMenu_forFileRow_containsExpectedItems() {
        let entry = makeVisibleFile(name: "App.swift", hasGitChange: false)
        let coordinator = makeCoordinator(entries: [entry])
        let menu = coordinator.buildContextMenu(forRow: 0)
        XCTAssertNotNil(menu)
        let titles = menu!.items.map(\.title)
        XCTAssertTrue(titles.contains("新建文件"))
        XCTAssertTrue(titles.contains("在访达中显示"))
        XCTAssertTrue(titles.contains("复制相对路径"))
    }

    func testBuildContextMenu_forOutOfBoundsRow_returnsNil() {
        let coordinator = makeCoordinator(entries: [])
        let menu = coordinator.buildContextMenu(forRow: 5)
        XCTAssertNil(menu)
    }

    func testBuildContextMenu_forGitChangedFile_showsDiff() {
        let entry = makeVisibleFile(name: "Changed.swift", hasGitChange: true)
        let coordinator = makeCoordinator(entries: [entry])
        let menu = coordinator.buildContextMenu(forRow: 0)
        let titles = menu!.items.map(\.title)
        XCTAssertTrue(titles.contains("查看 Diff"))
    }

    func testBuildContextMenu_forNegativeRow_returnsNil() {
        let coordinator = makeCoordinator(entries: [makeVisibleFile()])
        XCTAssertNil(coordinator.buildContextMenu(forRow: -1))
    }

    // MARK: - Helpers

    private func makeVisibleFile(name: String = "File.swift", hasGitChange: Bool = false) -> VisibleEntry {
        VisibleEntry(
            id: EntryID(url: URL(fileURLWithPath: "/project/\(name)")),
            name: name, isDirectory: false, depth: 1,
            isExpanded: false, loadState: .loaded,
            foldedAncestors: nil,
            gitSummary: hasGitChange ? .modified : nil,
            diagnosticSeverity: nil, isIgnored: false
        )
    }

    private func makeCoordinator(entries: [VisibleEntry]) -> FileTreeTableView.Coordinator {
        let c = FileTreeTableView.Coordinator(
            entries: entries,
            selection: .init(),
            onSelect: { _, _ in }, onToggleExpand: { _ in }, onDoubleClick: { _ in }
        )
        c.rootURL = URL(fileURLWithPath: "/project")
        return c
    }
}

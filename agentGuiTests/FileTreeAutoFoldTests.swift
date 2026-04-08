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

    /// 构造一个三层单子目录树：根层只有 src/，src 展开后只有 main/，main 展开后只有 java/。
    /// src 已展开，main 已展开，java 已展开。全部条目加载完成。
    func makeLinearChainStore() async -> FileTreeStore {
        let store = FileTreeStore(scanner: MockFileScanner())

        let srcID  = EntryID(url: URL(fileURLWithPath: "/tmp/root/src"))
        let mainID = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/main"))
        let javaID = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/main/java"))

        await store.injectEntries([
            srcID:  FileEntry(id: srcID,  name: "src",  isDirectory: true, parentID: nil,    loadState: .loaded),
            mainID: FileEntry(id: mainID, name: "main", isDirectory: true, parentID: srcID,  loadState: .loaded),
            javaID: FileEntry(id: javaID, name: "java", isDirectory: true, parentID: mainID, loadState: .loaded),
        ], children: [
            srcID:  [mainID],
            mainID: [javaID],
            javaID: [],
        ], rootIDs: [srcID],
           expandedIDs: [srcID, mainID])

        return store
    }

    // MARK: - 单子目录链被压缩

    /// src → main → java 全是单子目录，compactFolders = true
    /// 期望：visibleEntries 只有 1 行（java），foldedAncestors 含 [src, main, java] 三段
    func testAutoFold_singleChildChainCompressed() async throws {
        let store = await makeLinearChainStore()
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
        let store = FileTreeStore(scanner: MockFileScanner())

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
        let store = await makeLinearChainStore()
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
        let store = await makeLinearChainStore()
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

    // MARK: - 未展开目录不被折叠

    /// src 尚未展开（不在 expandedIDs 中），不应参与自动折叠
    func testAutoFold_collapsedDirNotFolded() async throws {
        let store = FileTreeStore(scanner: MockFileScanner())

        let srcID  = EntryID(url: URL(fileURLWithPath: "/tmp/root/src"))
        let mainID = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/main"))

        await store.injectEntries([
            srcID:  FileEntry(id: srcID,  name: "src",  isDirectory: true, parentID: nil,    loadState: .loaded),
            mainID: FileEntry(id: mainID, name: "main", isDirectory: true, parentID: srcID,  loadState: .loaded),
        ], children: [
            srcID:  [mainID],
            mainID: [],
        ], rootIDs: [srcID],
           expandedIDs: [])  // src 未展开

        await store.setCompactFolders(true)

        let entries = await store.computeVisibleEntries()

        // src 未展开，不参与折叠链；可见列表只有 src（未展开）
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].foldedAncestors, "未展开目录不应被折叠")
    }

    // MARK: - 每段 EntryID 正确

    func testAutoFold_segmentsHaveCorrectEntryIDs() async throws {
        let store = await makeLinearChainStore()
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
        let store = FileTreeStore(scanner: MockFileScanner())

        let srcID  = EntryID(url: URL(fileURLWithPath: "/tmp/root/src"))
        let mainID = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/main"))
        let javaID = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/main/java"))
        let fileID = EntryID(url: URL(fileURLWithPath: "/tmp/root/src/main/java/Main.java"))

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

// MARK: - ViewModel 接入（Task 2）

final class FileTreeViewModelAutoFoldTests: XCTestCase {

    /// unfoldDirectory 透传后触发 computeVisibleEntries，链断开
    func testViewModel_unfoldDirectory_updatesVisibleEntries() async throws {
        let store = FileTreeStore(scanner: MockFileScanner())
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
        let store = FileTreeStore(scanner: MockFileScanner())
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
        XCTAssertNotNil(cell.onUnfoldSegment)
        _ = unfoldCalled
    }

    /// 不含 foldedAncestors 的普通行：configure 后 onUnfoldSegment 为 nil
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

// MARK: - AppSettings 集成（Task 4）

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
        let store = FileTreeStore(scanner: MockFileScanner())
        let vm = await FileTreeViewModel(store: store, settings: settings)
        let actual = await vm.isCompactFoldersEnabled
        XCTAssertFalse(actual)
    }
}

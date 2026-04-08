// agentGuiTests/FileTreeInlineEditTests.swift
import XCTest
@testable import agentGui

/// FT-R8 内联编辑测试。
///
/// 对标：
/// - VSCode `editableData.validationMessage()` 的 ERROR/WARNING 分类
/// - Zed `populate_validation_error(cx)` 的 empty / whitespace / already_exists 检测
final class FileTreeInlineEditTests: XCTestCase {

    // MARK: - 校验：EditValidationError

    func testValidation_emptyName_returnsEmptyNameError() {
        let session = InlineEditSession(
            kind: .createFile,
            parentDirectoryID: EntryID(url: URL(fileURLWithPath: "/tmp/root")),
            targetEntryID: nil,
            placeholderIndex: 0,
            draftName: ""
        )
        XCTAssertEqual(session.validateDraftName(siblingNames: []), .emptyName)
    }

    func testValidation_whitespaceOnly_returnsEmptyNameError() {
        let session = InlineEditSession(
            kind: .createFile,
            parentDirectoryID: EntryID(url: URL(fileURLWithPath: "/tmp/root")),
            targetEntryID: nil,
            placeholderIndex: 0,
            draftName: "   "
        )
        XCTAssertEqual(session.validateDraftName(siblingNames: []), .emptyName)
    }

    func testValidation_duplicateName_returnsDuplicateError() {
        let session = InlineEditSession(
            kind: .createFile,
            parentDirectoryID: EntryID(url: URL(fileURLWithPath: "/tmp/root")),
            targetEntryID: nil,
            placeholderIndex: 0,
            draftName: "main.swift"
        )
        let error = session.validateDraftName(siblingNames: ["main.swift", "utils.swift"])
        XCTAssertEqual(error, .duplicateName("main.swift"))
    }

    func testValidation_duplicateName_caseInsensitive_returnsError() {
        let session = InlineEditSession(
            kind: .createFile,
            parentDirectoryID: EntryID(url: URL(fileURLWithPath: "/tmp/root")),
            targetEntryID: nil,
            placeholderIndex: 0,
            draftName: "MAIN.SWIFT"
        )
        let error = session.validateDraftName(siblingNames: ["main.swift"])
        XCTAssertEqual(error, .duplicateName("MAIN.SWIFT"))
    }

    func testValidation_illegalCharacter_slash_returnsError() {
        let session = InlineEditSession(
            kind: .createFile,
            parentDirectoryID: EntryID(url: URL(fileURLWithPath: "/tmp/root")),
            targetEntryID: nil,
            placeholderIndex: 0,
            draftName: "foo/bar"
        )
        XCTAssertEqual(session.validateDraftName(siblingNames: []), .illegalCharacter("/"))
    }

    func testValidation_validName_returnsNil() {
        let session = InlineEditSession(
            kind: .createFile,
            parentDirectoryID: EntryID(url: URL(fileURLWithPath: "/tmp/root")),
            targetEntryID: nil,
            placeholderIndex: 0,
            draftName: "NewFile.swift"
        )
        XCTAssertNil(session.validateDraftName(siblingNames: ["main.swift"]))
    }

    // MARK: - VisibleEntry 占位行

    func testPlaceholderEntry_isEditPlaceholder_isTrue() {
        let parentID = EntryID(url: URL(fileURLWithPath: "/tmp/root"))
        let placeholder = VisibleEntry.placeholder(depth: 1, parentID: parentID)
        XCTAssertTrue(placeholder.isEditPlaceholder)
        XCTAssertEqual(placeholder.id, .placeholderSentinel)
    }

    func testNormalEntry_isEditPlaceholder_isFalse() {
        let id = EntryID(url: URL(fileURLWithPath: "/tmp/root/main.swift"))
        let entry = VisibleEntry(
            id: id, name: "main.swift", isDirectory: false,
            depth: 1, isExpanded: false, loadState: .loaded,
            foldedAncestors: nil, gitSummary: nil,
            diagnosticSeverity: nil, isIgnored: false,
            isEditPlaceholder: false
        )
        XCTAssertFalse(entry.isEditPlaceholder)
    }

    // MARK: - InlineEditSession.isNewEntry

    func testIsNewEntry_createFile_isTrue() {
        let session = InlineEditSession(
            kind: .createFile,
            parentDirectoryID: EntryID(url: URL(fileURLWithPath: "/tmp/root")),
            targetEntryID: nil,
            placeholderIndex: 0,
            draftName: "new.txt"
        )
        XCTAssertTrue(session.isNewEntry)
    }

    func testIsNewEntry_rename_isFalse() {
        let targetID = EntryID(url: URL(fileURLWithPath: "/tmp/root/old.txt"))
        let session = InlineEditSession(
            kind: .rename,
            parentDirectoryID: EntryID(url: URL(fileURLWithPath: "/tmp/root")),
            targetEntryID: targetID,
            placeholderIndex: -1,
            draftName: "old.txt"
        )
        XCTAssertFalse(session.isNewEntry)
    }
}

// MARK: - FileTreeViewModel 集成测试

extension FileTreeInlineEditTests {

    // MARK: 辅助

    /// 快速构造 VisibleEntry（非占位行）
    func entry(name: String, depth: Int = 0, isDirectory: Bool = false,
               urlPath: String? = nil) -> VisibleEntry {
        let path = urlPath ?? "/tmp/\(name)"
        return VisibleEntry(
            id: EntryID(url: URL(fileURLWithPath: path)),
            name: name,
            isDirectory: isDirectory,
            depth: depth,
            isExpanded: false,
            loadState: .loaded,
            foldedAncestors: nil,
            gitSummary: nil,
            diagnosticSeverity: nil,
            isIgnored: false,
            isEditPlaceholder: false
        )
    }

    // MARK: - beginCreate / cancelEdit

    /// beginCreate 应在 visibleEntries 中插入占位行，并设置 inlineEdit。
    @MainActor
    func testBeginCreate_insertsPlaceholder() async {
        let vm = FileTreeViewModel(store: FileTreeStore())
        let srcEntry = entry(name: "src", isDirectory: true)
        let mainEntry = entry(name: "main.swift")
        vm.visibleEntries = [srcEntry, mainEntry]

        await vm.beginCreate(.createFile, near: mainEntry.id)

        XCTAssertNotNil(vm.inlineEdit)
        XCTAssertEqual(vm.inlineEdit?.kind, .createFile)
        let placeholder = vm.visibleEntries.first(where: { $0.isEditPlaceholder })
        XCTAssertNotNil(placeholder, "应插入占位行")
        XCTAssertEqual(vm.visibleEntries.count, 3, "原 2 条目 + 1 占位行 = 3")
    }

    /// cancelEdit 应移除占位行并清空 inlineEdit。
    @MainActor
    func testCancelEdit_removesPlaceholder() async {
        let vm = FileTreeViewModel(store: FileTreeStore())
        let srcEntry = entry(name: "src", isDirectory: true)
        vm.visibleEntries = [srcEntry]

        await vm.beginCreate(.createFile, near: srcEntry.id)
        XCTAssertEqual(vm.visibleEntries.count, 2)

        vm.cancelEdit()

        XCTAssertNil(vm.inlineEdit)
        XCTAssertFalse(vm.visibleEntries.contains(where: { $0.isEditPlaceholder }),
                       "cancelEdit 后应移除占位行")
        XCTAssertEqual(vm.visibleEntries.count, 1)
    }

    // MARK: - beginRename

    /// beginRename 设置 inlineEdit（kind=.rename，targetEntryID 非 nil），不插入占位行。
    @MainActor
    func testBeginRename_showsCurrentName() async {
        let vm = FileTreeViewModel(store: FileTreeStore())
        let mainEntry = entry(name: "main.swift")
        vm.visibleEntries = [mainEntry]

        await vm.beginRename(mainEntry.id)

        XCTAssertNotNil(vm.inlineEdit)
        XCTAssertEqual(vm.inlineEdit?.kind, .rename)
        XCTAssertEqual(vm.inlineEdit?.targetEntryID, mainEntry.id)
        XCTAssertEqual(vm.inlineEdit?.draftName, "main.swift")
        XCTAssertFalse(vm.visibleEntries.contains(where: { $0.isEditPlaceholder }),
                       "重命名不插入占位行")
        XCTAssertEqual(vm.visibleEntries.count, 1)
    }

    // MARK: - commitEdit 校验守卫

    /// commitEdit 空名时：不执行写磁盘，保留占位行，设 validationError。
    @MainActor
    func testCommitCreate_emptyName_showsError() async {
        let vm = FileTreeViewModel(store: FileTreeStore())
        let srcEntry = entry(name: "src", isDirectory: true)
        vm.visibleEntries = [srcEntry]

        await vm.beginCreate(.createFile, near: srcEntry.id)
        vm.inlineEdit?.draftName = ""

        await vm.commitEdit()

        XCTAssertNotNil(vm.inlineEdit, "空名时不提交，inlineEdit 保留")
        XCTAssertEqual(vm.validationError, .emptyName)
        XCTAssertTrue(vm.visibleEntries.contains(where: { $0.isEditPlaceholder }),
                      "占位行应保留")
    }

    // MARK: - 端到端：写磁盘

    /// commitEdit（新建文件）：文件写入临时目录，占位行消失，inlineEdit 清空。
    @MainActor
    func testCommitCreate_createsFileAndRefreshes() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let vm = FileTreeViewModel(store: FileTreeStore())
        await vm.setDirectory(tmpDir)
        try await Task.sleep(for: .milliseconds(300))

        let initialCount = vm.visibleEntries.count
        await vm.beginCreate(.createFile, near: nil)
        vm.inlineEdit?.draftName = "hello.txt"

        await vm.commitEdit()

        let newFile = tmpDir.appendingPathComponent("hello.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFile.path), "hello.txt 应写入磁盘")
        XCTAssertNil(vm.inlineEdit)
        XCTAssertNil(vm.validationError)
        XCTAssertFalse(vm.visibleEntries.contains(where: { $0.isEditPlaceholder }))
        XCTAssertEqual(vm.visibleEntries.count, initialCount + 1)
    }

    /// commitEdit（重命名）：磁盘文件名更新，条目名称在 visibleEntries 中变更。
    @MainActor
    func testCommitRename_renamesAndRefreshes() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let originalFile = tmpDir.appendingPathComponent("old.txt")
        FileManager.default.createFile(atPath: originalFile.path, contents: nil)

        let vm = FileTreeViewModel(store: FileTreeStore())
        await vm.setDirectory(tmpDir)
        try await Task.sleep(for: .milliseconds(300))

        guard let oldEntry = vm.visibleEntries.first(where: { $0.name == "old.txt" }) else {
            XCTFail("应能找到 old.txt 条目"); return
        }

        await vm.beginRename(oldEntry.id)
        vm.inlineEdit?.draftName = "new.txt"
        await vm.commitEdit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: originalFile.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmpDir.appendingPathComponent("new.txt").path))
        XCTAssertNil(vm.inlineEdit)
        XCTAssertFalse(vm.visibleEntries.contains(where: { $0.name == "old.txt" }))
        XCTAssertTrue(vm.visibleEntries.contains(where: { $0.name == "new.txt" }))
    }
}

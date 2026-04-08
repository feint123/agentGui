// agentGuiTests/FileTreeDropValidatorTests.swift
import XCTest
@testable import agentGui

final class FileTreeDropValidatorTests: XCTestCase {

    // MARK: - 测试用 Store 快照（仅邻接表，不需要 actor）

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
                id("root"):  FileEntry(id: id("root"), name: "root",       isDirectory: true,  parentID: nil),
                id("src"):   FileEntry(id: id("src"),  name: "src",        isDirectory: true,  parentID: id("root")),
                id("main"):  FileEntry(id: id("main"), name: "main",       isDirectory: true,  parentID: id("src")),
                id("App"):   FileEntry(id: id("App"),  name: "App.swift",  isDirectory: false, parentID: id("main")),
                id("tests"): FileEntry(id: id("tests"),name: "tests",      isDirectory: true,  parentID: id("root")),
                id("TestA"): FileEntry(id: id("TestA"),name: "TestA.swift",isDirectory: false, parentID: id("tests")),
            ],
            childrenMap: [
                id("root"):  [id("src"), id("tests")],
                id("src"):   [id("main")],
                id("main"):  [id("App")],
                id("tests"): [id("TestA")],
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

    // MARK: - 多选，部分无效（嵌套）

    func testValidate_multiSelect_nested_keepsAncestor() {
        // [App, main] → tests/: main 是 App 的祖先，去重后只有 main
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
    var childrenMap: [EntryID: [EntryID]]

    func entry(_ id: EntryID) -> FileEntry? { entries[id] }
    func parentID(of id: EntryID) -> EntryID? { entries[id]?.parentID }
    func children(of id: EntryID) -> [EntryID] { childrenMap[id] ?? [] }
}

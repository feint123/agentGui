// agentGuiTests/FileTreeViewModelTests.swift
import XCTest
@testable import agentGui

@MainActor
final class FileTreeViewModelTests: XCTestCase {

    // MARK: - 测试辅助

    func makeViewModel(entries: [URL: [ScannedEntry]] = [:]) -> FileTreeViewModel {
        let scanner = MockFileScanner()
        scanner.stubbedEntries = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.key.standardizedFileURL, $0.value) }
        )
        let store = FileTreeStore(scanner: scanner)
        return FileTreeViewModel(store: store)
    }

    // MARK: - setDirectory

    func testSetDirectory_populatesVisibleEntries() async throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        let vm = makeViewModel(entries: [
            root: [
                ScannedEntry(url: root.appendingPathComponent("src"), name: "src", isDirectory: true),
                ScannedEntry(url: root.appendingPathComponent("README.md"), name: "README.md", isDirectory: false),
            ]
        ])

        await vm.setDirectory(root)

        XCTAssertEqual(vm.visibleEntries.count, 2)
        let names = vm.visibleEntries.map(\.name)
        XCTAssertTrue(names.contains("src"))
        XCTAssertTrue(names.contains("README.md"))
    }

    func testSetDirectory_nil_clearsEntries() async {
        let root = URL(fileURLWithPath: "/tmp/project")
        let vm = makeViewModel(entries: [
            root: [ScannedEntry(url: root.appendingPathComponent("a"), name: "a", isDirectory: false)]
        ])
        await vm.setDirectory(root)
        XCTAssertFalse(vm.visibleEntries.isEmpty)

        await vm.setDirectory(nil)
        XCTAssertTrue(vm.visibleEntries.isEmpty)
    }

    // MARK: - toggleDirectory

    func testToggleDirectory_expandsAndUpdates() async throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        let srcURL = root.appendingPathComponent("src")
        let vm = makeViewModel(entries: [
            root: [ScannedEntry(url: srcURL, name: "src", isDirectory: true)],
            srcURL: [ScannedEntry(url: srcURL.appendingPathComponent("main.swift"), name: "main.swift", isDirectory: false)]
        ])

        await vm.setDirectory(root)
        XCTAssertEqual(vm.visibleEntries.count, 1)

        let srcID = EntryID(url: srcURL.standardizedFileURL)
        await vm.toggleDirectory(srcID)

        XCTAssertEqual(vm.visibleEntries.count, 2)
        XCTAssertTrue(vm.visibleEntries.map(\.name).contains("main.swift"))
    }

    func testToggleDirectory_collapsesAndUpdates() async throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        let srcURL = root.appendingPathComponent("src")
        let vm = makeViewModel(entries: [
            root: [ScannedEntry(url: srcURL, name: "src", isDirectory: true)],
            srcURL: [ScannedEntry(url: srcURL.appendingPathComponent("main.swift"), name: "main.swift", isDirectory: false)]
        ])

        await vm.setDirectory(root)
        let srcID = EntryID(url: srcURL.standardizedFileURL)
        await vm.toggleDirectory(srcID)      // 展开
        XCTAssertEqual(vm.visibleEntries.count, 2)

        await vm.toggleDirectory(srcID)      // 折叠
        XCTAssertEqual(vm.visibleEntries.count, 1)
    }

    // MARK: - selectEntry

    func testSelectEntry_singleSelect() async {
        let root = URL(fileURLWithPath: "/tmp/project")
        let aURL = root.appendingPathComponent("a.txt")
        let bURL = root.appendingPathComponent("b.txt")
        let vm = makeViewModel(entries: [
            root: [
                ScannedEntry(url: aURL, name: "a.txt", isDirectory: false),
                ScannedEntry(url: bURL, name: "b.txt", isDirectory: false),
            ]
        ])
        await vm.setDirectory(root)
        let aID = EntryID(url: aURL.standardizedFileURL)

        vm.selectEntry(aID, modifier: .none)

        XCTAssertEqual(vm.selection.primary, aID)
        XCTAssertEqual(vm.selection.selected.count, 1)
        XCTAssertTrue(vm.selection.selected.contains(aID))
    }

    func testSelectEntry_cmdClickToggle() async {
        let root = URL(fileURLWithPath: "/tmp/project")
        let aURL = root.appendingPathComponent("a.txt")
        let bURL = root.appendingPathComponent("b.txt")
        let vm = makeViewModel(entries: [
            root: [
                ScannedEntry(url: aURL, name: "a.txt", isDirectory: false),
                ScannedEntry(url: bURL, name: "b.txt", isDirectory: false),
            ]
        ])
        await vm.setDirectory(root)
        let aID = EntryID(url: aURL.standardizedFileURL)
        let bID = EntryID(url: bURL.standardizedFileURL)

        vm.selectEntry(aID, modifier: .none)
        vm.selectEntry(bID, modifier: .add)

        XCTAssertEqual(vm.selection.selected.count, 2)
        XCTAssertTrue(vm.selection.selected.contains(aID))
        XCTAssertTrue(vm.selection.selected.contains(bID))

        // 再次 Cmd-click b → 取消选择
        vm.selectEntry(bID, modifier: .add)
        XCTAssertEqual(vm.selection.selected.count, 1)
        XCTAssertFalse(vm.selection.selected.contains(bID))
    }

    func testSelectEntry_shiftClickRange() async {
        let root = URL(fileURLWithPath: "/tmp/project")
        let urls = (0..<5).map { root.appendingPathComponent("\($0).txt") }
        let vm = makeViewModel(entries: [
            root: urls.map { ScannedEntry(url: $0, name: $0.lastPathComponent, isDirectory: false) }
        ])
        await vm.setDirectory(root)
        let ids = urls.map { EntryID(url: $0.standardizedFileURL) }

        vm.selectEntry(ids[0], modifier: .none)  // 选中第 0 项，设为 anchor
        vm.selectEntry(ids[2], modifier: .range) // Shift-click 第 2 项

        // 期望 0、1、2 全部被选中
        XCTAssertEqual(vm.selection.selected.count, 3)
        XCTAssertTrue(vm.selection.selected.contains(ids[0]))
        XCTAssertTrue(vm.selection.selected.contains(ids[1]))
        XCTAssertTrue(vm.selection.selected.contains(ids[2]))
    }

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
}

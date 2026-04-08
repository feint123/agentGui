// agentGuiTests/FileTreeViewModelRevealCopyTests.swift
import XCTest
@testable import agentGui

@MainActor
final class FileTreeViewModelRevealCopyTests: XCTestCase {

    // MARK: - copyRelativePath

    func testCopyRelativePath_singleFile_writesRelPath() async {
        let vm = makeViewModel()
        await vm.setDirectory(URL(fileURLWithPath: "/project"))
        let id = EntryID(url: URL(fileURLWithPath: "/project/src/App.swift"))

        vm.copyRelativePath(ids: [id])

        let pasted = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(pasted, "src/App.swift")
    }

    func testCopyRelativePath_rootURLNil_writesAbsPath() async {
        let vm = makeViewModel()
        // rootDirectory 未设置时 fallback 到绝对路径
        let id = EntryID(url: URL(fileURLWithPath: "/project/src/App.swift"))
        vm.copyRelativePath(ids: [id])
        let pasted = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(pasted, "/project/src/App.swift")
    }

    func testCopyRelativePath_multipleFiles_writesNewlineSeparated() async {
        let vm = makeViewModel()
        await vm.setDirectory(URL(fileURLWithPath: "/project"))
        let ids = [
            EntryID(url: URL(fileURLWithPath: "/project/A.swift")),
            EntryID(url: URL(fileURLWithPath: "/project/B.swift"))
        ]
        vm.copyRelativePath(ids: ids)
        let pasted = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(pasted, "A.swift\nB.swift")
    }

    // MARK: - revealInFinder（仅验证不崩溃，无法 assert NSWorkspace 行为）

    func testRevealInFinder_doesNotCrash() {
        let vm = makeViewModel()
        let id = EntryID(url: URL(fileURLWithPath: "/project/App.swift"))
        // 此路径不存在，NSWorkspace 会静默失败；只需确保不崩溃
        XCTAssertNoThrow(vm.revealInFinder(ids: [id]))
    }

    // MARK: - Helpers

    private func makeViewModel() -> FileTreeViewModel {
        FileTreeViewModel(store: FileTreeStore(scanner: MockFileScanner()))
    }
}

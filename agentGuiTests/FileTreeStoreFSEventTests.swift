// agentGuiTests/FileTreeStoreFSEventTests.swift
import XCTest
@testable import agentGui

final class FileTreeStoreFSEventTests: XCTestCase {

    // MARK: - computeDirtyDirectories

    func testComputeDirtyDirectories_returnsParentsOfChangedFiles() {
        let rootURL = URL(fileURLWithPath: "/repo")
        let paths = [
            "/repo/src/main.swift",
            "/repo/tests/unit/FooTests.swift"
        ]
        let result = FileTreeStore.computeDirtyDirectories(paths, rootURL: rootURL)

        XCTAssertTrue(result.contains(URL(fileURLWithPath: "/repo/src")))
        XCTAssertTrue(result.contains(URL(fileURLWithPath: "/repo/tests/unit")))
    }

    func testComputeDirtyDirectories_excludesPathsOutsideRoot() {
        let rootURL = URL(fileURLWithPath: "/repo")
        let inputPaths = ["/other/project/file.swift", "/repo/main.swift"]
        let result = FileTreeStore.computeDirtyDirectories(inputPaths, rootURL: rootURL)

        let resultPaths = result.map(\.path)
        XCTAssertFalse(resultPaths.contains("/other/project"))
        XCTAssertTrue(resultPaths.contains("/repo"))
    }

    func testComputeDirtyDirectories_changedDirectoryIncludesItself() {
        let rootURL = URL(fileURLWithPath: "/repo")
        // 如果变更路径本身就是目录（e.g. 新目录创建），它自己也应被标记为 dirty
        let paths = ["/repo/src/NewDir"]
        let result = FileTreeStore.computeDirtyDirectories(paths, rootURL: rootURL)

        XCTAssertTrue(result.contains(URL(fileURLWithPath: "/repo/src")))
    }

    // MARK: - pruneDescendants

    func testPruneDescendants_removesChildWhenParentPresent() {
        let dirs = [
            URL(fileURLWithPath: "/repo/src"),
            URL(fileURLWithPath: "/repo/src/utils"),          // 子路径
            URL(fileURLWithPath: "/repo/src/utils/helpers"),  // 孙路径
            URL(fileURLWithPath: "/repo/tests"),
        ]
        let pruned = FileTreeStore.pruneDescendants(dirs)

        XCTAssertTrue(pruned.contains(URL(fileURLWithPath: "/repo/src")))
        XCTAssertTrue(pruned.contains(URL(fileURLWithPath: "/repo/tests")))
        XCTAssertFalse(pruned.contains(URL(fileURLWithPath: "/repo/src/utils")),
                       "Child of /repo/src should be pruned")
        XCTAssertFalse(pruned.contains(URL(fileURLWithPath: "/repo/src/utils/helpers")),
                       "Grandchild of /repo/src should be pruned")
    }

    func testPruneDescendants_keepsUnrelatedSiblings() {
        let dirs = [
            URL(fileURLWithPath: "/a/b"),
            URL(fileURLWithPath: "/a/c"),  // sibling, NOT child of /a/b
        ]
        let pruned = FileTreeStore.pruneDescendants(dirs)

        XCTAssertEqual(Set(pruned.map(\.path)), ["/a/b", "/a/c"])
    }

    // MARK: - applyFSEvents 集成测试

    func testApplyFSEvents_refreshesDirtyDirectory() async throws {
        let scanner = MockFileScanner()
        scanner.stub(directory: URL(fileURLWithPath: "/repo"), entries: [
            ScannedEntry(url: URL(fileURLWithPath: "/repo/src"), name: "src", isDirectory: true),
            ScannedEntry(url: URL(fileURLWithPath: "/repo/README.md"), name: "README.md", isDirectory: false),
        ])
        scanner.stub(directory: URL(fileURLWithPath: "/repo/src"), entries: [
            ScannedEntry(url: URL(fileURLWithPath: "/repo/src/main.swift"), name: "main.swift", isDirectory: false),
        ])

        let store = FileTreeStore(scanner: scanner)
        await store.setRoot(URL(fileURLWithPath: "/repo"))
        // 展开 src 目录使其加载
        let srcID = EntryID(url: URL(fileURLWithPath: "/repo/src").standardizedFileURL)
        try await store.expandDirectory(srcID)

        // 模拟 FSEvent：src 目录内新增文件
        scanner.stub(directory: URL(fileURLWithPath: "/repo/src"), entries: [
            ScannedEntry(url: URL(fileURLWithPath: "/repo/src/main.swift"), name: "main.swift", isDirectory: false),
            ScannedEntry(url: URL(fileURLWithPath: "/repo/src/utils.swift"), name: "utils.swift", isDirectory: false),
        ])

        await store.applyFSEvents(["/repo/src/utils.swift"])

        let visible = await store.computeVisibleEntries()
        let names = visible.map(\.name)
        XCTAssertTrue(names.contains("utils.swift"), "New file should appear after applyFSEvents")
    }

    func testApplyFSEvents_prunesDescendantPaths() async throws {
        var scannedDirs: [URL] = []
        let scanner = MockFileScanner()
        scanner.onShallowScan = { dir in scannedDirs.append(dir) }
        scanner.stub(directory: URL(fileURLWithPath: "/repo"), entries: [
            ScannedEntry(url: URL(fileURLWithPath: "/repo/src"), name: "src", isDirectory: true),
        ])
        scanner.stub(directory: URL(fileURLWithPath: "/repo/src"), entries: [
            ScannedEntry(url: URL(fileURLWithPath: "/repo/src/utils"), name: "utils", isDirectory: true),
        ])
        scanner.stub(directory: URL(fileURLWithPath: "/repo/src/utils"), entries: [])

        let store = FileTreeStore(scanner: scanner)
        await store.setRoot(URL(fileURLWithPath: "/repo"))
        // 先展开 src 和 src/utils
        let srcID = EntryID(url: URL(fileURLWithPath: "/repo/src").standardizedFileURL)
        let utilsID = EntryID(url: URL(fileURLWithPath: "/repo/src/utils").standardizedFileURL)
        try await store.expandDirectory(srcID)
        try await store.expandDirectory(utilsID)

        scannedDirs.removeAll()

        // 同时触发 src 和 src/utils 的变更——src/utils 应被剪枝
        await store.applyFSEvents(["/repo/src/foo.swift", "/repo/src/utils/bar.swift"])

        // src/utils 被 src 覆盖，不应独立重扫
        let scannedPaths = scannedDirs.map(\.path)
        XCTAssertTrue(scannedPaths.contains("/repo/src"), "src should be rescanned")
        XCTAssertFalse(scannedPaths.contains("/repo/src/utils"),
                       "src/utils is covered by src rescan, should be pruned")
    }

    func testApplyFSEvents_degradesToFullReloadWhenTooManyChanges() async throws {
        var fullReloadCount = 0
        let scanner = MockFileScanner()
        scanner.onShallowScan = { _ in fullReloadCount += 1 }
        scanner.stub(directory: URL(fileURLWithPath: "/repo"), entries: [])

        let store = FileTreeStore(scanner: scanner)
        await store.setRoot(URL(fileURLWithPath: "/repo"))
        fullReloadCount = 0  // reset after setRoot

        // 触发超过 30 个不同目录的变更
        let manyPaths = (1...35).map { "/repo/dir\($0)/file.swift" }
        for i in 1...35 {
            scanner.stub(
                directory: URL(fileURLWithPath: "/repo/dir\(i)"),
                entries: []
            )
        }

        await store.applyFSEvents(manyPaths)

        // 降级为全量重建：扫描 root 一次
        XCTAssertGreaterThan(fullReloadCount, 0, "Should fall back to full reload")
    }

    // MARK: - FSEventObserver 集成

    func testStore_withMockObserver_receivesSimulatedEvents() async throws {
        let scanner = MockFileScanner()
        scanner.stub(directory: URL(fileURLWithPath: "/repo"), entries: [
            ScannedEntry(url: URL(fileURLWithPath: "/repo/main.swift"), name: "main.swift", isDirectory: false),
        ])

        let mockObserver = MockFSEventObserver()
        let store = FileTreeStore(scanner: scanner, fsObserver: mockObserver)
        await store.setRoot(URL(fileURLWithPath: "/repo"))

        // 模拟新文件出现
        scanner.stub(directory: URL(fileURLWithPath: "/repo"), entries: [
            ScannedEntry(url: URL(fileURLWithPath: "/repo/main.swift"), name: "main.swift", isDirectory: false),
            ScannedEntry(url: URL(fileURLWithPath: "/repo/helper.swift"), name: "helper.swift", isDirectory: false),
        ])

        // 通过 Mock 触发 FSEvent
        await mockObserver.simulateEvents(["/repo/helper.swift"])

        // 等待 Store 处理（applyFSEvents 是 async）
        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        let visible = await store.computeVisibleEntries()
        let names = visible.map(\.name)
        XCTAssertTrue(names.contains("helper.swift"),
                      "Store should reflect new file after MockFSEventObserver triggers")
    }

    func testStore_clearRoot_stopsObserver() async throws {
        let scanner = MockFileScanner()
        scanner.stub(directory: URL(fileURLWithPath: "/repo"), entries: [])

        let mockObserver = MockFSEventObserver()
        let store = FileTreeStore(scanner: scanner, fsObserver: mockObserver)
        await store.setRoot(URL(fileURLWithPath: "/repo"))

        let isObservingBefore = await mockObserver.isObserving
        XCTAssertTrue(isObservingBefore, "Observer should be active after setRoot")

        await store.clearRoot()  // 清除 root
        let isObservingAfter = await mockObserver.isObserving
        XCTAssertFalse(isObservingAfter, "Observer should stop when root is cleared")    }
}

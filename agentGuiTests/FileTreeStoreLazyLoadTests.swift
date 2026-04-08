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

    // MARK: - expandDirectory happy path

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

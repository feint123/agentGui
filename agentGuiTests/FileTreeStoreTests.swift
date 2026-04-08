// agentGuiTests/FileTreeStoreTests.swift
import XCTest
@testable import agentGui

final class FileTreeStoreTests: XCTestCase {

    // MARK: - FileEntry

    func testEntryID_equalityByURL() {
        let url = URL(fileURLWithPath: "/tmp/foo")
        let a = EntryID(url: url)
        let b = EntryID(url: url)
        XCTAssertEqual(a, b)
    }

    func testFileEntry_defaultLoadState_notLoaded() {
        let entry = FileEntry(
            id: EntryID(url: URL(fileURLWithPath: "/tmp/dir")),
            name: "dir",
            isDirectory: true,
            parentID: nil
        )
        XCTAssertEqual(entry.loadState, .notLoaded)
    }

    // MARK: - VisibleEntry

    func testVisibleEntry_identifiableById() {
        let id = EntryID(url: URL(fileURLWithPath: "/tmp/file.txt"))
        let entry = VisibleEntry(
            id: id,
            name: "file.txt",
            isDirectory: false,
            depth: 1,
            isExpanded: false,
            foldedAncestors: nil,
            gitSummary: nil,
            diagnosticSeverity: nil,
            isIgnored: false
        )
        XCTAssertEqual(entry.id, id)
    }

    func testFoldedAncestors_segments() {
        let seg1 = FoldedAncestors.FoldedSegment(
            name: "src",
            entryID: EntryID(url: URL(fileURLWithPath: "/tmp/src"))
        )
        let seg2 = FoldedAncestors.FoldedSegment(
            name: "main",
            entryID: EntryID(url: URL(fileURLWithPath: "/tmp/src/main"))
        )
        let fa = FoldedAncestors(
            segments: [seg1, seg2],
            terminalID: seg2.entryID
        )
        XCTAssertEqual(fa.segments.count, 2)
        XCTAssertEqual(fa.terminalID, seg2.entryID)
    }

    // MARK: - GitSummary + DiagSeverity

    func testGitSummary_comparableOrder() {
        // conflict 最高优先级（最小值），added 最低
        XCTAssertLessThan(GitSummary.conflict, GitSummary.added)
        XCTAssertLessThan(GitSummary.modified, GitSummary.staged)
    }

    func testDiagSeverity_comparableOrder() {
        XCTAssertLessThan(DiagSeverity.error, DiagSeverity.warning)
        XCTAssertLessThan(DiagSeverity.warning, DiagSeverity.hint)
    }

    // MARK: - FileTreeSelection

    func testFileTreeSelection_defaultEmpty() {
        let sel = FileTreeSelection()
        XCTAssertNil(sel.primary)
        XCTAssertTrue(sel.selected.isEmpty)
        XCTAssertNil(sel.anchor)
    }

    func testFileTreeSelection_selectEntry() {
        let id = EntryID(url: URL(fileURLWithPath: "/tmp/a"))
        var sel = FileTreeSelection()
        sel.primary = id
        sel.selected = [id]
        XCTAssertEqual(sel.primary, id)
        XCTAssertEqual(sel.selected.count, 1)
    }

    // MARK: - ScannedEntry

    func testScannedEntry_hasRequiredFields() {
        let entry = ScannedEntry(
            url: URL(fileURLWithPath: "/tmp/a.txt"),
            name: "a.txt",
            isDirectory: false
        )
        XCTAssertEqual(entry.name, "a.txt")
        XCTAssertFalse(entry.isDirectory)
    }

    // MARK: - Mock Scanner（测试辅助）

    // MARK: - FileTreeStore

    func makeStore(entries: [URL: [ScannedEntry]] = [:]) -> FileTreeStore {
        let scanner = MockFileScanner()
        scanner.stubbedEntries = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.key.standardizedFileURL, $0.value) }
        )
        return FileTreeStore(scanner: scanner)
    }

    func testSetRoot_createsRootEntries() async throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        let store = makeStore(entries: [
            root: [
                ScannedEntry(url: root.appendingPathComponent("src"), name: "src", isDirectory: true),
                ScannedEntry(url: root.appendingPathComponent("README.md"), name: "README.md", isDirectory: false),
            ]
        ])

        await store.setRoot(root)

        let visible = await store.computeVisibleEntries()
        // Root level 仅展示根目录的直接子项（根目录本身展开，但不作为独立行）
        XCTAssertEqual(visible.count, 2)
        let names = Set(visible.map(\.name))
        XCTAssertTrue(names.contains("src"))
        XCTAssertTrue(names.contains("README.md"))
    }

    func testComputeVisibleEntries_unexpandedDirHidesChildren() async throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        let srcURL = root.appendingPathComponent("src")
        let store = makeStore(entries: [
            root: [
                ScannedEntry(url: srcURL, name: "src", isDirectory: true),
            ],
            srcURL: [
                ScannedEntry(url: srcURL.appendingPathComponent("main.swift"), name: "main.swift", isDirectory: false),
            ]
        ])

        await store.setRoot(root)
        // src 目录未展开，children 不可见
        let visible = await store.computeVisibleEntries()
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.name, "src")
    }

    func testExpandDirectory_loadsAndShowsChildren() async throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        let srcURL = root.appendingPathComponent("src")
        let store = makeStore(entries: [
            root: [ScannedEntry(url: srcURL, name: "src", isDirectory: true)],
            srcURL: [
                ScannedEntry(url: srcURL.appendingPathComponent("main.swift"),
                             name: "main.swift", isDirectory: false),
            ]
        ])

        await store.setRoot(root)
        let srcID = EntryID(url: srcURL.standardizedFileURL)
        try await store.expandDirectory(srcID)

        let visible = await store.computeVisibleEntries()
        XCTAssertEqual(visible.count, 2)
        let names = visible.map(\.name)
        XCTAssertTrue(names.contains("src"))
        XCTAssertTrue(names.contains("main.swift"))
    }

    func testCollapseDirectory_hidesChildren() async throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        let srcURL = root.appendingPathComponent("src")
        let store = makeStore(entries: [
            root: [ScannedEntry(url: srcURL, name: "src", isDirectory: true)],
            srcURL: [
                ScannedEntry(url: srcURL.appendingPathComponent("main.swift"),
                             name: "main.swift", isDirectory: false),
            ]
        ])

        await store.setRoot(root)
        let srcID = EntryID(url: srcURL.standardizedFileURL)
        try await store.expandDirectory(srcID)
        await store.collapseDirectory(srcID)

        let visible = await store.computeVisibleEntries()
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.name, "src")
    }

    func testEntryLookup_O1ById() async throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        let readmeURL = root.appendingPathComponent("README.md")
        let store = makeStore(entries: [
            root: [ScannedEntry(url: readmeURL, name: "README.md", isDirectory: false)]
        ])

        await store.setRoot(root)
        let readmeID = EntryID(url: readmeURL.standardizedFileURL)
        let entry = await store.entry(for: readmeID)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.name, "README.md")
    }

    // MARK: - Edge cases (Task 7)

    func testSetRoot_emptyDirectory_returnsEmpty() async throws {
        let root = URL(fileURLWithPath: "/tmp/empty")
        let store = makeStore(entries: [root: []])
        await store.setRoot(root)
        let visible = await store.computeVisibleEntries()
        XCTAssertEqual(visible.count, 0)
    }

    func testExpandDirectory_unknownID_doesNotCrash() async throws {
        let store = makeStore()
        let fakeID = EntryID(url: URL(fileURLWithPath: "/nonexistent"))
        try await store.expandDirectory(fakeID)   // 应静默通过
    }

    func testComputeVisibleEntries_directoriesBeforeFiles() async throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        let dirURL = root.appendingPathComponent("src")
        let fileURL = root.appendingPathComponent("a.txt")
        let store = makeStore(entries: [
            root: [
                ScannedEntry(url: fileURL, name: "a.txt", isDirectory: false),
                ScannedEntry(url: dirURL, name: "src", isDirectory: true),
            ]
        ])
        await store.setRoot(root)
        let visible = await store.computeVisibleEntries()
        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(visible[0].name, "src")    // 目录排前
        XCTAssertEqual(visible[1].name, "a.txt")
    }

    func testComputeVisibleEntries_depth() async throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        let srcURL = root.appendingPathComponent("src")
        let mainURL = srcURL.appendingPathComponent("main.swift")
        let store = makeStore(entries: [
            root: [ScannedEntry(url: srcURL, name: "src", isDirectory: true)],
            srcURL: [ScannedEntry(url: mainURL, name: "main.swift", isDirectory: false)],
        ])
        await store.setRoot(root)
        let srcID = EntryID(url: srcURL.standardizedFileURL)
        try await store.expandDirectory(srcID)
        let visible = await store.computeVisibleEntries()
        let depths = visible.map(\.depth)
        XCTAssertEqual(depths, [0, 1])   // src=0, main.swift=1
    }

    func testComputeVisibleEntries_searchFilter() async throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        let store = makeStore(entries: [
            root: [
                ScannedEntry(url: root.appendingPathComponent("ContentView.swift"),
                             name: "ContentView.swift", isDirectory: false),
                ScannedEntry(url: root.appendingPathComponent("AppMain.swift"),
                             name: "AppMain.swift", isDirectory: false),
            ]
        ])
        await store.setRoot(root)
        let visible = await store.computeVisibleEntries(searchFilter: "Content")
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.name, "ContentView.swift")
    }
}

// MARK: - MockFileScanner

final class MockFileScanner: FileScanning, @unchecked Sendable {
    var stubbedEntries: [URL: [ScannedEntry]] = [:]
    var onShallowScan: ((URL) -> Void)?

    func stub(directory: URL, entries: [ScannedEntry]) {
        stubbedEntries[directory.standardizedFileURL] = entries
    }

    func shallowScan(directory: URL) async throws -> [ScannedEntry] {
        onShallowScan?(directory)
        return stubbedEntries[directory.standardizedFileURL] ?? []
    }

    func isDirectory(_ url: URL) async -> Bool {
        return stubbedEntries[url.standardizedFileURL] != nil
    }
}

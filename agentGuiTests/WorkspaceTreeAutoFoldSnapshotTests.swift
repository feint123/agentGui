import Foundation
import Testing
@testable import agentGui

struct WorkspaceTreeAutoFoldSnapshotTests {

    // MARK: - compactSingleChildChain

    /// 辅助：在 tmp 下创建目录结构
    private func makeTmpDir(_ suffix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-u1-snap-\(suffix)-\(Int.random(in: 1000...9999))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func singleChildChainFoldsCorrectly() throws {
        // 创建 root/a/b/c/（每层只有 1 个子目录）
        let root = try makeTmpDir("chain3")
        defer { try? FileManager.default.removeItem(at: root) }

        let a = root.appendingPathComponent("a")
        let b = a.appendingPathComponent("b")
        let c = b.appendingPathComponent("c")
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)

        let result = WorkspaceTreeSnapshotOps.compactSingleChildChain(startingAt: a)
        #expect(result != nil)
        #expect(result?.segments == ["a", "b", "c"])
        #expect(result?.terminalURL.standardizedFileURL == c.standardizedFileURL)
    }

    @Test func directoryWithMultipleChildrenNotFolded() throws {
        // 创建 root/a/（含 b/ 和 c/ 两个子目录）→ 不折叠
        let root = try makeTmpDir("multi")
        defer { try? FileManager.default.removeItem(at: root) }

        let a = root.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: a.appendingPathComponent("b"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: a.appendingPathComponent("c"), withIntermediateDirectories: true)

        let result = WorkspaceTreeSnapshotOps.compactSingleChildChain(startingAt: a)
        #expect(result == nil)
    }

    @Test func directoryWithFileChildNotFolded() throws {
        // 创建 root/a/ 含一个文件（而非目录）→ 不折叠
        let root = try makeTmpDir("filechild")
        defer { try? FileManager.default.removeItem(at: root) }

        let a = root.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try "hello".write(to: a.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let result = WorkspaceTreeSnapshotOps.compactSingleChildChain(startingAt: a)
        #expect(result == nil)
    }

    @Test func emptyDirectoryNotFolded() throws {
        // 创建空目录 root/a/ → 不折叠
        let root = try makeTmpDir("empty")
        defer { try? FileManager.default.removeItem(at: root) }

        let a = root.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)

        let result = WorkspaceTreeSnapshotOps.compactSingleChildChain(startingAt: a)
        #expect(result == nil)
    }

    @Test func chainStopsAtNonSingleChildDir() throws {
        // 创建 root/a/b/（b 含 c/ 和 d/ 两个子目录）→ 折叠到 b，segments = ["a","b"]
        let root = try makeTmpDir("stop")
        defer { try? FileManager.default.removeItem(at: root) }

        let a = root.appendingPathComponent("a")
        let b = a.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: b.appendingPathComponent("c"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b.appendingPathComponent("d"), withIntermediateDirectories: true)

        let result = WorkspaceTreeSnapshotOps.compactSingleChildChain(startingAt: a)
        #expect(result != nil)
        #expect(result?.segments == ["a", "b"])
        #expect(result?.terminalURL.standardizedFileURL == b.standardizedFileURL)
    }

    @Test func chainMixedWithFileInTerminalIsAllowed() throws {
        // a/ -> b/（b 含 file.txt 和 subdir/）→ b 有 2 个可见条目，链止于 b，segments = ["a","b"]
        let root = try makeTmpDir("mixterm")
        defer { try? FileManager.default.removeItem(at: root) }

        let a = root.appendingPathComponent("a")
        let b = a.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try "x".write(to: b.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: b.appendingPathComponent("sub"), withIntermediateDirectories: true)

        // b 有 2 条目 → 链止于 b
        let result = WorkspaceTreeSnapshotOps.compactSingleChildChain(startingAt: a)
        #expect(result?.segments == ["a", "b"])
        #expect(result?.terminalURL.standardizedFileURL == b.standardizedFileURL)
    }

    // MARK: - buildNodesShallow with compactFolders

    @Test func buildNodesShallowFoldsChain() throws {
        let root = try makeTmpDir("build")
        defer { try? FileManager.default.removeItem(at: root) }

        // src → src/main → src/main/java（链）
        let java = root.appendingPathComponent("src/main/java")
        try FileManager.default.createDirectory(at: java, withIntermediateDirectories: true)
        // 同级文件，不是链的一部分
        try "top".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let nodes = WorkspaceTreeSnapshotOps.buildNodesShallow(at: root, compactFolders: true)

        let srcNode = nodes.first(where: { $0.name == "src" })
        #expect(srcNode != nil)
        #expect(srcNode?.isFolded == true)
        #expect(srcNode?.foldedSegments == ["src", "main", "java"])
        #expect(srcNode?.foldedTerminalURL?.standardizedFileURL == java.standardizedFileURL)
        #expect(srcNode?.childrenLoadState == .notLoaded)
    }

    @Test func buildNodesShallowDisabledDoesNotFold() throws {
        let root = try makeTmpDir("nofold")
        defer { try? FileManager.default.removeItem(at: root) }

        let java = root.appendingPathComponent("src/main/java")
        try FileManager.default.createDirectory(at: java, withIntermediateDirectories: true)

        let nodes = WorkspaceTreeSnapshotOps.buildNodesShallow(at: root, compactFolders: false)

        let srcNode = nodes.first(where: { $0.name == "src" })
        #expect(srcNode?.isFolded == false)
        #expect(srcNode?.foldedSegments.isEmpty == true)
    }

    @Test func buildNodesShallowMultiChildDirNotFolded() throws {
        let root = try makeTmpDir("multi2")
        defer { try? FileManager.default.removeItem(at: root) }

        // src/（含 main/ 和 test/ 两个子目录）→ 不折叠
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("main"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("test"), withIntermediateDirectories: true)

        let nodes = WorkspaceTreeSnapshotOps.buildNodesShallow(at: root, compactFolders: true)
        let srcNode = nodes.first(where: { $0.name == "src" })
        #expect(srcNode?.isFolded == false)
    }

    // MARK: - findNode

    @Test func findNodeLocatesTopLevel() {
        let url = URL(fileURLWithPath: "/tmp/src")
        let node = FileNode(id: url, name: "src", isDirectory: true, children: nil)
        let tree = [node]

        let found = WorkspaceTreeSnapshotOps.findNode(in: tree, id: url)
        #expect(found?.id == url)
    }

    @Test func findNodeLocatesNested() {
        let childURL = URL(fileURLWithPath: "/tmp/src/main")
        let child = FileNode(id: childURL, name: "main", isDirectory: true, children: nil)
        let parent = FileNode(
            id: URL(fileURLWithPath: "/tmp/src"),
            name: "src",
            isDirectory: true,
            children: [child],
            childrenLoadState: .loaded
        )
        let tree = [parent]

        let found = WorkspaceTreeSnapshotOps.findNode(in: tree, id: childURL)
        #expect(found?.id == childURL)
    }

    @Test func findNodeReturnsNilForUnknownID() {
        let tree: [FileNode] = []
        let found = WorkspaceTreeSnapshotOps.findNode(in: tree, id: URL(fileURLWithPath: "/tmp/x"))
        #expect(found == nil)
    }
}

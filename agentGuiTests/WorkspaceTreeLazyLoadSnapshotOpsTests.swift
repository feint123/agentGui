import Foundation
import Testing
@testable import agentGui

struct WorkspaceTreeLazyLoadSnapshotOpsTests {

    // MARK: - buildNodesShallow

    @Test func buildNodesShallowMarksSubdirectoriesAsNotLoaded() throws {
        // 准备：创建临时目录结构
        //   tmpRoot/
        //     file.txt
        //     subdir/
        //       nested.txt  ← 不应被扫描
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-p1-shallow-\(Int.random(in: 1000...9999))")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let fileURL = tmpRoot.appendingPathComponent("file.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let subdirURL = tmpRoot.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
        let nestedURL = subdirURL.appendingPathComponent("nested.txt")
        try "nested".write(to: nestedURL, atomically: true, encoding: .utf8)

        // 执行
        let nodes = WorkspaceTreeSnapshotOps.buildNodesShallow(at: tmpRoot)

        // 断言：应扫到 2 个节点（subdir + file.txt）
        #expect(nodes.count == 2)

        let dirNode = nodes.first(where: { $0.isDirectory })
        #expect(dirNode != nil)
        #expect(dirNode?.childrenLoadState == .notLoaded)
        // 关键：子目录的 children 应为 nil（未扫描），而非包含 nested.txt
        #expect(dirNode?.children == nil)

        let fileNode = nodes.first(where: { !$0.isDirectory })
        #expect(fileNode != nil)
        #expect(fileNode?.childrenLoadState == .loaded)
    }

    // MARK: - mergeNodes — 新目录不触发递归扫描

    @Test func mergeNodesCreatesNotLoadedNodeForNewDirectory() throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-p1-merge-\(Int.random(in: 1000...9999))")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        // 新目录（existing 中不存在）
        let newDirURL = tmpRoot.appendingPathComponent("newdir")
        try FileManager.default.createDirectory(at: newDirURL, withIntermediateDirectories: true)
        try "file".write(to: newDirURL.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)

        let freshScan: [WorkspaceTreeShallowEntry] = [
            (name: "newdir", url: newDirURL, isDirectory: true)
        ]
        let existing: [FileNode] = []

        let merged = WorkspaceTreeSnapshotOps.mergeNodes(existing: existing, freshScan: freshScan)

        #expect(merged.count == 1)
        let dirNode = merged[0]
        #expect(dirNode.isDirectory == true)
        // 新目录应被标记为 .notLoaded，child.txt 不应出现在 children 中
        #expect(dirNode.childrenLoadState == .notLoaded)
        #expect(dirNode.children == nil)
    }

    @Test func mergeNodesPreservesLoadedStateForExistingNode() {
        let url = URL(fileURLWithPath: "/tmp/existing-dir")
        let child = FileNode(id: url.appendingPathComponent("file.txt"), name: "file.txt", isDirectory: false, children: nil)
        let existingNode = FileNode(id: url, name: "existing-dir", isDirectory: true, children: [child], childrenLoadState: .loaded)

        let freshScan: [WorkspaceTreeShallowEntry] = [
            (name: "existing-dir", url: url, isDirectory: true)
        ]

        let merged = WorkspaceTreeSnapshotOps.mergeNodes(existing: [existingNode], freshScan: freshScan)

        #expect(merged.count == 1)
        // 已加载的节点（含其 children）应被完整保留
        #expect(merged[0].childrenLoadState == .loaded)
        #expect(merged[0].children?.count == 1)
    }

    // MARK: - applyPartialUpdate — 跳过 notLoaded 节点

    @Test func applyPartialUpdateSkipsNotLoadedDirectory() {
        // 树结构：root/ → notLoadedDir/ （.notLoaded）
        // FSEvent 来自 notLoadedDir 内部
        let rootURL = URL(fileURLWithPath: "/tmp/root")
        let notLoadedURL = rootURL.appendingPathComponent("notLoadedDir")

        let notLoadedNode = FileNode(id: notLoadedURL, name: "notLoadedDir", isDirectory: true, children: nil, childrenLoadState: .notLoaded)
        let rootNodes = [notLoadedNode]

        let updated = WorkspaceTreeSnapshotOps.applyPartialUpdate(to: rootNodes, at: notLoadedURL)

        // notLoaded 节点不应被修改（其子项依然为 nil）
        #expect(updated[0].childrenLoadState == .notLoaded)
        #expect(updated[0].children == nil)
    }

    // MARK: - replaceNode

    @Test func replaceNodeUpdatesTargetInFlatTree() {
        let url = URL(fileURLWithPath: "/tmp/dir")
        let original = FileNode(id: url, name: "dir", isDirectory: true, children: nil, childrenLoadState: .notLoaded)

        let loaded = FileNode(id: url, name: "dir", isDirectory: true, children: [], childrenLoadState: .loaded)
        let updated = WorkspaceTreeSnapshotOps.replaceNode(in: [original], id: url) { _ in loaded }

        #expect(updated[0].childrenLoadState == .loaded)
    }

    @Test func replaceNodeUpdatesTargetInNestedTree() {
        let rootURL = URL(fileURLWithPath: "/tmp/root")
        let nestedURL = rootURL.appendingPathComponent("nested")

        let nested = FileNode(id: nestedURL, name: "nested", isDirectory: true, children: nil, childrenLoadState: .notLoaded)
        let root = FileNode(id: rootURL, name: "root", isDirectory: true, children: [nested], childrenLoadState: .loaded)

        let loadedNested = FileNode(id: nestedURL, name: "nested", isDirectory: true, children: [], childrenLoadState: .loaded)
        let updated = WorkspaceTreeSnapshotOps.replaceNode(in: [root], id: nestedURL) { _ in loadedNested }

        #expect(updated[0].children?[0].childrenLoadState == .loaded)
    }
}

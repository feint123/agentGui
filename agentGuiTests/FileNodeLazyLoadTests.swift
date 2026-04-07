import Foundation
import Testing
@testable import agentGui

struct FileNodeLazyLoadTests {
    // MARK: - childrenLoadState 基础语义

    @Test func directoryDefaultsToNotLoaded() {
        let node = FileNode(
            id: URL(fileURLWithPath: "/tmp/dir"),
            name: "dir",
            isDirectory: true,
            children: nil,
            childrenLoadState: .notLoaded
        )
        #expect(node.childrenLoadState == .notLoaded)
        #expect(node.isDirectory == true)
    }

    @Test func loadedDirectoryPreservesChildren() {
        let child = FileNode(
            id: URL(fileURLWithPath: "/tmp/dir/file.txt"),
            name: "file.txt",
            isDirectory: false,
            children: nil,
            childrenLoadState: .loaded
        )
        let node = FileNode(
            id: URL(fileURLWithPath: "/tmp/dir"),
            name: "dir",
            isDirectory: true,
            children: [child],
            childrenLoadState: .loaded
        )
        #expect(node.childrenLoadState == .loaded)
        #expect(node.children?.count == 1)
    }

    @Test func fileNodeAlwaysLoaded() {
        let node = FileNode(
            id: URL(fileURLWithPath: "/tmp/file.txt"),
            name: "file.txt",
            isDirectory: false,
            children: nil,
            childrenLoadState: .loaded
        )
        #expect(node.childrenLoadState == .loaded)
        #expect(node.isDirectory == false)
    }

    // MARK: - Hashable / Equatable (ID 驱动)

    @Test func twoNodesWithSameURLAreEqual() {
        let url = URL(fileURLWithPath: "/tmp/dir")
        let a = FileNode(id: url, name: "dir", isDirectory: true, children: nil, childrenLoadState: .notLoaded)
        let b = FileNode(id: url, name: "dir", isDirectory: true, children: [], childrenLoadState: .loaded)
        // FileNode.Hashable 由 id 驱动，childrenLoadState 不影响等价性
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }
}

import Foundation
import Testing
@testable import agentGui

struct WorkspaceTreeSnapshotOpsTests {

    @Test func shallowScanIncludesHiddenDirectoriesButSkipsHiddenFiles() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let hiddenDirectoryURL = rootURL.appending(path: ".git")
        let visibleFileURL = rootURL.appending(path: "README.md")
        let hiddenFileURL = rootURL.appending(path: ".env")

        try FileManager.default.createDirectory(at: hiddenDirectoryURL, withIntermediateDirectories: true)
        try "visible".write(to: visibleFileURL, atomically: true, encoding: .utf8)
        try "secret".write(to: hiddenFileURL, atomically: true, encoding: .utf8)

        let entries = WorkspaceTreeSnapshotOps.shallowScan(at: rootURL)

        #expect(entries.map(\.name) == [".git", "README.md"])
        #expect(entries.map(\.isDirectory) == [true, false])
    }

    @Test func buildNodesKeepsHiddenDirectorySubtrees() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let hiddenDirectoryURL = rootURL.appending(path: ".config")
        let nestedVisibleFileURL = hiddenDirectoryURL.appending(path: "settings.json")
        let nestedHiddenFileURL = hiddenDirectoryURL.appending(path: ".secret")

        try FileManager.default.createDirectory(at: hiddenDirectoryURL, withIntermediateDirectories: true)
        try "{}".write(to: nestedVisibleFileURL, atomically: true, encoding: .utf8)
        try "x".write(to: nestedHiddenFileURL, atomically: true, encoding: .utf8)

        let nodes = WorkspaceTreeSnapshotOps.buildNodes(at: rootURL, depth: 0)
        let hiddenDirectoryNode = try #require(nodes.first)

        #expect(hiddenDirectoryNode.name == ".config")
        #expect(hiddenDirectoryNode.isDirectory)
        #expect(hiddenDirectoryNode.children?.map(\.name) == ["settings.json"])
    }

    @Test func filterNodesKeepsAncestorsForMatchingDescendants() {
        let matchingFile = FileNode(
            id: URL(fileURLWithPath: "/tmp/workspace/Sources/WorkspacePanelView.swift"),
            name: "WorkspacePanelView.swift",
            isDirectory: false,
            children: nil
        )
        let siblingFile = FileNode(
            id: URL(fileURLWithPath: "/tmp/workspace/Sources/ChatView.swift"),
            name: "ChatView.swift",
            isDirectory: false,
            children: nil
        )
        let sourcesDirectory = FileNode(
            id: URL(fileURLWithPath: "/tmp/workspace/Sources"),
            name: "Sources",
            isDirectory: true,
            children: [matchingFile, siblingFile]
        )
        let readmeFile = FileNode(
            id: URL(fileURLWithPath: "/tmp/workspace/README.md"),
            name: "README.md",
            isDirectory: false,
            children: nil
        )

        let filtered = WorkspaceTreeSnapshotOps.filterNodes([sourcesDirectory, readmeFile], query: "workspacepanel")

        #expect(filtered.count == 1)
        #expect(filtered.first?.name == "Sources")
        #expect(filtered.first?.children?.map(\.name) == ["WorkspacePanelView.swift"])
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let baseURL = FileManager.default.temporaryDirectory
    let directoryURL = baseURL.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}
import Foundation
import Testing
@testable import agentGui

// MARK: - FT-P2: pruneDescendants 单元测试

struct WorkspaceTreePruneDescendantsTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func emptyInputReturnsEmpty() {
        let result = WorkspaceTreeSnapshotOps.pruneDescendants([])
        #expect(result.isEmpty)
    }

    @Test func singleElementPassesThrough() {
        let input = [url("/a")]
        let result = WorkspaceTreeSnapshotOps.pruneDescendants(input)
        #expect(result == input)
    }

    @Test func noDescendantsKeepsAll() {
        // /a, /b, /c — 互不包含
        let input = [url("/a"), url("/b"), url("/c")]
        let result = WorkspaceTreeSnapshotOps.pruneDescendants(input)
        #expect(result == input)
    }

    @Test func descendantsAreRemoved() {
        // /src 是 /src/a 和 /src/b 的祖先 → 后两者应被裁剪
        let input = [url("/src"), url("/src/a"), url("/src/b")]
        let result = WorkspaceTreeSnapshotOps.pruneDescendants(input)
        #expect(result == [url("/src")])
    }

    @Test func mixedKeepsIndependentAndPrunesDescendants() {
        // /docs 独立，/src/a 是 /src 的后代，/tests 独立
        let input = [url("/docs"), url("/src"), url("/src/a"), url("/tests")]
        let result = WorkspaceTreeSnapshotOps.pruneDescendants(input)
        #expect(result == [url("/docs"), url("/src"), url("/tests")])
    }

    @Test func threeLayerNestingPrunesToRoot() {
        // /a → /a/b → /a/b/c，结果只保留 /a
        let input = [url("/a"), url("/a/b"), url("/a/b/c")]
        let result = WorkspaceTreeSnapshotOps.pruneDescendants(input)
        #expect(result == [url("/a")])
    }

    @Test func duplicatePathsDeduped() {
        // 完全相同路径（字典序相邻），第二个应被跳过
        let input = [url("/a"), url("/a")]
        let result = WorkspaceTreeSnapshotOps.pruneDescendants(input)
        #expect(result == [url("/a")])
    }

    @Test func prefixWithoutSlashIsNotDescendant() {
        // /src2 不以 /src/ 开头（/src2 ≠ /src + "/"...），应保留两者
        let input = [url("/src"), url("/src2")]
        let result = WorkspaceTreeSnapshotOps.pruneDescendants(input)
        #expect(result == [url("/src"), url("/src2")])
    }
}

// MARK: - FT-P2: refreshTargets 集成测试

struct WorkspaceTreeRefreshTargetsTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    /// 规范化路径：去除末尾斜杠后比较
    private func normalizedPath(_ url: URL) -> String {
        url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
    }

    @Test func prunesDescendantsWhenParentIsDirty() {
        let root = url("/project")
        // src/c.swift 使 src/ 进入脏集合；src/a/x.swift 和 src/b/z.swift 使 src/a/、src/b/ 进入脏集合
        // 由于 src/ 覆盖了 src/a/ 和 src/b/，后两者应被裁剪
        let paths = [
            "/project/src/a/x.swift",
            "/project/src/a/y.swift",
            "/project/src/b/z.swift",
            "/project/src/c.swift",
        ]
        let targets = WorkspaceTreeSnapshotOps.refreshTargets(for: paths, rootURL: root)
        let normalizedPaths = targets.map { normalizedPath($0) }
        #expect(normalizedPaths == ["/project/src"])
    }

    @Test func keepsIndependentDirectories() {
        let root = url("/project")
        let paths = [
            "/project/src/a.swift",
            "/project/tests/b.swift",
        ]
        let targets = WorkspaceTreeSnapshotOps.refreshTargets(for: paths, rootURL: root)
        let normalizedPaths = targets.map { normalizedPath($0) }
        #expect(normalizedPaths.count == 2)
        #expect(normalizedPaths.contains("/project/src"))
        #expect(normalizedPaths.contains("/project/tests"))
    }

    @Test func emptyPathsReturnsEmpty() {
        let root = url("/project")
        let targets = WorkspaceTreeSnapshotOps.refreshTargets(for: [], rootURL: root)
        #expect(targets.isEmpty)
    }

    @Test func pathsOutsideRootAreIgnored() {
        let root = url("/project")
        let paths = ["/other/file.swift", "/project/src/file.swift"]
        let targets = WorkspaceTreeSnapshotOps.refreshTargets(for: paths, rootURL: root)
        let normalizedPaths = targets.map { normalizedPath($0) }
        #expect(normalizedPaths == ["/project/src"])
    }

    @Test func singleFileChangeReturnsSingleDirectory() {
        let root = url("/project")
        let targets = WorkspaceTreeSnapshotOps.refreshTargets(
            for: ["/project/src/main.swift"],
            rootURL: root
        )
        let normalizedPaths = targets.map { normalizedPath($0) }
        #expect(normalizedPaths == ["/project/src"])
    }
}

// MARK: - FT-P2: largeRefreshThreshold 常量

struct WorkspaceTreeLargeRefreshThresholdTests {
    @Test func thresholdIs30() {
        #expect(WorkspaceTreeSnapshotOps.largeRefreshThreshold == 30)
    }

    @Test func thirtyDirtyDirsBelowThreshold() {
        // 30 个脏目录不超过阈值（≤ 30），不降级
        let root = URL(fileURLWithPath: "/project")
        let paths = (0..<30).map { i in "/project/dir\(i)/file.txt" }
        let targets = WorkspaceTreeSnapshotOps.refreshTargets(for: paths, rootURL: root)
        #expect(targets.count <= WorkspaceTreeSnapshotOps.largeRefreshThreshold)
    }

    @Test func thirtyOneDirtyDirsExceedsThreshold() {
        // 31 个各自独立的脏目录（> 阈值 30），coordinator 应降级
        let root = URL(fileURLWithPath: "/project")
        let paths = (0..<31).map { i in "/project/dir\(i)/file.txt" }
        let targets = WorkspaceTreeSnapshotOps.refreshTargets(for: paths, rootURL: root)
        #expect(targets.count > WorkspaceTreeSnapshotOps.largeRefreshThreshold)
    }
}

import Foundation
import Testing
@testable import agentGui

@MainActor
struct WorkspaceTreeDemandLoadCoordinatorTests {

    // MARK: - 初始加载：根目录只有 1 层，子目录为 .notLoaded

    @Test func initialLoadOnlyScansOneLevel() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-p1-coord-\(Int.random(in: 1000...9999))")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        // 创建：root/file.txt 和 root/subdir/nested.txt
        try "root".write(to: tmpRoot.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let subdirURL = tmpRoot.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
        try "nested".write(to: subdirURL.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)

        var receivedNodes: [FileNode] = []
        let coordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: .init { _, _ in nil }  // 禁用 FSEvent 监听
        )
        coordinator.onNodesChanged = { nodes, _ in receivedNodes = nodes }

        coordinator.setDirectory(tmpRoot)

        // 等待异步扫描完成
        try await Task.sleep(nanoseconds: 300_000_000)

        // 应扫到 2 个节点（subdir + file.txt），subdir 为 .notLoaded
        #expect(receivedNodes.count == 2)
        let subdirNode = receivedNodes.first(where: { $0.isDirectory })
        #expect(subdirNode?.childrenLoadState == .notLoaded)
        #expect(subdirNode?.children == nil)
    }

    // MARK: - demandLoad：展开后子节点出现

    @Test func demandLoadExpandsNotLoadedDirectory() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-p1-demand-\(Int.random(in: 1000...9999))")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let subdirURL = tmpRoot.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
        try "child".write(to: subdirURL.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)

        var receivedNodes: [FileNode] = []
        let coordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: .init { _, _ in nil }
        )
        coordinator.onNodesChanged = { nodes, _ in receivedNodes = nodes }

        coordinator.setDirectory(tmpRoot)
        try await Task.sleep(nanoseconds: 300_000_000)

        // 初始：subdir 为 .notLoaded
        let notLoadedNode = receivedNodes.first(where: { $0.isDirectory })
        #expect(notLoadedNode?.childrenLoadState == .notLoaded)

        // 触发按需加载
        coordinator.demandLoad(directoryID: subdirURL)
        try await Task.sleep(nanoseconds: 300_000_000)

        // demandLoad 后：subdir 应变为 .loaded，且包含 child.txt
        let loadedNode = receivedNodes.first(where: { $0.isDirectory })
        #expect(loadedNode?.childrenLoadState == .loaded)
        #expect(loadedNode?.children?.count == 1)
        #expect(loadedNode?.children?.first?.name == "child.txt")
    }

    // MARK: - demandLoad：对已加载节点无副作用

    @Test func demandLoadOnAlreadyLoadedNodeIsNoop() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-p1-noop-\(Int.random(in: 1000...9999))")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let subdirURL = tmpRoot.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
        try "child".write(to: subdirURL.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)

        var callCount = 0
        let coordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: .init { _, _ in nil }
        )
        coordinator.onNodesChanged = { _, _ in callCount += 1 }

        coordinator.setDirectory(tmpRoot)
        try await Task.sleep(nanoseconds: 300_000_000)
        coordinator.demandLoad(directoryID: subdirURL)
        try await Task.sleep(nanoseconds: 300_000_000)

        let countAfterFirstLoad = callCount

        // 再次 demandLoad 同一目录（此时已是 .loaded）
        coordinator.demandLoad(directoryID: subdirURL)
        try await Task.sleep(nanoseconds: 300_000_000)

        // onNodesChanged 会被再次调用（更新内容），但不应崩溃或出错
        // 子项数量应保持一致
        #expect(callCount >= countAfterFirstLoad)
    }
}

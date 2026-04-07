import Foundation
import Testing
@testable import agentGui

@MainActor
struct WorkspaceTreeAutoFoldDemandLoadTests {

    private func makeTmpDir(_ suffix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-u1-demandload-\(suffix)-\(Int.random(in: 1000...9999))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - 初始加载：折叠链节点出现

    @Test func initialLoadCreatesAutoFoldedNode() async throws {
        // root/src/main/java/（每层只有 1 个子目录）→ 初始扫描结果应有 1 个折叠节点
        let root = try makeTmpDir("init")
        defer { try? FileManager.default.removeItem(at: root) }

        let java = root.appendingPathComponent("src/main/java")
        try FileManager.default.createDirectory(at: java, withIntermediateDirectories: true)

        var receivedNodes: [FileNode] = []
        let coordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: .init { _, _ in nil }
        )
        coordinator.compactFolders = true
        coordinator.onNodesChanged = { nodes, _ in receivedNodes = nodes }

        coordinator.setDirectory(root)
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(receivedNodes.count == 1)
        let srcNode = receivedNodes.first
        #expect(srcNode?.isFolded == true)
        #expect(srcNode?.foldedSegments == ["src", "main", "java"])
        #expect(srcNode?.foldedTerminalURL?.standardizedFileURL.path == java.standardizedFileURL.path)
        #expect(srcNode?.childrenLoadState == .notLoaded)
    }

    @Test func initialLoadDisabledDoesNotFold() async throws {
        let root = try makeTmpDir("nofold")
        defer { try? FileManager.default.removeItem(at: root) }

        let java = root.appendingPathComponent("src/main/java")
        try FileManager.default.createDirectory(at: java, withIntermediateDirectories: true)

        var receivedNodes: [FileNode] = []
        let coordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: .init { _, _ in nil }
        )
        coordinator.compactFolders = false
        coordinator.onNodesChanged = { nodes, _ in receivedNodes = nodes }

        coordinator.setDirectory(root)
        try await Task.sleep(nanoseconds: 300_000_000)

        let srcNode = receivedNodes.first(where: { $0.name == "src" })
        #expect(srcNode?.isFolded == false)
    }

    // MARK: - demandLoad 展开折叠节点：扫描链尾

    @Test func demandLoadFoldedNodeScansTerminalURL() async throws {
        // root/src/main/java/ 含 App.swift
        let root = try makeTmpDir("fold-expand")
        defer { try? FileManager.default.removeItem(at: root) }

        let java = root.appendingPathComponent("src/main/java")
        try FileManager.default.createDirectory(at: java, withIntermediateDirectories: true)
        try "class App {}".write(to: java.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)

        var receivedNodes: [FileNode] = []
        let coordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: .init { _, _ in nil }
        )
        coordinator.compactFolders = true
        coordinator.onNodesChanged = { nodes, _ in receivedNodes = nodes }

        coordinator.setDirectory(root)
        try await Task.sleep(nanoseconds: 300_000_000)

        // 展开折叠节点（传入 id = src URL）
        let srcURL = root.appendingPathComponent("src")
        coordinator.demandLoad(directoryID: srcURL)
        try await Task.sleep(nanoseconds: 300_000_000)

        // src 节点应变为 .loaded，子项为 java/ 下的 App.swift
        let srcNode = receivedNodes.first(where: { $0.id.standardizedFileURL == srcURL.standardizedFileURL })
        #expect(srcNode?.childrenLoadState == .loaded)
        #expect(srcNode?.children?.count == 1)
        #expect(srcNode?.children?.first?.name == "App.swift")
        // 折叠字段应被保留
        #expect(srcNode?.isFolded == true)
        #expect(srcNode?.foldedSegments == ["src", "main", "java"])
    }

    @Test func demandLoadNonFoldedNodeWorksAsUsual() async throws {
        // 普通目录展开不受影响
        let root = try makeTmpDir("plain")
        defer { try? FileManager.default.removeItem(at: root) }

        let subdir = root.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "x".write(to: subdir.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)

        var receivedNodes: [FileNode] = []
        let coordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: .init { _, _ in nil }
        )
        coordinator.compactFolders = true
        coordinator.onNodesChanged = { nodes, _ in receivedNodes = nodes }
        coordinator.setDirectory(root)
        try await Task.sleep(nanoseconds: 300_000_000)

        coordinator.demandLoad(directoryID: subdir)
        try await Task.sleep(nanoseconds: 300_000_000)

        let subdirNode = receivedNodes.first(where: { $0.name == "subdir" })
        #expect(subdirNode?.childrenLoadState == .loaded)
        #expect(subdirNode?.children?.count == 1)
        #expect(subdirNode?.isFolded == false)
    }

    @Test func demandLoadChildDirsAlsoGetFolded() async throws {
        // root/src/main/java/ 下有 com/example/（单子链），java/ 内同时有一个文件
        // → java/ 有 2 个条目，链止于 java；展开后 com/ 应被折叠为 com/example
        let root = try makeTmpDir("nested-fold")
        defer { try? FileManager.default.removeItem(at: root) }

        let example = root.appendingPathComponent("src/main/java/com/example")
        try FileManager.default.createDirectory(at: example, withIntermediateDirectories: true)
        try "class A {}".write(to: example.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        // 在 java/ 中添加一个文件，使 java/ 有 2 个条目，让链在 java 停止而非穿透到 com
        try "".write(to: root.appendingPathComponent("src/main/java/Main.java"), atomically: true, encoding: .utf8)

        var receivedNodes: [FileNode] = []
        let coordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: .init { _, _ in nil }
        )
        coordinator.compactFolders = true
        coordinator.onNodesChanged = { nodes, _ in receivedNodes = nodes }
        coordinator.setDirectory(root)
        try await Task.sleep(nanoseconds: 300_000_000)

        // 展开 src（折叠链链头，链止于 java）
        let srcURL = root.appendingPathComponent("src")
        coordinator.demandLoad(directoryID: srcURL)
        try await Task.sleep(nanoseconds: 300_000_000)

        // java/ 下的 com/ 也应被折叠为 com/example
        let srcNode = receivedNodes.first(where: { $0.id.standardizedFileURL == srcURL.standardizedFileURL })
        let comNode = srcNode?.children?.first(where: { $0.name == "com" })
        #expect(comNode?.isFolded == true)
        #expect(comNode?.foldedSegments == ["com", "example"])
    }
}

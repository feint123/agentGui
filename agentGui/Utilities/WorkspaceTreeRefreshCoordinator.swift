import Foundation
import CoreServices

protocol WorkspaceDirectoryObservationSession: AnyObject {
    func stop()
}

struct WorkspaceDirectoryObservationFactory {
    let makeObservation: (URL, @escaping ([String]) -> Void) -> WorkspaceDirectoryObservationSession?

    init(_ makeObservation: @escaping (URL, @escaping ([String]) -> Void) -> WorkspaceDirectoryObservationSession?) {
        self.makeObservation = makeObservation
    }

    func make(url: URL, onChange: @escaping ([String]) -> Void) -> WorkspaceDirectoryObservationSession? {
        makeObservation(url.standardizedFileURL, onChange)
    }

    static let live = WorkspaceDirectoryObservationFactory { url, onChange in
        LiveWorkspaceDirectoryObservation(url: url, onChange: onChange)
    }
}

typealias WorkspaceTreeShallowEntry = (name: String, url: URL, isDirectory: Bool)

@MainActor
final class WorkspaceTreeRefreshCoordinator {
    var onNodesChanged: (([FileNode], Bool) -> Void)?

    private let observationFactory: WorkspaceDirectoryObservationFactory
    private let debounceNanoseconds: UInt64
    private let buildNodesClosure: @Sendable (URL) async -> [FileNode]
    private let shallowScanClosure: @Sendable (URL) async -> [WorkspaceTreeShallowEntry]
    private let mergeNodesClosure: @Sendable ([FileNode], [WorkspaceTreeShallowEntry]) async -> [FileNode]
    private let applyPartialUpdateClosure: @Sendable ([FileNode], URL) async -> [FileNode]

    private var activeObservation: WorkspaceDirectoryObservationSession?
    private var debounceTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var currentDirectory: URL?
    private var currentNodes: [FileNode] = []
    private var pendingPaths: Set<String> = []
    private var generation: Int = 0

    /// Auto-fold 开关（FT-U1）。与 AppSettings.compactFolders 同步，由 ViewModel 赋值。
    var compactFolders: Bool = true

    init(
        observationFactory: WorkspaceDirectoryObservationFactory = .live,
        debounceNanoseconds: UInt64 = 150_000_000,
        buildNodes: @escaping @Sendable (URL) async -> [FileNode] = { url in
            WorkspaceTreeSnapshotOps.buildNodesShallow(at: url)
        },
        shallowScan: @escaping @Sendable (URL) async -> [WorkspaceTreeShallowEntry] = { url in
            WorkspaceTreeSnapshotOps.shallowScan(at: url)
        },
        mergeNodes: @escaping @Sendable ([FileNode], [WorkspaceTreeShallowEntry]) async -> [FileNode] = { existing, freshScan in
            WorkspaceTreeSnapshotOps.mergeNodes(existing: existing, freshScan: freshScan)
        },
        applyPartialUpdate: @escaping @Sendable ([FileNode], URL) async -> [FileNode] = { nodes, targetURL in
            WorkspaceTreeSnapshotOps.applyPartialUpdate(to: nodes, at: targetURL)
        }
    ) {
        self.observationFactory = observationFactory
        self.debounceNanoseconds = debounceNanoseconds
        self.buildNodesClosure = buildNodes
        self.shallowScanClosure = shallowScan
        self.mergeNodesClosure = mergeNodes
        self.applyPartialUpdateClosure = applyPartialUpdate
    }

    deinit {
        activeObservation?.stop()
        debounceTask?.cancel()
        scanTask?.cancel()
    }

    func setDirectory(_ url: URL?) {
        generation += 1
        let currentGeneration = generation

        activeObservation?.stop()
        activeObservation = nil
        debounceTask?.cancel()
        debounceTask = nil
        scanTask?.cancel()
        scanTask = nil
        pendingPaths.removeAll()

        guard let url else {
            currentDirectory = nil
            currentNodes = []
            onNodesChanged?([], false)
            return
        }

        let standardizedURL = url.standardizedFileURL
        currentDirectory = standardizedURL
        currentNodes = []
        onNodesChanged?([], true)

        activeObservation = observationFactory.make(url: standardizedURL) { [weak self] changedPaths in
            Task { @MainActor [weak self] in
                self?.enqueue(paths: changedPaths, generation: currentGeneration)
            }
        }

        scheduleFullReload(for: standardizedURL, generation: currentGeneration)
    }

    func refreshDirectories(_ urls: [URL]) {
        guard let rootURL = currentDirectory else { return }

        let normalizedTargets = Array(Set(urls.map(\.standardizedFileURL))).filter {
            let path = $0.path
            let rootPath = rootURL.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
        guard !normalizedTargets.isEmpty else { return }

        let snapshot = currentNodes
        let generation = self.generation
        let shallowScan = shallowScanClosure
        let mergeNodes = mergeNodesClosure
        let applyPartialUpdate = applyPartialUpdateClosure

        scanTask?.cancel()
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            var updated = snapshot

            for targetURL in normalizedTargets.sorted(by: { $0.path.count < $1.path.count }) {
                guard !Task.isCancelled else { return }
                if targetURL == rootURL {
                    let freshScan = await shallowScan(rootURL)
                    updated = await mergeNodes(updated, freshScan)
                } else if updated.isEmpty {
                    let freshScan = await shallowScan(rootURL)
                    updated = await mergeNodes([], freshScan)
                } else {
                    updated = await applyPartialUpdate(updated, targetURL)
                }
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.generation == generation, self.currentDirectory == rootURL else { return }
                self.currentNodes = updated
                self.onNodesChanged?(updated, false)
            }
        }
    }

    /// 按需加载指定目录的 1 层子项。
    /// 若该节点是折叠节点（foldedTerminalURL 非空），则扫描链尾目录而非 id 所在目录。
    /// 扫描完成后通过 onNodesChanged 推送更新。
    func demandLoad(directoryID: URL) {
        let nodeID = directoryID.standardizedFileURL
        let snapshot = currentNodes
        let generation = self.generation
        let shallowScan = shallowScanClosure
        let shouldCompact = compactFolders

        // 从快照中取出该节点，获取真正的扫描目标（folded 节点扫链尾，普通节点扫自身）
        let existingNode = WorkspaceTreeSnapshotOps.findNode(in: snapshot, id: nodeID)
        let scanURL = existingNode?.foldedTerminalURL?.standardizedFileURL ?? nodeID

        scanTask?.cancel()
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }

            // 扫描目标目录（链尾）的 1 层子项
            let freshEntries = await shallowScan(scanURL)
            let freshChildren: [FileNode] = freshEntries.map { entry in
                if entry.isDirectory {
                    // 子目录也应用折叠（FT-U1）
                    if shouldCompact,
                       let chain = WorkspaceTreeSnapshotOps.compactSingleChildChain(startingAt: entry.url) {
                        return FileNode(
                            id: entry.url,
                            name: entry.name,
                            isDirectory: true,
                            children: nil,
                            childrenLoadState: .notLoaded,
                            foldedSegments: chain.segments,
                            foldedTerminalURL: chain.terminalURL
                        )
                    }
                    return FileNode(
                        id: entry.url,
                        name: entry.name,
                        isDirectory: true,
                        children: nil,
                        childrenLoadState: .notLoaded
                    )
                }
                return FileNode(id: entry.url, name: entry.name, isDirectory: false, children: nil)
            }

            guard !Task.isCancelled else { return }

            // 在树中找到目标节点（以 nodeID 查找），替换为 .loaded 状态，保留折叠字段
            let updated = WorkspaceTreeSnapshotOps.replaceNode(in: snapshot, id: nodeID) { node in
                FileNode(
                    id: node.id,
                    name: node.name,
                    isDirectory: true,
                    children: freshChildren,
                    childrenLoadState: .loaded,
                    foldedSegments: node.foldedSegments,       // 保留
                    foldedTerminalURL: node.foldedTerminalURL  // 保留
                )
            }

            await MainActor.run {
                guard let self, self.generation == generation else { return }
                self.currentNodes = updated
                self.onNodesChanged?(updated, false)
            }
        }
    }

    private func enqueue(paths: [String], generation: Int) {
        guard generation == self.generation else { return }

        pendingPaths.formUnion(paths)
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            let drainedPaths = Array(self.pendingPaths)
            self.pendingPaths.removeAll()
            await self.refresh(paths: drainedPaths, generation: generation)
        }
    }

    private func scheduleFullReload(for url: URL, generation: Int) {
        let shouldCompact = compactFolders          // 捕获（Sendable Bool）
        scanTask?.cancel()
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let nodes = await WorkspaceTreeSnapshotOps.buildNodesShallow(at: url, compactFolders: shouldCompact)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.generation == generation, self.currentDirectory == url else { return }
                self.currentNodes = nodes
                self.onNodesChanged?(nodes, false)
            }
        }
    }

    private func refresh(paths: [String], generation: Int) async {
        guard generation == self.generation, let rootURL = currentDirectory else { return }

        let snapshot = currentNodes
        guard !snapshot.isEmpty else {
            scheduleFullReload(for: rootURL, generation: generation)
            return
        }

        let shallowScan = shallowScanClosure
        let mergeNodes = mergeNodesClosure
        let applyPartialUpdate = applyPartialUpdateClosure
        let rootURLCopy = rootURL

        scanTask?.cancel()
        scanTask = Task.detached(priority: .utility) { [weak self] in
            // 1. 后台计算脏目录（FT-P2：原在 MainActor 上计算）
            let rawTargets = WorkspaceTreeSnapshotOps.refreshTargets(for: paths, rootURL: rootURLCopy)
            guard !rawTargets.isEmpty else { return }

            // 2. 大批量降级（FT-P2：超阈值降级为根级全量合并）
            let targets: [URL] = rawTargets.count > WorkspaceTreeSnapshotOps.largeRefreshThreshold
                ? [rootURLCopy]
                : rawTargets

            // 3. 串行刷新
            var updated = snapshot
            for targetURL in targets {
                guard !Task.isCancelled else { return }
                if targetURL == rootURLCopy {
                    let freshScan = await shallowScan(rootURLCopy)
                    updated = await mergeNodes(updated, freshScan)
                } else {
                    updated = await applyPartialUpdate(updated, targetURL)
                }
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.generation == generation,
                      self.currentDirectory == rootURLCopy else { return }
                self.currentNodes = updated
                self.onNodesChanged?(updated, false)
            }
        }
    }
}

enum WorkspaceTreeSnapshotOps {
    private static let scanResourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey]

    static func filterNodes(_ nodes: [FileNode], query: String) -> [FileNode] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return nodes }

        return nodes.compactMap { filter(node: $0, query: normalizedQuery) }
    }

    static func refreshTargets(for paths: [String], rootURL: URL) -> [URL] {
        let rootStandardizedURL = rootURL.standardizedFileURL
        let rootPath = rootStandardizedURL.path
        var dirtyDirectories = Set<URL>()

        for path in paths {
            let changedURL = URL(fileURLWithPath: path).standardizedFileURL
            let parentURL = changedURL.deletingLastPathComponent()

            if parentURL.path == rootPath || parentURL.path.hasPrefix(rootPath + "/") {
                dirtyDirectories.insert(parentURL)
            }

            if changedURL.path == rootPath || changedURL.path.hasPrefix(rootPath + "/") {
                let isDirectory = (try? changedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if isDirectory {
                    dirtyDirectories.insert(changedURL)
                }
            }
        }

        let sorted = dirtyDirectories.sorted { $0.path < $1.path }  // 字典序
        return pruneDescendants(sorted)
    }

    // MARK: - FT-P2: 祖先支配裁剪

    /// 大批量阈值：超过此数量的脏目录时，降级为根级全量合并。
    static let largeRefreshThreshold = 30

    /// 字典序排序后，移除「路径前缀被已保留条目覆盖」的后代 URL。
    /// 输入必须已按路径字典序排序。复杂度 O(N)。
    static func pruneDescendants(_ sorted: [URL]) -> [URL] {
        var result: [URL] = []
        result.reserveCapacity(sorted.count)
        for url in sorted {
            let path = url.path
            if let lastPath = result.last?.path,
               path == lastPath || path.hasPrefix(lastPath + "/") {
                continue   // 后代，跳过
            }
            result.append(url)
        }
        return result
    }

    static func shallowScan(at url: URL) -> [WorkspaceTreeShallowEntry] {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(scanResourceKeys),
            options: []
        ) else { return [] }

        return items.compactMap { itemURL -> WorkspaceTreeShallowEntry? in
            guard let values = try? itemURL.resourceValues(forKeys: scanResourceKeys),
                  let isDirectory = values.isDirectory else {
                return nil
            }
            let isHidden = values.isHidden == true
            guard shouldIncludeInTree(isDirectory: isDirectory, isHidden: isHidden) else {
                return nil
            }
            return (name: itemURL.lastPathComponent, url: itemURL, isDirectory: isDirectory == true)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func mergeNodes(
        existing: [FileNode],
        freshScan: [WorkspaceTreeShallowEntry]
    ) -> [FileNode] {
        let existingMap = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        return freshScan.map { item in
            if let existingNode = existingMap[item.url] {
                return existingNode
            }
            if item.isDirectory {
                // 新出现的目录标记为 .notLoaded，等待用户展开时按需扫描。
                // 不调用 buildNodes 以避免递归扫描带来的卡顿。
                return FileNode(id: item.url, name: item.name, isDirectory: true, children: nil, childrenLoadState: .notLoaded)
            }
            return FileNode(id: item.url, name: item.name, isDirectory: false, children: nil)
        }
    }

    static func applyPartialUpdate(to nodes: [FileNode], at targetURL: URL) -> [FileNode] {
        let targetPath = targetURL.path
        return nodes.map { node in
            guard node.isDirectory else { return node }
            let nodePath = node.id.path
            let terminalPath = node.foldedTerminalURL?.standardizedFileURL.path

            // 直接匹配或折叠链匹配（目标是链尾或链中间段）
            let matchesSelf = nodePath == targetPath
            let matchesFoldedTerminal = terminalPath != nil && terminalPath == targetPath
            let matchesFoldChain = terminalPath != nil
                && targetPath.hasPrefix(nodePath + "/")
                && terminalPath!.hasPrefix(targetPath + "/")

            if matchesSelf || matchesFoldedTerminal || matchesFoldChain {
                // 尚未加载的目录：直接返回原节点，用户展开时 demandLoad 会拿到最新状态。
                if node.childrenLoadState == .notLoaded {
                    return node
                }
                // 折叠节点：扫描链尾目录；普通节点：扫描自身
                let scanURL = node.foldedTerminalURL?.standardizedFileURL ?? node.id
                let freshScan = shallowScan(at: scanURL)
                let mergedNodes = mergeNodes(existing: node.children ?? [], freshScan: freshScan)
                return FileNode(
                    id: node.id, name: node.name, isDirectory: true,
                    children: mergedNodes, childrenLoadState: .loaded,
                    foldedSegments: node.foldedSegments,
                    foldedTerminalURL: node.foldedTerminalURL
                )
            }

            // 目标在子树中：递归处理（也检查折叠节点的链尾路径前缀）
            let isDescendant = targetPath.hasPrefix(nodePath + "/")
                || (terminalPath != nil && targetPath.hasPrefix(terminalPath! + "/"))
            if isDescendant {
                // 尚未加载的目录：FSEvent 到来时无需更新，用户展开时会触发按需扫描。
                if node.childrenLoadState == .notLoaded {
                    return node
                }
                let updatedChildren = applyPartialUpdate(to: node.children ?? [], at: targetURL)
                return FileNode(
                    id: node.id, name: node.name, isDirectory: true,
                    children: updatedChildren, childrenLoadState: node.childrenLoadState,
                    foldedSegments: node.foldedSegments,
                    foldedTerminalURL: node.foldedTerminalURL
                )
            }
            return node
        }
    }

    /// 浅扫描：只扫描 1 层，子目录标记为 .notLoaded，不递归。
    /// 初始加载和按需加载的"扫描该目录 1 层"逻辑均由此方法驱动。
    /// - `compactFolders`：若为 `true`，对单子目录链应用折叠压缩（FT-U1）。
    static func buildNodesShallow(at url: URL, compactFolders: Bool = true) -> [FileNode] {
        shallowScan(at: url).map { entry in
            if entry.isDirectory {
                if compactFolders,
                   let chain = compactSingleChildChain(startingAt: entry.url) {
                    return FileNode(
                        id: entry.url,
                        name: entry.name,
                        isDirectory: true,
                        children: nil,
                        childrenLoadState: .notLoaded,
                        foldedSegments: chain.segments,
                        foldedTerminalURL: chain.terminalURL
                    )
                }
                return FileNode(
                    id: entry.url,
                    name: entry.name,
                    isDirectory: true,
                    children: nil,
                    childrenLoadState: .notLoaded
                )
            }
            return FileNode(id: entry.url, name: entry.name, isDirectory: false, children: nil)
        }
    }

    // MARK: - FT-U1: Auto-fold 工具

    /// 从 `startURL` 沿单子目录链追踪，返回所有段名称和链尾 URL。
    ///
    /// 条件：该目录仅有一个可见子项，且该子项为目录。
    /// - 若链长度 == 1（`startURL` 自身无单子子目录）→ 返回 `nil`（不折叠）。
    /// - 若追踪链长度 >= 2 → 返回 `(segments, terminalURL)`。
    ///
    /// 性能：每步调用 `shallowScan`（I/O）。链深度通常 2–6，可接受。
    static func compactSingleChildChain(startingAt startURL: URL) -> (segments: [String], terminalURL: URL)? {
        var segments: [String] = [startURL.lastPathComponent]
        var current = startURL

        while true {
            let entries = shallowScan(at: current)
            // 可折叠条件：恰好 1 个可见条目，且该条目是目录
            guard entries.count == 1, let onlyChild = entries.first, onlyChild.isDirectory else {
                break
            }
            current = onlyChild.url
            segments.append(onlyChild.name)
        }

        guard segments.count > 1 else { return nil }
        return (segments: segments, terminalURL: current)
    }

    /// 在节点树中按 `id` 查找节点。
    /// 只递归进入 `childrenLoadState == .loaded` 的节点（未加载的子树不遍历）。
    /// 复杂度 O(已加载节点数)。
    static func findNode(in nodes: [FileNode], id: URL) -> FileNode? {
        let targetPath = id.standardizedFileURL.path
        for node in nodes {
            if node.id.standardizedFileURL.path == targetPath { return node }
            guard node.isDirectory,
                  node.childrenLoadState == .loaded,
                  let children = node.children else { continue }
            if let found = findNode(in: children, id: id) { return found }
        }
        return nil
    }

    /// 在树中递归找到 id 匹配的节点，用 transform 的返回值替换它。
    /// 若树中不存在该 id，返回原树不变。
    /// 只遍历 childrenLoadState == .loaded 的目录。
    static func replaceNode(in nodes: [FileNode], id: URL, transform: (FileNode) -> FileNode) -> [FileNode] {
        let targetPath = id.standardizedFileURL.path
        return nodes.map { node in
            let nodePath = node.id.standardizedFileURL.path
            if nodePath == targetPath {
                return transform(node)
            }
            guard node.isDirectory, node.childrenLoadState == .loaded, let children = node.children else {
                return node
            }
            let updatedChildren = replaceNode(in: children, id: id, transform: transform)
            return FileNode(
                id: node.id, name: node.name, isDirectory: true,
                children: updatedChildren, childrenLoadState: .loaded,
                foldedSegments: node.foldedSegments,
                foldedTerminalURL: node.foldedTerminalURL
            )
        }
    }

    static func buildNodes(at url: URL, depth: Int) -> [FileNode] {
        guard depth < 8 else { return [] }
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(scanResourceKeys),
            options: []
        ) else { return [] }

        return items.compactMap { itemURL -> FileNode? in
            guard let values = try? itemURL.resourceValues(forKeys: scanResourceKeys),
                  let isDirectory = values.isDirectory else {
                return nil
            }
            let isHidden = values.isHidden == true
            guard shouldIncludeInTree(isDirectory: isDirectory, isHidden: isHidden) else {
                return nil
            }
            if isDirectory == true {
                let children = buildNodes(at: itemURL, depth: depth + 1)
                return FileNode(id: itemURL, name: itemURL.lastPathComponent, isDirectory: true, children: children)
            }
            return FileNode(id: itemURL, name: itemURL.lastPathComponent, isDirectory: false, children: nil)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func shouldIncludeInTree(isDirectory: Bool, isHidden: Bool) -> Bool {
        return !isHidden
    }

    private static func filter(node: FileNode, query: String) -> FileNode? {
        let matchesSelf = node.name.localizedCaseInsensitiveContains(query)
            || (node.isFolded && node.foldedSegments.contains { $0.localizedCaseInsensitiveContains(query) })

        if !node.isDirectory {
            return matchesSelf ? node : nil
        }

        let filteredChildren = (node.children ?? []).compactMap { filter(node: $0, query: query) }
        guard matchesSelf || !filteredChildren.isEmpty else { return nil }

        return FileNode(
            id: node.id,
            name: node.name,
            isDirectory: true,
            children: matchesSelf ? node.children : filteredChildren,
            foldedSegments: node.foldedSegments,
            foldedTerminalURL: node.foldedTerminalURL
        )
    }
}

private final class LiveWorkspaceDirectoryObservation: WorkspaceDirectoryObservationSession, @unchecked Sendable {
    private var streamRef: FSEventStreamRef?

    init?(url: URL, onChange: @escaping ([String]) -> Void) {
        guard start(rootURL: url.standardizedFileURL, onChange: onChange) else { return nil }
    }

    deinit {
        stop()
    }

    private func start(rootURL: URL, onChange: @escaping ([String]) -> Void) -> Bool {
        final class CallbackBox {
            let fn: ([String]) -> Void

            init(_ fn: @escaping ([String]) -> Void) {
                self.fn = fn
            }
        }

        let callbackBox = Unmanaged.passRetained(CallbackBox(onChange))
        var context = FSEventStreamContext(
            version: 0,
            info: callbackBox.toOpaque(),
            retain: nil,
            release: { pointer in
                Unmanaged<CallbackBox>.fromOpaque(pointer!).release()
            },
            copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagNoDefer) |
            UInt32(kFSEventStreamCreateFlagWatchRoot) |
            UInt32(kFSEventStreamCreateFlagUseCFTypes)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, eventPaths, _, _ in
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                Unmanaged<CallbackBox>.fromOpaque(info!).takeUnretainedValue().fn(paths)
            },
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId.max,
            0.4,
            flags
        ) else {
            callbackBox.release()
            return false
        }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }

        streamRef = stream
        return true
    }

    func stop() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
    }
}
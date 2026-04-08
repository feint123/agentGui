// agentGui/Services/FileTreeStore.swift
import Foundation

/// 文件树核心 Actor。
///
/// 架构决策（参考 Zed project_panel.rs + VSCode explorerView.ts）：
/// - **扁平索引（entries + children）**：O(1) 条目查找，避免递归树遍历。
///   Zed 的 Worktree 同样以扁平 Arena（`HashMap<ProjectEntryId, Entry>`）存储。
/// - **邻接表（children）**：`[EntryID: [EntryID]]` 排序后的子节点列表，
///   更新单目录不影响其他节点。
/// - **expandedIDs**：仅跟踪已展开目录 ID（Set），不嵌入 Entry 本身。
///   VSCode `ExplorerView` 通过 `IAsyncDataTreeViewState` 存储展开状态，设计思路相同。
/// - **setRoot**：仅执行浅扫描（根级一层），深层目录按需懒加载（FT-R3）。
///   VSCode `explorerView.ts` 的 `setTreeInput` 也是先 setInput 再按需 expand。
actor FileTreeStore {

    // MARK: - 存储

    /// 所有已知条目的 O(1) 索引。
    private var entries: [EntryID: FileEntry] = [:]

    /// 邻接表：parentID → 已排序 childIDs（按名称升序，目录优先）。
    private var children: [EntryID: [EntryID]] = [:]

    /// 根级条目 ID 列表（对应 Zed 的 worktree 根节点列表）。
    private var rootIDs: [EntryID] = []

    /// 已展开目录的 ID 集合。
    private var expandedIDs: Set<EntryID> = []

    // FT-R7: Git 状态字典（EntryID → GitSummary）
    private var gitStatuses: [EntryID: GitSummary] = [:]

    private let scanner: FileScanning
    private let fsObserver: FSEventObserving

    /// 当前监听的根目录 URL。
    private var rootURL: URL?

    // MARK: - FSEvent 通知流

    /// FSEvent 处理完成后向 ViewModel 发送刷新通知的 continuation。
    /// ViewModel 在 `setDirectory` 中通过 `fsEventStream` 订阅。
    private var fsEventContinuation: AsyncStream<Void>.Continuation?

    /// ViewModel 订阅此流以获知 FSEvent 导致的 Store 变更。
    nonisolated let fsEventStream: AsyncStream<Void>

    // MARK: - Init

    init(
        scanner: FileScanning = RealFileScanner(),
        fsObserver: FSEventObserving = FSEventObserver()
    ) {
        self.scanner = scanner
        self.fsObserver = fsObserver
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.fsEventStream = stream
        self.fsEventContinuation = continuation
    }

    // MARK: - 公开 API

    /// 当前根目录 URL（供 `FileTreeViewModel.beginCreate(near:nil)` 使用）。
    var currentRootURL: URL? { rootURL }

    /// 父目录的直接子条目名称列表（用于内联编辑重复名检测）。
    /// 对标 Zed `populate_validation_error` 中的 `already_exists` 检测数据来源。
    func siblingNames(of parentID: EntryID) -> [String] {
        (children[parentID] ?? []).compactMap { entries[$0]?.name }
    }

    /// 设置工作区根目录，执行浅扫描并重建索引，启动 FSEvent 监听。
    func setRoot(_ url: URL) async {
        // 停止旧观察
        await fsObserver.stopObserving()

        let standardizedRoot = url.standardizedFileURL
        rootURL = standardizedRoot
        entries = [:]
        children = [:]
        rootIDs = []
        expandedIDs = []

        guard let scanned = try? await scanner.shallowScan(directory: standardizedRoot) else { return }

        var childIDs: [EntryID] = []
        for item in scanned {
            let id = EntryID(url: item.url.standardizedFileURL)
            let entry = FileEntry(
                id: id,
                name: item.name,
                isDirectory: item.isDirectory,
                parentID: nil,    // 根级条目无父
                loadState: item.isDirectory ? .notLoaded : .loaded
            )
            entries[id] = entry
            childIDs.append(id)
        }
        rootIDs = sortedIDs(childIDs)

        // 启动 FSEvent 监听
        await fsObserver.startObserving(directory: standardizedRoot) { [weak self] changedPaths in
            Task { [weak self] in
                await self?.applyFSEvents(changedPaths)
            }
        }
    }

    /// 清除根目录并停止 FSEvent 监听。
    func clearRoot() async {
        await fsObserver.stopObserving()
        rootURL = nil
        entries = [:]
        children = [:]
        rootIDs = []
        expandedIDs = []
    }

    /// 展开目录：若尚未加载则触发浅扫描，将 ID 加入 expandedIDs。
    ///
    /// 错误处理（参考 Zed `fetch_directory_contents()` 失败路径）：
    /// - 扫描失败时：重置 loadState 为 .notLoaded，从 expandedIDs 移除，再 rethrow。
    /// - 这确保目录在 UI 侧仍可再次点击展开，且 visibleEntries 不会出现悬空的 .loading 行。
    func expandDirectory(_ id: EntryID) async throws {
        guard let entry = entries[id], entry.isDirectory else { return }
        expandedIDs.insert(id)

        guard entry.loadState == .notLoaded else { return }

        // 标记 loading，触发 UI spinner
        entries[id]?.loadState = .loading

        do {
            let scanned = try await scanner.shallowScan(directory: id.url)

            var childIDs: [EntryID] = []
            for item in scanned {
                let childIDVal = EntryID(url: item.url.standardizedFileURL)
                let childEntry = FileEntry(
                    id: childIDVal,
                    name: item.name,
                    isDirectory: item.isDirectory,
                    parentID: id,
                    loadState: item.isDirectory ? .notLoaded : .loaded
                )
                entries[childIDVal] = childEntry
                childIDs.append(childIDVal)
            }
            children[id] = sortedIDs(childIDs)
            entries[id]?.loadState = .loaded
        } catch {
            // 扫描失败：回退状态，确保 UI 一致性
            entries[id]?.loadState = .notLoaded
            expandedIDs.remove(id)
            throw error
        }
    }

    /// 折叠目录：从 expandedIDs 移除，不卸载 children（保留缓存）。
    func collapseDirectory(_ id: EntryID) {
        expandedIDs.remove(id)
    }

    /// 查询目录是否已展开。
    func isExpanded(_ id: EntryID) -> Bool {
        expandedIDs.contains(id)
    }

    /// O(1) 查找条目。
    func entry(for id: EntryID) -> FileEntry? {
        entries[id]
    }

    // MARK: - FT-R7: Git 状态更新

    /// 接收外部 Git 状态更新（URL → GitSummary），转换后存储。
    /// 调用方需在更新后手动调用 computeVisibleEntries() 刷新快照。
    func updateGitStatuses(_ statuses: [URL: GitSummary]) {
        gitStatuses = Dictionary(
            uniqueKeysWithValues: statuses.map { (EntryID(url: $0.key), $0.value) }
        )
    }

    /// 后序递归聚合：文件直接返回状态；目录取子树 min（优先级最高）。
    private func aggregateGitSummary(for id: EntryID) -> GitSummary? {
        if let direct = gitStatuses[id] { return direct }
        guard let childIDs = children[id], !childIDs.isEmpty else { return nil }
        let childStatuses = childIDs.compactMap { aggregateGitSummary(for: $0) }
        return childStatuses.min()
    }

    // MARK: - computeVisibleEntries
    //
    // 核心热路径：DFS 遍历 rootIDs，生成 [VisibleEntry]。
    // 参考 Zed update_visible_entries（project_panel.rs）的 background_spawn 模式：
    // 计算在后台线程，结果推送回主线程。
    // 本 Actor 方法在 actor executor 上运行（等同于后台线程），
    // 调用方在 FileTreeViewModel 中用 Task { @MainActor in ... } 接收结果。

    func computeVisibleEntries(
        searchFilter: String? = nil
    ) -> [VisibleEntry] {
        var result: [VisibleEntry] = []
        dfs(ids: rootIDs, depth: 0, result: &result, searchFilter: searchFilter)
        return result
    }

    // MARK: - Auto-fold（FT-R5）

    /// 是否开启 Compact Folders（默认 true，对标 VSCode compactFolders 设置）。
    private var compactFolders: Bool = true

    /// 用户手动展开的节点集合（不参与 auto-fold）。
    /// 参考 Zed `State.unfolded_dir_ids: HashSet<ProjectEntryId>`。
    private var unfoldedIDs: Set<EntryID> = []

    /// 对外暴露的设置入口（供 ViewModel 调用）。
    func setCompactFolders(_ value: Bool) {
        compactFolders = value
    }

    /// 将目录加入 unfoldedIDs，阻止其被自动折叠。
    /// 参考 Zed `unfold_directory(id)`。
    func unfoldDirectory(_ id: EntryID) {
        unfoldedIDs.insert(id)
    }

    /// 从 unfoldedIDs 移除，恢复 auto-fold。
    /// 参考 Zed `fold_directory(id)`。
    func foldDirectory(_ id: EntryID) {
        unfoldedIDs.remove(id)
    }

    /// 判断目录节点是否满足 auto-fold 条件。
    ///
    /// 条件（参考 Zed `is_foldable` + VSCode `ExplorerCompressionDelegate.isIncompressible`）：
    /// 1. compactFolders 为 true
    /// 2. 节点不在 unfoldedIDs 中（用户未手动展开）
    /// 3. 节点已展开（expandedIDs 包含）
    /// 4. 节点的子列表恰好只有一个子目录
    private func shouldAutoFold(_ id: EntryID) -> Bool {
        guard compactFolders else { return false }
        guard !unfoldedIDs.contains(id) else { return false }
        guard expandedIDs.contains(id) else { return false }
        guard let childList = children[id], childList.count == 1 else { return false }
        return entries[childList[0]]?.isDirectory == true
    }

    /// 从 startID 开始沿单子目录链向下收集，返回所有段（含 startID 到终端）和终端 ID。
    ///
    /// 算法（参考 Zed `update_visible_entries` auto-fold 块）：
    /// 从 startID 开始，若当前节点满足 shouldAutoFold，将其加入 segments 并继续；
    /// 直至某节点不满足 shouldAutoFold 为止（该节点是 terminalID）。
    private func collectFoldedChain(from startID: EntryID) -> (segments: [FoldedAncestors.FoldedSegment], terminalID: EntryID) {
        var segments: [FoldedAncestors.FoldedSegment] = []
        var current = startID

        while shouldAutoFold(current) {
            let name = entries[current]?.name ?? current.url.lastPathComponent
            segments.append(FoldedAncestors.FoldedSegment(name: name, entryID: current))
            current = children[current]![0]
        }

        // current 是终端节点：加入 segments 的最后一段
        let terminalName = entries[current]?.name ?? current.url.lastPathComponent
        segments.append(FoldedAncestors.FoldedSegment(name: terminalName, entryID: current))

        return (segments: segments, terminalID: current)
    }

    // MARK: - 私有

    private func dfs(
        ids: [EntryID],
        depth: Int,
        result: inout [VisibleEntry],
        searchFilter: String?
    ) {
        for id in ids {
            guard let entry = entries[id] else { continue }

            // 搜索过滤（简单前缀匹配，FT-R10 实现模糊搜索）
            if let filter = searchFilter, !filter.isEmpty {
                if !entry.name.localizedCaseInsensitiveContains(filter) {
                    continue
                }
            }

            // Auto-fold（FT-R5）：若当前节点是链起点，走链收集分支，跳过中间节点
            if entry.isDirectory, shouldAutoFold(id) {
                let chain = collectFoldedChain(from: id)
                let terminalID = chain.terminalID
                guard let terminalEntry = entries[terminalID] else { continue }
                let terminalIsExpanded = terminalEntry.isDirectory && expandedIDs.contains(terminalID)
                let visible = VisibleEntry(
                    id: terminalID,
                    name: terminalEntry.name,
                    isDirectory: terminalEntry.isDirectory,
                    depth: depth,
                    isExpanded: terminalIsExpanded,
                    loadState: terminalEntry.loadState,
                    foldedAncestors: FoldedAncestors(
                        segments: chain.segments,
                        terminalID: terminalID
                    ),
                    gitSummary: terminalIsExpanded ? nil : aggregateGitSummary(for: terminalID),
                    diagnosticSeverity: nil,
                    isIgnored: false
                )
                result.append(visible)
                if terminalIsExpanded, let childIDs = children[terminalID] {
                    dfs(ids: childIDs, depth: depth + 1, result: &result, searchFilter: searchFilter)
                }
                continue
            }

            let isExpanded = entry.isDirectory && expandedIDs.contains(id)
            let visible = VisibleEntry(
                id: id,
                name: entry.name,
                isDirectory: entry.isDirectory,
                depth: depth,
                isExpanded: isExpanded,
                loadState: entry.loadState,
                foldedAncestors: nil,
                gitSummary: isExpanded ? nil : aggregateGitSummary(for: id),
                diagnosticSeverity: nil,  // Diag badge 在 FT-R14 实现
                isIgnored: false          // .gitignore 在 FT-R6 实现
            )
            result.append(visible)

            if isExpanded, let childIDs = children[id] {
                dfs(ids: childIDs, depth: depth + 1, result: &result, searchFilter: searchFilter)
            }
        }
    }

    // MARK: - 测试注入接口（仅测试使用）

    #if DEBUG
    /// 仅供单元测试：直接注入 entries/children/rootIDs/expandedIDs，跳过 I/O。
    func injectEntries(
        _ newEntries: [EntryID: FileEntry],
        children newChildren: [EntryID: [EntryID]],
        rootIDs newRootIDs: [EntryID],
        expandedIDs newExpandedIDs: Set<EntryID>
    ) {
        entries = newEntries
        children = newChildren
        rootIDs = newRootIDs
        expandedIDs = newExpandedIDs
    }
    #endif

    /// 按目录优先、名称升序排列 EntryID 列表。
    /// 参考 Zed `par_sort_worktree_entries_with_mode` / VSCode `FileSorter`。
    private func sortedIDs(_ ids: [EntryID]) -> [EntryID] {
        ids.sorted { a, b in
            let entryA = entries[a]
            let entryB = entries[b]
            let aIsDir = entryA?.isDirectory ?? false
            let bIsDir = entryB?.isDirectory ?? false
            if aIsDir != bIsDir { return aIsDir }  // 目录优先
            let nameA = entryA?.name ?? a.url.lastPathComponent
            let nameB = entryB?.name ?? b.url.lastPathComponent
            return nameA.localizedStandardCompare(nameB) == .orderedAscending
        }
    }

    // MARK: - FSEvent 增量更新

    /// FSEvent 回调入口：根据变更路径增量更新 Store 状态。
    ///
    /// 算法（参考设计文档 §3.2 + 旧 WorkspaceTreeRefreshCoordinator.refresh）：
    /// 1. 计算 dirty 目录集合（变更路径的父目录）
    /// 2. 祖先剪枝（子路径被父路径覆盖时移除）
    /// 3. 若剪枝后目录数 > 30 → 降级为 setRoot 全量重建
    /// 4. 否则逐一 refreshDirectory
    ///
    /// - Parameter changedPaths: FSEvent 回调的原始路径字符串数组
    func applyFSEvents(_ changedPaths: [String]) async {
        guard let rootURL else { return }

        let dirty = Self.computeDirtyDirectories(changedPaths, rootURL: rootURL)
        let pruned = Self.pruneDescendants(dirty)

        if pruned.count > 30 {
            // 降级：超过 30 个受影响目录，全量重建成本低于逐个刷新
            await setRoot(rootURL)
            fsEventContinuation?.yield()
            return
        }

        for dir in pruned {
            await refreshDirectory(dir)
        }
        fsEventContinuation?.yield()
    }

    /// 重新扫描单个目录，将结果与 Store 中现有子条目对比，增量更新。
    /// internal 访问修饰符：供 `FileTreeViewModel.commitEdit()` 在写磁盘后刷新父目录状态。
    func refreshDirectory(_ url: URL) async {
        guard let rootURL else { return }

        // 根目录特殊处理：root 本身不存储在 entries 中，只有其内容在 rootIDs
        if Self.normPath(url) == Self.normPath(rootURL) {
            guard let scanned = try? await scanner.shallowScan(directory: url) else { return }
            let existingRootSet = Set(rootIDs)
            var newRootIDs: [EntryID] = []
            for item in scanned {
                let itemID = EntryID(url: item.url.standardizedFileURL)
                newRootIDs.append(itemID)
                if entries[itemID] == nil {
                    entries[itemID] = FileEntry(
                        id: itemID,
                        name: item.name,
                        isDirectory: item.isDirectory,
                        parentID: nil,
                        loadState: item.isDirectory ? .notLoaded : .loaded
                    )
                }
            }
            let newRootSet = Set(newRootIDs)
            for removed in existingRootSet.subtracting(newRootSet) {
                removeSubtree(rooted: removed)
            }
            rootIDs = sortedIDs(newRootIDs)
            return
        }

        let dirID = EntryID(url: url.standardizedFileURL)

        // 只对已知且已展开的目录执行增量刷新
        guard entries[dirID] != nil else {
            // 目录不在 Store 中（可能是新目录），尝试刷新其父目录
            let parent = url.deletingLastPathComponent()
            let parentID = EntryID(url: parent.standardizedFileURL)
            if entries[parentID] != nil {
                await refreshDirectory(parent)
            }
            return
        }

        // 只刷新根目录或已展开目录的内容
        guard rootIDs.isEmpty || expandedIDs.contains(dirID) || isRootLevelDirectory(dirID) else {
            return
        }

        // 重新扫描
        guard let scanned = try? await scanner.shallowScan(directory: url) else { return }

        let existingChildren = Set(children[dirID] ?? [])
        var newChildren: [EntryID] = []

        for item in scanned {
            let itemID = EntryID(url: item.url.standardizedFileURL)
            newChildren.append(itemID)

            if entries[itemID] == nil {
                // 新出现的条目
                entries[itemID] = FileEntry(
                    id: itemID,
                    name: item.name,
                    isDirectory: item.isDirectory,
                    parentID: dirID,
                    loadState: item.isDirectory ? .notLoaded : .loaded
                )
            }
        }

        // 删除已消失的条目及其子树
        let newChildSet = Set(newChildren)
        for removed in existingChildren.subtracting(newChildSet) {
            removeSubtree(rooted: removed)
        }

        children[dirID] = sortedIDs(newChildren)

        // 更新父目录 loadState
        if entries[dirID] != nil {
            entries[dirID]?.loadState = .loaded
        }
    }

    /// 判断某 ID 是否是根级目录（出现在 rootIDs 中）。
    private func isRootLevelDirectory(_ id: EntryID) -> Bool {
        rootIDs.contains(id)
    }

    /// 无条件刷新目录内容——供 `commitEdit()` 使用。
    ///
    /// 与 `refreshDirectory` 的区别：不检查 `expandedIDs`/`isRootLevelDirectory`，
    /// 因为用户在内联编辑中创建文件后，目标目录一定是已展开的（占位行在其中），
    /// 但 `refreshDirectory` 的守卫可能因为 rootURL 路径对比差异而跳过。
    func refreshDirectoryForCommit(_ url: URL) async {
        guard rootURL != nil else { return }

        let standardizedURL = url.standardizedFileURL

        // 根目录特殊处理
        if let rootURL, Self.normPath(standardizedURL) == Self.normPath(rootURL) {
            await refreshDirectory(standardizedURL)
            return
        }

        let dirID = EntryID(url: standardizedURL)

        // 确保目录在 entries 中且标记为展开
        if entries[dirID] != nil {
            expandedIDs.insert(dirID)
        }
        await refreshDirectory(standardizedURL)
    }

    /// 递归删除某 entryID 及其所有子孙条目。
    private func removeSubtree(rooted id: EntryID) {
        if let childIDs = children.removeValue(forKey: id) {
            for child in childIDs {
                removeSubtree(rooted: child)
            }
        }
        entries.removeValue(forKey: id)
        expandedIDs.remove(id)
    }

    // MARK: - FSEvent 增量更新辅助（nonisolated static，供测试直接调用）

    /// 根据 FSEvent 变更路径计算需要重新扫描的目录集合。
    ///
    /// 算法（参考旧 `WorkspaceTreeSnapshotOps.refreshTargets(for:rootURL:)`）：
    /// 1. 文件变更 → 取父目录
    /// 2. 目录变更（isDirectory = true）→ 取自身
    /// 3. 只保留 rootURL 树内的路径
    ///
    /// 注意：此方法不进行 I/O（不 stat 路径），依赖已知条件，轻量快速。
    nonisolated static func computeDirtyDirectories(
        _ changedPaths: [String],
        rootURL: URL
    ) -> [URL] {
        let rootPath = Self.normPath(rootURL)
        var dirtyPaths = Set<String>()

        for path in changedPaths {
            let changedURL = URL(fileURLWithPath: path)
            let parentPath = Self.normPath(changedURL.deletingLastPathComponent())

            // 父目录若在 root 树下，标记为 dirty
            if parentPath == rootPath || parentPath.hasPrefix(rootPath + "/") {
                dirtyPaths.insert(parentPath)
            }

            // 变更路径本身若也在 root 树下，同样标记（可能是目录）
            let changedPath = Self.normPath(changedURL)
            if changedPath.hasPrefix(rootPath + "/") || changedPath == rootPath {
                dirtyPaths.insert(changedPath)
            }
        }

        // 按路径深度排序（浅层先处理），让后续 pruneDescendants 保留最浅的祖先
        return dirtyPaths
            .sorted { $0.count < $1.count }
            .map { URL(fileURLWithPath: $0) }
    }

    /// 剪枝：若一个路径已有祖先在集合中，则移除该路径。
    ///
    /// 算法参考 Zed `coalesce_pending_rescans` 的祖先覆盖逻辑：
    /// - 若父目录在列表中，子目录的刷新隐含在父目录刷新中，可丢弃
    /// - 减少不必要的 shallowScan 调用
    nonisolated static func pruneDescendants(_ directories: [URL]) -> [URL] {
        var result: [URL] = []
        for dir in directories {
            let dirPath = Self.normPath(dir)
            let coveredByAncestor = result.contains { ancestor in
                let ancestorPath = Self.normPath(ancestor)
                return dirPath != ancestorPath && dirPath.hasPrefix(ancestorPath + "/")
            }
            if !coveredByAncestor {
                result.append(dir)
            }
        }
        return result
    }

    /// 返回不带末尾斜杠的规范化路径字符串。
    nonisolated private static func normPath(_ url: URL) -> String {
        let p = url.path
        return (p.hasSuffix("/") && p.count > 1) ? String(p.dropLast()) : p
    }

    // MARK: - FT-R9: 快照 + 批量刷新

    /// 构建当前状态的值类型快照，供 FileTreeDropValidator 在非 actor 上下文使用。
    func makeSnapshot() -> FileTreeStoreSnapshot {
        FileTreeStoreSnapshot(entries: entries, children: children)
    }

    /// 批量刷新多个目录（先去除后代重复，再顺序刷新）。
    /// 参数使用 EntryID，内部转换为 URL 调用 refreshDirectory。
    func refreshMultipleDirectories(_ dirIDs: [EntryID]) async {
        // 用静态方法去重（按 URL 路径）
        let dirURLs = dirIDs.map(\.url)
        let pruned = Self.pruneDescendants(dirURLs)
        for url in pruned {
            await refreshDirectory(url)
        }
    }
}

// MARK: - FileTreeStoreSnapshot

/// `FileTreeStore` 的 Sendable 只读快照，符合 `StoreSnapshotProtocol`。
/// 供 `FileTreeDropValidator` 在主线程上下文中同步查询，无需等待 actor。
struct FileTreeStoreSnapshot: StoreSnapshotProtocol, Sendable {
    private let entries: [EntryID: FileEntry]
    private let children: [EntryID: [EntryID]]

    init(entries: [EntryID: FileEntry], children: [EntryID: [EntryID]]) {
        self.entries = entries
        self.children = children
    }

    func entry(_ id: EntryID) -> FileEntry? { entries[id] }
    func parentID(of id: EntryID) -> EntryID? { entries[id]?.parentID }
    func children(of id: EntryID) -> [EntryID] { children[id] ?? [] }
}

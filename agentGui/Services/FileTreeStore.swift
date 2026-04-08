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

    private let scanner: FileScanning

    // MARK: - Init

    init(scanner: FileScanning = RealFileScanner()) {
        self.scanner = scanner
    }

    // MARK: - 公开 API

    /// 设置工作区根目录，执行浅扫描并重建索引。
    func setRoot(_ url: URL) async {
        let rootURL = url.standardizedFileURL
        entries = [:]
        children = [:]
        rootIDs = []
        expandedIDs = []

        guard let scanned = try? await scanner.shallowScan(directory: rootURL) else { return }

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
    }

    /// 展开目录：若尚未加载则触发浅扫描，将 ID 加入 expandedIDs。
    func expandDirectory(_ id: EntryID) async throws {
        guard let entry = entries[id], entry.isDirectory else { return }
        expandedIDs.insert(id)

        guard entry.loadState == .notLoaded else { return }

        // 标记 loading
        entries[id]?.loadState = .loading
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
    }

    /// 折叠目录：从 expandedIDs 移除，不卸载 children（保留缓存）。
    func collapseDirectory(_ id: EntryID) {
        expandedIDs.remove(id)
    }

    /// O(1) 查找条目。
    func entry(for id: EntryID) -> FileEntry? {
        entries[id]
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

            let isExpanded = entry.isDirectory && expandedIDs.contains(id)
            let visible = VisibleEntry(
                id: id,
                name: entry.name,
                isDirectory: entry.isDirectory,
                depth: depth,
                isExpanded: isExpanded,
                foldedAncestors: nil,    // Auto-fold 在 FT-R5 实现
                gitSummary: nil,          // Git badge 在 FT-R7 实现
                diagnosticSeverity: nil,  // Diag badge 在 FT-R14 实现
                isIgnored: false          // .gitignore 在 FT-R6 实现
            )
            result.append(visible)

            if isExpanded, let childIDs = children[id] {
                dfs(ids: childIDs, depth: depth + 1, result: &result, searchFilter: searchFilter)
            }
        }
    }

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
}

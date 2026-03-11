//
//  WorkspacePanelView.swift
//  agentGui
//

import SwiftUI
import SwiftData
import AppKit
import CoreServices

// MARK: - FileNode

/// 文件树中的一个节点（文件或目录）
struct FileNode: Identifiable, Hashable {
    let id: URL
    let name: String
    let isDirectory: Bool
    /// `nil` = 叶节点（文件）；非nil = 可展开的目录
    var children: [FileNode]?

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.id == rhs.id }
}

// MARK: - WorkspacePanelView

/// 左侧文件浏览器面板
struct WorkspacePanelView: View {

    // MARK: - Environment

    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(GitPanelViewModel.self) private var gitPanelViewModel
    @Environment(ClaudeService.self) private var claudeService
    @Environment(PersistenceCoordinator.self) private var persistenceCoordinator
    @Environment(\.modelContext) private var modelContext

    // MARK: - State

    @State private var rootNodes: [FileNode] = []
    @State private var currentDirectory: URL?
    @State private var isLoading = false
    @State private var directoryWatcher: DirectoryWatcher?
    @State private var updateTask: Task<Void, Never>?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            directoryBar
            GitPanelView()
            Divider()
                .opacity(0.4)
            if !todoItems.isEmpty {
                TodoListView(items: todoItems)
                Divider()
                    .opacity(0.4)
            }
            treeContent
        }
        .accessibilityIdentifier("panel.workspace")
        .onAppear { loadFromWorkspaceState() }
        .onChange(of: workspaceState.selectedSession?.persistentModelID) { _, _ in
            loadFromWorkspaceState()
        }
    }

    // MARK: - Todo Items

    private var todoItems: [TodoItem] {
        guard let session = workspaceState.selectedSession else { return [] }
        let store = SessionTaskStateStore(modelContext: modelContext, persistenceCoordinator: persistenceCoordinator)
        let persistedItems = store.todoItems(for: session.sessionId)
        if !persistedItems.isEmpty {
            return persistedItems
        }
        return claudeService.sessionTodoLists[session.sessionId] ?? []
    }

    // MARK: - Top directory bar

    private var directoryBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            Text(currentDirectory?.lastPathComponent ?? "无工作目录")
                .font(.caption)
                .foregroundStyle(currentDirectory == nil ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: chooseDirectory) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("选择工作目录")
            .accessibilityIdentifier("workspace.chooseDirectoryButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .accessibilityIdentifier("workspace.selector")
    }

    // MARK: - Tree

    @ViewBuilder
    private var treeContent: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rootNodes.isEmpty {
            emptyState
        } else {
            List(rootNodes, children: \.optionalChildren) { node in
                let gitChange = gitChangeMatch(for: node)
                FileRowView(
                    node: node,
                    isSelected: !node.isDirectory && workspaceState.selectedFile == node.id,
                    gitChange: gitChange,
                    onPreviewDiff: { change, staged in
                        Task { await gitPanelViewModel.selectDiff(for: change, staged: staged, workspaceState: workspaceState) }
                    },
                    onStage: { change in
                        Task { await gitPanelViewModel.stage(change) }
                    },
                    onUnstage: { change in
                        Task { await gitPanelViewModel.unstage(change) }
                    },
                    onDiscard: { change in
                        gitPanelViewModel.requestDiscard(change)
                    },
                    onDeleteUntracked: { change in
                        gitPanelViewModel.requestClean(change)
                    }
                ) {
                    if !node.isDirectory {
                        workspaceState.clearGitDiffSelection()
                        workspaceState.selectedFile = node.id
                    }
                }
                .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("workspace.fileTree")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("无工作目录")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("点击右上角选择目录")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "选择工作目录"
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDirectory(url)
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        settings.workingDirectory = url.path
        do {
            try persistenceCoordinator.save(
                modelContext,
                domain: .settings,
                userMessage: "工作目录未成功保存"
            )
        } catch {
            return
        }
    }

    private func setDirectory(_ url: URL) {
        currentDirectory = url
        loadDirectory(url)
        startWatching(url)
        Task { await gitPanelViewModel.refresh(for: url) }
    }

    private func loadFromWorkspaceState() {
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        let dir = workspaceState.effectiveWorkingDirectory(globalDefault: settings.workingDirectory)
        guard !dir.isEmpty else {
            rootNodes = []
            currentDirectory = nil
            return
        }
        let url = URL(fileURLWithPath: dir)
        if url != currentDirectory {
            setDirectory(url)
        }
    }

    private func startWatching(_ url: URL) {
        directoryWatcher?.stop()
        directoryWatcher = DirectoryWatcher(path: url.path) { paths in
            handleChanges(paths: paths, rootURL: url)
        }
    }

    /// 部分刷新：只重新扫描发生变更的目录，保留其余节点的结构与展开状态。
    private func handleChanges(paths: [String], rootURL: URL) {
        let rootStd = rootURL.standardizedFileURL
        let rootPath = rootStd.path

        // 推断需要重新扫描的目录集合
        var dirtyDirs = Set<URL>()
        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let parent = url.deletingLastPathComponent()
            // 文件的父目录 or 目录本身，都需要重新扫描
            if parent.path == rootPath || parent.path.hasPrefix(rootPath + "/") {
                dirtyDirs.insert(parent)
            }
            if url.path == rootPath || url.path.hasPrefix(rootPath + "/") {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if isDir { dirtyDirs.insert(url) }
            }
        }
        guard !dirtyDirs.isEmpty else { return }

        // 按路径深度排序（浅层优先，子目录更新会被父目录合并覆盖）
        let sortedDirs = dirtyDirs.sorted { $0.path.count < $1.path.count }
        let snapshot = rootNodes
        // Capture on main actor before entering detached task
        let openFile = workspaceState.selectedFile

        updateTask?.cancel()
        updateTask = Task.detached(priority: .userInitiated) {
            var updated = snapshot
            for dirURL in sortedDirs {
                if Task.isCancelled { return }
                if dirURL == rootStd {
                    let fresh = Self.shallowScan(at: rootURL)
                    updated = Self.mergeNodes(existing: updated, freshScan: fresh)
                } else {
                    updated = Self.applyPartialUpdate(to: updated, at: dirURL)
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.rootNodes = updated
                // Notify editor if the currently open file lives in a dirty directory
                if let openFile,
                   dirtyDirs.contains(openFile.deletingLastPathComponent()) {
                    self.workspaceState.externallyModifiedFile = openFile
                }
            }
        }
    }

    /// 只读取目录的直接子项（不递归）。
    nonisolated static func shallowScan(at url: URL) -> [(name: String, url: URL, isDirectory: Bool)] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.compactMap { itemURL -> (name: String, url: URL, isDirectory: Bool)? in
            guard let isDir = try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory
            else { return nil }
            return (name: itemURL.lastPathComponent, url: itemURL, isDirectory: isDir == true)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// 将现有节点列表与新的浅层扫描结果合并：
    /// - 仍存在的节点 → 保留原 FileNode（含已展开的子树）
    /// - 新出现的节点 → 新建（目录会递归扫描）
    /// - 已消失的节点 → 自动删除（不在 freshScan 中）
    nonisolated static func mergeNodes(
        existing: [FileNode],
        freshScan: [(name: String, url: URL, isDirectory: Bool)]
    ) -> [FileNode] {
        let existingMap = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        return freshScan.map { item in
            if let existing = existingMap[item.url] {
                return existing  // 保留原节点，展开状态不变
            }
            if item.isDirectory {
                let children = buildNodes(at: item.url, depth: 0)
                return FileNode(id: item.url, name: item.name, isDirectory: true, children: children)
            }
            return FileNode(id: item.url, name: item.name, isDirectory: false, children: nil)
        }
    }

    /// 递归定位 targetURL 所在的节点并重新扫描，其他节点保持不变。
    nonisolated static func applyPartialUpdate(to nodes: [FileNode], at targetURL: URL) -> [FileNode] {
        let targetPath = targetURL.path
        return nodes.map { node -> FileNode in
            guard node.isDirectory else { return node }
            let nodePath = node.id.path
            if nodePath == targetPath {
                let fresh = shallowScan(at: node.id)
                let merged = mergeNodes(existing: node.children ?? [], freshScan: fresh)
                return FileNode(id: node.id, name: node.name, isDirectory: true, children: merged)
            } else if targetPath.hasPrefix(nodePath + "/") {
                // 目标在此节点内部，递归向下
                let updated = applyPartialUpdate(to: node.children ?? [], at: targetURL)
                return FileNode(id: node.id, name: node.name, isDirectory: true, children: updated)
            }
            return node
        }
    }

    private func loadDirectory(_ url: URL) {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let nodes = Self.buildNodes(at: url, depth: 0)
            await MainActor.run {
                self.rootNodes = nodes
                self.isLoading = false
            }
        }
    }

    nonisolated static func buildNodes(at url: URL, depth: Int) -> [FileNode] {
        guard depth < 8 else { return [] }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return items.compactMap { itemURL -> FileNode? in
            guard let isDir = try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else {
                return nil
            }
            if isDir == true {
                let subNodes = buildNodes(at: itemURL, depth: depth + 1)
                return FileNode(id: itemURL, name: itemURL.lastPathComponent, isDirectory: true, children: subNodes)
            } else {
                return FileNode(id: itemURL, name: itemURL.lastPathComponent, isDirectory: false, children: nil)
            }
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func gitChangeMatch(for node: FileNode) -> GitFileChange? {
        guard !node.isDirectory, let snapshot = gitPanelViewModel.snapshot else { return nil }
        let relativePath = relativePath(for: node.id, root: snapshot.repositoryRoot)
        return (snapshot.stagedChanges + snapshot.unstagedChanges + snapshot.untrackedChanges)
            .first { $0.relativePath == relativePath }
    }

    private func relativePath(for fileURL: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return fileURL.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count + 1))
    }
}

// MARK: - FileNode helper

private extension FileNode {
    var optionalChildren: [FileNode]? {
        guard isDirectory else { return nil }
        return children
    }
}

// MARK: - FileRowView

private struct FileRowView: View {
    let node: FileNode
    let isSelected: Bool
    let gitChange: GitFileChange?
    let onPreviewDiff: (GitFileChange, Bool) -> Void
    let onStage: (GitFileChange) -> Void
    let onUnstage: (GitFileChange) -> Void
    let onDiscard: (GitFileChange) -> Void
    let onDeleteUntracked: (GitFileChange) -> Void
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: node.isDirectory ? "folder.fill" : fileIcon(for: node.name))
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
                .frame(width: 14)
            Text(node.name)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                .lineLimit(1)
            if let gitChange {
                Text(gitChange.statusBadge)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(backgroundFill)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovered in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovered
            }
        }
        .contextMenu {
            if let gitChange {
                Button("查看 Diff") {
                    onPreviewDiff(gitChange, gitChange.section == .staged)
                }
                switch gitChange.section {
                case .staged:
                    Button("取消暂存") { onUnstage(gitChange) }
                case .modified:
                    Button("暂存") { onStage(gitChange) }
                    Button("丢弃改动", role: .destructive) { onDiscard(gitChange) }
                case .untracked:
                    Button("暂存") { onStage(gitChange) }
                    Button("删除文件", role: .destructive) { onDeleteUntracked(gitChange) }
                }
            }
        }
    }

    private var backgroundFill: Color {
        if isSelected { return Color.accentColor.opacity(0.12) }
        if isHovered  { return Color.primary.opacity(0.07) }
        return .clear
    }

    private var iconColor: Color {
        if node.isDirectory {
            return isSelected ? .accentColor : Color(nsColor: .systemOrange).opacity(0.85)
        }
        return isSelected ? Color.accentColor.opacity(0.8) : .secondary
    }

    private func fileIcon(for name: String) -> String {
        FileIconSymbolResolver.symbol(forFileName: name)
    }
}

private extension GitFileChange {
    var statusBadge: String {
        switch status {
        case .added:
            return "A"
        case .modified:
            return "M"
        case .deleted:
            return "D"
        case .renamed:
            return "R"
        case .untracked:
            return "?"
        }
    }
}

// MARK: - DirectoryWatcher

/// 使用 FSEvents 递归监听目录内文件变更，回调携带发生变更的路径列表
private final class DirectoryWatcher: @unchecked Sendable {

    private var streamRef: FSEventStreamRef?

    init(path: String, onChange: @escaping ([String]) -> Void) {
        start(path: path, onChange: onChange)
    }

    deinit { stop() }

    private func start(path: String, onChange: @escaping ([String]) -> Void) {
        final class CallbackBox {
            let fn: ([String]) -> Void
            init(_ fn: @escaping ([String]) -> Void) { self.fn = fn }
        }

        let paths = [path] as CFArray
        let box = Unmanaged.passRetained(CallbackBox(onChange))
        var ctx = FSEventStreamContext(
            version: 0,
            info: box.toOpaque(),
            retain: nil,
            release: { ptr in Unmanaged<CallbackBox>.fromOpaque(ptr!).release() },
            copyDescription: nil
        )
        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagNoDefer) |
            UInt32(kFSEventStreamCreateFlagWatchRoot) |
            UInt32(kFSEventStreamCreateFlagUseCFTypes) // 以 CFArray 形式返回路径

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, eventPaths, _, _ in
                // kFSEventStreamCreateFlagUseCFTypes 保证 eventPaths 是 CFArray of CFString
                let nsArray = unsafeBitCast(eventPaths, to: NSArray.self)
                let changedPaths = nsArray as? [String] ?? []
                Unmanaged<CallbackBox>.fromOpaque(info!).takeUnretainedValue().fn(changedPaths)
            },
            &ctx,
            paths,
            FSEventStreamEventId.max, // kFSEventStreamEventIdSinceNow
            0.4,
            flags
        ) else {
            box.release()
            return
        }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        self.streamRef = stream
    }

    func stop() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.streamRef = nil
    }
}

// MARK: - Preview

#Preview {
    WorkspacePanelView()
        .environment(WorkspaceState())
        .frame(width: 220, height: 500)
}

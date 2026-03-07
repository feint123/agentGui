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
    @Environment(ClaudeService.self) private var claudeService
    @Environment(\.modelContext) private var modelContext

    // MARK: - State

    @State private var rootNodes: [FileNode] = []
    @State private var currentDirectory: URL?
    @State private var isLoading = false
    @State private var directoryWatcher: DirectoryWatcher?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            directoryBar
            Divider()
                .opacity(0.4)
            if !todoItems.isEmpty {
                TodoListView(items: todoItems)
                Divider()
                    .opacity(0.4)
            }
            treeContent
        }
        .onAppear { loadFromWorkspaceState() }
    }

    // MARK: - Todo Items

    private var todoItems: [TodoItem] {
        guard let session = workspaceState.selectedSession else { return [] }
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
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
                FileRowView(
                    node: node,
                    isSelected: !node.isDirectory && workspaceState.selectedFile == node.id
                ) {
                    if !node.isDirectory {
                        workspaceState.selectedFile = node.id
                    }
                }
                .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
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
        let settings = AppSettings.getOrCreate(in: modelContext)
        settings.workingDirectory = url.path
        try? modelContext.save()
    }

    private func setDirectory(_ url: URL) {
        currentDirectory = url
        loadDirectory(url)
        startWatching(url)
    }

    private func loadFromWorkspaceState() {
        let settings = AppSettings.getOrCreate(in: modelContext)
        let dir = settings.workingDirectory
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
        directoryWatcher = DirectoryWatcher(path: url.path) {
            loadDirectory(url)
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
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":              return "swift"
        case "md", "markdown":     return "doc.richtext"
        case "json":               return "curlybraces"
        case "py":                 return "chevron.left.forwardslash.chevron.right"
        case "js", "ts":           return "chevron.left.forwardslash.chevron.right"
        case "png", "jpg", "jpeg",
             "gif", "webp", "svg": return "photo"
        case "pdf":                return "doc.fill"
        case "sh", "zsh", "bash":  return "terminal"
        default:                   return "doc"
        }
    }
}

// MARK: - DirectoryWatcher

/// 使用 FSEvents 递归监听目录内文件变更
private final class DirectoryWatcher: @unchecked Sendable {

    private var streamRef: FSEventStreamRef?

    init(path: String, onChange: @escaping () -> Void) {
        start(path: path, onChange: onChange)
    }

    deinit { stop() }

    private func start(path: String, onChange: @escaping () -> Void) {
        final class CallbackBox {
            let fn: () -> Void
            init(_ fn: @escaping () -> Void) { self.fn = fn }
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
            UInt32(kFSEventStreamCreateFlagNoDefer) | UInt32(kFSEventStreamCreateFlagWatchRoot)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                Unmanaged<CallbackBox>.fromOpaque(info!).takeUnretainedValue().fn()
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

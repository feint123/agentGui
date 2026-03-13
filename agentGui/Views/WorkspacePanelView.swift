//
//  WorkspacePanelView.swift
//  agentGui
//

import SwiftUI
import SwiftData
import AppKit

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
    @Environment(GitPanelViewModel.self) private var gitPanelViewModel
    @Environment(PersistenceCoordinator.self) private var persistenceCoordinator
    @Environment(\.modelContext) private var modelContext

    // MARK: - State

    @State private var rootNodes: [FileNode] = []
    @State private var currentDirectory: URL?
    @State private var isLoading = false
    @State private var refreshCoordinator = WorkspaceTreeRefreshCoordinator()
    @State private var showsLSPDiagnosticsPopover = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            directoryBar
            GitPanelView()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            Divider()
                .opacity(0.4)
            treeContent
                .frame(maxHeight: .infinity, alignment: .top)
            Divider()
                .opacity(0.4)
            lspStatusFooter
        }
        .accessibilityIdentifier("panel.workspace")
        .onAppear {
            configureRefreshCoordinator()
            loadFromWorkspaceState()
            triggerWorkspaceLSPBootstrap()
        }
        .onDisappear {
            refreshCoordinator.setDirectory(nil)
        }
        .onChange(of: workspaceState.selectedSession?.persistentModelID) { _, _ in
            loadFromWorkspaceState()
            triggerWorkspaceLSPBootstrap()
        }
        .onChange(of: workspaceState.selectedFile) { _, _ in
            triggerWorkspaceLSPBootstrap()
        }
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
                    isSelected: !node.isDirectory && (workspaceState.selectedFile == node.id || workspaceState.selectedGitDiffPath == node.id),
                    gitChange: gitChange,
                    onPreviewDiff: { change, staged in
                        Task { await gitPanelViewModel.selectDiff(for: change, staged: staged, workspaceState: workspaceState) }
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

    private var lspStatusFooter: some View {
        let _ = claudeService.lspPresentationRevision
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        let status = claudeService.makeWorkspacePanelLSPStatus(
            workingDirectory: currentDirectory?.path ?? "",
            selectedFilePath: workspaceState.selectedFile?.standardizedFileURL.path,
            settings: settings
        )

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("LSP")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(status.stateText)
                    .font(.caption)
                    .foregroundStyle(lspStateColor(status.stateText))
                    .lineLimit(1)
            }

            if let fileName = status.selectedFileName {
                Text(fileName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                Label(status.serverID ?? "未绑定", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button {
                    showsLSPDiagnosticsPopover.toggle()
                } label: {
                    lspCountChip(title: "错误", count: status.errorCount, color: .red)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsLSPDiagnosticsPopover, arrowEdge: .bottom) {
                    LSPDiagnosticsPopoverView(status: status)
                }

                Button {
                    showsLSPDiagnosticsPopover.toggle()
                } label: {
                    lspCountChip(title: "警告", count: status.warningCount, color: .orange)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityIdentifier("workspace.lspStatusFooter")
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
        currentDirectory = url.standardizedFileURL
        refreshCoordinator.setDirectory(currentDirectory)
        Task { await gitPanelViewModel.refresh(for: url, workspaceState: workspaceState) }
    }

    private func triggerWorkspaceLSPBootstrap() {
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        let workingDirectory = currentDirectory?.path ?? workspaceState.effectiveWorkingDirectory(globalDefault: settings.workingDirectory)
        let selectedFilePath = workspaceState.selectedFile?.standardizedFileURL.path
        Task {
            _ = try? await claudeService.ensureWorkspaceLSPState(
                workingDirectory: workingDirectory,
                selectedFilePath: selectedFilePath,
                settings: settings
            )
        }
    }

    private func loadFromWorkspaceState() {
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        let dir = workspaceState.effectiveWorkingDirectory(globalDefault: settings.workingDirectory)
        guard !dir.isEmpty else {
            rootNodes = []
            currentDirectory = nil
            refreshCoordinator.setDirectory(nil)
            return
        }
        let url = URL(fileURLWithPath: dir).standardizedFileURL
        if url != currentDirectory {
            setDirectory(url)
        }
    }

    private func configureRefreshCoordinator() {
        refreshCoordinator.onNodesChanged = { nodes, loading in
            self.rootNodes = nodes
            self.isLoading = loading
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

    private func lspStateColor(_ stateText: String) -> Color {
        let normalized = stateText.lowercased()
        if normalized.contains("running") {
            return .green
        }
        if normalized.contains("failed") || normalized.contains("crashed") || normalized.contains("无匹配") {
            return .red
        }
        if normalized.contains("禁用") || normalized.contains("未启动") || normalized.contains("选择文件") {
            return .secondary
        }
        return .secondary
    }

    private func lspCountChip(title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(title) \(count)")
                .font(.caption2)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.10), in: Capsule())
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
                    .foregroundStyle(statusColor(for: gitChange.status))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(statusColor(for: gitChange.status).opacity(isSelected || isHovered ? 0.16 : 0.08), in: Capsule())
                    .opacity(isSelected || isHovered ? 1 : 0.72)
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
        .accessibilityIdentifier(node.isDirectory ? "workspace.directory.\(node.name)" : "workspace.file.\(node.name)")
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
            }
        }
    }

    private var backgroundFill: Color {
        if isSelected { return Color.accentColor.opacity(0.14) }
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

    private func statusColor(for status: GitChangeStatus) -> Color {
        switch status {
        case .added, .untracked:
            return .green
        case .deleted:
            return .red
        case .renamed:
            return .orange
        case .modified:
            return .secondary
        }
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

// MARK: - Preview

#Preview {
    WorkspacePanelView()
        .environment(WorkspaceState())
        .frame(width: 220, height: 500)
}

// agentGui/Views/FileTree/FileTreeContainerView.swift
import SwiftUI

/// 文件树 SwiftUI 容器视图。
/// 组合：[FileTreeTableView] + [状态栏]
///
/// 外部通过 `directory` 绑定根目录，`onOpenFile` 处理打开事件。
struct FileTreeContainerView: View {

    // MARK: - 外部输入

    var directory: URL?
    var onOpenFile: (EntryID) -> Void = { _ in }
    /// 单击选中文件时回调，外部可同步到 workspaceState.selectedFile。
    var onPrimarySelectionChange: (URL?) -> Void = { _ in }

    // MARK: - 内部状态

    @State private var viewModel: FileTreeViewModel

    // MARK: - 初始化

    init(directory: URL? = nil,
         store: FileTreeStore = FileTreeStore(),
         onOpenFile: @escaping (EntryID) -> Void = { _ in },
         onPrimarySelectionChange: @escaping (URL?) -> Void = { _ in }) {
        self.directory = directory
        self.onOpenFile = onOpenFile
        self.onPrimarySelectionChange = onPrimarySelectionChange
        _viewModel = State(initialValue: FileTreeViewModel(store: store))
    }

    // MARK: - 视图

    var body: some View {
        VStack(spacing: 0) {
            // 主文件树
            FileTreeTableView(
                entries: viewModel.visibleEntries,
                selection: viewModel.selection,
                onSelect: { id, modifier in
                    viewModel.selectEntry(id, modifier: modifier)
                },
                onToggleExpand: { id in
                    Task { await viewModel.toggleDirectory(id) }
                },
                onDoubleClick: { id in
                    onOpenFile(id)
                },
                inlineEditSession: viewModel.inlineEdit,
                onCommitEdit: { draft in
                    Task {
                        viewModel.inlineEdit?.draftName = draft
                        await viewModel.commitEdit()
                    }
                },
                onCancelEdit: {
                    viewModel.cancelEdit()
                },
                onNewFile: {
                    Task {
                        await viewModel.beginCreate(.createFile, near: viewModel.selection.primary)
                    }
                },
                onNewFolder: {
                    Task {
                        await viewModel.beginCreate(.createFolder,
                                                    near: viewModel.selection.primary)
                    }
                },
                onRenameSelected: {
                    guard let primary = viewModel.selection.primary else { return }
                    Task { await viewModel.beginRename(primary) }
                },
                onRevealInFinder: { ids in
                    viewModel.revealInFinder(ids: ids)
                },
                onCopyPath: { ids in
                    viewModel.copyRelativePath(ids: ids)
                },
                onConfirmDelete: { ids in
                    viewModel.beginDelete(ids: ids)
                },
                onPreviewDiff: { id in
                    // TODO: 接入 Git Diff 预览视图（FT-R17 或现有 PreviewDiffService）
                    NSLog("[FT-R16] previewDiff not yet connected: \(id.url.lastPathComponent)")
                },
                rootURL: viewModel.rootDirectory
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 状态栏（条目数）
            if !viewModel.visibleEntries.isEmpty {
                Divider()
                HStack {
                    Text("\(viewModel.visibleEntries.count) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
        }
        .task(id: directory?.path) {
            await viewModel.setDirectory(directory)
        }
        .onChange(of: viewModel.selection.primary) { _, newPrimary in
            onPrimarySelectionChange(newPrimary?.url)
        }
    }
}

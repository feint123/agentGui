import SwiftUI

struct WorkspaceTreeRowContent: View {
    let node: FileNode
    let isSelected: Bool
    let gitChange: GitFileChange?
    let inlineEdit: WorkspaceTreeInlineEdit?
    let onInlineEditChange: (String) -> Void
    let onInlineEditCommit: () -> Void
    let onInlineEditCancel: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: node.isDirectory ? "folder.fill" : fileIcon(for: node.name))
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
                .frame(width: 14)

            if isInlineEditing {
                InlineNameField(
                    text: Binding(
                        get: { inlineEdit?.draftName ?? node.name },
                        set: onInlineEditChange
                    ),
                    placeholder: "输入名称",
                    onCommit: onInlineEditCommit,
                    onCancel: onInlineEditCancel
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if node.isFolded {
                // FT-U1：折叠路径分段渲染 — "src / main / java"
                foldedLabel
            } else {
                Text(node.name)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    .lineLimit(1)
            }

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
        .onHover { hovered in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovered
            }
        }
        .accessibilityIdentifier(node.isDirectory ? "workspace.directory.\(node.name)" : "workspace.file.\(node.name)")
    }

    private var backgroundFill: Color {
        if isSelected { return Color.accentColor.opacity(0.14) }
        if isHovered { return Color.primary.opacity(0.07) }
        return .clear
    }

    private var iconColor: Color {
        if node.isDirectory {
            return isSelected ? .accentColor : Color(nsColor: .systemOrange).opacity(0.85)
        }
        return isSelected ? Color.accentColor.opacity(0.8) : .secondary
    }

    private var isInlineEditing: Bool {
        inlineEdit?.editingNodeID == node.id
    }

    private func fileIcon(for name: String) -> String {
        FileIconSymbolResolver.symbol(forFileName: name)
    }

    // MARK: - Auto-fold rendering (FT-U1)

    /// 折叠链分段标签："src / main / java"，"/"呈灰色，其余段与普通目录样式一致。
    @ViewBuilder
    private var foldedLabel: some View {
        HStack(spacing: 0) {
            ForEach(Array(node.foldedSegments.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Text(" / ")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)   // 灰色分隔符
                }
                Text(segment)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
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
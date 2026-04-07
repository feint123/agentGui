import SwiftUI

/// 统一面包屑栏：文件路径节点 + LSP symbol 路径节点在同一横向滚动行内渲染。
///
/// 布局：[icon?] [file₀ › file₁ › … › fileN] [› sym₀ › sym₁ › …] [TrailingContent]
///
/// - 文件节点：不可点击的当前文件高亮；祖先节点调用 `onSelectFile`。
/// - 符号节点：siblings > 1 时渲染 Menu 下拉；否则渲染 Button 直接导航。
/// - `symbolPath` 为空时不渲染任何符号节点，也不渲染过渡分隔符。
struct UnifiedEditorBreadcrumbBar<TrailingContent: View>: View {
    let iconSystemName: String?
    let fileItems: [BreadcrumbNavigationItem]
    let symbolPath: [CodeEditorSymbolPathNode]
    let onSelectFile: ((BreadcrumbNavigationItem) -> Void)?
    let onNavigateSymbol: ((CodeEditorRevealRequest) -> Void)?
    @ViewBuilder private let trailingContent: TrailingContent

    init(
        iconSystemName: String? = nil,
        fileItems: [BreadcrumbNavigationItem],
        symbolPath: [CodeEditorSymbolPathNode] = [],
        onSelectFile: ((BreadcrumbNavigationItem) -> Void)? = nil,
        onNavigateSymbol: ((CodeEditorRevealRequest) -> Void)? = nil,
        @ViewBuilder trailingContent: () -> TrailingContent = { EmptyView() }
    ) {
        self.iconSystemName = iconSystemName
        self.fileItems = fileItems
        self.symbolPath = symbolPath
        self.onSelectFile = onSelectFile
        self.onNavigateSymbol = onNavigateSymbol
        self.trailingContent = trailingContent()
    }

    var body: some View {
        HStack(spacing: 6) {
            if let iconSystemName {
                Image(systemName: iconSystemName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    // ── 文件路径节点 ──
                    ForEach(Array(fileItems.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            chevron
                        }
                        fileNodeView(for: item)
                    }

                    // ── 过渡分隔 + 符号节点 ──
                    if !symbolPath.isEmpty {
                        chevron
                        ForEach(Array(symbolPath.enumerated()), id: \.element.id) { index, node in
                            if index > 0 {
                                chevron
                            }
                            symbolNodeView(node)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingContent
        }
    }

    // MARK: - Private

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func fileNodeView(for item: BreadcrumbNavigationItem) -> some View {
        if let onSelectFile, !item.isCurrent {
            Button {
                onSelectFile(item)
            } label: {
                fileLabel(for: item)
            }
            .buttonStyle(.plain)
            .help(item.url?.path ?? item.title)
        } else {
            fileLabel(for: item)
                .help(item.url?.path ?? item.title)
        }
    }

    private func fileLabel(for item: BreadcrumbNavigationItem) -> some View {
        Text(item.title)
            .font(item.isCurrent ? .caption.weight(.medium) : .caption)
            .foregroundStyle(item.isCurrent ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func symbolNodeView(_ node: CodeEditorSymbolPathNode) -> some View {
        if node.siblings.count > 1 {
            Menu {
                ForEach(node.siblings) { sibling in
                    Button {
                        onNavigateSymbol?(sibling.revealRequest)
                    } label: {
                        Label(sibling.name, systemImage: symbolIconName(for: sibling.symbolKind))
                    }
                }
            } label: {
                symbolLabel(name: node.name, kind: node.symbolKind)
            }
            .menuStyle(.borderlessButton)
        } else {
            Button {
                onNavigateSymbol?(node.revealRequest)
            } label: {
                symbolLabel(name: node.name, kind: node.symbolKind)
            }
            .buttonStyle(.plain)
        }
    }

    private func symbolLabel(name: String, kind: Int) -> some View {
        HStack(spacing: 3) {
            if let icon = CodeEditorViewModel.symbolKindIconName(for: kind) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func symbolIconName(for kind: Int) -> String {
        CodeEditorViewModel.symbolKindIconName(for: kind) ?? "square.dashed"
    }
}

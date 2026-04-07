import SwiftUI

/// 符号路径面包屑栏，展示当前光标所在的 LSP symbol 层级。
/// 每个节点可点击弹出同级 sibling 下拉菜单（SwiftUI Menu），选中后通过
/// onNavigate 回调发出 CodeEditorRevealRequest。
///
/// 当 path 为空时，视图高度保持不变但展示占位文字「(符号)」。
struct CodeEditorSymbolBreadcrumbBar: View {
    let path: [CodeEditorSymbolPathNode]
    var onNavigate: ((CodeEditorRevealRequest) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                if path.isEmpty {
                    Text("(符号)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(Array(path.enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        symbolNodeView(node)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func symbolNodeView(_ node: CodeEditorSymbolPathNode) -> some View {
        if node.siblings.count > 1 {
            // 有同级 sibling → 用 Menu 展示下拉
            Menu {
                ForEach(node.siblings) { sibling in
                    Button {
                        onNavigate?(sibling.revealRequest)
                    } label: {
                        Label(sibling.name, systemImage: iconName(for: sibling.symbolKind))
                    }
                }
            } label: {
                symbolLabel(name: node.name, kind: node.symbolKind, isCurrent: true)
            }
            .menuStyle(.borderlessButton)
        } else {
            // 唯一节点（顶层孤立 symbol）直接可点击
            Button {
                onNavigate?(node.revealRequest)
            } label: {
                symbolLabel(name: node.name, kind: node.symbolKind, isCurrent: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func symbolLabel(name: String, kind: Int, isCurrent: Bool) -> some View {
        HStack(spacing: 3) {
            if let icon = CodeEditorViewModel.symbolKindIconName(for: kind) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(name)
                .font(isCurrent ? .caption.weight(.medium) : .caption)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 3)
    }

    private func iconName(for kind: Int) -> String {
        CodeEditorViewModel.symbolKindIconName(for: kind) ?? "square.dashed"
    }
}

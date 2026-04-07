import SwiftUI

/// ⌘⇧O 触发的「转到符号」快速跳转面板。
/// 展示当前文件所有扁平化 symbols，支持模糊过滤，Enter 跳转，Esc 关闭。
struct CodeEditorSymbolOutlineView: View {
    let symbols: [CodeEditorDocumentSymbolItem]
    var onNavigate: ((CodeEditorRevealRequest) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 搜索输入框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.body)
                TextField("转到符号...", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onKeyPress(.escape) {
                        onDismiss?()
                        return .handled
                    }
                    .onKeyPress(.return) {
                        commitSelection()
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1)
                        return .handled
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // 符号列表
            if filteredSymbols.isEmpty {
                Text("无匹配符号")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredSymbols.enumerated()), id: \.element.id) { index, item in
                                symbolRow(item, index: index)
                                    .id(index)
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, newIndex in
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 420)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 10))
        .shadow(radius: 12)
        .onAppear {
            isSearchFocused = true
            selectedIndex = 0
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
    }

    private var filteredSymbols: [CodeEditorDocumentSymbolItem] {
        guard !query.isEmpty else { return symbols }
        return symbols.filter {
            $0.title.localizedStandardContains(query)
        }
    }

    private func symbolRow(_ item: CodeEditorDocumentSymbolItem, index: Int) -> some View {
        Button {
            selectedIndex = index
            commitSelection()
        } label: {
            HStack(spacing: 8) {
                Text(item.title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(index == selectedIndex ? Color.accentColor.opacity(0.15) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func commitSelection() {
        guard !filteredSymbols.isEmpty, filteredSymbols.indices.contains(selectedIndex) else { return }
        onNavigate?(filteredSymbols[selectedIndex].revealRequest)
        onDismiss?()
    }

    private func moveSelection(by delta: Int) {
        let count = filteredSymbols.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }
}

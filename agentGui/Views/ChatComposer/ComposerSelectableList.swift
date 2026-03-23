import SwiftUI

struct ComposerSelectableList<Data, RowContent: View>: View {
    let items: [Data]
    let highlightedIndex: Int?
    let maximumHeight: CGFloat?
    let autoScrollToHighlightedItem: Bool
    let onSelect: (Data) -> Void
    let rowContent: (Data, Bool) -> RowContent

    init(
        items: [Data],
        highlightedIndex: Int?,
        maximumHeight: CGFloat? = nil,
        autoScrollToHighlightedItem: Bool = false,
        onSelect: @escaping (Data) -> Void,
        @ViewBuilder rowContent: @escaping (Data, Bool) -> RowContent
    ) {
        self.items = items
        self.highlightedIndex = highlightedIndex
        self.maximumHeight = maximumHeight
        self.autoScrollToHighlightedItem = autoScrollToHighlightedItem
        self.onSelect = onSelect
        self.rowContent = rowContent
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        Button {
                            onSelect(item)
                        } label: {
                            rowContent(item, highlightedIndex == index)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
            }
            .frame(maxHeight: maximumHeight)
            .onAppear {
                scrollToHighlightedItem(using: proxy)
            }
            .onChange(of: highlightedIndex) {
                scrollToHighlightedItem(using: proxy)
            }
        }
    }

    private func scrollToHighlightedItem(using proxy: ScrollViewProxy) {
        guard autoScrollToHighlightedItem,
              let highlightedIndex else {
            return
        }

        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(highlightedIndex, anchor: .center)
        }
    }
}
import SwiftUI

struct ComposerSelectableList<Data, RowContent: View>: View {
    let items: [Data]
    let highlightedIndex: Int?
    let onSelect: (Data) -> Void
    let rowContent: (Data, Bool) -> RowContent

    init(
        items: [Data],
        highlightedIndex: Int?,
        onSelect: @escaping (Data) -> Void,
        @ViewBuilder rowContent: @escaping (Data, Bool) -> RowContent
    ) {
        self.items = items
        self.highlightedIndex = highlightedIndex
        self.onSelect = onSelect
        self.rowContent = rowContent
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Button {
                    onSelect(item)
                } label: {
                    rowContent(item, highlightedIndex == index)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
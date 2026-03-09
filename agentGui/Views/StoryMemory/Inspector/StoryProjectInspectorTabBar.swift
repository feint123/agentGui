import SwiftUI

struct StoryProjectInspectorTabBar: View {
    let items: [StoryProjectInspectorTabItem]
    let selectedTab: StoryProjectInspectorTab
    let onSelect: (StoryProjectInspectorTab) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(items) { item in
                    Button {
                        onSelect(item.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.systemImage)
                            Text(item.title)
                            if let count = item.count {
                                Text("\(count)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(item.id == selectedTab ? .primary : .secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.thinMaterial, in: Capsule())
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(item.id == selectedTab ? .primary : .secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            Group {
                                if item.id == selectedTab {
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(.regularMaterial)
                                } else {
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(.ultraThinMaterial)
                                }
                            }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
import SwiftUI

struct StoryProjectInspectorJumpTarget: Equatable {
    let tab: StoryProjectInspectorTab
    let anchorID: String?

    init(tab: StoryProjectInspectorTab, anchorID: String? = nil) {
        self.tab = tab
        self.anchorID = anchorID
    }
}

struct StoryProjectInspectorSection<Content: View>: View {
    let title: String
    let count: Int?
    let trailing: AnyView?
    let content: Content

    init(
        _ title: String,
        count: Int? = nil,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.count = count
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                if let count {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer(minLength: 0)
                trailing
            }
            content
        }
    }
}

struct StoryProjectInspectorCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct StoryProjectInspectorEmptyState: View {
    let title: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct StoryProjectInspectorChipButton: View {
    let title: String
    let action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(title, action: action)
                    .buttonStyle(.plain)
            } else {
                Text(title)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
    }
}

struct StoryProjectInspectorChipCloud: View {
    let values: [String]
    let actionForValue: ((String) -> Void)?

    init(_ values: [String], actionForValue: ((String) -> Void)? = nil) {
        self.values = values
        self.actionForValue = actionForValue
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 10) {
            ForEach(values, id: \.self) { value in
                StoryProjectInspectorChipButton(title: value, action: actionForValue.map { handler in { handler(value) } })
            }
        }
    }
}

struct StoryProjectInspectorDetailGrid: View {
    let items: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index.isMultiple(of: 2) {
                    GridRow {
                        detailPair(title: item.0, value: item.1)
                        if index + 1 < items.count {
                            detailPair(title: items[index + 1].0, value: items[index + 1].1)
                        } else {
                            Color.clear
                        }
                    }
                }
            }
        }
    }

    private func detailPair(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
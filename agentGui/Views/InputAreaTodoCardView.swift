import SwiftUI

struct InputAreaTodoCardView: View {
    let presentation: ChatComposerTodoCardPresentation
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Label(presentation.title, systemImage: "checklist")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("chat.todoCard.header")
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.todoCard.toggle")
                Spacer(minLength: 0)
                Text(presentation.progressText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat.todoCard.progress")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if isExpanded, !presentation.visibleItems.isEmpty {
                Divider()
                    .opacity(0.08)

                TodoListView(
                    items: presentation.visibleItems,
                    maxHeight: presentation.maxListHeight,
                    showsScrollIndicators: presentation.showsScrollContainer
                )
                .accessibilityIdentifier("chat.todoCard.scrollArea")
                .padding(.vertical, 4)
            } else if !isExpanded {
                Text("已折叠，点击展开任务列表")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("chat.todoCard.collapsedHint")
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 8, y: -2)
        .accessibilityIdentifier("chat.todoCard")
    }
}
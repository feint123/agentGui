import SwiftUI

struct InputAreaTodoCardView: View {
    let presentation: ChatComposerTodoCardPresentation
    let showsContainerChrome: Bool
    @State private var isExpanded = true

    init(presentation: ChatComposerTodoCardPresentation, showsContainerChrome: Bool = true) {
        self.presentation = presentation
        self.showsContainerChrome = showsContainerChrome
    }

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
        .modifier(TodoCardContainerChromeModifier(isEnabled: showsContainerChrome))
        .accessibilityIdentifier("chat.todoCard")
    }
}

private struct TodoCardContainerChromeModifier: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        } else {
            content
        }
    }
}

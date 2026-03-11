import SwiftUI

struct InputAreaTodoCardView: View {
    let presentation: ChatComposerTodoCardPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label(presentation.title, systemImage: "checklist")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("chat.todoCard.header")
                Spacer(minLength: 0)
                Text(presentation.progressText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat.todoCard.progress")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if !presentation.visibleItems.isEmpty {
                Divider()
                    .opacity(0.08)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(presentation.visibleItems) { item in
                        TodoRowContentView(item: item)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }

                    if presentation.hiddenCount > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                            Text("还有 \(presentation.hiddenCount) 项")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                    }
                }
                .padding(.vertical, 4)
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
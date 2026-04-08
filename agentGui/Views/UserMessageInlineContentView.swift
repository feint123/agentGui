import SwiftUI

struct UserMessageInlineContentView: View {
    let presentation: UserMessagePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !presentation.directiveChips.isEmpty {
                ChatFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(presentation.directiveChips) { chip in
                        directiveChipView(chip)
                    }
                }
            }

            ChatFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(presentation.inlineItems) { item in
                    inlineItemView(item)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func inlineItemView(_ item: InlineItem) -> some View {
        switch item {
        case .text(let run):
            Text(run.text)
                .font(.body)
                .foregroundStyle(.primary)
        case .mention(let token):
            mentionTokenView(token)
        }
    }

    private func directiveChipView(_ chip: DirectiveChipPresentation) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "command")
                .font(.caption2)
            Text(chip.title)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(Capsule())
        .help(chip.helpText)
    }

    private func mentionTokenView(_ token: MentionTokenPresentation) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: token.iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor.opacity(0.9))

            Text(token.title)
                .font(.body)
                .foregroundStyle(.primary.opacity(0.72))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.16), lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: false)
        .help(token.fullPath)
    }
}
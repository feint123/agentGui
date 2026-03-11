import SwiftUI

struct UserMessageInlineContentView: View {
    let presentation: UserMessagePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !presentation.directiveChips.isEmpty {
                UserMessageWrapLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(presentation.directiveChips) { chip in
                        directiveChipView(chip)
                    }
                }
            }

            UserMessageWrapLayout(spacing: 6, lineSpacing: 6) {
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

private struct UserMessageWrapLayout<Content: View>: View {
    let spacing: CGFloat
    let lineSpacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        UserMessageWrappingLayout(spacing: spacing, lineSpacing: lineSpacing) {
            content
        }
    }
}

private struct UserMessageWrappingLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    struct Cache {
        var rows: [Row] = []
        var size: CGSize = .zero
    }

    struct Row {
        var elements: [Element]
        var width: CGFloat
        var height: CGFloat
    }

    struct Element {
        let index: Int
        let size: CGSize
        let x: CGFloat
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        cache = makeRows(proposal: proposal, subviews: subviews)
        return cache.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        if cache.rows.isEmpty {
            cache = makeRows(proposal: proposal, subviews: subviews)
        }

        var y = bounds.minY
        for row in cache.rows {
            for element in row.elements {
                subviews[element.index].place(
                    at: CGPoint(x: bounds.minX + element.x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: element.size.width, height: element.size.height)
                )
            }
            y += row.height + lineSpacing
        }
    }

    private func makeRows(proposal: ProposedViewSize, subviews: Subviews) -> Cache {
        let maxWidth = max(proposal.width ?? 0, 1)
        var rows: [Row] = []
        var currentElements: [Element] = []
        var currentWidth: CGFloat = 0
        var currentRowWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: proposal.height))
            let proposedX = currentElements.isEmpty ? 0 : currentWidth + spacing

            if !currentElements.isEmpty && proposedX + size.width > maxWidth {
                rows.append(Row(elements: currentElements, width: currentRowWidth, height: currentHeight))
                currentElements = []
                currentWidth = 0
                currentRowWidth = 0
                currentHeight = 0
            }

            let x = currentElements.isEmpty ? 0 : currentWidth + spacing
            currentElements.append(Element(index: index, size: size, x: x))
            currentWidth = x + size.width
            currentRowWidth = max(currentRowWidth, currentWidth)
            currentHeight = max(currentHeight, size.height)
        }

        if !currentElements.isEmpty {
            rows.append(Row(elements: currentElements, width: currentRowWidth, height: currentHeight))
        }

        let totalHeight = rows.enumerated().reduce(CGFloat(0)) { partial, entry in
            let isLast = entry.offset == rows.count - 1
            return partial + entry.element.height + (isLast ? 0 : lineSpacing)
        }
        let totalWidth = rows.map(\ .width).max() ?? 0

        return Cache(rows: rows, size: CGSize(width: totalWidth, height: totalHeight))
    }
}
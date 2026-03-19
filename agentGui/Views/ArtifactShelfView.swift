import SwiftUI

struct ArtifactShelfView: View {
    let presentation: ArtifactShelfPresentation

    var body: some View {
        if presentation.hasContent {
            VStack(alignment: .leading, spacing: 10) {
                artifactChipSection(
                    title: "变更文件",
                    iconName: "square.and.pencil",
                    items: presentation.changedFiles,
                    tint: .orange
                )

                artifactChipSection(
                    title: "参考文件",
                    iconName: "doc.text.magnifyingglass",
                    items: presentation.referencedFiles,
                    tint: .blue
                )

                artifactChipSection(
                    title: "引用",
                    iconName: "quote.opening",
                    items: presentation.citations,
                    tint: .secondary
                )

                artifactSummarySection(
                    title: "命令摘要",
                    iconName: "terminal",
                    items: presentation.commandSummaries,
                    tint: .green
                )

                artifactSummarySection(
                    title: "验证摘要",
                    iconName: "checkmark.seal",
                    items: presentation.testSummaries,
                    tint: .mint
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [Color.primary.opacity(0.035), Color.primary.opacity(0.018)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
            .accessibilityIdentifier("chat.agentMessage.artifactShelf")
        }
    }

    @ViewBuilder
    private func artifactChipSection(
        title: String,
        iconName: String,
        items: [ArtifactChipPresentation],
        tint: Color
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader(title: title, iconName: iconName, tint: tint)
                ArtifactShelfWrapLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(items) { item in
                        artifactChip(item, tint: tint)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func artifactSummarySection(
        title: String,
        iconName: String,
        items: [ArtifactSummaryLine],
        tint: Color
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader(title: title, iconName: iconName, tint: tint)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        Text(item.text)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func sectionHeader(title: String, iconName: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func artifactChip(_ item: ArtifactChipPresentation, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "doc")
                .font(.caption2)
            Text(item.displayName)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
        .help(item.path)
    }
}

private struct ArtifactShelfWrapLayout<Content: View>: View {
    let spacing: CGFloat
    let lineSpacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ArtifactShelfWrappingLayout(spacing: spacing, lineSpacing: lineSpacing) {
            content
        }
    }
}

private struct ArtifactShelfWrappingLayout: Layout {
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
        let totalWidth = rows.map(\.width).max() ?? 0

        return Cache(rows: rows, size: CGSize(width: totalWidth, height: totalHeight))
    }
}
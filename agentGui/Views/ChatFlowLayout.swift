//  ChatFlowLayout.swift
//  agentGui
//
//  换行 FlowLayout，ChatView 体系共享。

import SwiftUI

/// 水平排列子视图，超出宽度时自动换行，类似 CSS flexbox wrap。
struct ChatFlowLayout<Content: View>: View {
    let spacing: CGFloat
    let lineSpacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat = 6, lineSpacing: CGFloat = 6, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.content = content()
    }

    var body: some View {
        _ChatWrappingLayout(spacing: spacing, lineSpacing: lineSpacing) {
            content
        }
    }
}

struct _ChatWrappingLayout: Layout {
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

    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        cache = makeRows(proposal: proposal, subviews: subviews)
        return cache.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        if cache.rows.isEmpty { cache = makeRows(proposal: proposal, subviews: subviews) }
        var y = bounds.minY
        for row in cache.rows {
            for element in row.elements {
                let x = bounds.minX + element.x
                subviews[element.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(element.size)
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

//
//  MarkdownMessageView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import AppKit

// MARK: - Markdown Message View

struct MarkdownMessageView: View {
    let text: String

    @SwiftUI.State private var parser = MarkdownMessageIncrementalParser()
    @SwiftUI.State private var snapshot = MarkdownIncrementalSnapshot(sourceText: "", blocks: [])

    init(text: String) {
        self.text = text
        let parser = MarkdownMessageIncrementalParser()
        _parser = SwiftUI.State(initialValue: parser)
        _snapshot = SwiftUI.State(initialValue: Self.initialSnapshot(for: text))
    }

    @MainActor
    static func initialSnapshot(for text: String) -> MarkdownIncrementalSnapshot {
        guard !text.isEmpty else {
            return MarkdownIncrementalSnapshot(sourceText: "", blocks: [])
        }
        let parser = MarkdownMessageIncrementalParser()
        return parser.reconcile(oldText: "", newText: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(snapshot.blocks.enumerated()), id: \.element.id) { index, block in
                blockView(block, index: index)
            }
        }
        .onChange(of: text) { oldValue, newValue in
            snapshot = parser.reconcile(
                oldText: oldValue,
                newText: newValue,
                previous: snapshot.sourceText == oldValue ? snapshot : nil
            )
        }
        .onAppear {
            guard snapshot.sourceText != text else { return }
            snapshot = parser.reconcile(oldText: snapshot.sourceText, newText: text, previous: snapshot)
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownMessageRenderBlock, index: Int) -> some View {
        switch block.kind {
        case .paragraph:
            inlineText(block.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level):
            inlineText(block.text)
                .font(headingFont(level))
                .bold()
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 6 : 2)
                .padding(.bottom, 2)

        case .quote:
            QuoteBlockView(text: block.text)

        case .bulletedList:
            ListItemBlockView(marker: "•", text: block.text, indentLevel: block.indentLevel)

        case .numberedList:
            ListItemBlockView(marker: numberedMarker(for: index), text: block.text, indentLevel: block.indentLevel)

        case .todo:
            TodoBlockView(text: block.text, isChecked: block.isChecked, indentLevel: block.indentLevel)

        case .divider:
            Divider()
                .padding(.vertical, 4)

        case .code:
            if block.language?.lowercased() == "mermaid" {
                MermaidBlockView(source: block.text)
            } else {
                CodeBlockView(code: block.text, language: block.language)
            }

        case .table:
            MarkdownTableView(
                headers: block.tableRows.first ?? [],
                alignments: block.tableAlignments,
                rows: Array(block.tableRows.dropFirst())
            )

        case .image:
            ResourceCardView(
                title: block.secondaryText.isEmpty ? "图片" : block.secondaryText,
                subtitle: block.resource,
                systemImage: "photo"
            )

        case .url:
            LinkBlockView(title: block.text.isEmpty ? block.resource : block.text, destination: block.resource)

        case .callout:
            CalloutBlockView(tone: block.calloutTone, title: block.secondaryText, text: block.text)

        case .toggle:
            ToggleBlockView(title: block.secondaryText, text: block.text, startsExpanded: !block.isCollapsed)
        }
    }

    private func inlineText(_ raw: String) -> Text {
        let trimmed = raw.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return Text("") }
        if let attr = try? AttributedString(
            markdown: trimmed,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(trimmed)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        case 4: return .headline
        case 5: return .subheadline
        default: return .footnote
        }
    }

    private func numberedMarker(for index: Int) -> String {
        let previousKinds = snapshot.blocks.prefix(index).map(\.kind)
        let previousNumberedCount = previousKinds.filter { kind in
            if case .numberedList = kind { return true }
            return false
        }.count
        return "\(previousNumberedCount + 1)."
    }
}

private struct QuoteBlockView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 4)
            MarkdownInlineTextBlock(text: text)
        }
        .padding(.vertical, 2)
    }
}

private struct ListItemBlockView: View {
    let marker: String
    let text: String
    let indentLevel: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(marker)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            MarkdownInlineTextBlock(text: text)
        }
        .padding(.leading, CGFloat(indentLevel) * 18)
    }
}

private struct TodoBlockView: View {
    let text: String
    let isChecked: Bool
    let indentLevel: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .foregroundStyle(isChecked ? Color.accentColor : .secondary)
                .frame(width: 28, alignment: .trailing)
            MarkdownInlineTextBlock(text: text)
                .foregroundStyle(isChecked ? .secondary : .primary)
        }
        .padding(.leading, CGFloat(indentLevel) * 18)
    }
}

private struct CalloutBlockView: View {
    let tone: String
    let title: String
    let text: String

    private var accent: Color {
        switch tone.lowercased() {
        case "warning", "caution":
            return .orange
        case "danger", "error":
            return .red
        case "tip", "success":
            return .green
        default:
            return .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(accent)
                Text(title.isEmpty ? "提示" : title)
                    .font(.callout)
                    .fontWeight(.semibold)
            }
            MarkdownInlineTextBlock(text: text)
        }
        .padding(12)
        .background(accent.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(accent.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct ToggleBlockView: View {
    let title: String
    let text: String

    @SwiftUI.State private var isExpanded: Bool

    init(title: String, text: String, startsExpanded: Bool) {
        self.title = title
        self.text = text
        _isExpanded = SwiftUI.State(initialValue: startsExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            MarkdownInlineTextBlock(text: text)
                .padding(.top, 6)
        } label: {
            Text(title.isEmpty ? "折叠块" : title)
                .font(.callout)
                .fontWeight(.medium)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct ResourceCardView: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .fontWeight(.medium)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct LinkBlockView: View {
    let title: String
    let destination: String

    var body: some View {
        if let url = URL(string: destination), !destination.isEmpty {
            Link(destination: url) {
                ResourceCardView(title: title, subtitle: destination, systemImage: "link")
            }
            .buttonStyle(.plain)
        } else {
            ResourceCardView(title: title, subtitle: destination, systemImage: "link")
        }
    }
}

private struct MarkdownInlineTextBlock: View {
    let text: String

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .newlines)
        if let attr = try? AttributedString(
            markdown: trimmed,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attr)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(trimmed)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Table View

@MainActor
struct MarkdownTableCellContent {
    let sourceText: String
    let renderedContent: BlockInlineMarkdownRenderedContent

    init(_ sourceText: String) {
        self.sourceText = sourceText
        self.renderedContent = BlockInlineMarkdownRendering.renderedContent(for: sourceText)
    }
}

@MainActor
struct MarkdownTableLayout {
    let alignments: [HorizontalAlignment]
    let headerCells: [MarkdownTableCellContent]
    let rowCells: [[MarkdownTableCellContent]]
    let columnWidths: [CGFloat]
    let totalWidth: CGFloat

    private static let cellHorizontalPadding: CGFloat = 24
    private static let minColumnWidth: CGFloat = 120
    private static let maxColumnWidth: CGFloat = 340
    private static let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    private static let bodyFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    init(
        headers: [String],
        rows: [[String]],
        alignments: [HorizontalAlignment],
        availableWidth: CGFloat
    ) {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        let normalizedHeaders = MarkdownTableLayout.pad(headers, to: columnCount)
        let normalizedRows = rows.map { MarkdownTableLayout.pad($0, to: columnCount) }

        self.alignments = alignments
        self.headerCells = normalizedHeaders.map(MarkdownTableCellContent.init)
        self.rowCells = normalizedRows.map { $0.map(MarkdownTableCellContent.init) }

        let measuredWidths = MarkdownTableLayout.measureColumnWidths(
            headerCells: headerCells,
            rowCells: rowCells
        )
        self.columnWidths = MarkdownTableLayout.distribute(
            measuredWidths,
            toFill: availableWidth
        )
        self.totalWidth = max(availableWidth, columnWidths.reduce(0, +))
    }

    func alignment(for column: Int) -> HorizontalAlignment {
        column < alignments.count ? alignments[column] : .leading
    }

    private static func pad(_ row: [String], to count: Int) -> [String] {
        guard row.count < count else { return row }
        return row + Array(repeating: "", count: count - row.count)
    }

    private static func measureColumnWidths(
        headerCells: [MarkdownTableCellContent],
        rowCells: [[MarkdownTableCellContent]]
    ) -> [CGFloat] {
        guard !headerCells.isEmpty else { return [] }

        return headerCells.indices.map { column in
            let headerWidth = measuredWidth(for: headerCells[column], font: headerFont)
            let bodyWidth = rowCells.map { row in
                measuredWidth(for: row[column], font: bodyFont)
            }.max() ?? minColumnWidth
            return max(headerWidth, bodyWidth)
        }
    }

    private static func measuredWidth(for content: MarkdownTableCellContent, font: NSFont) -> CGFloat {
        let plainText = content.renderedContent.displayPlainText.isEmpty ? " " : content.renderedContent.displayPlainText
        let measured = ceil((plainText as NSString).size(withAttributes: [.font: font]).width)
        return min(max(measured + cellHorizontalPadding, minColumnWidth), maxColumnWidth)
    }

    private static func distribute(_ widths: [CGFloat], toFill availableWidth: CGFloat) -> [CGFloat] {
        guard !widths.isEmpty else { return [] }

        let measuredTotal = widths.reduce(0, +)
        guard availableWidth > measuredTotal else { return widths }

        let extraWidth = availableWidth - measuredTotal
        let columnBonus = extraWidth / CGFloat(widths.count)
        return widths.map { $0 + columnBonus }
    }
}

private struct MarkdownTableCellView: View {
    let content: MarkdownTableCellContent
    let width: CGFloat
    let alignment: HorizontalAlignment
    let isHeader: Bool
    let showsTrailingDivider: Bool

    var body: some View {
        Group {
            if isHeader {
                InlineMarkdownText(
                    renderedContent: content.renderedContent,
                    font: .callout
                )
                .fontWeight(.semibold)
            } else {
                InlineMarkdownText(
                    renderedContent: content.renderedContent,
                    font: .callout
                )
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: alignment.cellFrameAlignment)
        .padding(.horizontal, 12)
        .padding(.vertical, isHeader ? 10 : 8)
        .frame(width: width, alignment: alignment.cellFrameAlignment)
        .overlay(alignment: .trailing) {
            if showsTrailingDivider {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 1)
                    .padding(.vertical, 6)
            }
        }
}

}

private struct MarkdownTableWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MarkdownTableView: View {
    let headers: [String]
    let alignments: [HorizontalAlignment]
    let rows: [[String]]

    @SwiftUI.State private var availableWidth: CGFloat = 0

    var body: some View {
        let layout = MarkdownTableLayout(
            headers: headers,
            rows: rows,
            alignments: alignments,
            availableWidth: max(availableWidth, 0)
        )

        HorizontalScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                tableRow(
                    cells: layout.headerCells,
                    widths: layout.columnWidths,
                    isHeader: true,
                    rowIndex: 0,
                    layout: layout
                )

                ForEach(Array(layout.rowCells.enumerated()), id: \.offset) { rowIndex, row in
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 1)

                    tableRow(
                        cells: row,
                        widths: layout.columnWidths,
                        isHeader: false,
                        rowIndex: rowIndex,
                        layout: layout
                    )
                }
            }
            .frame(width: layout.totalWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .overlay {
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.12),
                            Color.clear,
                            Color.primary.opacity(0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(.rect(cornerRadius: 12))
                }
        )
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: MarkdownTableWidthPreferenceKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(MarkdownTableWidthPreferenceKey.self) { newWidth in
            let roundedWidth = max(0, floor(newWidth))
            guard abs(roundedWidth - availableWidth) > 1 else { return }
            availableWidth = roundedWidth
        }
    }

    @ViewBuilder
    private func tableRow(
        cells: [MarkdownTableCellContent],
        widths: [CGFloat],
        isHeader: Bool,
        rowIndex: Int,
        layout: MarkdownTableLayout
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                MarkdownTableCellView(
                    content: cell,
                    width: widths[column],
                    alignment: layout.alignment(for: column),
                    isHeader: isHeader,
                    showsTrailingDivider: column < cells.count - 1
                )
            }
        }
        .background(isHeader ? headerBackground : rowBackground(for: rowIndex))
    }

    private var headerBackground: AnyShapeStyle {
        AnyShapeStyle(LinearGradient(
            colors: [
                Color.accentColor.opacity(0.14),
                Color.accentColor.opacity(0.05)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ))
    }

    private func rowBackground(for rowIndex: Int) -> AnyShapeStyle {
        rowIndex.isMultiple(of: 2)
        ? AnyShapeStyle(Color.primary.opacity(0.025))
        : AnyShapeStyle(Color.clear)
    }
}

private extension HorizontalAlignment {
    var cellFrameAlignment: Alignment {
        switch self {
        case .center:
            return .center
        case .trailing:
            return .trailing
        default:
            return .leading
        }
    }
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let code: String
    let language: String?

    @Environment(\.colorScheme) private var colorScheme
    @SwiftUI.State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(displayLanguage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copyCode()
                } label: {
                    Label(isCopied ? "已复制" : "复制", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)

            Divider()

            HorizontalScrollView(showsIndicators: false) {
                SyntaxHighlightedCodeTextView(attributedString: highlightedCode)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        withAnimation { isCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { isCopied = false }
        }
    }

    private var highlightedCode: NSAttributedString {
        CodeSyntaxHighlightingService.shared.highlightedString(
            code: code.trimmingCharacters(in: .newlines),
            language: language,
            appearance: colorScheme == .dark ? .dark : .light,
            fontSize: 12
        )
    }

    private var displayLanguage: String {
        let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "code" : trimmed
    }
}

// MARK: - Scroll-Event-Isolated Horizontal Scroll View
// Prevents block elements' inner horizontal scroll views from stealing vertical scroll
// events that belong to the enclosing message List.

final class DirectionalNSScrollView: NSScrollView {
    /// Only consumes scroll events that are primarily horizontal.
    /// Vertical events are forwarded to the next responder so the
    /// enclosing List / ScrollView can scroll without conflict.
    override func scrollWheel(with event: NSEvent) {
        let dx = abs(event.scrollingDeltaX)
        let dy = abs(event.scrollingDeltaY)
        if dy > dx {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

struct HorizontalScrollView<Content: View>: NSViewRepresentable {
    let showsIndicators: Bool
    @ViewBuilder let content: () -> Content

    final class Coordinator {
        var hostingController: NSHostingController<Content>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DirectionalNSScrollView {
        let sv = DirectionalNSScrollView()
        sv.hasHorizontalScroller = showsIndicators
        sv.autohidesScrollers = true
        sv.hasVerticalScroller = false
        sv.verticalScrollElasticity = .none
        sv.drawsBackground = false
        sv.borderType = .noBorder

        let hc = NSHostingController(rootView: content())
        // Use intrinsicContentSize so Auto Layout drives the document view size
        // entirely via SwiftUI's ideal size — avoids manual frame.size assignment
        // which triggers AppKit constraint re-evaluation cycles.
        hc.sizingOptions = .intrinsicContentSize
        context.coordinator.hostingController = hc

        let docView = hc.view
        docView.translatesAutoresizingMaskIntoConstraints = false
        // Raise priorities so the AL intrinsic-size constraints win decisively
        // (default hugging/resistance is 250/750; .required = 1000).
        docView.setContentHuggingPriority(.required, for: .horizontal)
        docView.setContentHuggingPriority(.required, for: .vertical)
        docView.setContentCompressionResistancePriority(.required, for: .horizontal)
        docView.setContentCompressionResistancePriority(.required, for: .vertical)

        sv.documentView = docView
        // Pin to top-left; width and height are owned by the intrinsic-size constraints.
        NSLayoutConstraint.activate([
            docView.topAnchor.constraint(equalTo: sv.contentView.topAnchor),
            docView.leadingAnchor.constraint(equalTo: sv.contentView.leadingAnchor),
        ])
        return sv
    }

    func updateNSView(_ nsView: DirectionalNSScrollView, context: Context) {
        // Only propagate content changes; Auto Layout handles the document view sizing.
        context.coordinator.hostingController?.rootView = content()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: DirectionalNSScrollView,
        context: Context
    ) -> CGSize? {
        guard let hc = context.coordinator.hostingController else { return nil }
        let w = max(proposal.replacingUnspecifiedDimensions().width, 1)
        let fitting = hc.sizeThatFits(in: CGSize(width: w, height: .greatestFiniteMagnitude))
        return CGSize(width: w, height: max(fitting.height, 1))
    }
}


//
//  MarkdownMessageView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import AppKit
import BeautifulMermaid

// MARK: - Markdown Message View

struct MarkdownMessageView: View {
    let text: String

    @SwiftUI.State private var parser = MarkdownMessageIncrementalParser()
    @SwiftUI.State private var snapshot = MarkdownIncrementalSnapshot(sourceText: "", blocks: [])

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

private struct MarkdownTableView: View {
    let headers: [String]
    let alignments: [HorizontalAlignment]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                // Header row
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { idx, header in
                        Text(header)
                            .font(.callout)
                            .bold()
                            .frame(maxWidth: .infinity, alignment: .init(horizontal: alignment(idx), vertical: .center))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial)
                    }
                }
                Divider()

                // Data rows
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    GridRow {
                        ForEach(0..<headers.count, id: \.self) { colIdx in
                            let cell = colIdx < row.count ? row[colIdx] : ""
                            Text(cell)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .init(horizontal: alignment(colIdx), vertical: .center))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(rowIdx.isMultiple(of: 2)
                                    ? Color.primary.opacity(0.03)
                                    : Color.clear)
                        }
                    }
                    if rowIdx < rows.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func alignment(_ idx: Int) -> HorizontalAlignment {
        idx < alignments.count ? alignments[idx] : .leading
    }
}

// MARK: - Mermaid Diagram View

private struct MermaidNSView: NSViewRepresentable {
    let source: String
    let theme: DiagramTheme

    func makeNSView(context: Context) -> MermaidView {
        MermaidView(frame: .zero)
    }

    func updateNSView(_ nsView: MermaidView, context: Context) {
        nsView.source = source
        nsView.theme = theme
    }
}

private struct MermaidBlockView: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @SwiftUI.State private var showSource = false
    @SwiftUI.State private var diagramWidth: CGFloat = 600

    private var theme: DiagramTheme {
        colorScheme == .dark ? .zincDark : .zincLight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Text("mermaid")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Width stepper (only shown in diagram mode)
                if !showSource {
                    HStack(spacing: 2) {
                        Button { diagramWidth = max(200, diagramWidth - 100) } label: {
                            Image(systemName: "minus")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        Text("\(Int(diagramWidth))px")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 50)
                        Button { diagramWidth = min(1600, diagramWidth + 100) } label: {
                            Image(systemName: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                // Toggle source / diagram
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showSource.toggle() }
                } label: {
                    Label(showSource ? "图表" : "源码",
                          systemImage: showSource ? "chart.xyaxis.line" : "chevron.left.forwardslash.chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)

            Divider()

            if showSource {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(source.trimmingCharacters(in: .newlines))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    MermaidNSView(source: source, theme: theme)
                        .frame(width: diagramWidth, height: 250)
                        .padding(8)
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let code: String
    let language: String?

    @SwiftUI.State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
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

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.trimmingCharacters(in: .newlines))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
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
}


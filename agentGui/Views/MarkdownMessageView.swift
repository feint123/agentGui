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

/// 块级 Markdown 渲染视图
/// 按行扫描，识别标题 / 分割线 / 表格 / 代码块 / 普通文本段，各类型专属渲染
struct MarkdownMessageView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(parseBlocks(text)) { block in
                blockView(block)
            }
        }
    }

    // MARK: - Block Rendering

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .text:
            inlineText(block.content)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level):
            inlineText(block.content)
                .font(headingFont(level))
                .bold()
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 6 : 2)
                .padding(.bottom, 2)

        case .divider:
            Divider()
                .padding(.vertical, 4)

        case .code(let language):
            if language?.lowercased() == "mermaid" {
                MermaidBlockView(source: block.content)
            } else {
                CodeBlockView(code: block.content, language: language)
            }

        case .table(let headers, let alignments, let rows):
            MarkdownTableView(headers: headers, alignments: alignments, rows: rows)
        }
    }

    // MARK: - Inline Markdown (AttributedString)

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

    // MARK: - Block Parser

    private func parseBlocks(_ input: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = input.components(separatedBy: "\n")
        var i = 0
        var textBuffer: [String] = []

        func flushText() {
            let joined = textBuffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty {
                blocks.append(MarkdownBlock(kind: .text, content: joined))
            }
            textBuffer = []
        }

        while i < lines.count {
            let line = lines[i]

            // ── Fenced code block ──
            if line.hasPrefix("```") {
                flushText()
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(MarkdownBlock(
                    kind: .code(language: lang.isEmpty ? nil : lang),
                    content: code.joined(separator: "\n")
                ))
                i += 1
                continue
            }

            // ── ATX Heading  # … ######  ──
            if let m = line.firstMatch(of: /^(#{1,6})\s+(.+)$/) {
                flushText()
                let level = m.1.count
                let text = String(m.2)
                blocks.append(MarkdownBlock(kind: .heading(level: level), content: text))
                i += 1
                continue
            }

            // ── Setext Heading (=== or ---) — only if prev line is text ──
            if i + 1 < lines.count {
                let next = lines[i + 1]
                if !line.trimmingCharacters(in: .whitespaces).isEmpty,
                   next.allSatisfy({ $0 == "=" }) && next.count >= 2 {
                    flushText()
                    blocks.append(MarkdownBlock(kind: .heading(level: 1), content: line))
                    i += 2
                    continue
                }
                if !line.trimmingCharacters(in: .whitespaces).isEmpty,
                   next.allSatisfy({ $0 == "-" }) && next.count >= 2 {
                    flushText()
                    blocks.append(MarkdownBlock(kind: .heading(level: 2), content: line))
                    i += 2
                    continue
                }
            }

            // ── Thematic break / Divider (--- *** ___) ──
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if isThematicBreak(stripped) {
                flushText()
                blocks.append(MarkdownBlock(kind: .divider, content: ""))
                i += 1
                continue
            }

            // ── GFM Table ──
            if looksLikeTableRow(line) && i + 1 < lines.count && isTableSeparator(lines[i + 1]) {
                flushText()
                let headers = parseTableCells(line)
                let sepCells = parseTableCells(lines[i + 1])
                let alignments = sepCells.map { tableAlignment($0) }
                var rows: [[String]] = []
                i += 2
                while i < lines.count && looksLikeTableRow(lines[i]) {
                    rows.append(parseTableCells(lines[i]))
                    i += 1
                }
                blocks.append(MarkdownBlock(
                    kind: .table(headers: headers, alignments: alignments, rows: rows),
                    content: ""
                ))
                continue
            }

            // ── Regular text ──
            textBuffer.append(line)
            i += 1
        }

        flushText()
        return blocks
    }

    // MARK: - Table Helpers

    private func looksLikeTableRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.hasSuffix("|") && t.count > 2
    }

    private func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|") else { return false }
        return t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private func parseTableCells(_ line: String) -> [String] {
        let t = line.trimmingCharacters(in: .whitespaces)
        let inner = t.hasPrefix("|") ? String(t.dropFirst()) : t
        let stripped = inner.hasSuffix("|") ? String(inner.dropLast()) : inner
        return stripped.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func tableAlignment(_ cell: String) -> HorizontalAlignment {
        let t = cell.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix(":") && t.hasSuffix(":") { return .center }
        if t.hasSuffix(":") { return .trailing }
        return .leading
    }

    private func isThematicBreak(_ s: String) -> Bool {
        guard s.count >= 3 else { return false }
        let chars = Set(s.filter { !$0.isWhitespace })
        return chars.count == 1 && (chars.contains("-") || chars.contains("*") || chars.contains("_"))
    }
}

// MARK: - Markdown Block Model

private struct MarkdownBlock: Identifiable {
    let id = UUID()
    enum Kind {
        case text
        case heading(level: Int)
        case divider
        case code(language: String?)
        case table(headers: [String], alignments: [HorizontalAlignment], rows: [[String]])
    }
    let kind: Kind
    let content: String
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


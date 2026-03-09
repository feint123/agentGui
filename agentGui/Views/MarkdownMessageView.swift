//
//  MarkdownMessageView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import AppKit
import BeautifulMermaid
import OSLog

// MARK: - Performance Monitor

private let perfUI = PerformanceMonitor.self

// MARK: - Markdown Block Cache

/// Markdown 解析缓存管理器
@Observable
final class MarkdownBlockCache {
    private var storage: [String: CachedBlockList] = [:]

    func getBlocks(for text: String, baseText: String? = nil, parser: @escaping (String) -> [CachedBlock]) -> [CachedBlock] {
        let textKey = text.isEmpty ? "" : text
        let parseSpan = PerformanceMonitor.startSpan("MarkdownCache.getBlocks", category: "Markdown", level: .verbose)
        defer {
            parseSpan.addMetadata("textLength", value: text.count)
            parseSpan.end()
        }

        // 如果缓存完全匹配，直接返回
        if let cached = storage[textKey] {
            return cached.blocks
        }

        // 检查是否是增量更新（append-only）
        if let base = baseText, !base.isEmpty, text.hasPrefix(base) {
            if let baseCached = storage[base] {
                return appendBlocks(to: baseCached.blocks, baseText: base, newText: text, parser: parser)
            }
        }

        // 完全重新解析
        let blocks = parser(text)
        storage[textKey] = CachedBlockList(blocks: blocks, textLength: text.count)
        return blocks
    }

    /// 增量解析：只解析新增的部分
    private func appendBlocks(to baseBlocks: [CachedBlock], baseText: String, newText: String, parser: @escaping (String) -> [CachedBlock]) -> [CachedBlock] {
        guard newText.count > baseText.count else { return baseBlocks }

        // 找出新增的文本
        let appendedText = String(newText.dropFirst(baseText.count))

        var result = baseBlocks

        // 检测新文本是否包含复杂的 markdown 结构
        let hasComplexStructure = containsComplexMarkdown(appendedText)

        // 如果最后一个 block 是 text 类型，且新文本不包含复杂结构
        if let lastBlock = result.last,
           lastBlock.kind == .text,
           !hasComplexStructure {
            // 简单地将新文本追加到最后的 text block
            let updatedBlock = CachedBlock(kind: .text, content: lastBlock.content + appendedText)
            result[result.count - 1] = updatedBlock
        } else {
            // 直接解析新增文本并追加
            let newBlocks = parser(appendedText)
            result.append(contentsOf: newBlocks)
        }

        // 更新缓存
        storage[newText] = CachedBlockList(blocks: result, textLength: newText.count)
        return result
    }

    /// 检测文本是否包含复杂的 markdown 结构
    private func containsComplexMarkdown(_ text: String) -> Bool {
        // 检测是否包含以下结构：
        // - ATX heading (#)
        // - 代码块 (```)
        // - 分割线 (---, ***, ___)
        // - 表格行 (|)
        // - Setext heading 下划线 (====, ----)

        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // ATX heading
            if trimmed.hasPrefix("#") { return true }

            // 代码块标记
            if trimmed.hasPrefix("```") { return true }

            // 表格行
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 2 {
                return true
            }

            // 分割线
            if isThematicBreak(trimmed) { return true }
        }

        // 检测 Setext heading（以下一行的 ==== 或 ---- 为准）
        for i in 0..<(lines.count - 1) {
            let nextLine = lines[i + 1].trimmingCharacters(in: .whitespaces)
            if nextLine.allSatisfy({ $0 == "=" }) || nextLine.allSatisfy({ $0 == "-" }) {
                if nextLine.count >= 2 {
                    return true
                }
            }
        }

        return false
    }

    /// 检测是否是分割线
    private func isThematicBreak(_ s: String) -> Bool {
        guard s.count >= 3 else { return false }
        let chars = Set(s.filter { !$0.isWhitespace })
        return chars.count == 1 && (chars.contains("-") || chars.contains("*") || chars.contains("_"))
    }

    func clear() {
        storage.removeAll()
    }
}

/// 缓存的 block 列表
private struct CachedBlockList {
    let blocks: [CachedBlock]
    let textLength: Int
}

/// 缓存的 block（可序列化的 block 数据）
struct CachedBlock: Identifiable, Equatable {
    let id = UUID()
    enum Kind: Equatable {
        case text
        case heading(level: Int)
        case divider
        case code(language: String?)
        case table(headers: [String], alignments: TableAlignmentArray, rows: [[String]])

        static func == (lhs: Kind, rhs: Kind) -> Bool {
            switch (lhs, rhs) {
            case (.text, .text), (.divider, .divider):
                return true
            case (.heading(let l), .heading(let r)):
                return l == r
            case (.code(let l), .code(let r)):
                return l == r
            case (.table(let lh, let la, let lr), .table(let rh, let ra, let rr)):
                return lh == rh && la.alignments == ra.alignments && lr == rr
            default:
                return false
            }
        }
    }
    let kind: Kind
    let content: String

    static func == (lhs: CachedBlock, rhs: CachedBlock) -> Bool {
        lhs.kind == rhs.kind && lhs.content == rhs.content
    }
}

/// 表格对齐数组（可序列化）
struct TableAlignmentArray: Equatable {
    let alignments: [HorizontalAlignment]
    init(_ alignments: [HorizontalAlignment]) {
        self.alignments = alignments
    }
}

// MARK: - Markdown Message View

/// 块级 Markdown 渲染视图
/// 按行扫描，识别标题 / 分割线 / 表格 / 代码块 / 普通文本段，各类型专属渲染
/// 支持 stream 输出的增量渲染和缓存
struct MarkdownMessageView: View {
    let text: String

    @SwiftUI.State private var cache = MarkdownBlockCache()
    @SwiftUI.State private var blocks: [CachedBlock] = []
    @SwiftUI.State private var lastTextLength: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks) { block in
                blockView(block)
                    .id(block.id) // 稳定 ID 帮助 SwiftUI 复用视图
            }
        }
        .onChange(of: text) { oldValue, newValue in
            updateBlocks(oldText: oldValue, newText: newValue)
        }
        .onAppear {
            blocks = cache.getBlocks(for: text, parser: parseCachedBlocks)
            lastTextLength = text.count
        }
    }

    private func updateBlocks(oldText: String, newText: String) {
        let updateSpan = PerformanceMonitor.startSpan("updateBlocks", category: "UI", level: .verbose)
        defer {
            updateSpan.addMetadata("oldLength", value: oldText.count)
            updateSpan.addMetadata("newLength", value: newText.count)
            updateSpan.end()
        }

        // 检测是否是增量更新（stream 模式下通常是追加）
        let isAppendOnly = newText.hasPrefix(oldText) && newText.count >= oldText.count

        if isAppendOnly {
            // 使用增量解析
            blocks = cache.getBlocks(for: newText, baseText: oldText, parser: parseCachedBlocks)
        } else {
            // 完全重新解析
            blocks = cache.getBlocks(for: newText, parser: parseCachedBlocks)
        }

        lastTextLength = newText.count
    }

    // MARK: - Block Rendering

    @ViewBuilder
    private func blockView(_ block: CachedBlock) -> some View {
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
            MarkdownTableView(headers: headers, alignments: alignments.alignments, rows: rows)
        }
    }

    /// 解析并缓存 blocks
    private func parseCachedBlocks(_ text: String) -> [CachedBlock] {
        return parseBlocksImpl(text).map { block in
            switch block.kind {
            case .text:
                return CachedBlock(kind: .text, content: block.content)
            case .heading(let level):
                return CachedBlock(kind: .heading(level: level), content: block.content)
            case .divider:
                return CachedBlock(kind: .divider, content: block.content)
            case .code(let language):
                return CachedBlock(kind: .code(language: language), content: block.content)
            case .table(let headers, let alignments, let rows):
                return CachedBlock(kind: .table(headers: headers, alignments: TableAlignmentArray(alignments), rows: rows), content: block.content)
            }
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

    /// 解析 Markdown 文本为 blocks
    /// 这个实现是独立的，不依赖实例状态，可以从缓存类中调用
    private func parseBlocks(_ input: String) -> [MarkdownBlock] {
        return parseBlocksImpl(input)
    }

    /// 实际的解析实现，被缓存类使用
    fileprivate func parseBlocksImpl(_ input: String) -> [MarkdownBlock] {
        let span = PerformanceMonitor.startSpan("parseBlocksImpl", category: "Markdown", level: .verbose)
        defer {
            span.addMetadata("inputLength", value: input.count)
            span.end()
        }
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

private struct MarkdownBlock: Identifiable, Equatable {
    let id = UUID()
    enum Kind: Equatable {
        case text
        case heading(level: Int)
        case divider
        case code(language: String?)
        case table(headers: [String], alignments: [HorizontalAlignment], rows: [[String]])

        static func == (lhs: Kind, rhs: Kind) -> Bool {
            switch (lhs, rhs) {
            case (.text, .text), (.divider, .divider):
                return true
            case (.heading(let l), .heading(let r)):
                return l == r
            case (.code(let l), .code(let r)):
                return l == r
            case (.table(let lh, let la, let lr), .table(let rh, let ra, let rr)):
                return lh == rh && la == ra && lr == rr
            default:
                return false
            }
        }
    }
    let kind: Kind
    let content: String

    static func == (lhs: MarkdownBlock, rhs: MarkdownBlock) -> Bool {
        lhs.kind == rhs.kind && lhs.content == rhs.content
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


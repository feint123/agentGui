//
//  BlockMarkdownCodec.swift
//  agentGui
//

import Foundation

enum BlockMarkdownCodec {

    struct InlineMarkdownMatch: Equatable {
        let fullRange: NSRange
        let contentRange: NSRange
        let markerRanges: [NSRange]
    }

    enum InlineMarkdownSemantic: String, CaseIterable, Hashable {
        case bold
        case italic
        case inlineCode
        case strikethrough
        case link
    }

    struct InlineMarkdownRule {
        let semantic: InlineMarkdownSemantic
        let regex: NSRegularExpression
        let contentCaptureIndex: Int
        let markerCaptureIndexes: [Int]

        func matches(in text: String) -> [InlineMarkdownMatch] {
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            return regex.matches(in: text, options: [], range: fullRange).compactMap { match in
                let contentRange = match.range(at: contentCaptureIndex)
                guard contentRange.location != NSNotFound else { return nil }

                let markerRanges = markerCaptureIndexes.compactMap { index -> NSRange? in
                    let range = match.range(at: index)
                    return range.location == NSNotFound ? nil : range
                }

                return InlineMarkdownMatch(
                    fullRange: match.range(at: 0),
                    contentRange: contentRange,
                    markerRanges: markerRanges
                )
            }
        }

        static let bold = InlineMarkdownRule(
            semantic: .bold,
            regex: try! NSRegularExpression(pattern: #"(\*\*)(.+?)(\*\*)"#, options: []),
            contentCaptureIndex: 2,
            markerCaptureIndexes: [1, 3]
        )

        static let boldUnderscore = InlineMarkdownRule(
            semantic: .bold,
            regex: try! NSRegularExpression(pattern: #"(__)(.+?)(__)"#, options: []),
            contentCaptureIndex: 2,
            markerCaptureIndexes: [1, 3]
        )

        static let italic = InlineMarkdownRule(
            semantic: .italic,
            regex: try! NSRegularExpression(pattern: #"(?<!\*)(\*)(?!\*)(.+?)(?<!\*)(\*)(?!\*)"#, options: []),
            contentCaptureIndex: 2,
            markerCaptureIndexes: [1, 3]
        )

        static let italicUnderscore = InlineMarkdownRule(
            semantic: .italic,
            regex: try! NSRegularExpression(pattern: #"(?<!_)(_)(?!_)(.+?)(?<!_)(_)(?!_)"#, options: []),
            contentCaptureIndex: 2,
            markerCaptureIndexes: [1, 3]
        )

        static let code = InlineMarkdownRule(
            semantic: .inlineCode,
            regex: try! NSRegularExpression(pattern: #"(`)(.+?)(`)"#, options: []),
            contentCaptureIndex: 2,
            markerCaptureIndexes: [1, 3]
        )

        static let strikethrough = InlineMarkdownRule(
            semantic: .strikethrough,
            regex: try! NSRegularExpression(pattern: #"(~~)(.+?)(~~)"#, options: []),
            contentCaptureIndex: 2,
            markerCaptureIndexes: [1, 3]
        )

        static let link = InlineMarkdownRule(
            semantic: .link,
            regex: try! NSRegularExpression(pattern: #"(\[)(.+?)(\]\((.+?)\))"#, options: []),
            contentCaptureIndex: 2,
            markerCaptureIndexes: [1, 3]
        )

        static let defaultDisplayRules: [InlineMarkdownRule] = [
            .bold,
            .boldUnderscore,
            .italic,
            .italicUnderscore,
            .code,
            .strikethrough,
            .link
        ]
    }

    static func inlineRules(for semantic: InlineMarkdownSemantic) -> [InlineMarkdownRule] {
        InlineMarkdownRule.defaultDisplayRules.filter { $0.semantic == semantic }
    }

    static func inlineMarkerRanges(
        in text: String,
        rules: [InlineMarkdownRule] = InlineMarkdownRule.defaultDisplayRules
    ) -> [NSRange] {
        rules
            .flatMap { $0.matches(in: text) }
            .flatMap(\.markerRanges)
            .filter { $0.location != NSNotFound && $0.length > 0 }
            .sorted { lhs, rhs in
                if lhs.location == rhs.location {
                    return lhs.length < rhs.length
                }
                return lhs.location < rhs.location
            }
    }

    static func parse(_ text: String, fileURL: URL?) -> BlockDocument {
        let cacheKey = "parse::\(fileURL?.pathExtension.lowercased() ?? "md")::\(text.hashValue)"
        if let cached = BlockEditorPerformance.cachedDocument(for: cacheKey) {
            return cached
        }
        let document = BlockEditorPerformance.measureParse(fileURL?.pathExtension) {
            parseUncached(text, fileURL: fileURL)
        }
        BlockEditorPerformance.storeDocument(document, for: cacheKey)
        return document
    }

    static func serialize(_ document: BlockDocument, fileURL: URL?) -> String {
        guard isMarkdownDocument(fileURL) else {
            let body = document.blocks.map { blockToSourceText($0) }.joined(separator: "\n\n")
            return body.trimmingCharacters(in: .newlines)
        }

        return BlockEditorPerformance.measureSerialize(document.blocks.count) {
            let orderedListIndices = BlockListIndexMap.make(for: document.blocks)
            var output = ""

            for (index, block) in document.blocks.enumerated() {
                let chunk: String
                switch block.kind {
                case .paragraph:
                    chunk = block.text
                case .heading1:
                    chunk = "# \(block.text)"
                case .heading2:
                    chunk = "## \(block.text)"
                case .heading3:
                    chunk = "### \(block.text)"
                case .quote:
                    chunk = serializeQuotedLines(block.text, level: max(1, block.metadata.indentLevel + 1))
                case .bulletedList:
                    chunk = serializeListItem(prefix: "- ", body: block.text, indentLevel: block.metadata.indentLevel)
                case .numberedList:
                    let orderedIndex = orderedListIndices[block.id] ?? 1
                    chunk = serializeListItem(prefix: "\(orderedIndex). ", body: block.text, indentLevel: block.metadata.indentLevel)
                case .todo:
                    chunk = serializeListItem(prefix: "- [\(block.metadata.checked ? "x" : " ")] ", body: block.text, indentLevel: block.metadata.indentLevel)
                case .code:
                    chunk = "```\(block.metadata.language)\n\(block.text)\n```"
                case .divider:
                    chunk = "---"
                case .table:
                    chunk = block.text
                case .image:
                    let alt = block.metadata.secondaryText.isEmpty ? "image" : block.metadata.secondaryText
                    chunk = "![\(alt)](\(block.metadata.resource))"
                case .url:
                    let title = block.text.isEmpty ? "链接" : block.text
                    chunk = "[\(title)](\(block.metadata.resource))"
                case .file:
                    let title = block.text.isEmpty ? (block.metadata.secondaryText.isEmpty ? "附件" : block.metadata.secondaryText) : block.text
                    chunk = "::file[\(title)](\(block.metadata.resource))"
                case .callout:
                    let header = "> [!\(block.metadata.tone.uppercased())] \(block.metadata.secondaryText)"
                    let body = serializeQuotedLines(block.text)
                    chunk = [header, body].filter { !$0.isEmpty }.joined(separator: "\n")
                case .toggle:
                    let openMarker = block.metadata.isCollapsed ? "" : " open"
                    chunk = "<details\(openMarker)><summary>\(block.metadata.secondaryText)</summary>\n\n\(block.text)\n\n</details>"
                case .source:
                    chunk = block.text
                }

                if !output.isEmpty {
                    let previous = document.blocks[index - 1]
                    let sameIndent = previous.metadata.indentLevel == block.metadata.indentLevel
                    output += requiresTightSpacing(previous: previous.kind, next: block.kind) && sameIndent ? "\n" : "\n\n"
                }
                output += chunk
            }

            return output.trimmingCharacters(in: .newlines)
        }
    }

    static func parseTableContent(_ markdown: String) -> [[String]] {
        let key = "table::\(markdown.hashValue)"
        if let cached = BlockEditorPerformance.cachedTable(for: key) {
            return cached
        }
        let rows = markdown
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .enumerated()
            .compactMap { index, line -> [String]? in
                if index == 1 && isTableSeparator(line) { return nil }
                return parseTableCells(line)
            }
        let normalized = rows.count >= 2 ? rows : [["列 1", "列 2"], ["", ""]]
        BlockEditorPerformance.storeTable(normalized, for: key)
        return normalized
    }

    static func serializeTableContent(_ rows: [[String]]) -> String {
        let normalizedRows = rows.filter { !$0.isEmpty }
        guard let header = normalizedRows.first else {
            return "| 列 1 | 列 2 |\n| --- | --- |\n|  |  |"
        }
        let columnCount = max(header.count, 2)
        let normalizedHeader = normalizeTableRow(header, columnCount: columnCount)
        let separator = Array(repeating: "---", count: columnCount)
        let bodyRows = normalizedRows.dropFirst().map { normalizeTableRow($0, columnCount: columnCount) }
        let finalRows = [normalizedHeader, separator] + (bodyRows.isEmpty ? [Array(repeating: "", count: columnCount)] : bodyRows)
        return finalRows.map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n")
    }

    static func isMarkdownDocument(_ fileURL: URL?) -> Bool {
        guard let ext = fileURL?.pathExtension.lowercased() else { return true }
        return ["md", "markdown", "mdown", "mkd"].contains(ext)
    }

    static func languageHint(for fileURL: URL?) -> String {
        guard let ext = fileURL?.pathExtension.lowercased(), !ext.isEmpty else { return "plain" }
        return ext
    }

    private static func parseUncached(_ text: String, fileURL: URL?) -> BlockDocument {
        guard isMarkdownDocument(fileURL) else {
            var block = DocumentBlock.empty(.source)
            block.text = text
            block.metadata.language = languageHint(for: fileURL)
            return BlockDocument(blocks: [block])
        }

        let lines = text.components(separatedBy: .newlines)
        var blocks: [DocumentBlock] = []
        var index = 0
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            let content = paragraphBuffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !content.isEmpty {
                blocks.append(DocumentBlock(kind: .paragraph, text: content))
            }
            paragraphBuffer.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if line.hasPrefix("```") {
                flushParagraph()
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count && !lines[index].hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                var block = DocumentBlock.empty(.code)
                block.text = codeLines.joined(separator: "\n")
                block.metadata.language = language.isEmpty ? "text" : language
                blocks.append(block)
                index += 1
                continue
            }

            if line.hasPrefix("<details") {
                flushParagraph()
                let title = extractSummary(from: line)
                index += 1
                var contentLines: [String] = []
                while index < lines.count && lines[index] != "</details>" {
                    contentLines.append(lines[index])
                    index += 1
                }
                var block = DocumentBlock.empty(.toggle)
                block.metadata.secondaryText = title
                block.metadata.isCollapsed = !line.contains(" open")
                block.text = contentLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                blocks.append(block)
                index += 1
                continue
            }

            if let heading = parseHeading(line) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(DocumentBlock(kind: .divider, text: ""))
                index += 1
                continue
            }

            if let callout = parseCallout(lines: lines, start: index) {
                flushParagraph()
                blocks.append(callout.block)
                index = callout.nextIndex
                continue
            }

            if let task = parseTask(line) {
                flushParagraph()
                let parsed = parseContinuationBody(lines: lines, start: index + 1)
                var block = task
                if !parsed.lines.isEmpty {
                    block.text += "\n" + parsed.lines.joined(separator: "\n")
                }
                blocks.append(block)
                index = parsed.nextIndex
                continue
            }

            if let listBlock = parseList(line) {
                flushParagraph()
                let parsed = parseContinuationBody(lines: lines, start: index + 1)
                var block = listBlock
                if !parsed.lines.isEmpty {
                    block.text += "\n" + parsed.lines.joined(separator: "\n")
                }
                blocks.append(block)
                index = parsed.nextIndex
                continue
            }

            if looksLikeTableRow(line) && index + 1 < lines.count && isTableSeparator(lines[index + 1]) {
                flushParagraph()
                var tableLines = [line, lines[index + 1]]
                index += 2
                while index < lines.count && looksLikeTableRow(lines[index]) {
                    tableLines.append(lines[index])
                    index += 1
                }
                blocks.append(DocumentBlock(kind: .table, text: tableLines.joined(separator: "\n")))
                continue
            }

            if let image = parseImage(line) {
                flushParagraph()
                blocks.append(image)
                index += 1
                continue
            }

            if let file = parseFile(line) {
                flushParagraph()
                blocks.append(file)
                index += 1
                continue
            }

            if let url = parseURL(line) {
                flushParagraph()
                blocks.append(url)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                let parsed = parseQuote(lines: lines, start: index)
                blocks.append(parsed.block)
                index = parsed.nextIndex
                continue
            }

            paragraphBuffer.append(line)
            index += 1
        }

        flushParagraph()
        return BlockDocument(blocks: blocks.isEmpty ? [.empty(.paragraph)] : blocks)
    }

    private static func parseHeading(_ line: String) -> DocumentBlock? {
        guard let match = line.firstMatch(of: /^(#{1,6})\s+(.+)$/) else { return nil }
        let level = min(match.1.count, 3)
        let kind: DocumentBlockKind = level == 1 ? .heading1 : level == 2 ? .heading2 : .heading3
        return DocumentBlock(kind: kind, text: String(match.2))
    }

    private static func parseTask(_ line: String) -> DocumentBlock? {
        guard let match = line.firstMatch(of: /^(\s*)[-*]\s+\[( |x|X)\]\s+(.+)$/) else { return nil }
        var block = DocumentBlock(kind: .todo, text: String(match.3))
        block.metadata.checked = String(match.2).lowercased() == "x"
        block.metadata.indentLevel = indentationLevel(String(match.1))
        return block
    }

    private static func parseList(_ line: String) -> DocumentBlock? {
        if let match = line.firstMatch(of: /^(\s*)[-*]\s+(.+)$/) {
            var block = DocumentBlock(kind: .bulletedList, text: String(match.2))
            block.metadata.indentLevel = indentationLevel(String(match.1))
            return block
        }
        if let match = line.firstMatch(of: /^(\s*)\d+\.\s+(.+)$/) {
            var block = DocumentBlock(kind: .numberedList, text: String(match.2))
            block.metadata.indentLevel = indentationLevel(String(match.1))
            return block
        }
        return nil
    }

    private static func parseImage(_ line: String) -> DocumentBlock? {
        guard let match = line.firstMatch(of: /^!\[(.*)\]\((.+)\)$/) else { return nil }
        var block = DocumentBlock.empty(.image)
        block.metadata.secondaryText = String(match.1)
        block.metadata.resource = String(match.2)
        return block
    }

    private static func parseFile(_ line: String) -> DocumentBlock? {
        guard let match = line.firstMatch(of: /^::file\[(.*)\]\((.+)\)$/) else { return nil }
        var block = DocumentBlock.empty(.file)
        block.text = String(match.1)
        block.metadata.secondaryText = String(match.1)
        block.metadata.resource = String(match.2)
        return block
    }

    private static func parseURL(_ line: String) -> DocumentBlock? {
        // Standard markdown link: [title](url)
        if let match = line.firstMatch(of: /^\[(.+)\]\((.+)\)$/) {
            var block = DocumentBlock.empty(.url)
            block.text = String(match.1)
            block.metadata.resource = String(match.2)
            return block
        }
        // Custom format: ::url[title](url)
        if let match = line.firstMatch(of: /^::url\[(.*)\]\((.+)\)$/) {
            var block = DocumentBlock.empty(.url)
            block.text = String(match.1)
            block.metadata.resource = String(match.2)
            return block
        }
        // Custom format: ::url(url)
        if let match = line.firstMatch(of: /^::url\((.+)\)$/) {
            var block = DocumentBlock.empty(.url)
            block.metadata.resource = String(match.1)
            return block
        }
        // Bare URL on its own line
        if let match = line.firstMatch(of: /^(https?:\/\/\S+)$/) {
            var block = DocumentBlock.empty(.url)
            block.metadata.resource = String(match.1)
            return block
        }
        return nil
    }

    private static func parseCallout(lines: [String], start: Int) -> (block: DocumentBlock, nextIndex: Int)? {
        let line = lines[start].trimmingCharacters(in: .whitespaces)
        guard let match = line.firstMatch(of: /^>\s+\[!(\w+)\]\s*(.*)$/) else { return nil }
        let tone = String(match.1).lowercased()
        let title = String(match.2)
        var body: [String] = []
        var index = start + 1
        while index < lines.count {
            let current = lines[index].trimmingCharacters(in: .whitespaces)
            guard current.hasPrefix(">") else { break }
            body.append(current.dropFirst().trimmingCharacters(in: .whitespaces))
            index += 1
        }
        var block = DocumentBlock.empty(.callout)
        block.metadata.tone = tone
        block.metadata.secondaryText = title.isEmpty ? "提示" : title
        block.text = body.joined(separator: "\n")
        return (block, index)
    }

    private static func parseQuote(lines: [String], start: Int) -> (block: DocumentBlock, nextIndex: Int) {
        var body: [String] = []
        var index = start
        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            // Stop at non-quote lines or callout markers (> [!TYPE])
            guard trimmed.hasPrefix(">"), !trimmed.hasPrefix("> [!") else { break }
            // Strip exactly ONE leading > and optional single space after it,
            // preserving any further > markers for nested quotes.
            var rest = trimmed.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
            body.append(String(rest))
            index += 1
        }
        // Trim trailing blank lines from the collected body
        while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            body.removeLast()
        }
        var block = DocumentBlock(kind: .quote, text: body.joined(separator: "\n"))
        block.metadata.indentLevel = 0
        return (block, index)
    }

    private static func parseContinuationBody(lines: [String], start: Int) -> (lines: [String], nextIndex: Int) {
        var continuation: [String] = []
        var index = start

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Empty line ends continuation
            if trimmed.isEmpty {
                break
            }

            // Check if this line starts a new list item (bullet or number with optional checkbox)
            // This stops continuation when we encounter a nested or sibling list item
            let isListItem = trimmed.firstMatch(of: /^[-*]\s+/) != nil ||
                            trimmed.firstMatch(of: /^\d+\.\s+/) != nil ||
                            trimmed.firstMatch(of: /^[-*]\s+\[[ xX]\]/) != nil

            if isListItem {
                // This is a list item - end continuation
                // It will be parsed as a separate block on the next iteration
                break
            }

            // Indented non-list content is part of continuation (soft-wrapped text)
            if line.hasPrefix("  ") || line.hasPrefix("\t") {
                continuation.append(line.trimmingCharacters(in: .whitespaces))
                index += 1
                continue
            }

            // Non-indented content that's not a list item ends continuation
            break
        }

        return (continuation, index)
    }

    private static func extractSummary(from line: String) -> String {
        guard let range = line.range(of: "<summary>")?.upperBound,
              let end = line.range(of: "</summary>")?.lowerBound else { return "折叠标题" }
        return String(line[range..<end])
    }

    private static func parseTableCells(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let inner = trimmed.hasPrefix("|") ? String(trimmed.dropFirst()) : trimmed
        let stripped = inner.hasSuffix("|") ? String(inner.dropLast()) : inner
        return stripped.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func looksLikeTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.hasSuffix("|")
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return false }
        return trimmed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func isDivider(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        return stripped == "---" || stripped == "***" || stripped == "___"
    }

    private static func requiresTightSpacing(previous: DocumentBlockKind, next: DocumentBlockKind) -> Bool {
        let tightKinds: Set<DocumentBlockKind> = [.bulletedList, .numberedList, .todo, .quote]
        return previous == next && tightKinds.contains(previous)
    }

    private static func serializeListItem(prefix: String, body: String, indentLevel: Int) -> String {
        let indentation = String(repeating: "  ", count: max(0, indentLevel))
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return indentation + prefix.trimmingCharacters(in: .whitespaces) }
        let remainder = lines.dropFirst().map { indentation + "  \($0)" }
        return ([indentation + prefix + first] + remainder).joined(separator: "\n")
    }

    private static func serializeQuotedLines(_ body: String, level: Int = 1) -> String {
        let prefix = String(repeating: ">", count: max(level, 1))
        return body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let text = String(line)
                return text.isEmpty ? prefix : "\(prefix) \(text)"
            }
            .joined(separator: "\n")
    }

    private static func indentationLevel(_ whitespace: String) -> Int {
        let spaces = whitespace.replacingOccurrences(of: "\t", with: "    ").count
        return max(0, spaces / 2)
    }

    private static func normalizeTableRow(_ row: [String], columnCount: Int) -> [String] {
        var normalized = row
        if normalized.count < columnCount {
            normalized.append(contentsOf: Array(repeating: "", count: columnCount - normalized.count))
        }
        return Array(normalized.prefix(columnCount))
    }

    private static func blockToSourceText(_ block: DocumentBlock) -> String {
        switch block.kind {
        case .source, .paragraph:
            return block.text
        case .heading1, .heading2, .heading3, .quote, .bulletedList, .numberedList, .todo, .code, .divider, .table, .image, .url, .file, .callout, .toggle:
            return serialize(BlockDocument(blocks: [block]), fileURL: URL(fileURLWithPath: "/tmp/file.md"))
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

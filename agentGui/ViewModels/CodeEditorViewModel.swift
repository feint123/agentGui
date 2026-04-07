import Foundation

struct CodeEditorCursorStatus: Equatable, Sendable {
    let line: Int
    let column: Int
}

struct CodeEditorIndentationStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case spaces
        case tabs
        case unknown
    }

    let kind: Kind
    let width: Int
}

struct CodeEditorLineDiagnosticSummary: Equatable, Sendable {
    let highestSeverity: LSPDiagnosticSeverity
    let messageCount: Int
}

struct CodeEditorStatusBarState: Equatable, Sendable {
    let cursor: CodeEditorCursorStatus
    let languageLabel: String
    let indentation: CodeEditorIndentationStatus
    let lspStateText: String
    let errorCount: Int
    let warningCount: Int
    var selectionCount: Int = 1
}

enum CodeEditorSemanticNavigationAction: Equatable, Sendable {
    case revealInCurrentFile(CodeEditorRevealRequest)
    case openFileAndReveal(URL, CodeEditorRevealRequest)
    case unsupported
}

struct CodeEditorDocumentSymbolItem: Equatable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let subtitle: String?
    let revealRequest: CodeEditorRevealRequest

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String?,
        revealRequest: CodeEditorRevealRequest
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.revealRequest = revealRequest
    }
}

enum CodeEditorViewModel {
    static func findMatchSnapshot(
        document: CodeEditorDocument,
        findState: CodeEditorFindState,
        visibleLineRange: ClosedRange<Int>
    ) -> CodeEditorDecorationSnapshot {
        let query = findState.query
        guard findState.isPresented, query.isEmpty == false else {
            return .empty(version: document.version, lineRange: visibleLineRange)
        }

        let matches = utf16Matches(
            of: query,
            in: document.text,
            caseSensitive: findState.caseSensitive
        )
        var spansByLine: [Int: [CodeEditorDecorationSpan]] = [:]

        for (index, range) in matches.enumerated() {
            let line = document.location(ofUTF16Offset: range.location).line
            guard visibleLineRange.contains(line) else {
                continue
            }

            let kind: CodeEditorDecorationKind = findState.selectedMatchIndex == index ? .activeFindMatch : .findMatch
            spansByLine[line, default: []].append(
                CodeEditorDecorationSpan(utf16Range: range, line: line, kind: kind)
            )
        }

        return CodeEditorDecorationSnapshot(
            version: document.version,
            lineRange: visibleLineRange,
            spansByLine: spansByLine
        )
    }

    static func selectionMatchSnapshot(
        document: CodeEditorDocument,
        selectedRange: NSRange,
        visibleLineRange: ClosedRange<Int>
    ) -> CodeEditorDecorationSnapshot {
        let selectionText = selectedText(in: document.text, range: selectedRange)
        guard shouldHighlightSelection(selectionText, selectedRange: selectedRange, document: document) else {
            return .empty(version: document.version, lineRange: visibleLineRange)
        }

        let matches = utf16Matches(
            of: selectionText,
            in: document.text,
            caseSensitive: true
        )
        var spansByLine: [Int: [CodeEditorDecorationSpan]] = [:]

        for range in matches {
            let line = document.location(ofUTF16Offset: range.location).line
            guard visibleLineRange.contains(line) else {
                continue
            }

            spansByLine[line, default: []].append(
                CodeEditorDecorationSpan(utf16Range: range, line: line, kind: .selectionMatch)
            )
        }

        return CodeEditorDecorationSnapshot(
            version: document.version,
            lineRange: visibleLineRange,
            spansByLine: spansByLine
        )
    }

    static func diagnosticUnderlineSnapshot(
        diagnostics: LSPDiagnosticsSnapshot?,
        document: CodeEditorDocument,
        visibleLineRange: ClosedRange<Int>
    ) -> CodeEditorDecorationSnapshot {
        guard let diagnostics else {
            return .empty(version: document.version, lineRange: visibleLineRange)
        }

        var spansByLine: [Int: [CodeEditorDecorationSpan]] = [:]

        for diagnostic in diagnostics.diagnostics {
            guard let line = diagnostic.line, line >= 0 else {
                continue
            }

            let displayLine = line + 1
            guard visibleLineRange.contains(displayLine) else {
                continue
            }

            let startColumn = max((diagnostic.character ?? 0) + 1, 1)
            let startOffset = document.utf16Offset(line: displayLine, column: startColumn)
            let defaultEndOffset = min(startOffset + 1, document.text.utf16.count)

            let endOffset: Int
            if let endLine = diagnostic.endLine,
               let endCharacter = diagnostic.endCharacter,
               endLine == line {
                endOffset = max(
                    document.utf16Offset(line: displayLine, column: max(endCharacter + 1, startColumn)),
                    defaultEndOffset
                )
            } else {
                endOffset = defaultEndOffset
            }

            let safeLength = max(1, endOffset - startOffset)
            let range = NSRange(location: startOffset, length: safeLength)
            spansByLine[displayLine, default: []].append(
                CodeEditorDecorationSpan(
                    utf16Range: range,
                    line: displayLine,
                    kind: .diagnosticUnderline(diagnostic.severity)
                )
            )
        }

        return CodeEditorDecorationSnapshot(
            version: document.version,
            lineRange: visibleLineRange,
            spansByLine: spansByLine
        )
    }

    static func makeStatusBarState(
        document: CodeEditorDocument,
        selectedRange: NSRange,
        fileURL: URL?,
        lspStatus: WorkspacePanelLSPStatusPresentation?,
        diagnostics: LSPDiagnosticsSnapshot?
    ) -> CodeEditorStatusBarState {
        let textLength = document.text.utf16.count
        let clampedLocation = min(max(selectedRange.location, 0), textLength)
        let location = document.location(ofUTF16Offset: clampedLocation)

        let errorCount: Int
        let warningCount: Int
        if let lspStatus {
            errorCount = lspStatus.errorCount
            warningCount = lspStatus.warningCount
        } else if let diagnostics {
            errorCount = diagnostics.diagnostics.filter { $0.severity == .error }.count
            warningCount = diagnostics.diagnostics.filter { $0.severity == .warning }.count
        } else {
            errorCount = 0
            warningCount = 0
        }

        return CodeEditorStatusBarState(
            cursor: CodeEditorCursorStatus(line: location.line, column: location.column),
            languageLabel: fileURL.flatMap { CodeSyntaxHighlightingService.languageIdentifier(for: $0) } ?? "plain text",
            indentation: detectIndentation(in: document.text),
            lspStateText: lspStatus?.stateText ?? "未连接",
            errorCount: errorCount,
            warningCount: warningCount
        )
    }

    static func diagnosticsByLine(_ snapshot: LSPDiagnosticsSnapshot) -> [Int: CodeEditorLineDiagnosticSummary] {
        var summaries: [Int: CodeEditorLineDiagnosticSummary] = [:]

        for diagnostic in snapshot.diagnostics {
            guard let line = diagnostic.line, line >= 0 else {
                continue
            }

            let lineNumber = line + 1
            if let existing = summaries[lineNumber] {
                summaries[lineNumber] = CodeEditorLineDiagnosticSummary(
                    highestSeverity: maxSeverity(existing.highestSeverity, diagnostic.severity),
                    messageCount: existing.messageCount + 1
                )
            } else {
                summaries[lineNumber] = CodeEditorLineDiagnosticSummary(
                    highestSeverity: diagnostic.severity,
                    messageCount: 1
                )
            }
        }

        return summaries
    }

    static func detectIndentation(in text: String) -> CodeEditorIndentationStatus {
        let lines = text.split(whereSeparator: \ .isNewline)
        var spaceWidths: [Int] = []
        var tabWidths: [Int] = []

        for line in lines {
            guard let first = line.first, first == " " || first == "\t" else {
                continue
            }

            if first == " " {
                let width = line.prefix { $0 == " " }.count
                if width > 0 {
                    spaceWidths.append(width)
                }
            } else {
                let width = line.prefix { $0 == "\t" }.count
                if width > 0 {
                    tabWidths.append(width)
                }
            }
        }

        if let spaceWidth = preferredWidth(from: spaceWidths), tabWidths.isEmpty || spaceWidths.count >= tabWidths.count {
            return CodeEditorIndentationStatus(kind: .spaces, width: spaceWidth)
        }

        if let tabWidth = preferredWidth(from: tabWidths) {
            return CodeEditorIndentationStatus(kind: .tabs, width: tabWidth)
        }

        return CodeEditorIndentationStatus(kind: .unknown, width: 0)
    }

    static func navigationAction(
        currentFileURL: URL,
        revealRequest: CodeEditorRevealRequest
    ) -> CodeEditorSemanticNavigationAction {
        let currentFileURL = currentFileURL.standardizedFileURL
        let targetFileURL = revealRequest.fileURL.standardizedFileURL

        if targetFileURL == currentFileURL {
            return .revealInCurrentFile(revealRequest)
        }

        if targetFileURL.isFileURL, targetFileURL.path.isEmpty == false {
            return .openFileAndReveal(targetFileURL, revealRequest)
        }

        return .unsupported
    }

    static func flattenedDocumentSymbols(
        _ symbols: [LSPDocumentSymbol],
        fileURL: URL
    ) -> [CodeEditorDocumentSymbolItem] {
        flatten(symbols, depth: 0, fileURL: fileURL.standardizedFileURL)
    }

    private static func preferredWidth(from widths: [Int]) -> Int? {
        guard !widths.isEmpty else {
            return nil
        }

        let counts = widths.reduce(into: [Int: Int]()) { partialResult, width in
            partialResult[width, default: 0] += 1
        }

        return counts.max { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key > rhs.key
            }
            return lhs.value < rhs.value
        }?.key
    }

    private static func maxSeverity(
        _ lhs: LSPDiagnosticSeverity,
        _ rhs: LSPDiagnosticSeverity
    ) -> LSPDiagnosticSeverity {
        severityRank(lhs) <= severityRank(rhs) ? lhs : rhs
    }

    private static func severityRank(_ severity: LSPDiagnosticSeverity) -> Int {
        switch severity {
        case .error:
            return 0
        case .warning:
            return 1
        case .information:
            return 2
        case .hint:
            return 3
        }
    }

    private static func selectedText(in text: String, range: NSRange) -> String {
        let nsText = text as NSString
        guard range.location >= 0,
              range.length > 0,
              range.upperBound <= nsText.length else {
            return ""
        }

        return nsText.substring(with: range)
    }

    private static func shouldHighlightSelection(
        _ selectionText: String,
        selectedRange: NSRange,
        document: CodeEditorDocument
    ) -> Bool {
        guard selectedRange.length >= 2, selectedRange.length <= 120 else {
            return false
        }

        let lineRange = document.lineRange(for: selectedRange)
        guard lineRange.startLine == lineRange.endLine else {
            return false
        }

        return selectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func utf16Matches(
        of query: String,
        in text: String,
        caseSensitive: Bool
    ) -> [NSRange] {
        guard query.isEmpty == false else {
            return []
        }

        let nsText = text as NSString
        let nsQuery = query as NSString
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var matches: [NSRange] = []
        var searchRange = NSRange(location: 0, length: nsText.length)

        while searchRange.length > 0 {
            let foundRange = nsText.range(of: nsQuery as String, options: options, range: searchRange)
            guard foundRange.location != NSNotFound else {
                break
            }

            matches.append(foundRange)
            let nextLocation = foundRange.location + max(foundRange.length, 1)
            guard nextLocation <= nsText.length else {
                break
            }

            searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
        }

        return matches
    }

    private static func flatten(
        _ symbols: [LSPDocumentSymbol],
        depth: Int,
        fileURL: URL
    ) -> [CodeEditorDocumentSymbolItem] {
        symbols.flatMap { symbol in
            let title = String(repeating: "  ", count: depth) + symbol.name
            let subtitle = symbol.detail?.isEmpty == false ? symbol.detail : nil
            let revealRequest = CodeEditorRevealRequest(
                fileURL: fileURL,
                line: symbol.line + 1,
                column: symbol.character + 1,
                reason: .documentSymbol
            )

            return [
                CodeEditorDocumentSymbolItem(
                    title: title,
                    subtitle: subtitle,
                    revealRequest: revealRequest
                )
            ] + flatten(symbol.children, depth: depth + 1, fileURL: fileURL)
        }
    }

    // MARK: - Symbol Breadcrumb Path

    /// 返回包含 cursorLine 的 symbol 路径（从最外层到最内层）。
    /// cursorLine 是 0-based（与 LSPDocumentSymbol.line / endLine 的坐标系相同）。
    ///
    /// 算法：对每级 symbols 深度优先搜索包含 cursorLine 的 symbol，
    /// 递归取最深匹配。对于没有 endLine 的 SymbolInformation 格式，
    /// 回退到取 line 最大且 ≤ cursorLine 的 symbol（Zed 启发式）。
    static func symbolBreadcrumbPath(
        for cursorLine: Int,
        in symbols: [LSPDocumentSymbol]
    ) -> [LSPDocumentSymbol] {
        // 先尝试精确 range 包含（DocumentSymbol 格式，有 endLine）
        let symbolsWithRange = symbols.filter { $0.endLine != nil }
        if !symbolsWithRange.isEmpty {
            for symbol in symbolsWithRange {
                guard let endLine = symbol.endLine else { continue }
                guard (symbol.line...endLine).contains(cursorLine) else { continue }
                let childPath = symbolBreadcrumbPath(for: cursorLine, in: symbol.children)
                return [symbol] + childPath
            }
            return []
        }

        // 回退：SymbolInformation 格式（无 endLine），Zed 策略
        // 取 line 最大且 ≤ cursorLine 的 symbol
        let fallback = symbols
            .filter { $0.line <= cursorLine }
            .max(by: { $0.line < $1.line })
        return fallback.map { [$0] } ?? []
    }

    /// LSP SymbolKind 整数 → SF Symbols 名称（用于面包屑图标）。
    /// 返回 nil 表示未识别的 kind，调用方可用通用图标替代。
    /// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#symbolKind
    static func symbolKindIconName(for kind: Int) -> String? {
        switch kind {
        case 1:  return "doc.text"            // File
        case 2:  return "square.stack"        // Module
        case 3:  return "square.stack"        // Namespace
        case 4:  return "shippingbox"         // Package
        case 5:  return "c.square"            // Class
        case 6:  return "m.square"            // Method
        case 7:  return "p.square"            // Property
        case 8:  return "f.square"            // Field
        case 9:  return "c.square.fill"       // Constructor
        case 10: return "e.square"            // Enum
        case 11: return "i.square"            // Interface
        case 12: return "f.square.fill"       // Function
        case 13: return "v.square"            // Variable
        case 14: return "number.square"       // Constant
        case 15: return "s.square"            // String
        case 16: return "n.square"            // Number
        case 17: return "b.square"            // Boolean
        case 18: return "a.square"            // Array
        case 19: return "o.square"            // Object
        case 20: return "k.square"            // Key
        case 21: return "x.square"            // Null
        case 22: return "e.square.fill"       // EnumMember
        case 23: return "s.square.fill"       // Struct
        case 24: return "calendar"            // Event
        case 25: return "o.square.fill"       // Operator
        case 26: return "t.square"            // TypeParameter
        default: return nil
        }
    }
}
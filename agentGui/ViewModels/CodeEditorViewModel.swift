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
}

enum CodeEditorViewModel {
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
}
import Foundation

struct CodeEditorFindState: Equatable, Sendable {
    var isPresented: Bool
    var query: String
    var caseSensitive: Bool
    var selectedMatchIndex: Int?

    static let inactive = Self(
        isPresented: false,
        query: "",
        caseSensitive: false,
        selectedMatchIndex: nil
    )
}

enum CodeEditorFindIntent: Equatable, Sendable {
    case present
    case dismiss
    case nextMatch
    case previousMatch
}

enum CodeEditorDecorationKind: Equatable, Sendable {
    case findMatch
    case activeFindMatch
    case selectionMatch
    case diagnosticUnderline(LSPDiagnosticSeverity)
}

struct CodeEditorDecorationSpan: Equatable, Sendable, Identifiable {
    let id: String
    let utf16Range: NSRange
    let line: Int
    let kind: CodeEditorDecorationKind

    init(
        utf16Range: NSRange,
        line: Int,
        kind: CodeEditorDecorationKind
    ) {
        self.utf16Range = utf16Range
        self.line = line
        self.kind = kind
        self.id = "\(line):\(utf16Range.location):\(utf16Range.length):\(Self.kindIdentifier(kind))"
    }

    private static func kindIdentifier(_ kind: CodeEditorDecorationKind) -> String {
        switch kind {
        case .findMatch:
            return "find"
        case .activeFindMatch:
            return "active-find"
        case .selectionMatch:
            return "selection"
        case let .diagnosticUnderline(severity):
            return "diagnostic-\(severity.rawValue)"
        }
    }
}

struct CodeEditorDecorationSnapshot: Equatable, Sendable {
    let version: Int
    let lineRange: ClosedRange<Int>
    let spansByLine: [Int: [CodeEditorDecorationSpan]]

    static func empty(version: Int, lineRange: ClosedRange<Int>) -> Self {
        Self(version: version, lineRange: lineRange, spansByLine: [:])
    }
}
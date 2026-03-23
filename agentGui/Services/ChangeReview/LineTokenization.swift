import Foundation

struct TokenizedText: Sendable, Equatable {
    let lines: [String]
    let hasTrailingNewline: Bool
}

enum LineTokenization {
    static func tokenize(_ text: String?) -> TokenizedText {
        guard let text else {
            return TokenizedText(lines: [], hasTrailingNewline: true)
        }
        guard !text.isEmpty else {
            return TokenizedText(lines: [], hasTrailingNewline: false)
        }

        let hasTrailingNewline = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if hasTrailingNewline, lines.last == "" {
            lines.removeLast()
        }
        return TokenizedText(lines: lines, hasTrailingNewline: hasTrailingNewline)
    }
}
import Foundation

struct ChatInputCommandParser {
    struct DetectedSlashQuery: Equatable {
        let rawToken: String
        let query: String
    }

    struct ReplacementResult: Equatable {
        let updatedText: String
        let directive: ChatInputDirective?
    }

    static func detectSlashQuery(in text: String) -> DetectedSlashQuery? {
        guard let token = currentSlashToken(in: text) else { return nil }
        guard token != "/" else {
            return DetectedSlashQuery(rawToken: token, query: "")
        }
        guard token.hasPrefix("/") else { return nil }

        let query = String(token.dropFirst())
        guard !query.contains("/") else { return nil }
        return DetectedSlashQuery(rawToken: token, query: query)
    }

    static func makeDirective(from item: ChatSlashCommandItem) -> ChatInputDirective? {
        switch item.payload {
        case .skill(let directoryName):
            return .skill(SkillInputDirective(directoryName: directoryName, displayName: item.title))
        case .acpCommand:
            return nil
        }
    }

    static func replacingSlashToken(in text: String, selectedItem: ChatSlashCommandItem) -> ReplacementResult {
        let directive = makeDirective(from: selectedItem)
        guard let range = slashTokenRange(in: text) else {
            return ReplacementResult(updatedText: text, directive: directive)
        }

        var updated = text
        switch selectedItem.payload {
        case .skill:
            updated.replaceSubrange(range, with: "")
            updated = updated.replacingOccurrences(of: "  ", with: " ")
            updated = updated.trimmingCharacters(in: .whitespacesAndNewlines)
        case .acpCommand(let name, _, _, _):
            updated.replaceSubrange(range, with: "/\(name)")
            if range.upperBound == text.endIndex {
                updated.append(" ")
            }
        }
        return ReplacementResult(updatedText: updated, directive: directive)
    }

    private static func currentSlashToken(in text: String) -> String? {
        guard !text.isEmpty else { return nil }

        if let lastWhitespace = text.lastIndex(where: { $0.isWhitespace || $0.isNewline }) {
            let afterWhitespace = text.index(after: lastWhitespace)
            guard afterWhitespace < text.endIndex else { return nil }
            let token = String(text[afterWhitespace...])
            return token.hasPrefix("/") ? token : nil
        }

        return text.hasPrefix("/") ? text : nil
    }

    private static func slashTokenRange(in text: String) -> Range<String.Index>? {
        let pattern = #"(?:(?<=^)|(?<=[\s\n]))/[^\s/]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let tokenRange = Range(match.range, in: text) else {
            return nil
        }
        return tokenRange
    }
}
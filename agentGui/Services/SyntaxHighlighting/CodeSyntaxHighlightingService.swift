import AppKit
import Highlightr

enum CodeHighlightAppearance: Hashable {
    case light
    case dark
}

struct CodeHighlightTheme: Hashable {
    let appearance: CodeHighlightAppearance
    let fontSize: CGFloat
    let themeName: String

    static func `for`(appearance: CodeHighlightAppearance, fontSize: CGFloat) -> CodeHighlightTheme {
        CodeHighlightTheme(
            appearance: appearance,
            fontSize: fontSize,
            themeName: appearance == .dark ? "xcode-dark" : "xcode"
        )
    }
}

protocol CodeSyntaxHighlighting {
    func highlightedString(
        code: String,
        language: String?,
        appearance: CodeHighlightAppearance,
        fontSize: CGFloat
    ) -> NSAttributedString
}

protocol CodeSyntaxHighlightingEngine: AnyObject {
    func highlight(code: String, language: String?, theme: CodeHighlightTheme) -> NSAttributedString?
}

@MainActor
final class CodeSyntaxHighlightingService: CodeSyntaxHighlighting {
    static let shared = CodeSyntaxHighlightingService()

    private struct CacheKey: Hashable {
        let code: String
        let language: String?
        let appearance: CodeHighlightAppearance
        let fontSize: CGFloat
    }

    private let engine: CodeSyntaxHighlightingEngine
    private var cache: [CacheKey: NSAttributedString] = [:]

    init() {
        self.engine = LiveCodeSyntaxHighlightingEngine()
    }

    init(engine: CodeSyntaxHighlightingEngine) {
        self.engine = engine
    }

    func highlightedString(
        code: String,
        language: String?,
        appearance: CodeHighlightAppearance,
        fontSize: CGFloat
    ) -> NSAttributedString {
        let normalizedLanguage = Self.normalizedLanguage(language)
        let key = CacheKey(
            code: code,
            language: normalizedLanguage,
            appearance: appearance,
            fontSize: fontSize
        )

        if let cached = cache[key] {
            return cached
        }

        let theme = CodeHighlightTheme.for(appearance: appearance, fontSize: fontSize)
        let highlighted = engine.highlight(code: code, language: normalizedLanguage, theme: theme)
        let result = highlighted.map(Self.sanitizedHighlightedString) ?? Self.makeFallbackString(code: code, fontSize: fontSize)

        cache[key] = result
        return result
    }

    static func liveForTesting() -> CodeSyntaxHighlightingService {
        CodeSyntaxHighlightingService()
    }

    static func normalizedLanguage(_ language: String?) -> String? {
        guard let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !trimmed.isEmpty else {
            return nil
        }

        switch trimmed {
        case "text", "plain", "plaintext", "txt":
            return nil
        default:
            return trimmed
        }
    }

    private static func sanitizedHighlightedString(_ attributedString: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedString)
        let fullRange = NSRange(location: 0, length: mutable.length)
        guard fullRange.length > 0 else { return mutable }

        mutable.removeAttribute(.backgroundColor, range: fullRange)
        return mutable
    }

    private static func makeFallbackString(code: String, fontSize: CGFloat) -> NSAttributedString {
        NSAttributedString(
            string: code,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        )
    }
}

@MainActor
private final class LiveCodeSyntaxHighlightingEngine: CodeSyntaxHighlightingEngine {
    private lazy var highlightr = Highlightr()
    private var activeThemeName: String?
    private var cachedSupportedLanguages: Set<String>?

    func highlight(code: String, language: String?, theme: CodeHighlightTheme) -> NSAttributedString? {
        guard let highlightr else {
            return nil
        }

        if activeThemeName != theme.themeName {
            guard highlightr.setTheme(to: theme.themeName) else {
                return nil
            }
            activeThemeName = theme.themeName
        }

        if let language, !supportedLanguages(using: highlightr).contains(language) {
            return nil
        }

        return highlightr.highlight(code, as: language)
    }

    private func supportedLanguages(using highlightr: Highlightr) -> Set<String> {
        if let cachedSupportedLanguages {
            return cachedSupportedLanguages
        }

        let supported = Set(highlightr.supportedLanguages().map { $0.lowercased() })
        cachedSupportedLanguages = supported
        return supported
    }
}
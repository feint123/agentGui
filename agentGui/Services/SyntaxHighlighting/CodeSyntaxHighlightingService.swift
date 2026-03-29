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

final class CodeSyntaxHighlightingService: CodeSyntaxHighlighting {
    static let shared = CodeSyntaxHighlightingService()

    private static let languageAliases: [String: String?] = [
        "text": nil,
        "plain": nil,
        "plaintext": nil,
        "txt": nil,
        "bash": "bash",
        "shell": "bash",
        "sh": "bash",
        "zsh": "bash",
        "js": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "jsx": "javascript",
        "ts": "typescript",
        "tsx": "typescript",
        "yml": "yaml",
        "md": "markdown",
        "rb": "ruby",
        "py": "python",
        "kt": "kotlin",
        "kts": "kotlin",
        "rs": "rust",
        "plist": "xml",
        "ps1": "powershell",
        "cs": "csharp",
        "cc": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",
        "hxx": "cpp"
    ]

    private struct CacheKey: Hashable {
        let code: String
        let language: String?
        let appearance: CodeHighlightAppearance
        let fontSize: CGFloat
    }

    private let engine: CodeSyntaxHighlightingEngine
    private let cacheLock = NSLock()
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

        cacheLock.lock()
        let cached = cache[key]
        cacheLock.unlock()
        if let cached {
            return cached
        }

        let theme = CodeHighlightTheme.for(appearance: appearance, fontSize: fontSize)
        let highlighted = engine.highlight(code: code, language: normalizedLanguage, theme: theme)
        let result = highlighted.map(Self.sanitizedHighlightedString) ?? Self.makeFallbackString(code: code, fontSize: fontSize)

        cacheLock.lock()
        cache[key] = result
        cacheLock.unlock()
        return result
    }

    static func liveForTesting() -> CodeSyntaxHighlightingService {
        CodeSyntaxHighlightingService()
    }

    static func languageIdentifier(for fileURL: URL) -> String? {
        normalizedLanguage(fileURL.pathExtension)
    }

    static func normalizedLanguage(_ language: String?) -> String? {
        guard let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !trimmed.isEmpty else {
            return nil
        }

        if let aliased = languageAliases[trimmed] {
            return aliased
        }

        return trimmed
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

private final class LiveCodeSyntaxHighlightingEngine: CodeSyntaxHighlightingEngine {
    private lazy var highlightr = Highlightr()
    private let stateLock = NSLock()
    private var activeThemeName: String?
    private var cachedSupportedLanguages: Set<String>?

    func highlight(code: String, language: String?, theme: CodeHighlightTheme) -> NSAttributedString? {
        stateLock.lock()
        defer { stateLock.unlock() }

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
import AppKit
import Testing
@testable import agentGui

@MainActor
struct CodeSyntaxHighlightingServiceTests {
    @Test
    func normalizesPlaintextLanguagesToFallback() {
        let engine = RecordingHighlightEngine()
        let service = CodeSyntaxHighlightingService(engine: engine)

        _ = service.highlightedString(
            code: "let value = 1",
            language: "plaintext",
            appearance: .light,
            fontSize: 12
        )

        #expect(engine.recordedLanguages == [nil])
    }

    @Test
    func unsupportedLanguageFallsBackToPlainMonospace() {
        let engine = RecordingHighlightEngine(unsupportedLanguages: ["unknownlang"])
        let service = CodeSyntaxHighlightingService(engine: engine)

        let result = service.highlightedString(
            code: "value",
            language: "unknownlang",
            appearance: .dark,
            fontSize: 14
        )

        #expect(result.string == "value")
        let font = result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        let color = result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == NSColor.labelColor)
    }

    @Test
    func normalizesCommonFileExtensionAliases() {
        let engine = RecordingHighlightEngine()
        let service = CodeSyntaxHighlightingService(engine: engine)

        _ = service.highlightedString(
            code: "const value = 1",
            language: "js",
            appearance: .light,
            fontSize: 12
        )
        _ = service.highlightedString(
            code: "name: demo",
            language: "yml",
            appearance: .light,
            fontSize: 12
        )
        _ = service.highlightedString(
            code: "echo hello",
            language: "sh",
            appearance: .light,
            fontSize: 12
        )

        #expect(engine.recordedLanguages == ["javascript", "yaml", "bash"])
    }

    @Test
    func infersCanonicalLanguageFromFileURL() {
        #expect(
            CodeSyntaxHighlightingService.languageIdentifier(
                for: URL(fileURLWithPath: "/tmp/sample.ts")
            ) == "typescript"
        )
        #expect(
            CodeSyntaxHighlightingService.languageIdentifier(
                for: URL(fileURLWithPath: "/tmp/config.yml")
            ) == "yaml"
        )
        #expect(
            CodeSyntaxHighlightingService.languageIdentifier(
                for: URL(fileURLWithPath: "/tmp/run.sh")
            ) == "bash"
        )
        #expect(
            CodeSyntaxHighlightingService.languageIdentifier(
                for: URL(fileURLWithPath: "/tmp/notes.txt")
            ) == nil
        )
    }

    @Test
    func repeatedRequestsUseCachedResult() {
        let engine = RecordingHighlightEngine()
        let service = CodeSyntaxHighlightingService(engine: engine)

        let first = service.highlightedString(
            code: "let value = 1",
            language: "swift",
            appearance: .light,
            fontSize: 12
        )
        let second = service.highlightedString(
            code: "let value = 1",
            language: "swift",
            appearance: .light,
            fontSize: 12
        )

        #expect(engine.callCount == 1)
        #expect(first.string == second.string)
    }

    @Test
    func engineFailureStillReturnsPlainString() {
        let engine = RecordingHighlightEngine(shouldFail: true)
        let service = CodeSyntaxHighlightingService(engine: engine)

        let result = service.highlightedString(
            code: "print(1)",
            language: "swift",
            appearance: .light,
            fontSize: 12
        )

        #expect(result.string == "print(1)")
        #expect(engine.callCount == 1)
    }

    @Test
    func highlightedStringPreservesSourceTextAndAppliesColoredTokens() {
        let service = CodeSyntaxHighlightingService.liveForTesting()

        let result = service.highlightedString(
            code: "let value = 1",
            language: "swift",
            appearance: .light,
            fontSize: 12
        )

        #expect(result.string == "let value = 1")
        #expect(result.foregroundColor(forSubstring: "let") != nil)
        #expect(result.foregroundColor(forSubstring: "value") != nil)
        #expect(result.foregroundColor(forSubstring: "let") != result.foregroundColor(forSubstring: "value"))
    }

    @Test
    func lightAndDarkAppearancesProduceDifferentTokenColors() {
        let service = CodeSyntaxHighlightingService.liveForTesting()

        let light = service.highlightedString(
            code: "let value = 1",
            language: "swift",
            appearance: .light,
            fontSize: 12
        )
        let dark = service.highlightedString(
            code: "let value = 1",
            language: "swift",
            appearance: .dark,
            fontSize: 12
        )

        #expect(light.foregroundColor(forSubstring: "let") != dark.foregroundColor(forSubstring: "let"))
    }

    @Test
    func quotedCodeUsesSameHighlightPipelineAsRegularCodeBlock() {
        let service = CodeSyntaxHighlightingService.liveForTesting()

        let regular = service.highlightedString(
            code: "print(1)",
            language: "swift",
            appearance: .light,
            fontSize: 12
        )
        let quoted = service.highlightedString(
            code: "print(1)",
            language: "swift",
            appearance: .light,
            fontSize: 12
        )

        #expect(regular.string == quoted.string)
        #expect(regular.length == quoted.length)
        #expect(regular.foregroundColor(forSubstring: "print") == quoted.foregroundColor(forSubstring: "print"))
    }
}

private final class RecordingHighlightEngine: CodeSyntaxHighlightingEngine {
    private let unsupportedLanguages: Set<String>
    private let shouldFail: Bool

    private(set) var recordedLanguages: [String?] = []
    private(set) var callCount = 0

    init(unsupportedLanguages: Set<String> = [], shouldFail: Bool = false) {
        self.unsupportedLanguages = unsupportedLanguages
        self.shouldFail = shouldFail
    }

    func highlight(
        code: String,
        language: String?,
        theme: CodeHighlightTheme
    ) -> NSAttributedString? {
        callCount += 1
        recordedLanguages.append(language)

        if shouldFail {
            return nil
        }

        if let language, unsupportedLanguages.contains(language) {
            return nil
        }

        return NSAttributedString(
            string: code,
            attributes: [
                .foregroundColor: theme.appearance == .dark ? NSColor.systemGreen : NSColor.systemBlue,
                .font: NSFont.monospacedSystemFont(ofSize: theme.fontSize, weight: .regular)
            ]
        )
    }
}

private extension NSAttributedString {
    func foregroundColor(forSubstring substring: String) -> NSColor? {
        let range = (string as NSString).range(of: substring)
        guard range.location != NSNotFound else {
            return nil
        }

        return attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }
}
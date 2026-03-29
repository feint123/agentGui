import AppKit
import Testing
@testable import agentGui

@MainActor
struct BlockInlineMarkdownStylerCodeHighlightTests {
    @Test
    func codeBlocksApplyHighlightAttributesWithoutChangingPlainTypingAttributes() {
        let textView = BlockEditorTextView()
        textView.string = "let value = 1"
        let highlighter = TestingCodeHighlighter(keywordColor: .systemPink)

        BlockInlineMarkdownStyler.apply(
            to: textView,
            kind: .code,
            language: "swift",
            highlighter: highlighter
        )

        let keywordColor = textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(keywordColor == .systemPink)
        #expect((textView.typingAttributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        #expect(textView.typingAttributes[.foregroundColor] as? NSColor == .labelColor)
    }

    @Test
    func plainLanguagesKeepBaseMonospaceAttributes() {
        let textView = BlockEditorTextView()
        textView.string = "value"
        let highlighter = TestingCodeHighlighter(keywordColor: .systemPink)

        BlockInlineMarkdownStyler.apply(
            to: textView,
            kind: .source,
            language: "plain",
            highlighter: highlighter
        )

        let color = textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let font = textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(color == .labelColor)
        #expect(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        #expect(highlighter.callCount == 0)
    }

    @Test
    func nonCodeBlocksContinueUsingInlineMarkdownRules() {
        let textView = BlockEditorTextView()
        textView.string = "**bold**"
        let highlighter = TestingCodeHighlighter(keywordColor: .systemPink)

        BlockInlineMarkdownStyler.apply(
            to: textView,
            kind: .paragraph,
            language: "swift",
            highlighter: highlighter
        )

        let boldRange = NSRange(location: 2, length: 4)
        let boldFont = textView.textStorage?.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        #expect(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(highlighter.callCount == 0)
    }
}

private final class TestingCodeHighlighter: CodeSyntaxHighlighting {
    let keywordColor: NSColor
    private(set) var callCount = 0

    init(keywordColor: NSColor) {
        self.keywordColor = keywordColor
    }

    func highlightedString(
        code: String,
        language: String?,
        appearance: CodeHighlightAppearance,
        fontSize: CGFloat
    ) -> NSAttributedString {
        callCount += 1

        let attributedString = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        )
        if code.hasPrefix("let") {
            attributedString.addAttribute(.foregroundColor, value: keywordColor, range: NSRange(location: 0, length: 3))
        }
        return attributedString
    }
}
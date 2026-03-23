import Foundation
import AppKit
import Testing
@testable import agentGui

@MainActor
struct BlockInlineMarkdownRenderingTests {

    @Test func repeatedReadOnlyRenderingHitsSharedCache() {
        BlockInlineMarkdownRendering.resetCacheForTesting()
        let source = "Mix **bold** *italic* ~~strike~~ `code` [link](https://example.com)"

        let first = BlockInlineMarkdownRendering.renderedContent(for: source)
        let second = BlockInlineMarkdownRendering.renderedContent(for: source)
        let stats = BlockInlineMarkdownRendering.cacheStatsForTesting()

        #expect(first.displayPlainText == "Mix bold italic strike code link")
        #expect(second.displayPlainText == first.displayPlainText)
        #expect(second.projection == first.projection)
        #expect(stats.missCount == 1)
        #expect(stats.hitCount == 1)
    }

    @Test func resettingReadOnlyRenderingCacheDropsStoredEntries() {
        BlockInlineMarkdownRendering.resetCacheForTesting()
        let source = "Before **bold** after"

        _ = BlockInlineMarkdownRendering.renderedContent(for: source)
        let populated = BlockInlineMarkdownRendering.cacheStatsForTesting()
        BlockInlineMarkdownRendering.resetCacheForTesting()
        let cleared = BlockInlineMarkdownRendering.cacheStatsForTesting()

        #expect(populated.entryCount == 1)
        #expect(populated.missCount == 1)
        #expect(cleared.entryCount == 0)
        #expect(cleared.hitCount == 0)
        #expect(cleared.missCount == 0)
    }

    @Test func displayPlainTextHidesInlineMarkdownMarkers() {
        let source = "Mix **bold** *italic* ~~strike~~ `code` [link](https://example.com)"

        let rendered = BlockInlineMarkdownRendering.displayPlainText(for: source)

        #expect(rendered == "Mix bold italic strike code link")
    }

    @Test func displayPlainTextPreservesNestedInlineContent() {
        let source = "Before **bold _italic_** after"

        let rendered = BlockInlineMarkdownRendering.displayPlainText(for: source)

        #expect(rendered == "Before bold italic after")
    }

    @Test func markerRangesCollectInlineMarkdownDelimiters() {
        let source = "Mix **bold** and [link](https://example.com)"

        let ranges = BlockInlineMarkdownStyler.markerRanges(in: source)
        let substrings = ranges.map { (source as NSString).substring(with: $0) }

        #expect(substrings.contains("**"))
        #expect(substrings.contains("["))
        #expect(substrings.contains("](https://example.com)"))
    }

    @Test func sharedStylerAppliesBoldTraitToEditorContent() throws {
        let textView = NSTextView()
        textView.string = "**bold**"

        BlockInlineMarkdownStyler.apply(to: textView, kind: .paragraph)

        let boldRange = NSRange(location: 2, length: 4)
        let attributes = textView.textStorage?.attributes(at: boldRange.location, effectiveRange: nil)
        let font = try #require(attributes?[.font] as? NSFont)
        let traits = NSFontManager.shared.traits(of: font)

        #expect(traits.contains(.boldFontMask))
    }

    @Test func sharedStylerHidesMarkdownMarkerGlyphs() {
        let textView = BlockEditorTextView()
        textView.layoutManager?.delegate = textView
        textView.string = "**bold**"

        BlockInlineMarkdownStyler.apply(to: textView, kind: .paragraph)

        let markerRange = NSRange(location: 0, length: 2)
        let glyphRange = textView.layoutManager?.glyphRange(forCharacterRange: markerRange, actualCharacterRange: nil) ?? .init(location: NSNotFound, length: 0)
        let glyphProperty = textView.layoutManager?.propertyForGlyph(at: glyphRange.location) ?? []

        #expect(glyphRange.location != NSNotFound)
        #expect(glyphProperty.contains(.null))
    }
}
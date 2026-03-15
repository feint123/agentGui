import Foundation
import Testing
@testable import agentGui

struct BlockInlineMarkdownRenderingTests {

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
}
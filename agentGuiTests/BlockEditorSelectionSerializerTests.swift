import Foundation
import Testing
@testable import agentGui

@MainActor
struct BlockEditorSelectionSerializerTests {

    @Test func serializerBuildsMarkdownPlainTextAndHTMLForMixedBlocks() {
        let blocks = [
            DocumentBlock(kind: .heading1, text: "Title"),
            {
                var block = DocumentBlock(kind: .todo, text: "Ship it")
                block.metadata.checked = true
                return block
            }(),
            DocumentBlock(kind: .quote, text: "Quoted")
        ]

        let payload = BlockEditorSelectionSerializer.serialize(blocks: blocks, fileURL: nil)

        #expect(payload.markdown.contains("# Title"))
        #expect(payload.markdown.contains("- [x] Ship it"))
        #expect(payload.plainText.contains("Title"))
        #expect(payload.plainText.contains("[x] Ship it"))
        #expect(payload.plainText.contains("> Quoted"))
        #expect(payload.html.contains("<h1>Title</h1>"))
        #expect(payload.html.contains("<blockquote>"))
        #expect(payload.html.contains("<li>"))
    }

    @Test func serializerProducesReadablePlainTextForResourcesAndCode() {
        var image = DocumentBlock.empty(.image)
        image.metadata.secondaryText = "封面图"
        image.metadata.resource = "/tmp/cover.png"

        var file = DocumentBlock.empty(.file)
        file.text = "设计稿"
        file.metadata.resource = "/tmp/design.sketch"

        var code = DocumentBlock.empty(.code)
        code.metadata.language = "swift"
        code.text = "print(\"hello\")"

        let payload = BlockEditorSelectionSerializer.serialize(blocks: [image, file, code], fileURL: nil)

        #expect(payload.plainText.contains("[图片] 封面图"))
        #expect(payload.plainText.contains("/tmp/cover.png"))
        #expect(payload.plainText.contains("[附件] 设计稿"))
        #expect(payload.plainText.contains("swift"))
        #expect(payload.html.contains("<img"))
        #expect(payload.html.contains("<pre><code class=\"language-swift\">"))
    }

    @Test func serializerReturnsStructuredHtmlFragmentInsteadOfWholeDocument() {
        let blocks = [
            DocumentBlock(kind: .paragraph, text: "Alpha"),
            DocumentBlock(kind: .heading2, text: "Beta")
        ]

        let payload = BlockEditorSelectionSerializer.serialize(blocks: blocks, fileURL: nil)

        #expect(payload.html.contains("<p>Alpha</p>"))
        #expect(payload.html.contains("<h2>Beta</h2>"))
        #expect(!payload.html.contains("<html"))
        #expect(!payload.html.contains("<body"))
    }

    @Test func serializerReturnsEmptyPayloadForEmptySelection() {
        let payload = BlockEditorSelectionSerializer.serialize(blocks: [], fileURL: nil)

        #expect(payload.markdown.isEmpty)
        #expect(payload.plainText.isEmpty)
        #expect(payload.html.isEmpty)
        #expect(payload.internalJSON.isEmpty)
    }
}
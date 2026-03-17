import Foundation
import Testing
@testable import agentGui

struct BlockInlineMarkdownProjectionTests {

    @Test func projectionRemovesMarkersAndMapsVisibleOffsetsBackToSource() {
        let projection = BlockInlineMarkdownProjection(sourceText: "a **bold** c")

        #expect(projection.visibleText == "a bold c")
        #expect(projection.sourceOffset(forVisibleUTF16Offset: 2) == 4)
        #expect(projection.sourceOffset(forVisibleUTF16Offset: 6) == 10)
        #expect(projection.visibleOffset(forSourceUTF16Offset: 10) == 6)
    }

    @Test func projectionDetectsActiveInlineActionsFromSourceSyntax() {
        let source = "Before **bold** and *italic*"
        let projection = BlockInlineMarkdownProjection(sourceText: source)
        let boldRange = NSRange(location: 9, length: 4)
        let italicRange = NSRange(location: 21, length: 6)

        #expect(projection.activeActions(in: boldRange) == [.bold])
        #expect(projection.activeActions(in: italicRange) == [.italic])
    }

    @Test func projectionNormalizesCaretOutOfHiddenMarkerRuns() {
        let projection = BlockInlineMarkdownProjection(sourceText: "**bold**")

        #expect(projection.normalizedSourceOffset(for: 1) == 2)
        #expect(projection.normalizedSourceOffset(for: 7) == 8)
    }
}
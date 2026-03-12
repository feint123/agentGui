import Foundation
import Testing
@testable import agentGui

@MainActor
struct MarkdownMessageViewRenderingTests {

    @Test func initialSnapshotSeedsBlocksBeforeAppear() async throws {
        let text = "# Title\n\nFirst paragraph"

        let snapshot = MarkdownMessageView.initialSnapshot(for: text)

        #expect(snapshot.sourceText == text)
        #expect(snapshot.blocks.isEmpty == false)
        #expect(snapshot.blocks.first?.kind == .heading(level: 1))
    }

    @Test func finalStreamedTableMatchesFullParseProjection() async throws {
        let parser = MarkdownMessageIncrementalParser()
        let full = """
        | Name | Value |
        | --- | --- |
        | A | 1 |
        """

        let step1 = parser.reconcile(oldText: "", newText: "| Name | Value |\n")
        let step2 = parser.reconcile(
            oldText: step1.sourceText,
            newText: "| Name | Value |\n| --- | --- |\n",
            previous: step1
        )
        let final = parser.reconcile(oldText: step2.sourceText, newText: full, previous: step2)

        #expect(final.blocks == parser.fullParse(full))
    }

    @Test func mermaidCodeFenceKeepsLanguageInFinalProjection() async throws {
        let parser = MarkdownMessageIncrementalParser()
        let full = """
        ```mermaid
        graph TD
        A-->B
        ```
        """

        let step1 = parser.reconcile(oldText: "", newText: "```mermaid\n")
        let step2 = parser.reconcile(
            oldText: step1.sourceText,
            newText: "```mermaid\ngraph TD\nA-->B\n",
            previous: step1
        )
        let final = parser.reconcile(oldText: step2.sourceText, newText: full, previous: step2)

        let block = try #require(final.blocks.first)
        #expect(final.blocks == parser.fullParse(full))
        #expect(block.kind == .code)
        #expect(block.language == "mermaid")
    }

    @Test func nonAppendEditFallsBackToFullParseProjection() async throws {
        let parser = MarkdownMessageIncrementalParser()

        let original = parser.reconcile(oldText: "", newText: "> first\n> second\n")
        let edited = parser.reconcile(
            oldText: original.sourceText,
            newText: "> replacement\n> second\n",
            previous: original
        )

        #expect(edited.blocks == parser.fullParse("> replacement\n> second\n"))
    }
}
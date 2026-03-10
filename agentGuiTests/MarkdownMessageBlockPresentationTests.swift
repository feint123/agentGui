import Foundation
import Testing
@testable import agentGui

@MainActor
struct MarkdownMessageBlockPresentationTests {

    @Test func mapsParagraphHeadingQuoteAndListBlocks() async throws {
        let source = """
        # Title

        > quoted

        - one
        - two
        """

        let document = BlockMarkdownCodec.parse(source, fileURL: nil)

        let blocks = MarkdownMessageBlockPresentation.makeBlocks(from: document)

        #expect(blocks.map(\.kind) == [
            .heading(level: 1),
            .quote,
            .bulletedList,
            .bulletedList
        ])
        #expect(blocks.map(\.text) == ["Title", "quoted", "one", "two"])
    }

    @Test func mapsMermaidCodeBlockAsCodeKindWithLanguage() async throws {
        let source = """
        ```mermaid
        graph TD
        A-->B
        ```
        """

        let document = BlockMarkdownCodec.parse(source, fileURL: nil)

        let blocks = MarkdownMessageBlockPresentation.makeBlocks(from: document)

        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .code)
        #expect(blocks.first?.language == "mermaid")
        #expect(blocks.first?.text == "graph TD\nA-->B")
    }

    @Test func mapsTableTodoCalloutToggleImageAndURLBlocks() async throws {
        let source = """
        | Name | Value |
        | --- | --- |
        | A | 1 |

        - [x] done

        > [!NOTE] Heads up
        > body

        <details open><summary>More</summary>

        hidden body

        </details>

        ![Diagram](https://example.com/image.png)

        [Link](https://example.com)
        """

        let document = BlockMarkdownCodec.parse(source, fileURL: nil)

        let blocks = MarkdownMessageBlockPresentation.makeBlocks(from: document)

        #expect(blocks.map(\.kind) == [
            .table,
            .todo,
            .callout,
            .toggle,
            .image,
            .url
        ])

        let table = try #require(blocks.first)
        #expect(table.tableRows == [["Name", "Value"], ["A", "1"]])
        #expect(table.tableAlignments.count == 2)

        let todo = try #require(blocks[safe: 1])
        #expect(todo.isChecked == true)
        #expect(todo.text == "done")

        let callout = try #require(blocks[safe: 2])
        #expect(callout.calloutTone == "note")
        #expect(callout.secondaryText == "Heads up")
        #expect(callout.text == "body")

        let toggle = try #require(blocks[safe: 3])
        #expect(toggle.secondaryText == "More")
        #expect(toggle.isCollapsed == false)
        #expect(toggle.text == "hidden body")

        let image = try #require(blocks[safe: 4])
        #expect(image.resource == "https://example.com/image.png")
        #expect(image.secondaryText == "Diagram")

        let url = try #require(blocks[safe: 5])
        #expect(url.resource == "https://example.com")
        #expect(url.text == "Link")
    }

    @Test func renderBlockIDsAreDeterministicForSameInput() async throws {
        let source = """
        ## Stable

        Paragraph text
        """

        let document = BlockMarkdownCodec.parse(source, fileURL: nil)

        let first = MarkdownMessageBlockPresentation.makeBlocks(from: document)
        let second = MarkdownMessageBlockPresentation.makeBlocks(from: document)

        #expect(first.map(\.id) == second.map(\.id))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
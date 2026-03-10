import Foundation
import Testing
@testable import agentGui

@MainActor
struct MarkdownMessageIncrementalParserTests {

    @Test func tableStreamConvergesToSingleTableBlock() async throws {
        let parser = MarkdownMessageIncrementalParser()

        let step1 = parser.reconcile(oldText: "", newText: "| A | B |\n")
        let step2 = parser.reconcile(
            oldText: step1.sourceText,
            newText: "| A | B |\n| --- | --- |\n",
            previous: step1
        )
        let step3 = parser.reconcile(
            oldText: step2.sourceText,
            newText: "| A | B |\n| --- | --- |\n| 1 | 2 |\n",
            previous: step2
        )

        #expect(step3.blocks.count == 1)
        #expect(step3.blocks.first?.kind == .table)
        #expect(step3.blocks.first?.tableRows == [["A", "B"], ["1", "2"]])
    }

    @Test func finalAppendMatchesFullParseForCodeFence() async throws {
        let parser = MarkdownMessageIncrementalParser()
        let full = """
        ```swift
        print(1)
        ```
        """

        let step1 = parser.reconcile(oldText: "", newText: "```swift\n")
        let step2 = parser.reconcile(
            oldText: step1.sourceText,
            newText: "```swift\nprint(1)\n",
            previous: step1
        )
        let final = parser.reconcile(oldText: step2.sourceText, newText: full, previous: step2)

        #expect(final.blocks == parser.fullParse(full))
        #expect(final.blocks.count == 1)
        #expect(final.blocks.first?.kind == .code)
    }

    @Test func quoteGrowthReusesSingleQuoteBlock() async throws {
        let parser = MarkdownMessageIncrementalParser()

        let step1 = parser.reconcile(oldText: "", newText: "> one\n")
        let step2 = parser.reconcile(oldText: step1.sourceText, newText: "> one\n> two\n", previous: step1)

        #expect(step2.blocks.count == 1)
        #expect(step2.blocks.first?.kind == .quote)
        #expect(step2.blocks.first?.text == "one\ntwo")
    }

    @Test func bulletedListGrowthReusesListBlocksAndStablePrefixIDs() async throws {
        let parser = MarkdownMessageIncrementalParser()

        let step1 = parser.reconcile(oldText: "", newText: "# Title\n\n- one\n")
        let step2 = parser.reconcile(oldText: step1.sourceText, newText: "# Title\n\n- one\n- two\n", previous: step1)

        #expect(step2.blocks.map(\.kind) == [.heading(level: 1), .bulletedList, .bulletedList])
        #expect(step2.blocks.first?.id == step1.blocks.first?.id)
    }

    @Test func todoGrowthKeepsCheckedState() async throws {
        let parser = MarkdownMessageIncrementalParser()

        let step1 = parser.reconcile(oldText: "", newText: "- [x] done\n")
        let step2 = parser.reconcile(oldText: step1.sourceText, newText: "- [x] done\n- [ ] next\n", previous: step1)

        #expect(step2.blocks.map(\.kind) == [.todo, .todo])
        #expect(step2.blocks[safe: 0]?.isChecked == true)
        #expect(step2.blocks[safe: 1]?.isChecked == false)
    }

    @Test func nonAppendEditFallsBackToFullParse() async throws {
        let parser = MarkdownMessageIncrementalParser()

        let original = parser.reconcile(oldText: "", newText: "- one\n- two\n")
        let edited = parser.reconcile(
            oldText: original.sourceText,
            newText: "- zero\n- one\n- two\n",
            previous: original
        )

        #expect(edited.blocks == parser.fullParse("- zero\n- one\n- two\n"))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
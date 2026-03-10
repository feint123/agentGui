import Foundation
import Testing
@testable import agentGui

struct TextEditorViewRangeSafetyTests {

    @Test func startGreaterThanEndReturnsSingleSafeLine() async throws {
        let rendered = ClaudeService.renderTextEditorViewForTests(
            content: "a\nb\nc",
            viewRange: [3, 1]
        )

        #expect(rendered == "3\tc")
    }

    @Test func outOfBoundsRangeClampsToAvailableLines() async throws {
        let rendered = ClaudeService.renderTextEditorViewForTests(
            content: "a\nb\nc",
            viewRange: [-5, 99]
        )

        #expect(rendered == "1\ta\n2\tb\n3\tc")
    }

    @Test func startPastEndOfFileReturnsLastLine() async throws {
        let rendered = ClaudeService.renderTextEditorViewForTests(
            content: "a\nb\nc",
            viewRange: [10, 20]
        )

        #expect(rendered == "3\tc")
    }

    @Test func emptyContentDoesNotCrash() async throws {
        let rendered = ClaudeService.renderTextEditorViewForTests(
            content: "",
            viewRange: [1, 5]
        )

        #expect(rendered == "1\t")
    }
}
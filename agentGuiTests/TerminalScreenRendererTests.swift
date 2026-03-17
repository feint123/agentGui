import AppKit
import Foundation
import Testing
@testable import agentGui

struct TerminalScreenRendererTests {

    @Test func rendererMapsInverseCellIntoSwappedForegroundAndBackground() {
        let snapshot = TerminalRenderFixtures.inverseWarningSnapshot
        let rendered = TerminalScreenRenderer(theme: .darkDefault).render(snapshot)

        let firstRun = try! #require(rendered.runs.first)
        #expect(firstRun.text == "WARN")
        #expect(firstRun.foregroundColor != nil)
        #expect(firstRun.backgroundColor != nil)
        #expect(rendered.hasStyledRuns)
    }

    @Test func rendererPreservesBoldUnderlineAndTrueColorRuns() {
        let rendered = TerminalScreenRenderer(theme: .darkDefault).render(TerminalRenderFixtures.coloredDiffSnapshot)

        #expect(rendered.attributedString.string == "+ new line")
        #expect(rendered.runs.contains(where: { $0.attributes.contains(.bold) }))
        #expect(rendered.runs.contains(where: { $0.attributes.contains(.underline) }))
        #expect(rendered.runs.contains(where: { $0.foregroundColor != nil && $0.text.contains("line") }))
    }

    @Test func rendererProvidesPlainTextFallbackForUnstyledSnapshots() {
        let snapshot = TerminalScreenSnapshot(
            plainTextLines: ["plain output"],
            activeBuffer: .primary,
            cursor: .init(row: 0, column: 12),
            width: 80,
            height: 24
        )

        let rendered = TerminalScreenRenderer(theme: .darkDefault).render(snapshot)

        #expect(rendered.attributedString.string == "plain output")
        #expect(rendered.runs.count == 1)
        #expect(rendered.plainText == "plain output")
    }
}
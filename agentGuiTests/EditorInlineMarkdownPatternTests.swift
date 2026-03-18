import Foundation
import Testing
@testable import agentGui

struct EditorInlineMarkdownPatternTests {

    @Test func boldRuleSeparatesMarkersFromContent() throws {
        let source = "**bold**"
        let match = try #require(BlockMarkdownCodec.InlineMarkdownRule.bold.matches(in: source).first)

        #expect((source as NSString).substring(with: match.contentRange) == "bold")
        #expect(match.markerRanges.map { (source as NSString).substring(with: $0) } == ["**", "**"])
    }

    @Test func linkRuleTargetsVisibleLabelInsteadOfBracketSyntax() throws {
        let source = "[docs](https://example.com)"
        let match = try #require(BlockMarkdownCodec.InlineMarkdownRule.link.matches(in: source).first)

        #expect((source as NSString).substring(with: match.contentRange) == "docs")
        #expect(match.markerRanges.map { (source as NSString).substring(with: $0) } == ["[", "](https://example.com)"])
    }
}
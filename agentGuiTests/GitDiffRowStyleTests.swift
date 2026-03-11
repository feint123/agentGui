import Foundation
import Testing
@testable import agentGui

struct GitDiffRowStyleTests {

    @Test func rowStyleUsesUnifiedGutterBackgroundForAddition() {
        let style = GitDiffRowStyle.make(for: .addition(oldLineNumber: nil, newLineNumber: 12, text: "new line"))

        #expect(style.gutterBackgroundOpacity > 0)
        #expect(style.contentBackgroundRole == .addition)
    }

    @Test func rowStyleUsesUnifiedGutterBackgroundForContext() {
        let style = GitDiffRowStyle.make(for: .context(oldLineNumber: 10, newLineNumber: 10, text: "same line"))

        #expect(style.gutterBackgroundOpacity > 0)
        #expect(style.contentBackgroundRole == .neutral)
    }
}
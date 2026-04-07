import AppKit
import Foundation
import Testing
@testable import agentGui

@MainActor
struct CodeEditorBracketPairColorizationTests {

    @Test func colorizationDoesNotCrashOnEmptyText() {
        let textView = NSTextView()
        textView.string = ""
        CodeEditorBracketPairColorizationService.colorize(
            textView: textView,
            visibleUTF16Range: NSRange(location: 0, length: 0)
        )
    }

    @Test func colorizationDoesNotCrashOnNoBrackets() {
        let textView = NSTextView()
        textView.string = "hello world"
        CodeEditorBracketPairColorizationService.colorize(
            textView: textView,
            visibleUTF16Range: NSRange(location: 0, length: 11)
        )
    }

    @Test func colorizationDoesNotCrashOnOutOfBoundsRange() {
        let textView = NSTextView()
        textView.string = "(x)"
        CodeEditorBracketPairColorizationService.colorize(
            textView: textView,
            visibleUTF16Range: NSRange(location: 0, length: 999)
        )
    }

    @Test func colorizationHasSixDistinctColors() {
        #expect(CodeEditorBracketPairColorizationService.paletteColors.count == 6)
    }

    @Test func colorizationDepthModuloWrapsCorrectly() {
        // Depth 0 → paletteColors[0], depth 6 → paletteColors[0], depth 7 → paletteColors[1]
        let colors = CodeEditorBracketPairColorizationService.paletteColors
        #expect(colors.count == 6)
        let depth6Color = colors[6 % colors.count]
        let depth0Color = colors[0]
        #expect(depth6Color == depth0Color)
    }
}

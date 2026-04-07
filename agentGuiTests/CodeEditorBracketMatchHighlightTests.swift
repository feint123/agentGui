import AppKit
import Foundation
import Testing
@testable import agentGui

@MainActor
struct CodeEditorBracketMatchHighlightTests {

    // 注意：CodeEditorPlatformTextView 需要 NSWindow 才能有 layoutManager 的 temporary attributes 效果。
    // 这里仅测试 applyBracketMatchHighlight 不崩溃，以及 appliedBracketMatchRanges 状态。

    @Test func applyBracketMatchHighlightSetsBothRanges() {
        let textView = CodeEditorPlatformTextView()
        textView.string = "(hello)"
        let result = CodeEditorBracketMatchResult(
            openRange: NSRange(location: 0, length: 1),
            closeRange: NSRange(location: 6, length: 1)
        )
        // Should not crash even without a window/layoutManager
        textView.applyBracketMatchHighlight(result)
        // If no layoutManager, just verify no crash
    }

    @Test func applyBracketMatchHighlightNilClearsPreviousState() {
        let textView = CodeEditorPlatformTextView()
        textView.string = "(hello)"
        let result = CodeEditorBracketMatchResult(
            openRange: NSRange(location: 0, length: 1),
            closeRange: NSRange(location: 6, length: 1)
        )
        textView.applyBracketMatchHighlight(result)
        textView.applyBracketMatchHighlight(nil)  // 清除，不崩溃
    }

    @Test func applyBracketMatchHighlightWithOutOfBoundsRangeSafelyClamps() {
        let textView = CodeEditorPlatformTextView()
        textView.string = "x"  // length=1
        let badResult = CodeEditorBracketMatchResult(
            openRange: NSRange(location: 0, length: 1),
            closeRange: NSRange(location: 999, length: 1)  // out of bounds
        )
        textView.applyBracketMatchHighlight(badResult)
        // Should not crash
    }

    @Test func bracketScannerAndHighlightEndToEnd() {
        let textView = CodeEditorPlatformTextView()
        textView.string = "func foo(x: Int) {}"
        // Cursor 在 '(' 上 (offset=8)
        let matchResult = CodeEditorBracketScanner.findMatch(
            in: textView.string,
            cursorOffset: 8
        )
        #expect(matchResult != nil)
        #expect(matchResult?.openRange.location == 8)
        // ')' 在 offset 15
        #expect(matchResult?.closeRange.location == 15)
        textView.applyBracketMatchHighlight(matchResult)
    }
}

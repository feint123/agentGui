import Foundation
import Testing
@testable import agentGui

struct CodeEditorBracketScannerTests {

    // MARK: - Forward scan

    @Test func cursorOnOpenParenFindsMatchingCloseParen() {
        let text = "(hello)"
        // cursor 在 '(' 上，offset=0
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: 0)
        #expect(result?.openRange == NSRange(location: 0, length: 1))
        #expect(result?.closeRange == NSRange(location: 6, length: 1))
    }

    @Test func cursorOnOpenBraceFindsMatchingCloseBrace() {
        let text = "{ a + b }"
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: 0)
        #expect(result?.openRange == NSRange(location: 0, length: 1))
        #expect(result?.closeRange == NSRange(location: 8, length: 1))
    }

    @Test func nestedBracketsReturnsInnermostMatch() {
        let text = "((x))"
        // cursor 在内层 '('，offset=1
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: 1)
        #expect(result?.openRange == NSRange(location: 1, length: 1))
        #expect(result?.closeRange == NSRange(location: 3, length: 1))
    }

    // MARK: - Backward scan

    @Test func cursorAfterCloseParenFindsMatchingOpenParen() {
        let text = "(hello)"
        // cursor 在 ')' 后面，offset=7；cursor-1=')' at 6
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: 7)
        #expect(result?.openRange == NSRange(location: 0, length: 1))
        #expect(result?.closeRange == NSRange(location: 6, length: 1))
    }

    @Test func cursorOnCloseBracketBeforeTextFindsOpen() {
        // "[abc]" — cursor 在 ']' 处（offset=4）
        let text = "[abc]"
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: 4)
        // 先检测 offset=4 (']'):  backward scan
        #expect(result?.openRange == NSRange(location: 0, length: 1))
        #expect(result?.closeRange == NSRange(location: 4, length: 1))
    }

    // MARK: - No match cases

    @Test func unmatchedOpenParenReturnsNil() {
        let text = "(no close"
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: 0)
        #expect(result == nil)
    }

    @Test func cursorOnNonBracketCharReturnsNil() {
        let text = "hello world"
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: 3)
        #expect(result == nil)
    }

    @Test func emptyStringReturnsNil() {
        let result = CodeEditorBracketScanner.findMatch(in: "", cursorOffset: 0)
        #expect(result == nil)
    }

    @Test func cursorAtEndOfStringWithNoBracketReturnsNil() {
        // "hello" has no brackets near cursor → should return nil
        let text = "hello"
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: text.utf16.count)
        #expect(result == nil)
    }

    // MARK: - maxSearchDistance 截断

    @Test func searchDistanceLimitPreventsMatchTooFarAway() {
        // 在 '(' 和 ')' 之间插入 100 个字符
        let inner = String(repeating: "x", count: 100)
        let text = "(" + inner + ")"
        // maxSearchDistance=10 应无法找到
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: 0, maxSearchDistance: 10)
        #expect(result == nil)
    }

    @Test func searchDistanceLargeEnoughFindsBracket() {
        let inner = String(repeating: "x", count: 100)
        let text = "(" + inner + ")"
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: 0, maxSearchDistance: 200)
        #expect(result != nil)
    }

    // MARK: - 多行

    @Test func multilineBracketMatch() {
        let text = "func foo() {\n    let x = 1\n}"
        // '{' 在 offset=11
        let braceOffset = (text as NSString).range(of: "{").location
        let result = CodeEditorBracketScanner.findMatch(in: text, cursorOffset: braceOffset)
        let closeOffset = (text as NSString).range(of: "}", options: .backwards).location
        #expect(result?.openRange.location == braceOffset)
        #expect(result?.closeRange.location == closeOffset)
    }
}

// agentGuiTests/CodeEditorGhostTextKeyboardTests.swift
import XCTest
@testable import agentGui

final class CodeEditorGhostTextKeyboardTests: XCTestCase {

    private func makeTextView(string: String, cursor: Int) -> CodeEditorPlatformTextView {
        let textView = CodeEditorPlatformTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        textView.string = string
        textView.setSelectedRange(NSRange(location: cursor, length: 0))
        return textView
    }

    func test_acceptFullGhostText_insertsTextAtCursor() {
        let textView = makeTextView(string: "let x = ", cursor: 8)

        let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 8, text: "42")
        textView.currentGhostText = snap

        textView.acceptFullGhostText()

        XCTAssertNil(textView.currentGhostText)
        XCTAssertEqual(textView.string, "let x = 42")
        XCTAssertEqual(textView.selectedRange().location, 10)
    }

    func test_acceptNextWord_insertsFirstWord() {
        let textView = makeTextView(string: "foo", cursor: 3)

        let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 3, text: "Bar Baz")
        textView.currentGhostText = snap

        textView.acceptNextWordGhostText()

        // "Bar" 被插入，剩余 " Baz" 保留为新 snapshot
        XCTAssertEqual(textView.string, "fooBar")
        XCTAssertNotNil(textView.currentGhostText)
        XCTAssertEqual(textView.currentGhostText?.text, " Baz")
    }

    func test_acceptNextWord_lastWord_clearsSnapshot() {
        let textView = makeTextView(string: "x", cursor: 1)

        let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 1, text: "42")
        textView.currentGhostText = snap
        textView.acceptNextWordGhostText()

        XCTAssertNil(textView.currentGhostText)
        XCTAssertEqual(textView.string, "x42")
    }

    func test_acceptFullGhostText_multiLine_insertsAll() {
        let textView = makeTextView(string: "func foo() {", cursor: 12)

        let snap = CodeEditorGhostTextSnapshot(
            generation: 1, insertionOffset: 12, text: "\n    return 42\n}"
        )
        textView.currentGhostText = snap
        textView.acceptFullGhostText()

        XCTAssertNil(textView.currentGhostText)
        XCTAssertTrue(textView.string.contains("return 42"))
        XCTAssertTrue(textView.string.hasSuffix("}"))
    }

    func test_clearGhostText_preventsAccept() {
        let textView = makeTextView(string: "code", cursor: 4)

        let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 4, text: "more")
        textView.currentGhostText = snap
        textView.clearGhostText()

        // After clear, acceptFull should do nothing
        let stringBefore = textView.string
        textView.acceptFullGhostText()
        XCTAssertEqual(textView.string, stringBefore)
    }

    // MARK: - 行级接受（f23-v2 Task 2）

    func testCmdReturnAcceptsNextLine_singleLine() {
        let textView = makeTextView(string: "", cursor: 0)
        textView.currentGhostText = CodeEditorGhostTextSnapshot(
            generation: 1, insertionOffset: 0, text: "hello"
        )
        textView.acceptNextLineGhostText()
        XCTAssertNil(textView.currentGhostText, "单行无换行：整行接受后 ghost text 应为 nil")
        XCTAssertEqual(textView.string, "hello", "文本应插入第一行内容")
    }

    func testCmdReturnAcceptsNextLine_multiLine() {
        let textView = makeTextView(string: "", cursor: 0)
        textView.currentGhostText = CodeEditorGhostTextSnapshot(
            generation: 1, insertionOffset: 0, text: "line1\nline2\nline3"
        )
        textView.acceptNextLineGhostText()
        let remaining = textView.currentGhostText
        XCTAssertNotNil(remaining, "多行：接受第一行后应保留剩余行")
        XCTAssertEqual(remaining?.text, "line2\nline3")
        XCTAssertEqual(textView.string, "line1\n", "只应插入第一行（含尾部换行）")
    }

    func testCmdReturnAcceptsNextLine_trailingNewline() {
        let textView = makeTextView(string: "", cursor: 0)
        textView.currentGhostText = CodeEditorGhostTextSnapshot(
            generation: 1, insertionOffset: 0, text: "func foo() {\n    return 42\n}"
        )
        textView.acceptNextLineGhostText()
        XCTAssertEqual(textView.string, "func foo() {\n")
        XCTAssertEqual(textView.currentGhostText?.text, "    return 42\n}")
    }
}

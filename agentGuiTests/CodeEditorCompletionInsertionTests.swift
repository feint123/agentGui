// agentGuiTests/CodeEditorCompletionInsertionTests.swift
import Foundation
import Testing
@testable import agentGui

struct CodeEditorCompletionInsertionTests {

    // MARK: - insertCompletion 辅助函数测试

    @Test func plainTextCompletion_replacesPrefix() {
        // "myFu" + 选中 "myFunction" → 文本变为 (原文 - prefix + insertText)
        let text = "let x = myFu"
        let item = CodeEditorCompletionItem(
            label: "myFunction",
            insertText: "myFunction",
            insertTextFormat: .plainText
        )
        let result = CodeEditorCompletionInserter.apply(
            item: item,
            to: text,
            cursorOffset: text.utf16.count, // cursor 在末尾
            prefixWord: "myFu"
        )
        #expect(result.newText == "let x = myFunction")
        #expect(result.newCursorOffset == result.newText.utf16.count)
    }

    @Test func snippetCompletion_replacesPlaceholderAndPositionsCursor() {
        // snippet "print($0)" → 插入后把 $0 替换为空，光标在括号内
        let text = "pr"
        let item = CodeEditorCompletionItem(
            label: "print(_:)",
            insertText: "print($0)",
            insertTextFormat: .snippet
        )
        let result = CodeEditorCompletionInserter.apply(
            item: item,
            to: text,
            cursorOffset: text.utf16.count,
            prefixWord: "pr"
        )
        #expect(result.newText == "print()")
        // cursor 应在 '(' 之后，即 offset = "print(".count = 6
        #expect(result.newCursorOffset == 6)
    }

    @Test func snippet_withNoPlaceholder_cursorAfterInsertedText() {
        // snippet "import Foundation" (no $0) → cursor 在文本末尾
        let text = "im"
        let item = CodeEditorCompletionItem(
            label: "import Foundation",
            insertText: "import Foundation",
            insertTextFormat: .plainText
        )
        let result = CodeEditorCompletionInserter.apply(
            item: item,
            to: text,
            cursorOffset: "im".utf16.count,
            prefixWord: "im"
        )
        #expect(result.newText == "import Foundation")
        #expect(result.newCursorOffset == result.newText.utf16.count)
    }

    @Test func completion_withPrefixNotMatchingInsertText_stillInsertsCorrectly() {
        // 触发字符 "." 后 prefixWord="" 但 insertText="show()"
        let text = "window."
        let item = CodeEditorCompletionItem(
            label: "show()",
            insertText: "show()",
            insertTextFormat: .plainText
        )
        let result = CodeEditorCompletionInserter.apply(
            item: item,
            to: text,
            cursorOffset: text.utf16.count,
            prefixWord: ""  // trigger character 后前缀为空
        )
        #expect(result.newText == "window.show()")
        #expect(result.newCursorOffset == result.newText.utf16.count)
    }
}

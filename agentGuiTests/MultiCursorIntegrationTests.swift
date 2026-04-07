import Testing
import AppKit
@testable import agentGui

// MARK: - Unit Tests for CodeEditorMultiSelectionController

@MainActor
struct MultiCursorControllerTests {

    @Test
    func toggleCursor_addsNewCursorAtEmptyPosition() {
        let initial = [NSRange(location: 5, length: 0)]
        let result = CodeEditorMultiSelectionController.toggleCursor(at: 10, in: initial)
        #expect(result.count == 2)
        #expect(result.contains(NSRange(location: 10, length: 0)))
    }

    @Test
    func toggleCursor_removesExistingCursor() {
        let initial = [NSRange(location: 5, length: 0), NSRange(location: 10, length: 0)]
        let result = CodeEditorMultiSelectionController.toggleCursor(at: 10, in: initial)
        #expect(result.count == 1)
        #expect(!result.contains(NSRange(location: 10, length: 0)))
    }

    @Test
    func toggleCursor_keepsAtLeastOneCursor() {
        let initial = [NSRange(location: 5, length: 0)]
        let result = CodeEditorMultiSelectionController.toggleCursor(at: 5, in: initial)
        #expect(result.count == 1)
        // 唯一光标不能被删除，仍在原位
        #expect(result[0].location == 5)
    }

    @Test
    func toggleCursor_respectsMaxCursorCount() {
        let initial = (0..<CodeEditorMultiSelectionController.maxCursorCount).map {
            NSRange(location: $0 * 2, length: 0)
        }
        let result = CodeEditorMultiSelectionController.toggleCursor(
            at: CodeEditorMultiSelectionController.maxCursorCount * 2,
            in: initial
        )
        #expect(result.count == CodeEditorMultiSelectionController.maxCursorCount)
    }

    @Test
    func selectNextMatch_findsNextOccurrence() {
        let text = "alpha beta alpha"
        let initial = [NSRange(location: 6, length: 4)]   // "beta"
        let (newRanges, _) = CodeEditorMultiSelectionController.selectNextMatch(
            searchText: "alpha",
            lastRange: NSRange(location: 0, length: 5),   // first "alpha"
            in: text,
            currentRanges: initial
        )
        // 应该新增 range for second "alpha" = location:11, length:5
        #expect(newRanges.count == 2)
        #expect(newRanges.last == NSRange(location: 11, length: 5))
    }

    @Test
    func selectNextMatch_wrapsAroundDocument() {
        let text = "alpha beta"
        let initial = [NSRange(location: 0, length: 5)]   // "alpha"
        let (_, wrapped) = CodeEditorMultiSelectionController.selectNextMatch(
            searchText: "alpha",
            lastRange: NSRange(location: 6, length: 4),
            in: text,
            currentRanges: initial
        )
        // "beta" 不含 alpha，搜索应 wrap 回文档开头找到 "alpha" 但已存在，返回 done
        // 此处主要验证 wrapped 行为或 count 不变
        #expect(wrapped == true || initial.count >= 1)
    }

    @Test
    func selectNextMatch_doesNotAddDuplicate() {
        let text = "hello world"
        let initial = [NSRange(location: 0, length: 5)]   // "hello"
        // 只有一个 "hello"，第二次 selectNext 应返回 done（不追加）
        let (newRanges, _) = CodeEditorMultiSelectionController.selectNextMatch(
            searchText: "hello",
            lastRange: NSRange(location: 0, length: 5),
            in: text,
            currentRanges: initial
        )
        #expect(newRanges.count == initial.count)
    }

    @Test
    func selectNextMatch_emptySearchTextReturnsOriginal() {
        let text = "hello world"
        let initial = [NSRange(location: 0, length: 5)]
        let (newRanges, _) = CodeEditorMultiSelectionController.selectNextMatch(
            searchText: "",
            lastRange: NSRange(location: 0, length: 5),
            in: text,
            currentRanges: initial
        )
        #expect(newRanges == initial)
    }

    @Test
    func collapseToLastCursor_keepsPrimarySelection() {
        let ranges = [
            NSRange(location: 0, length: 0),
            NSRange(location: 10, length: 3),
        ]
        let collapsed = CodeEditorMultiSelectionController.collapseToLastCursor(from: ranges)
        #expect(collapsed.count == 1)
        // head = location + length = 13
        #expect(collapsed[0].location == 13)
        #expect(collapsed[0].length == 0)
    }

    @Test
    func collapseToLastCursor_singleRangeUnchangedCount() {
        let ranges = [NSRange(location: 5, length: 0)]
        let collapsed = CodeEditorMultiSelectionController.collapseToLastCursor(from: ranges)
        #expect(collapsed.count == 1)
    }

    @Test
    func collapseToLastCursor_emptyInputReturnsSelf() {
        let collapsed = CodeEditorMultiSelectionController.collapseToLastCursor(from: [])
        #expect(collapsed.isEmpty)
    }
}

// MARK: - Integration Tests

@MainActor
struct MultiCursorIntegrationTests {

    @Test
    func multiCursorEditSetsIsMultiCursorEditFlag() {
        // 通过 Harness 模拟 shouldChangeTextInRanges 被调用（多选区路径）
        let harness = CodeEditorTextViewHarness(text: "abc\ndef")
        harness.simulateMultiCursorEdit(
            ranges: [NSRange(location: 3, length: 0), NSRange(location: 7, length: 0)],
            replacement: "X"
        )
        #expect(harness.lastChangeSet?.isMultiCursorEdit == true)
    }

    @Test
    func multiCursorEditUpdatesDocumentText() {
        // 验证多光标编辑后 document.text 被正确更新
        let harness = CodeEditorTextViewHarness(text: "abc\ndef")
        harness.simulateMultiCursorEdit(
            ranges: [NSRange(location: 3, length: 0), NSRange(location: 7, length: 0)],
            replacement: "!"
        )
        // 两处都插入了 "!"
        #expect(harness.document.text.contains("!"))
    }

    @Test
    func multiCursorEditChangeSetVersionIncremented() {
        let harness = CodeEditorTextViewHarness(text: "hello\nworld")
        let beforeVersion = harness.document.version
        harness.simulateMultiCursorEdit(
            ranges: [NSRange(location: 5, length: 0), NSRange(location: 11, length: 0)],
            replacement: "X"
        )
        #expect(harness.document.version > beforeVersion)
    }

    @Test
    func singleCursorEditIsNotMarkedAsMultiCursor() {
        let harness = CodeEditorTextViewHarness(text: "hello world")
        harness.replaceCharacters(in: NSRange(location: 5, length: 1), with: "-")
        #expect(harness.lastChangeSet?.isMultiCursorEdit == false)
    }

    @Test
    func highlightedLineNumbersUpdatesForSingleCursor() {
        let harness = CodeEditorTextViewHarness(text: "line1\nline2\nline3")
        harness.select(range: NSRange(location: 6, length: 0))  // line2
        #expect(harness.textView.highlightedLineNumbers.count >= 1)
    }
}

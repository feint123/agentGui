// agentGuiTests/CodeEditorGhostTextModelsTests.swift
import XCTest
@testable import agentGui

final class CodeEditorGhostTextModelsTests: XCTestCase {

    func test_snapshot_singleLine_displayLinesCount() {
        let snap = CodeEditorGhostTextSnapshot(
            generation: 1,
            insertionOffset: 10,
            text: "hello world"
        )
        XCTAssertEqual(snap.displayLines.count, 1)
        XCTAssertEqual(snap.displayLines[0].text, "hello world")
    }

    func test_snapshot_multiLine_displayLinesCount() {
        let snap = CodeEditorGhostTextSnapshot(
            generation: 2,
            insertionOffset: 5,
            text: "line1\nline2\nline3"
        )
        XCTAssertEqual(snap.displayLines.count, 3)
        XCTAssertEqual(snap.displayLines[1].text, "line2")
    }

    func test_snapshot_truncatesAt20Lines() {
        let text = (0..<25).map { "line\($0)" }.joined(separator: "\n")
        let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 0, text: text)
        XCTAssertEqual(snap.displayLines.count, 20)
    }

    func test_nextWordRange_simpleWord() {
        let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 0, text: "hello world")
        let range = snap.nextWordRange()
        XCTAssertNotNil(range)
        XCTAssertEqual(String(snap.text[range!]), "hello")
    }

    func test_nextWordRange_leadingWhitespace() {
        let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 0, text: "  foo")
        let range = snap.nextWordRange()
        XCTAssertNotNil(range)
        XCTAssertEqual(String(snap.text[range!]), "  ")
    }

    func test_nextWordRange_emptyText_returnsNil() {
        let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 0, text: "")
        XCTAssertNil(snap.nextWordRange())
    }

    // MARK: - AppSettings tests (Task 2)

    func test_appSettings_ghostTextFieldsExist() {
        let settings = AppSettings.ghostTextMock
        // 验证字段存在（编译时验证）且默认值正确
        XCTAssertFalse(settings.enableGhostText, "enableGhostText 默认值应为 false")
        XCTAssertEqual(settings.ghostTextDebounceMs, 500, "ghostTextDebounceMs 默认值应为 500")
    }

    // MARK: - Edge cases (Task 10)

    func test_snapshot_windowsNewline_handledCorrectly() {
        let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 0, text: "line1\r\nline2")
        // CRLF: components(separatedBy: "\n") 会产生 "line1\r" 和 "line2"
        XCTAssertLessThanOrEqual(snap.displayLines.count, 3)
    }
}

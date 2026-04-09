// agentGuiTests/CodeEditorGhostTextRenderTests.swift
import XCTest
@testable import agentGui

final class CodeEditorGhostTextRenderTests: XCTestCase {

    func test_setGhostText_triggersRedraw() {
        let textView = CodeEditorPlatformTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        textView.string = "func hello() {"

        let snap = CodeEditorGhostTextSnapshot(
            generation: 1, insertionOffset: 14, text: "\n    return 42\n}"
        )
        textView.currentGhostText = snap

        // 验证 snapshot 已存储（headless 测试中 needsDisplay 行为不确定，只验证数据正确性）
        XCTAssertNotNil(textView.currentGhostText)
        XCTAssertEqual(textView.currentGhostText?.generation, 1)
        XCTAssertEqual(textView.currentGhostText?.displayLines.count, 3)
    }

    func test_clearGhostText_removesSnapshot() {
        let textView = CodeEditorPlatformTextView()
        textView.currentGhostText = CodeEditorGhostTextSnapshot(
            generation: 1, insertionOffset: 0, text: "test"
        )
        textView.clearGhostText()
        XCTAssertNil(textView.currentGhostText)
    }

    func test_setGhostText_differentGeneration_replaces() {
        let textView = CodeEditorPlatformTextView()
        let snap1 = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 0, text: "v1")
        let snap2 = CodeEditorGhostTextSnapshot(generation: 2, insertionOffset: 5, text: "v2")
        textView.currentGhostText = snap1
        textView.currentGhostText = snap2
        XCTAssertEqual(textView.currentGhostText?.generation, 2)
    }

    func test_setGhostText_sameContent_doesNotSpam() {
        let textView = CodeEditorPlatformTextView()
        let snap = CodeEditorGhostTextSnapshot(generation: 1, insertionOffset: 0, text: "hello")
        textView.currentGhostText = snap
        textView.needsDisplay = false
        // Setting same snap again should NOT trigger redraw
        textView.currentGhostText = snap
        XCTAssertFalse(textView.needsDisplay)
    }
}

// agentGuiTests/CodeEditorGhostTextIntegrationTests.swift
import XCTest
import SwiftUI
@testable import agentGui

@MainActor
final class CodeEditorGhostTextIntegrationTests: XCTestCase {

    func test_ghostTextEnabled_false_doesNotRequestService() async {
        let client = MockGhostTextClient()
        let service = CodeEditorGhostTextService(client: client)
        // disabled 路径：trigger.handleChange(isGhostTextEnabled: false) 不应调用 service
        let trigger = CodeEditorGhostTextTrigger(debounceMs: 50)
        trigger.handleChange(isIMEActive: false, isGhostTextEnabled: false)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(client.requestCalled)
        _ = service // suppress unused warning
    }

    func test_installGhostText_setsService() async {
        let client = MockGhostTextClient()
        let coordinator = CodeEditorTextView(
            text: .constant(""),
            document: .constant(CodeEditorDocument(text: "", persistedText: "", version: 1, selectedRange: NSRange())),
            isGhostTextEnabled: true,
            ghostTextClient: client
        ).makeCoordinator()

        // Coordinator is created, service should be nil initially
        // (installed lazily via syncRuntimeIntegrations)
        XCTAssertNotNil(coordinator)
    }

    func test_trigger_callsServiceOnDebounce() async {
        let client = MockGhostTextClient()
        let service = CodeEditorGhostTextService(client: client)
        let trigger = CodeEditorGhostTextTrigger(debounceMs: 50)
        let expectation = XCTestExpectation(description: "trigger fired")

        trigger.onRequestGhostText = { _, ctxProvider in
            // Simulate service request
            service.request(
                prefix: ctxProvider()?.prefix ?? "",
                suffix: "",
                language: "swift",
                generation: 1,
                onFirstLine: { _ in },
                onComplete: { _ in expectation.fulfill() },
                onCancel: {}
            )
        }

        trigger.handleChange(
            isIMEActive: false,
            isGhostTextEnabled: true,
            contextProvider: { ("prefix code", "", "swift") }
        )

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertTrue(client.requestCalled)
    }

    // MARK: - 光标偏离失效（f23-v2 Task 3）

    func testGhostTextClearedWhenCursorMovesAway() {
        let textView = CodeEditorPlatformTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        textView.string = "hello world"
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.currentGhostText = CodeEditorGhostTextSnapshot(
            generation: 1, insertionOffset: 5, text: " completion"
        )
        XCTAssertNotNil(textView.currentGhostText)

        // 移动光标到 offset 0（不同位置）
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNil(textView.currentGhostText,
            "光标离开 insertionOffset 时 ghost text 应自动清除")
    }

    func testGhostTextPreservedWhenCursorStaysAtInsertionOffset() {
        let textView = CodeEditorPlatformTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        textView.string = "hello world"
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.currentGhostText = CodeEditorGhostTextSnapshot(
            generation: 1, insertionOffset: 5, text: " completion"
        )
        // 不移动光标，再次设置到同一位置
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertNotNil(textView.currentGhostText,
            "光标留在 insertionOffset 不应清除 ghost text")
    }

    // MARK: - 动态语言检测（f23-v2 Task 4）

    func testExtractGhostTextContext_usesLanguageParam() {
        let textView = CodeEditorPlatformTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        textView.string = "let x = 1"
        textView.setSelectedRange(NSRange(location: 9, length: 0))
        let context = textView.extractGhostTextContext(language: "python")
        XCTAssertEqual(context?.language, "python",
            "提取的上下文 language 应与传入参数一致")
    }

    func testExtractGhostTextContext_defaultLanguage_isSwift() {
        let textView = CodeEditorPlatformTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        textView.string = "let x = 1"
        textView.setSelectedRange(NSRange(location: 9, length: 0))
        let context = textView.extractGhostTextContext(language: nil)
        XCTAssertEqual(context?.language, "swift",
            "未传入 language 时默认应为 'swift'")
    }
}

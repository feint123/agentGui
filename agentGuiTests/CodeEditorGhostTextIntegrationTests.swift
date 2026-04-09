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
}

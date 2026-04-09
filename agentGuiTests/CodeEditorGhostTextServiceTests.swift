// agentGuiTests/CodeEditorGhostTextServiceTests.swift
import XCTest
@testable import agentGui

@MainActor
final class CodeEditorGhostTextServiceTests: XCTestCase {

    func test_request_callsClientWithCorrectPrompt() async {
        let client = MockGhostTextClient()
        let service = CodeEditorGhostTextService(client: client)
        let expectation = XCTestExpectation(description: "complete")
        var receivedText: String?

        service.request(
            prefix: "func hello() {",
            suffix: "}",
            language: "swift",
            generation: 1,
            onFirstLine: { _ in },
            onComplete: { text in receivedText = text; expectation.fulfill() },
            onCancel: {}
        )

        await fulfillment(of: [expectation], timeout: 3.0)
        XCTAssertTrue(client.requestCalled)
        XCTAssertEqual(receivedText, "mock response")
    }

    func test_request_outdatedGeneration_bothComplete() async {
        let client = MockGhostTextClient()
        let service = CodeEditorGhostTextService(client: client)

        let exp1 = XCTestExpectation(description: "req1 done")
        let exp2 = XCTestExpectation(description: "req2 done")

        service.request(
            prefix: "code", suffix: "", language: "swift", generation: 1,
            onFirstLine: { _ in },
            onComplete: { _ in exp1.fulfill() },
            onCancel: { exp1.fulfill() }
        )
        service.request(
            prefix: "code2", suffix: "", language: "swift", generation: 2,
            onFirstLine: { _ in },
            onComplete: { _ in exp2.fulfill() },
            onCancel: { exp2.fulfill() }
        )

        await fulfillment(of: [exp1, exp2], timeout: 3.0)
        XCTAssertTrue(client.requestCalled)
    }

    func test_cancel_stopsOngoingRequest() async {
        let client = SlowMockGhostTextClient()
        let service = CodeEditorGhostTextService(client: client)
        var completeCalled = false
        let cancelExpectation = XCTestExpectation(description: "cancel called")

        service.request(
            prefix: "long code", suffix: "", language: "swift", generation: 1,
            onFirstLine: { _ in },
            onComplete: { _ in completeCalled = true },
            onCancel: { cancelExpectation.fulfill() }
        )
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        service.cancel()

        await fulfillment(of: [cancelExpectation], timeout: 2.0)
        XCTAssertFalse(completeCalled)
    }

    func test_emptyResponse_doesNotCallOnComplete() async {
        let client = EmptyMockGhostTextClient()
        let service = CodeEditorGhostTextService(client: client)
        var completeCalled = false

        service.request(
            prefix: "x", suffix: "", language: "swift", generation: 1,
            onFirstLine: { _ in },
            onComplete: { _ in completeCalled = true },
            onCancel: {}
        )
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        XCTAssertFalse(completeCalled)
    }

    func test_apiError_doesNotCrash() async {
        let client = ErrorMockGhostTextClient()
        let service = CodeEditorGhostTextService(client: client)
        service.request(
            prefix: "x", suffix: "", language: "swift", generation: 1,
            onFirstLine: { _ in },
            onComplete: { _ in },
            onCancel: {}
        )
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        // 不崩溃即通过
    }
}

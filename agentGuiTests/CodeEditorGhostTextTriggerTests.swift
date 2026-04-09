// agentGuiTests/CodeEditorGhostTextTriggerTests.swift
import XCTest
@testable import agentGui

@MainActor
final class CodeEditorGhostTextTriggerTests: XCTestCase {

    func test_handleChange_schedulesRequestAfterDebounce() async {
        let expectation = XCTestExpectation(description: "request fired")
        let trigger = CodeEditorGhostTextTrigger(debounceMs: 100)
        trigger.onRequestGhostText = { _, _ in expectation.fulfill() }

        trigger.handleChange(isIMEActive: false, isGhostTextEnabled: true)
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func test_handleChange_imeActive_doesNotFire() async {
        let trigger = CodeEditorGhostTextTrigger(debounceMs: 50)
        var fired = false
        trigger.onRequestGhostText = { _, _ in fired = true }

        trigger.handleChange(isIMEActive: true, isGhostTextEnabled: true)
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

        XCTAssertFalse(fired)
    }

    func test_handleChange_disabled_doesNotFire() async {
        let trigger = CodeEditorGhostTextTrigger(debounceMs: 50)
        var fired = false
        trigger.onRequestGhostText = { _, _ in fired = true }

        trigger.handleChange(isIMEActive: false, isGhostTextEnabled: false)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(fired)
    }

    func test_handleChange_rapidTyping_onlyLatestFires() async {
        let trigger = CodeEditorGhostTextTrigger(debounceMs: 100)
        var fireCount = 0
        var lastGeneration = 0
        trigger.onRequestGhostText = { gen, _ in
            fireCount += 1
            lastGeneration = gen
        }

        // 模拟快速连续输入（每 20ms 一次，共 5 次）
        for _ in 1...5 {
            trigger.handleChange(isIMEActive: false, isGhostTextEnabled: true)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000) // 等待防抖结束

        XCTAssertEqual(fireCount, 1)     // 只触发一次
        XCTAssertEqual(lastGeneration, 5) // generation 正确递增
    }

    func test_cancel_preventsScheduledRequest() async {
        let trigger = CodeEditorGhostTextTrigger(debounceMs: 200)
        var fired = false
        trigger.onRequestGhostText = { _, _ in fired = true }

        trigger.handleChange(isIMEActive: false, isGhostTextEnabled: true)
        trigger.cancel()
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertFalse(fired)
    }
}

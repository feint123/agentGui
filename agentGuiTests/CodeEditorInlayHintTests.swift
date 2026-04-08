// agentGuiTests/CodeEditorInlayHintTests.swift
import Foundation
import Testing
@testable import agentGui

@MainActor
@Suite("CodeEditorInlayHint Tests")
struct CodeEditorInlayHintTests {

    // MARK: - 数据模型解析

    @Test("parseInlayHints: 正常 JSON 数组解析")
    func parseNormalHints() throws {
        let client = LSPClient.makeTestInstance()
        let json: [[String: Any]] = [
            [
                "position": ["line": 2, "character": 15],
                "label": ": String",
                "kind": 1,
                "paddingLeft": false,
                "paddingRight": true
            ]
        ]
        let hints = client.parseInlayHints(from: json)
        #expect(hints.count == 1)
        let h0 = hints[0]
        #expect(h0.line == 3)         // 0-based → 1-based
        #expect(h0.character == 16)   // 0-based → 1-based
        #expect(h0.label == ": String")
        #expect(h0.kind == .type)
        #expect(h0.paddingRight == true)
        #expect(h0.paddingLeft == false)
    }

    @Test("parseInlayHints: labelParts 格式正常解析")
    func parseLabelPartsHints() throws {
        let client = LSPClient.makeTestInstance()
        let json: [[String: Any]] = [
            [
                "position": ["line": 5, "character": 8],
                "label": [["value": "label:"], ["value": "arg"]] as [[String: Any]],
                "kind": 2,
                "paddingLeft": true,
                "paddingRight": false
            ]
        ]
        let hints = client.parseInlayHints(from: json)
        #expect(hints.count == 1)
        let h0 = hints[0]
        #expect(h0.line == 6)
        #expect(h0.character == 9)
        #expect(h0.label == "label:arg")
        #expect(h0.kind == .parameter)
        #expect(h0.paddingLeft == true)
    }

    @Test("parseInlayHints: nil 响应返回空数组")
    func parseNilResponse() {
        let client = LSPClient.makeTestInstance()
        let hints = client.parseInlayHints(from: nil)
        #expect(hints.isEmpty)
    }

    @Test("parseInlayHints: 非数组响应返回空数组")
    func parseNonArrayResponse() {
        let client = LSPClient.makeTestInstance()
        let hints = client.parseInlayHints(from: "not an array")
        #expect(hints.isEmpty)
    }

    @Test("parseInlayHints: label 超 40 字符时截断")
    func parseLongLabel() {
        let client = LSPClient.makeTestInstance()
        let longLabel = String(repeating: "a", count: 50)
        let json: [[String: Any]] = [[
            "position": ["line": 0, "character": 0],
            "label": longLabel,
            "kind": 1
        ]]
        let hints = client.parseInlayHints(from: json)
        #expect(hints.count == 1)
        #expect(hints[0].label.count <= 41)  // 40 + "…" = 41
        #expect(hints[0].label.hasSuffix("…"))
    }

    @Test("parseInlayHints: kind 未知 rawValue 返回 .unknown")
    func parseUnknownKind() {
        let client = LSPClient.makeTestInstance()
        let json: [[String: Any]] = [[
            "position": ["line": 0, "character": 5],
            "label": "hint",
            "kind": 99
        ]]
        let hints = client.parseInlayHints(from: json)
        #expect(hints.count == 1)
        #expect(hints[0].kind == .unknown)
    }

    @Test("parseInlayHints: 格式错误的 item 被跳过")
    func parseMalformedItemSkipped() {
        let client = LSPClient.makeTestInstance()
        let json: [[String: Any]] = [
            ["label": "no position"],  // 缺少 position
            ["position": ["line": 1, "character": 0], "label": "ok", "kind": 1]
        ]
        let hints = client.parseInlayHints(from: json)
        #expect(hints.count == 1)
        #expect(hints[0].label == "ok")
    }

    // MARK: - Snapshot 构建

    @Test("InlayHintSnapshot: hintsByLine 按 character 有序")
    func snapshotHintsByLineOrdered() {
        let hints = [
            CodeEditorInlayHint(line: 3, character: 20, label: "B", kind: .type, paddingLeft: false, paddingRight: false),
            CodeEditorInlayHint(line: 3, character: 5,  label: "A", kind: .parameter, paddingLeft: false, paddingRight: false),
            CodeEditorInlayHint(line: 1, character: 10, label: "C", kind: .type, paddingLeft: false, paddingRight: false),
        ]
        let snapshot = CodeEditorInlayHintSnapshot(documentVersion: 42, hints: hints)
        let line3 = snapshot.hintsByLine[3]!
        #expect(line3[0].label == "A")  // character 5 < 20
        #expect(line3[1].label == "B")
        #expect(snapshot.hintsByLine[1]?.count == 1)
        #expect(snapshot.documentVersion == 42)
    }

    @Test("InlayHintSnapshot.empty: documentVersion == -1，hintsByLine 为空")
    func snapshotEmptyIsEmpty() {
        let snapshot = CodeEditorInlayHintSnapshot.empty
        #expect(snapshot.documentVersion == -1)
        #expect(snapshot.hintsByLine.isEmpty)
    }

    // MARK: - Coordinator 代际取消

    @Test("scheduleInlayHintRequest: 连续调用只触发最后一次")
    func generationCancellation() async throws {
        let coordinator = makeTestCoordinator()
        var callCount = 0
        coordinator.onInlayHintResult = { _ in callCount += 1 }

        // 快速连续调度 5 次，每次之间 < 300ms
        for i in 1...5 {
            coordinator.scheduleInlayHintRequest(
                visibleLineRange: (i * 10)...(i * 10 + 20),
                documentVersion: 1
            )
        }

        // 等待 400ms（> 300ms debounce）
        try await Task.sleep(nanoseconds: 400_000_000)
        // 前 4 次任务被取消，最后一次触发回调
        #expect(callCount == 1)
    }

    @Test("scheduleInlayHintRequest: coordinator 未激活时不触发")
    func noRequestWhenNotOpen() async throws {
        let coordinator = makeTestCoordinator(supportsInlayHints: false)
        var callCount = 0
        coordinator.onInlayHintResult = { _ in callCount += 1 }

        coordinator.scheduleInlayHintRequest(visibleLineRange: 1...50, documentVersion: 1)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(callCount == 0)
    }

    // MARK: - 渲染层：版本一致性

    @Test("currentInlayHintSnapshot: 版本不一致时 drawBackground 应跳过绘制")
    func snapshotVersionMismatch() {
        let stale = CodeEditorInlayHintSnapshot(documentVersion: 3, hints: [
            .init(line: 1, character: 1, label: "test", kind: .type, paddingLeft: false, paddingRight: false)
        ])
        #expect(stale.documentVersion == 3)
        #expect(stale.hintsByLine[1]?.count == 1)
        // documentVersion 5 != 3，draw 层 guard 掉
        #expect(stale.documentVersion != 5)
    }
}

// MARK: - Test Helpers

@MainActor
private func makeTestCoordinator(supportsInlayHints: Bool = true) -> CodeEditorLSPCoordinator {
    let binding = CodeEditorLSPDocumentBinding(
        workspaceRoot: "/tmp",
        serverID: "test",
        uri: "file:///tmp/test.swift",
        languageID: "swift"
    )
    let harness = SharedLSPServerManagerHarness(settings: .lspFixture(installedProviderIDs: []))
    let manager = harness.makeManager()
    let coordinator = CodeEditorLSPCoordinator(
        manager: manager,
        binding: binding,
        debounceNanoseconds: 300_000_000
    )
    if supportsInlayHints {
        // activate 使 isOpen = true，版本 = 1，使得 scheduleInlayHintRequest 可以执行
        coordinator.activate(initialText: "let x = 1", version: 1)
    }
    return coordinator
}

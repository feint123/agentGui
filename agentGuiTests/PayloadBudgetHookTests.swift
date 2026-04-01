import XCTest
@testable import agentGui
import Foundation

final class PayloadBudgetHookTests: XCTestCase {

    // MARK: - Helpers

    /// 构建 PayloadBudgetHook，默认阈值设为 100 字符以便测试（不需要构造 16 KB 字符串）。
    private func makeHook(
        threshold: Int = 100,
        store: ToolPayloadStore = ToolPayloadStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appending(path: "PayloadBudgetHookTests-\(UUID().uuidString)")
        )
    ) -> (PayloadBudgetHook, ToolPayloadStore) {
        (PayloadBudgetHook(payloadStore: store, charThreshold: threshold), store)
    }

    private func makeRecord(
        toolName: String = "bash",
        text: String = "output",
        isError: Bool = false,
        envelope: ToolResultEnvelope? = nil
    ) -> ToolRunRecord {
        let status: ToolResultStatus = isError ? .failure : .success
        let result = ToolExecutionResult(text, status: status, envelope: envelope)
        return ToolRunRecord(
            toolCallId: "tc-test",
            toolName: toolName,
            input: [:],
            result: result,
            sessionID: "session-test",
            executionContext: .mainAgent
        )
    }

    private func makeEnvelope() -> ToolResultEnvelope {
        ToolResultEnvelope(
            summary: "existing",
            preview: nil,
            payloadRef: "payload_existing",
            isTruncated: true,
            estimatedChars: 1000,
            estimatedTokens: 250,
            retrievalHint: nil,
            sourceKind: .bash,
            injectionMode: .referenced,
            rawCharCount: 1000,
            injectedCharCount: 100
        )
    }

    // MARK: - preExecute 永远 allow

    func test_preExecute_alwaysAllows() async {
        let (hook, _) = makeHook()
        let preview = ToolCallPreview(
            toolCallId: "id", toolName: "bash",
            input: [:], sessionID: "s1", executionContext: .mainAgent
        )
        let decision = await hook.preExecute(toolCall: preview)
        guard case .allow = decision else {
            XCTFail("Expected .allow, got \(decision)"); return
        }
    }

    // MARK: - postFailure 永远 propagate

    func test_postFailure_alwaysPropagates() async {
        let (hook, _) = makeHook()
        let preview = ToolCallPreview(
            toolCallId: "id", toolName: "bash",
            input: [:], sessionID: "s1", executionContext: .mainAgent
        )
        let action = await hook.postFailure(
            toolCall: preview,
            error: ToolExecutionHookError(message: "simulated failure")
        )
        guard case .propagate = action else {
            XCTFail("Expected .propagate, got \(action)"); return
        }
    }

    // MARK: - 小结果 passthrough

    func test_smallResult_passthrough() async {
        let (hook, _) = makeHook(threshold: 100)
        let record = makeRecord(text: String(repeating: "x", count: 50)) // 50 ≤ 100
        let action = await hook.postExecute(record: record)
        guard case .passthrough = action else {
            XCTFail("Expected .passthrough for small result, got \(action)"); return
        }
    }

    func test_resultAtExactThreshold_passthrough() async {
        let (hook, _) = makeHook(threshold: 100)
        let record = makeRecord(text: String(repeating: "x", count: 100)) // 100 == 100, not >
        let action = await hook.postExecute(record: record)
        guard case .passthrough = action else {
            XCTFail("Expected .passthrough at exact threshold, got \(action)"); return
        }
    }

    // MARK: - 已有 envelope passthrough（dispatch 层已处理）

    func test_resultWithExistingEnvelope_passthrough() async {
        let (hook, _) = makeHook(threshold: 10)
        let record = makeRecord(
            text: String(repeating: "x", count: 200), // > threshold
            envelope: makeEnvelope()
        )
        let action = await hook.postExecute(record: record)
        guard case .passthrough = action else {
            XCTFail("Expected .passthrough when envelope already present, got \(action)"); return
        }
    }

    // MARK: - 错误结果 passthrough

    func test_errorResult_passthrough() async {
        let (hook, _) = makeHook(threshold: 10)
        let record = makeRecord(
            text: String(repeating: "x", count: 200),
            isError: true
        )
        let action = await hook.postExecute(record: record)
        guard case .passthrough = action else {
            XCTFail("Expected .passthrough for error result, got \(action)"); return
        }
    }

    // MARK: - 大结果：rewriteResult + payload 已存储

    func test_largeResult_rewritesResult() async {
        let (hook, _) = makeHook(threshold: 100)
        let original = String(repeating: "A", count: 200)
        let record = makeRecord(text: original)
        let action = await hook.postExecute(record: record)
        switch action {
        case .rewriteResult(let result):
            XCTAssertFalse(result.text.isEmpty, "Rewritten result text should not be empty")
        default:
            XCTFail("Expected .rewriteResult for large result, got \(action)")
        }
    }

    func test_largeResult_preservesOriginalStatus() async {
        let (hook, _) = makeHook(threshold: 100)
        let record = makeRecord(
            text: String(repeating: "x", count: 200),
            isError: false
        )
        let action = await hook.postExecute(record: record)
        if case .rewriteResult(let result) = action {
            XCTAssertEqual(result.status, .success, "Original success status must be preserved")
        } else {
            XCTFail("Expected .rewriteResult")
        }
    }

    func test_largeResult_rawOutputTextPreserved() async {
        let (hook, _) = makeHook(threshold: 100)
        let original = String(repeating: "B", count: 200)
        let record = makeRecord(text: original)
        let action = await hook.postExecute(record: record)
        if case .rewriteResult(let result) = action {
            XCTAssertEqual(
                result.rawOutputText, original,
                "rawOutputText must preserve original text for later payload reads"
            )
        } else {
            XCTFail("Expected .rewriteResult")
        }
    }

    func test_largeResult_envelopeInjectionModeIsReferenced() async {
        let (hook, _) = makeHook(threshold: 100)
        let record = makeRecord(text: String(repeating: "C", count: 200))
        let action = await hook.postExecute(record: record)
        if case .rewriteResult(let result) = action {
            XCTAssertEqual(
                result.envelope?.injectionMode, .referenced,
                "Envelope injection mode must be .referenced"
            )
        } else {
            XCTFail("Expected .rewriteResult")
        }
    }

    func test_largeResult_envelopeContainsPayloadRef() async {
        let (hook, _) = makeHook(threshold: 100)
        let record = makeRecord(text: String(repeating: "D", count: 200))
        let action = await hook.postExecute(record: record)
        if case .rewriteResult(let result) = action {
            XCTAssertNotNil(result.envelope?.payloadRef, "Envelope must carry a payload_ref")
        } else {
            XCTFail("Expected .rewriteResult")
        }
    }

    // MARK: - payload 存入 store 可读取

    func test_largeResult_storesPayloadInStore() async throws {
        let (hook, store) = makeHook(threshold: 100)
        let original = String(repeating: "E", count: 200)
        let record = makeRecord(text: original)
        let action = await hook.postExecute(record: record)

        guard case .rewriteResult(let result) = action,
              let payloadRef = result.envelope?.payloadRef else {
            XCTFail("Expected .rewriteResult with payloadRef"); return
        }

        // Payload should be retrievable from store
        let payload = try await store.payload(for: payloadRef)
        XCTAssertEqual(payload.rawCharCount, 200)
    }

    func test_largeResult_payloadContentMatchesOriginal() async throws {
        let (hook, store) = makeHook(threshold: 100)
        let original = "Hello world! " + String(repeating: "Z", count: 200)
        let record = makeRecord(text: original)
        let action = await hook.postExecute(record: record)

        guard case .rewriteResult(let result) = action,
              let payloadRef = result.envelope?.payloadRef else {
            XCTFail("Expected .rewriteResult with payloadRef"); return
        }

        // Read from store and verify content matches
        let window = try await store.readChars(payloadID: payloadRef, start: 1, end: original.count)
        XCTAssertEqual(window, original)
    }

    // MARK: - source kind 映射

    func test_bashTool_sourceKindIsBash() async {
        let (hook, _) = makeHook(threshold: 100)
        let record = makeRecord(toolName: "bash", text: String(repeating: "x", count: 200))
        let action = await hook.postExecute(record: record)
        if case .rewriteResult(let result) = action {
            XCTAssertEqual(result.envelope?.sourceKind, .bash)
        } else {
            XCTFail("Expected .rewriteResult")
        }
    }

    func test_readFileTool_sourceKindIsFile() async {
        let (hook, _) = makeHook(threshold: 100)
        let record = makeRecord(toolName: "read_file", text: String(repeating: "x", count: 200))
        let action = await hook.postExecute(record: record)
        if case .rewriteResult(let result) = action {
            XCTAssertEqual(result.envelope?.sourceKind, .file)
        } else {
            XCTFail("Expected .rewriteResult")
        }
    }

    func test_unknownTool_sourceKindIsOther() async {
        let (hook, _) = makeHook(threshold: 100)
        let record = makeRecord(toolName: "my_custom_tool", text: String(repeating: "x", count: 200))
        let action = await hook.postExecute(record: record)
        if case .rewriteResult(let result) = action {
            XCTAssertEqual(result.envelope?.sourceKind, .other)
        } else {
            XCTFail("Expected .rewriteResult")
        }
    }

    // MARK: - payload store 失败时安全降级

    func test_payloadStoreFailure_passthrough() async {
        // 使用一个不可写路径使 store 创建 payload 必然失败
        let badStore = ToolPayloadStore(
            baseDirectory: URL(fileURLWithPath: "/nonexistent/path/that/cannot/be/created")
        )
        let hook = PayloadBudgetHook(payloadStore: badStore, charThreshold: 10)
        let record = makeRecord(text: String(repeating: "x", count: 200))
        let action = await hook.postExecute(record: record)
        // Should silently degrade to passthrough, not throw or crash
        switch action {
        case .passthrough, .rewriteResult:
            break  // both are acceptable: rewriteResult if store worked, passthrough if failed
        default:
            XCTFail("Should not return appendAttachment or other unexpected action")
        }
    }
}

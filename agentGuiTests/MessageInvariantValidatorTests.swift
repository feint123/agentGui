import XCTest
import SwiftAnthropic
@testable import agentGui

final class MessageInvariantValidatorTests: XCTestCase {

    private let validator = MessageInvariantValidator()

    // MARK: - 辅助工厂方法

    /// 构造一条带 tool_use 对象的 assistant 消息。
    private func assistantMsg(toolUseIds: [String]) -> MessageParameter.Message {
        let objects: [MessageParameter.Message.Content.ContentObject] = toolUseIds.map {
            .toolUse($0, "bash", [:])
        }
        return .init(role: .assistant, content: .list(objects))
    }

    /// 构造一条带 tool_result 对象的 user 消息。
    private func userMsg(toolUseIds: [String]) -> MessageParameter.Message {
        let objects: [MessageParameter.Message.Content.ContentObject] = toolUseIds.map {
            .toolResult($0, "output", isError: nil)
        }
        return .init(role: .user, content: .list(objects))
    }

    /// 构造普通文本消息。
    private func textMsg(role: MessageParameter.Message.Role, text: String = "hello") -> MessageParameter.Message {
        .init(role: role, content: .text(text))
    }

    // MARK: - Scanning Utilities

    func test_toolResultIds_returnsEmpty_forAssistantMessage() {
        let msg = assistantMsg(toolUseIds: ["id-1"])
        XCTAssertTrue(validator.toolResultIds(in: msg).isEmpty)
    }

    func test_toolResultIds_returnsIds_forUserMessage() {
        let msg = userMsg(toolUseIds: ["r-1", "r-2"])
        let ids = validator.toolResultIds(in: msg)
        XCTAssertEqual(Set(ids), Set(["r-1", "r-2"]))
    }

    func test_toolUseIds_returnsEmpty_forUserMessage() {
        let msg = userMsg(toolUseIds: ["id-1"])
        XCTAssertTrue(validator.toolUseIds(in: msg).isEmpty)
    }

    func test_toolUseIds_returnsIds_forAssistantMessage() {
        let msg = assistantMsg(toolUseIds: ["u-1", "u-2"])
        let ids = validator.toolUseIds(in: msg)
        XCTAssertEqual(Set(ids), Set(["u-1", "u-2"]))
    }

    func test_toolResultIds_returnsEmpty_forTextOnlyMessage() {
        let msg = textMsg(role: .user, text: "hello")
        XCTAssertTrue(validator.toolResultIds(in: msg).isEmpty)
    }

    // MARK: - adjustedStartIndex

    func test_adjustedStartIndex_noToolCalls_returnsProposedIndex() {
        let messages: [MessageParameter.Message] = [
            textMsg(role: .user),
            textMsg(role: .assistant),
            textMsg(role: .user),
            textMsg(role: .assistant),
        ]
        let result = validator.adjustedStartIndex(2, in: messages)
        XCTAssertEqual(result, 2)
    }

    func test_adjustedStartIndex_toolPairFullyInKeptRange_returnsProposedIndex() {
        // 0: text-user
        // 1: assistant (tool_use A, B)
        // 2: user (tool_result A, B)
        // 3: text-assistant
        // 提案 startIndex = 1；pair 在 [1,2]，均在 kept range [1...] 内 → 不调整
        let messages: [MessageParameter.Message] = [
            textMsg(role: .user),
            assistantMsg(toolUseIds: ["A", "B"]),
            userMsg(toolUseIds: ["A", "B"]),
            textMsg(role: .assistant),
        ]
        let result = validator.adjustedStartIndex(1, in: messages)
        XCTAssertEqual(result, 1)
    }

    func test_adjustedStartIndex_toolUseBeforeStart_pullsBackIndex() {
        // 0: text-user
        // 1: assistant (tool_use A)          ← 被截断（不在 kept range）
        // 2: user (tool_result A)            ← 在 kept range，但 tool_use 缺失
        // 提案 startIndex = 2 → 应调整为 1（包含 tool_use）
        let messages: [MessageParameter.Message] = [
            textMsg(role: .user),
            assistantMsg(toolUseIds: ["A"]),
            userMsg(toolUseIds: ["A"]),
        ]
        let result = validator.adjustedStartIndex(2, in: messages)
        XCTAssertEqual(result, 1)
    }

    func test_adjustedStartIndex_multipleToolsPartialKept_pullsBackToEarliestRequired() {
        // 0: assistant (tool_use X)
        // 1: user (tool_result X)
        // 2: assistant (tool_use Y)
        // 3: user (tool_result Y)
        // 提案 startIndex = 3 → tool_result Y 需要 tool_use Y (at 2) → adjustedIndex = 2
        let messages: [MessageParameter.Message] = [
            assistantMsg(toolUseIds: ["X"]),
            userMsg(toolUseIds: ["X"]),
            assistantMsg(toolUseIds: ["Y"]),
            userMsg(toolUseIds: ["Y"]),
        ]
        let result = validator.adjustedStartIndex(3, in: messages)
        XCTAssertEqual(result, 2)
    }

    func test_adjustedStartIndex_startIndexZero_returnsZero() {
        let messages: [MessageParameter.Message] = [
            assistantMsg(toolUseIds: ["A"]),
            userMsg(toolUseIds: ["A"]),
        ]
        let result = validator.adjustedStartIndex(0, in: messages)
        XCTAssertEqual(result, 0)
    }

    func test_adjustedStartIndex_startIndexBeyondEnd_returnsProposedIndex() {
        let messages: [MessageParameter.Message] = [textMsg(role: .user)]
        let result = validator.adjustedStartIndex(5, in: messages)
        XCTAssertEqual(result, 5)
    }

    func test_adjustedStartIndex_emptyMessages_returnsProposedIndex() {
        let result = validator.adjustedStartIndex(0, in: [])
        XCTAssertEqual(result, 0)
    }

    func test_adjustedStartIndex_multipleToolUsesInOneAssistantMsg_pullsBackCorrectly() {
        // 0: assistant (tool_use A, tool_use B)
        // 1: user (tool_result A, tool_result B)
        // 2: assistant (text only)
        // 提案 startIndex = 1 → 需要 tool_use A+B（均在 index 0）→ adjustedIndex = 0
        let messages: [MessageParameter.Message] = [
            assistantMsg(toolUseIds: ["A", "B"]),
            userMsg(toolUseIds: ["A", "B"]),
            textMsg(role: .assistant),
        ]
        let result = validator.adjustedStartIndex(1, in: messages)
        XCTAssertEqual(result, 0)
    }

    // MARK: - validate

    func test_validate_emptyMessages_isValid() {
        let result = validator.validate([])
        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.violations.isEmpty)
    }

    func test_validate_textOnlyMessages_isValid() {
        let messages: [MessageParameter.Message] = [
            textMsg(role: .user),
            textMsg(role: .assistant),
        ]
        let result = validator.validate(messages)
        XCTAssertTrue(result.isValid)
    }

    func test_validate_pairedToolCallsInOrder_isValid() {
        let messages: [MessageParameter.Message] = [
            textMsg(role: .user),
            assistantMsg(toolUseIds: ["A"]),
            userMsg(toolUseIds: ["A"]),
        ]
        let result = validator.validate(messages)
        XCTAssertTrue(result.isValid)
    }

    func test_validate_orphanToolResult_returnsViolation() {
        // user 消息中有 tool_result "A"，但前面没有 assistant 含 tool_use "A"
        let messages: [MessageParameter.Message] = [
            textMsg(role: .user),
            userMsg(toolUseIds: ["A"]),
        ]
        let result = validator.validate(messages)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.violations.count, 1)
        if case .orphanToolResult(let id, let idx) = result.violations[0] {
            XCTAssertEqual(id, "A")
            XCTAssertEqual(idx, 1)
        } else {
            XCTFail("Expected orphanToolResult violation")
        }
    }

    func test_validate_orphanToolUse_returnsViolation() {
        // assistant 消息中有 tool_use "B"，但后面没有 user 含 tool_result "B"
        let messages: [MessageParameter.Message] = [
            assistantMsg(toolUseIds: ["B"]),
            textMsg(role: .user),
        ]
        let result = validator.validate(messages)
        XCTAssertFalse(result.isValid)
        let orphanUse = result.violations.first {
            if case .orphanToolUse(let id, _) = $0 { return id == "B" }
            return false
        }
        XCTAssertNotNil(orphanUse)
    }

    func test_validate_multiplePairsAllMatchedInOrder_isValid() {
        // 两对 tool_use / tool_result，按顺序
        let messages: [MessageParameter.Message] = [
            assistantMsg(toolUseIds: ["X", "Y"]),
            userMsg(toolUseIds: ["X", "Y"]),
            assistantMsg(toolUseIds: ["Z"]),
            userMsg(toolUseIds: ["Z"]),
        ]
        let result = validator.validate(messages)
        XCTAssertTrue(result.isValid)
    }

    func test_validate_toolResultBeforeToolUse_isOrphan() {
        // tool_result 出现在 tool_use 之前（非法顺序）
        let messages: [MessageParameter.Message] = [
            userMsg(toolUseIds: ["C"]),       // tool_result C 在前
            assistantMsg(toolUseIds: ["C"]),  // tool_use C 在后
        ]
        let result = validator.validate(messages)
        XCTAssertFalse(result.isValid)
    }

    // MARK: - 边界情况

    func test_adjustedStartIndex_startIndexEqualToMessagesCount_returnsProposedIndex() {
        let messages: [MessageParameter.Message] = [textMsg(role: .user)]
        // proposedStart == messages.count（表示不保留任何消息）
        let result = validator.adjustedStartIndex(1, in: messages)
        XCTAssertEqual(result, 1)
    }

    func test_adjustedStartIndex_chainedToolRounds_pullsBackToEarliestRequired() {
        // round-1: assistant(tool_use X) + user(tool_result X)
        // round-2: assistant(tool_use Y) + user(tool_result Y)
        // round-3: assistant(text only)
        // 提案 startIndex = 3 (仅保留 round-3 起)
        // tool_result Y 需要 tool_use Y (index 2) → adjustedIndex = 2
        let messages: [MessageParameter.Message] = [
            assistantMsg(toolUseIds: ["X"]),  // 0
            userMsg(toolUseIds: ["X"]),       // 1
            assistantMsg(toolUseIds: ["Y"]),  // 2
            userMsg(toolUseIds: ["Y"]),       // 3
            textMsg(role: .assistant),        // 4
        ]
        let result = validator.adjustedStartIndex(3, in: messages)
        XCTAssertEqual(result, 2)
    }

    func test_adjustedStartIndex_orphanToolResultNotInKeptRange_doesNotPullBack() {
        // [0: assistant(tool_use A), 1: user(tool_result A), 2: text-user, 3: text-assistant]
        // proposedStart = 2 → kept range [2,3] 中没有 tool_result → 不需要调整
        let messages: [MessageParameter.Message] = [
            assistantMsg(toolUseIds: ["A"]),
            userMsg(toolUseIds: ["A"]),
            textMsg(role: .user),
            textMsg(role: .assistant),
        ]
        let result = validator.adjustedStartIndex(2, in: messages)
        XCTAssertEqual(result, 2)
    }

    func test_validate_singleTextMessage_isValid() {
        let result = validator.validate([textMsg(role: .user)])
        XCTAssertTrue(result.isValid)
    }

    func test_validate_multipleOrphans_reportsAll() {
        // 两个孤立 tool_result，一个孤立 tool_use
        let messages: [MessageParameter.Message] = [
            assistantMsg(toolUseIds: ["orphan-use"]),  // 0: orphan tool_use
            userMsg(toolUseIds: ["r1", "r2"]),         // 1: orphan tool_results
        ]
        let result = validator.validate(messages)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.violations.count, 3)  // 2 orphanToolResult + 1 orphanToolUse
    }
}

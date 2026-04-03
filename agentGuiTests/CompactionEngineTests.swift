import XCTest
import SwiftAnthropic
@testable import agentGui

final class CompactionEngineTests: XCTestCase {

    private let engine = CompactionEngine()

    // MARK: - Helper factories

    private func textMsg(_ role: MessageParameter.Message.Role, _ text: String = "x") -> MessageParameter.Message {
        MessageParameter.Message(role: role, content: .text(text))
    }

    private func assistantMsg(toolUseIds: [String]) -> MessageParameter.Message {
        .init(role: .assistant, content: .list(toolUseIds.map { .toolUse($0, "bash", [:]) }))
    }

    private func userMsg(toolUseIds: [String]) -> MessageParameter.Message {
        .init(role: .user, content: .list(toolUseIds.map { .toolResult($0, "out", isError: nil) }))
    }

    // MARK: - proposeCutIndex

    func test_proposeCutIndex_emptyMessages_returnsZero() {
        let idx = engine.proposeCutIndex(in: [])
        XCTAssertEqual(idx, 0)
    }

    func test_proposeCutIndex_fewerThanMinimum_returnsZero() {
        // 4 条消息 < minimumKeepRecentCount(8) → cut at 0
        let msgs = (0..<4).map { _ in textMsg(.user) }
        let idx = engine.proposeCutIndex(in: msgs)
        XCTAssertEqual(idx, 0)
    }

    func test_proposeCutIndex_exactlyMinimum_returnsZero() {
        let msgs = (0..<8).map { _ in textMsg(.user) }
        let idx = engine.proposeCutIndex(in: msgs)
        XCTAssertEqual(idx, 0)
    }

    func test_proposeCutIndex_largeHistory_keepsApproximatelyQuarter() {
        // 40 条 → keep 25% = 10；raw cut = 30
        let msgs = (0..<40).map { _ in textMsg(.user) }
        let idx = engine.proposeCutIndex(in: msgs)
        XCTAssertEqual(idx, 30)
    }

    func test_proposeCutIndex_adjustsForOrphanToolResult() {
        // 要测试 tool_result 边界调整，需要 > 32 条消息（minimumKeepRecentCount=8，25% > 8 时才生效）
        // 40 条消息：index 29 = assistant(tool_use Y), index 30 = user(tool_result Y)
        // keepCount = max(8, 40*0.25=10) = 10, rawCut = 30
        // kept = [30..39]; index 30 has tool_result Y → needs tool_use Y at index 29 → adjust to 29
        var msgs: [MessageParameter.Message] = (0..<29).map { _ in textMsg(.user) }  // 0..28
        msgs.append(assistantMsg(toolUseIds: ["Y"]))     // 29: tool_use Y
        msgs.append(userMsg(toolUseIds: ["Y"]))          // 30: tool_result Y
        msgs += (0..<9).map { _ in textMsg(.user) }     // 31..39
        // Total = 40
        let idx = engine.proposeCutIndex(in: msgs)
        XCTAssertEqual(idx, 29)  // adjusted back from 30 to 29
    }

    func test_proposeCutIndex_noAdjustment_whenBoundaryIsClean() {
        // 40 条消息，rawCut = 30；index 30 是普通 user text（无 tool_result）→ 不需要调整
        var msgs: [MessageParameter.Message] = (0..<28).map { _ in textMsg(.user) }  // 0..27
        msgs.append(assistantMsg(toolUseIds: ["T1"]))    // 28: tool_use T1
        msgs.append(userMsg(toolUseIds: ["T1"]))         // 29: tool_result T1
        msgs += (0..<10).map { _ in textMsg(.user) }    // 30..39 plain user texts
        // Total = 40, keepCount = max(8, 10) = 10, rawCut = 30
        // index 30 is plain user text → no adjustment needed → cut stays at 30
        let idx = engine.proposeCutIndex(in: msgs)
        XCTAssertEqual(idx, 30)
    }

    // MARK: - buildCompactedMessages

    func test_buildCompactedMessages_replacesHeadWithSummaryUserMessage() {
        let msgs = (0..<10).map { i in textMsg(i % 2 == 0 ? .user : .assistant, "msg\(i)") }
        let result = engine.buildCompactedMessages(original: msgs, summaryText: "summary text", cutIndex: 6)
        // result = [summary user msg] + msgs[6..9]
        XCTAssertEqual(result.count, 5)  // 1 summary + 4 kept
        guard case .text(let first) = result[0].content else {
            XCTFail("First message must be text"); return
        }
        XCTAssertTrue(first.contains("summary text"))
        XCTAssertTrue(first.contains("[Conversation history has been compacted]"))
    }

    func test_buildCompactedMessages_summaryMessageHasUserRole() {
        let msgs = (0..<10).map { _ in textMsg(.user) }
        let result = engine.buildCompactedMessages(original: msgs, summaryText: "s", cutIndex: 8)
        XCTAssertEqual(result[0].role, "user")
    }

    func test_buildCompactedMessages_cutIndexAtEnd_returnsJustSummary() {
        let msgs = (0..<5).map { _ in textMsg(.user) }
        let result = engine.buildCompactedMessages(original: msgs, summaryText: "s", cutIndex: 5)
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - buildCompactedMessages with sessionSummary (M-11 summary.md integration)

    func test_buildCompactedMessages_withSessionSummary_includesSummarySection() {
        let msgs = (0..<10).map { _ in textMsg(.user) }
        let result = engine.buildCompactedMessages(
            original: msgs, summaryText: "compact summary", cutIndex: 8,
            sessionSummary: "Session memory: previously worked on X")
        guard case .text(let text) = result[0].content else { XCTFail(); return }
        XCTAssertTrue(text.contains("Session memory: previously worked on X"))
        XCTAssertTrue(text.contains("Session Memory"))
    }

    func test_buildCompactedMessages_nilSessionSummary_noSessionMemorySection() {
        let msgs = (0..<10).map { _ in textMsg(.user) }
        let result = engine.buildCompactedMessages(
            original: msgs, summaryText: "s", cutIndex: 8, sessionSummary: nil)
        guard case .text(let text) = result[0].content else { XCTFail(); return }
        XCTAssertFalse(text.contains("Session Memory"))
    }
}

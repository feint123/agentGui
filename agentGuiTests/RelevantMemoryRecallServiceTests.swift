import XCTest
import SwiftAnthropic
@testable import agentGui

final class RelevantMemoryRecallServiceTests: XCTestCase {

    // MARK: - extractUserQuery

    func test_extractUserQuery_lastUserMessage_returnsText() {
        let messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text("First message")),
            .init(role: .assistant, content: .text("Reply")),
            .init(role: .user, content: .text("What is the API key format?"))
        ]
        let text = RelevantMemoryRecallService.extractUserQuery(from: messages)
        XCTAssertEqual(text, "What is the API key format?")
    }

    func test_extractUserQuery_noUserMessage_returnsNil() {
        let messages: [MessageParameter.Message] = [
            .init(role: .assistant, content: .text("Hello"))
        ]
        XCTAssertNil(RelevantMemoryRecallService.extractUserQuery(from: messages))
    }

    func test_extractUserQuery_singleWord_returnsNil() {
        let messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text("hello"))
        ]
        XCTAssertNil(
            RelevantMemoryRecallService.extractUserQuery(from: messages),
            "单词 query 缺乏足够上下文，应返回 nil"
        )
    }

    // MARK: - formatInjectionBlock

    func test_formatInjectionBlock_wrapsInSystemReminder() {
        let result = RelevantMemoryRecallService.formatInjectionBlock(
            filename: "foo_abc12345.md",
            content: "The API key must be 32 chars.",
            mtimeMs: 1_700_000_000_000,
            now: Date(timeIntervalSince1970: 1_700_000_000_000 / 1000 + 86_400 * 3)
        )
        XCTAssertTrue(result.contains("<system-reminder>"))
        XCTAssertTrue(result.contains("</system-reminder>"))
        XCTAssertTrue(result.contains("foo_abc12345.md"))
        XCTAssertTrue(result.contains("The API key must be 32 chars."))
    }

    func test_formatInjectionBlock_freshMemory_noFreshnessWarning() {
        let now = Date()
        let result = RelevantMemoryRecallService.formatInjectionBlock(
            filename: "fresh_abc12345.md",
            content: "Fresh content.",
            mtimeMs: now.timeIntervalSince1970 * 1000,
            now: now
        )
        // 今天的记忆不应有 freshness warning
        XCTAssertFalse(result.contains("days old"))
    }

    func test_formatInjectionBlock_staleMemory_includesFreshnessWarning() {
        let now = Date()
        let tenDaysAgo = now.addingTimeInterval(-86_400 * 10)
        let result = RelevantMemoryRecallService.formatInjectionBlock(
            filename: "stale_abc12345.md",
            content: "Old content.",
            mtimeMs: tenDaysAgo.timeIntervalSince1970 * 1000,
            now: now
        )
        XCTAssertTrue(result.contains("days old"), "10 天前的记忆应有 freshness warning")
    }

    // MARK: - collectRecentToolNames

    func test_collectRecentToolNames_extractsToolUseNames() throws {
        // 空消息快照测试
        let names = RelevantMemoryRecallService.collectRecentToolNames(
            from: [],
            maxRounds: 3
        )
        XCTAssertTrue(names.isEmpty)
    }
}

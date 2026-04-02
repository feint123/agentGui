import XCTest
@testable import agentGui

/// 测试 `MemoryAge.swift` 中与 Claude Code `memoryAge.ts` 对齐的自由函数。
///
/// 固定 `now = 2024-10-04T00:00:00Z`（unix: 86_400 * 20_000）以避免跨午夜偶发失败。
final class MemoryAgeTests: XCTestCase {

    // MARK: - Fixtures

    private let now = Date(timeIntervalSince1970: 86_400 * 20_000)

    /// 将 "N 天前" 转换为 mtimeMs（毫秒）
    private func mtimeMsDaysAgo(_ days: Int) -> Double {
        (now.timeIntervalSince1970 - Double(days) * 86_400) * 1000
    }

    // MARK: - memoryAgeDays

    func test_memoryAgeDays_sameInstant_isZero() {
        XCTAssertEqual(memoryAgeDays(now.timeIntervalSince1970 * 1000, now: now), 0)
    }

    func test_memoryAgeDays_oneDayAgo_isOne() {
        XCTAssertEqual(memoryAgeDays(mtimeMsDaysAgo(1), now: now), 1)
    }

    func test_memoryAgeDays_futureMtime_clampsToZero() {
        let futureMtimeMs = (now.timeIntervalSince1970 + 86_400 * 5) * 1000
        XCTAssertEqual(memoryAgeDays(futureMtimeMs, now: now), 0,
                       "未来时间戳应截断到 0（时钟偏差场景）")
    }

    func test_memoryAgeDays_thirtyDays_isThirty() {
        XCTAssertEqual(memoryAgeDays(mtimeMsDaysAgo(30), now: now), 30)
    }

    // MARK: - memoryAge

    func test_memoryAge_today_returnsEnglishToday() {
        XCTAssertEqual(memoryAge(now.timeIntervalSince1970 * 1000, now: now), "today")
    }

    func test_memoryAge_yesterday_returnsEnglishYesterday() {
        XCTAssertEqual(memoryAge(mtimeMsDaysAgo(1), now: now), "yesterday")
    }

    func test_memoryAge_sevenDays_returnsNDaysAgo() {
        XCTAssertEqual(memoryAge(mtimeMsDaysAgo(7), now: now), "7 days ago")
    }

    func test_memoryAge_thirtyDays_returnsNDaysAgo() {
        XCTAssertEqual(memoryAge(mtimeMsDaysAgo(30), now: now), "30 days ago")
    }

    // MARK: - memoryFreshnessText

    func test_memoryFreshnessText_today_isEmpty() {
        XCTAssertTrue(
            memoryFreshnessText(now.timeIntervalSince1970 * 1000, now: now).isEmpty,
            "今天的记忆不应有 freshness 警告"
        )
    }

    func test_memoryFreshnessText_yesterday_isEmpty() {
        XCTAssertTrue(
            memoryFreshnessText(mtimeMsDaysAgo(1), now: now).isEmpty,
            "昨天的记忆不应有 freshness 警告（边界值）"
        )
    }

    func test_memoryFreshnessText_twoDays_containsAgeAndVerifyHint() {
        let text = memoryFreshnessText(mtimeMsDaysAgo(2), now: now)
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("2 days old"),
                      "应明确输出 '2 days old'，模型不善做日期计算")
        XCTAssertTrue(text.contains("Verify"),
                      "应包含 Verify 提示引导 agent 核实")
        XCTAssertTrue(text.contains("point-in-time observations"),
                      "措辞应与 Claude Code memoryFreshnessText 对齐")
    }

    func test_memoryFreshnessText_sevenDays_containsCorrectAge() {
        let text = memoryFreshnessText(mtimeMsDaysAgo(7), now: now)
        XCTAssertTrue(text.contains("7 days old"))
    }

    func test_memoryFreshnessText_thirtyDays_containsCorrectAge() {
        let text = memoryFreshnessText(mtimeMsDaysAgo(30), now: now)
        XCTAssertTrue(text.contains("30 days old"))
    }

    // MARK: - memoryFreshnessNote

    func test_memoryFreshnessNote_today_isEmpty() {
        XCTAssertTrue(
            memoryFreshnessNote(now.timeIntervalSince1970 * 1000, now: now).isEmpty
        )
    }

    func test_memoryFreshnessNote_yesterday_isEmpty() {
        XCTAssertTrue(
            memoryFreshnessNote(mtimeMsDaysAgo(1), now: now).isEmpty,
            "≤1 天不应生成 <system-reminder> 节"
        )
    }

    func test_memoryFreshnessNote_twoDays_wrapsInSystemReminder() {
        let note = memoryFreshnessNote(mtimeMsDaysAgo(2), now: now)
        XCTAssertTrue(note.contains("<system-reminder>"))
        XCTAssertTrue(note.contains("</system-reminder>"))
        XCTAssertTrue(note.contains("2 days old"))
    }

    func test_memoryFreshnessNote_endsWithNewline() {
        let note = memoryFreshnessNote(mtimeMsDaysAgo(3), now: now)
        XCTAssertTrue(note.hasSuffix("\n"),
                      "freshnessNote 末尾应带换行，与 Claude Code 对齐")
    }
}

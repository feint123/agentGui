import XCTest
@testable import agentGui

final class MemoryFreshnessAnnotatorTests: XCTestCase {

    private let annotator = MemoryFreshnessAnnotator()

    // 固定 now，避免跨午夜边界的偶发失败
    private let now = Date(timeIntervalSince1970: 86_400 * 20_000)  // 2024-10-04T00:00:00Z

    private func daysAgo(_ days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    // MARK: - ageDays

    func test_ageDays_sameMoment_isZero() {
        XCTAssertEqual(annotator.ageDays(updatedAt: now, now: now), 0)
    }

    func test_ageDays_oneDay_isOne() {
        XCTAssertEqual(annotator.ageDays(updatedAt: daysAgo(1), now: now), 1)
    }

    func test_ageDays_futureMtime_clampsToZero() {
        let future = now.addingTimeInterval(86_400 * 5)
        XCTAssertEqual(annotator.ageDays(updatedAt: future, now: now), 0,
                       "未来时间戳应截断到 0（处理时钟偏差）")
    }

    func test_ageDays_thirtyDays_isThirty() {
        XCTAssertEqual(annotator.ageDays(updatedAt: daysAgo(30), now: now), 30)
    }

    func test_ageDays_sevenDays_isSeven() {
        XCTAssertEqual(annotator.ageDays(updatedAt: daysAgo(7), now: now), 7)
    }

    // MARK: - ageText

    func test_ageText_today_returnsToday() {
        XCTAssertEqual(annotator.ageText(updatedAt: now, now: now), "今天")
    }

    func test_ageText_yesterday_returnsYesterday() {
        XCTAssertEqual(annotator.ageText(updatedAt: daysAgo(1), now: now), "昨天")
    }

    func test_ageText_sevenDays_returnsDaysAgo() {
        XCTAssertEqual(annotator.ageText(updatedAt: daysAgo(7), now: now), "7 天前")
    }

    func test_ageText_thirtyDays_returnsThirtyDaysAgo() {
        XCTAssertEqual(annotator.ageText(updatedAt: daysAgo(30), now: now), "30 天前")
    }

    // MARK: - freshnessText

    func test_freshnessText_today_isEmpty() {
        XCTAssertTrue(annotator.freshnessText(updatedAt: now, now: now).isEmpty,
                      "今天的记忆不应有 freshness warning")
    }

    func test_freshnessText_yesterday_isEmpty() {
        XCTAssertTrue(annotator.freshnessText(updatedAt: daysAgo(1), now: now).isEmpty,
                      "昨天的记忆不应有 freshness warning（边界值）")
    }

    func test_freshnessText_twoDays_containsAgeAndVerifyHint() {
        let text = annotator.freshnessText(updatedAt: daysAgo(2), now: now)
        XCTAssertFalse(text.isEmpty, "2 天前的记忆应有 freshness warning")
        XCTAssertTrue(text.contains("2 days old"),
                      "应明确写出 '2 days old' — 模型不善做日期计算")
        XCTAssertTrue(text.contains("Verify"),
                      "应包含 Verify 提示，引导 agent 核实")
    }

    func test_freshnessText_sevenDays_containsCorrectAge() {
        let text = annotator.freshnessText(updatedAt: daysAgo(7), now: now)
        XCTAssertTrue(text.contains("7 days old"))
    }

    func test_freshnessText_thirtyDays_containsCorrectAge() {
        let text = annotator.freshnessText(updatedAt: daysAgo(30), now: now)
        XCTAssertTrue(text.contains("30 days old"))
    }

    // MARK: - freshnessNote

    func test_freshnessNote_yesterday_isEmpty() {
        let note = annotator.freshnessNote(updatedAt: daysAgo(1), now: now)
        XCTAssertTrue(note.isEmpty,
                      "≤1 天的记忆不应生成 <system-reminder> 节")
    }

    func test_freshnessNote_twoDays_wrapsInSystemReminder() {
        let note = annotator.freshnessNote(updatedAt: daysAgo(2), now: now)
        XCTAssertTrue(note.contains("<system-reminder>"),
                      "freshness note 应以 <system-reminder> 开头")
        XCTAssertTrue(note.contains("</system-reminder>"),
                      "freshness note 应以 </system-reminder> 结尾")
        XCTAssertTrue(note.contains("2 days old"))
    }

    func test_freshnessNote_today_isEmpty() {
        let note = annotator.freshnessNote(updatedAt: now, now: now)
        XCTAssertTrue(note.isEmpty)
    }
}

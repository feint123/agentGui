import XCTest
@testable import agentGui

final class MemoryTopicFilenameTests: XCTestCase {

    func test_filename_normalCase() {
        XCTAssertEqual(
            MemoryTopicFilename.filename(title: "User Role", id: "abcd1234-xxxx"),
            "user_role_abcd1234.md"
        )
    }

    func test_filename_specialCharsAreSlugified() {
        XCTAssertEqual(
            MemoryTopicFilename.filename(title: "Feedback: No mock DB!", id: "abcd1234-xxxx"),
            "feedback_no_mock_db_abcd1234.md"
        )
    }

    func test_filename_titleTruncatedAt40Chars() {
        let longTitle = String(repeating: "a", count: 60)
        let name = MemoryTopicFilename.filename(title: longTitle, id: "abcd1234-xxxx")
        // slug part ≤ 40 chars + "_" + 8 char id + ".md"
        let slugPart = name.replacingOccurrences(of: "_abcd1234.md", with: "")
        XCTAssertLessThanOrEqual(slugPart.count, 40)
    }

    func test_filename_emptyTitleFallsBackToMemoryPrefix() {
        XCTAssertEqual(
            MemoryTopicFilename.filename(title: "", id: "abcd1234-xxxx"),
            "memory_abcd1234.md"
        )
    }

    func test_filename_unicodeTitleFallsBackToMemoryPrefix() {
        // 全 Unicode 字符（非 ASCII 字母数字）→ slug 为空 → fallback
        let name = MemoryTopicFilename.filename(title: "纯中文标 题", id: "abcd1234-xxxx")
        XCTAssertTrue(name.hasPrefix("memory_"), "非 ASCII slug 应 fallback 到 memory_ 前缀")
    }

    func test_sanitizeTitle_rejectsPathTraversal() {
        let slug = MemoryTopicFilename.sanitizeTitle("../../etc/passwd")
        XCTAssertFalse(slug.contains(".."), "slug 不应包含路径穿越字符")
        XCTAssertFalse(slug.contains("/"), "slug 不应包含斜线")
    }

    func test_filename_idShorterThan8UsesFullId() {
        let name = MemoryTopicFilename.filename(title: "Short ID Record", id: "ab12")
        XCTAssertTrue(name.hasSuffix("_ab12.md"), "ID 不足 8 位时使用完整 ID")
    }

    // MARK: - filename(title:suffix:)

    func test_filenameFromTitleAndSuffix_basic() {
        let name = MemoryTopicFilename.filename(title: "User Role", suffix: "abcd1234")
        XCTAssertEqual(name, "user_role_abcd1234.md")
    }

    func test_filenameFromTitleAndSuffix_emptyTitle_fallsBack() {
        let name = MemoryTopicFilename.filename(title: "", suffix: "abcd1234")
        XCTAssertEqual(name, "memory_abcd1234.md")
    }

    func test_filenameFromTitleAndSuffix_truncatesLongTitle() {
        let longTitle = String(repeating: "x", count: 60)
        let name = MemoryTopicFilename.filename(title: longTitle, suffix: "12345678")
        XCTAssertTrue(name.hasSuffix("_12345678.md"))
        XCTAssertTrue(name.count <= 56) // 40 slug + _ + 8 suffix + .md
    }
}

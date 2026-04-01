import XCTest
@testable import agentGui

final class MemoryTopicFilenameTests: XCTestCase {

    func test_filename_normalCase() {
        let record = MemoryRecord.fixture(id: "abcd1234-xxxx", title: "User Role")
        XCTAssertEqual(MemoryTopicFilename.filename(for: record), "user_role_abcd1234.md")
    }

    func test_filename_specialCharsAreSlugified() {
        let record = MemoryRecord.fixture(id: "abcd1234-xxxx", title: "Feedback: No mock DB!")
        XCTAssertEqual(MemoryTopicFilename.filename(for: record), "feedback_no_mock_db_abcd1234.md")
    }

    func test_filename_titleTruncatedAt40Chars() {
        let longTitle = String(repeating: "a", count: 60)
        let record = MemoryRecord.fixture(id: "abcd1234-xxxx", title: longTitle)
        let name = MemoryTopicFilename.filename(for: record)
        // slug part ≤ 40 chars + "_" + 8 char id + ".md"
        let slugPart = name.replacingOccurrences(of: "_abcd1234.md", with: "")
        XCTAssertLessThanOrEqual(slugPart.count, 40)
    }

    func test_filename_emptyTitleFallsBackToMemoryPrefix() {
        let record = MemoryRecord.fixture(id: "abcd1234-xxxx", title: "")
        XCTAssertEqual(MemoryTopicFilename.filename(for: record), "memory_abcd1234.md")
    }

    func test_filename_unicodeTitleFallsBackToMemoryPrefix() {
        // 全 Unicode 字符（非 ASCII 字母数字）→ slug 为空 → fallback
        let record = MemoryRecord.fixture(id: "abcd1234-xxxx", title: "纯中文标题")
        let name = MemoryTopicFilename.filename(for: record)
        XCTAssertTrue(name.hasPrefix("memory_"), "非 ASCII slug 应 fallback 到 memory_ 前缀")
    }

    func test_sanitizeTitle_rejectsPathTraversal() {
        let slug = MemoryTopicFilename.sanitizeTitle("../../etc/passwd")
        XCTAssertFalse(slug.contains(".."), "slug 不应包含路径穿越字符")
        XCTAssertFalse(slug.contains("/"), "slug 不应包含斜线")
    }

    func test_filename_idShorterThan8UsesFullId() {
        let record = MemoryRecord.fixture(id: "ab12", title: "Short ID Record")
        let name = MemoryTopicFilename.filename(for: record)
        XCTAssertTrue(name.hasSuffix("_ab12.md"), "ID 不足 8 位时使用完整 ID")
    }
}

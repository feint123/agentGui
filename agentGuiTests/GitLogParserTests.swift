import XCTest
@testable import agentGui

final class GitLogParserTests: XCTestCase {

    private let sampleOutput = """
    ---COMMIT---
    abcdef1234567890abcdef1234567890abcdef12
    fix: handle nil case
    fix: handle nil case

    Resolved a crash when the user taps on an empty list.
    ---END---
    ---COMMIT---
    1111111111111111111111111111111111111111
    feat: add dark mode
    feat: add dark mode
    ---END---
    """

    func test_parse_returnsCorrectCount() throws {
        let commits = try GitLogParser.parse(sampleOutput)
        XCTAssertEqual(commits.count, 2)
    }

    func test_parse_firstCommit_sha() throws {
        let commits = try GitLogParser.parse(sampleOutput)
        XCTAssertEqual(commits[0].sha, "abcdef1234567890abcdef1234567890abcdef12")
    }

    func test_parse_firstCommit_message() throws {
        let commits = try GitLogParser.parse(sampleOutput)
        XCTAssertEqual(commits[0].message, "fix: handle nil case")
    }

    func test_parse_firstCommit_fullMessageContainsBody() throws {
        let commits = try GitLogParser.parse(sampleOutput)
        XCTAssertTrue(commits[0].fullMessage.contains("Resolved a crash"))
    }

    func test_parse_emptyInput_returnsEmpty() throws {
        let commits = try GitLogParser.parse("")
        XCTAssertTrue(commits.isEmpty)
    }

    func test_parse_singleLineBody_noExtraBody() throws {
        let commits = try GitLogParser.parse(sampleOutput)
        XCTAssertEqual(commits[1].message, "feat: add dark mode")
    }

    // MARK: - Rich format tests (Task 3)

    private let richOutput = """
    ---COMMIT---
    abcdef1234567890abcdef1234567890abcdef12
    fix: handle nil case
    Alice
    alice@example.com
    2026-04-07T10:00:00+08:00
    fix: handle nil case

    Body text here.
    ---END---
    """

    func test_parse_rich_author() throws {
        let commits = try GitLogParser.parseRich(richOutput)
        XCTAssertEqual(commits[0].author, "Alice")
    }

    func test_parse_rich_email() throws {
        let commits = try GitLogParser.parseRich(richOutput)
        XCTAssertEqual(commits[0].authorEmail, "alice@example.com")
    }

    func test_parse_rich_date_notDistantPast() throws {
        let commits = try GitLogParser.parseRich(richOutput)
        let year2025 = Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 1))!
        XCTAssertGreaterThan(commits[0].date, year2025)
    }
}

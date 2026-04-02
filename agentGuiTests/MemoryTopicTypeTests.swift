import XCTest
@testable import agentGui

final class MemoryTopicTypeTests: XCTestCase {

    // MARK: - allCases

    func test_allCases_containsExactlyFourTypes() {
        let cases = MemoryTopicType.allCases
        XCTAssertEqual(cases.count, 4)
        XCTAssertTrue(cases.contains(.user))
        XCTAssertTrue(cases.contains(.feedback))
        XCTAssertTrue(cases.contains(.project))
        XCTAssertTrue(cases.contains(.reference))
    }

    // MARK: - rawValue

    func test_rawValues_matchClaudeCodeConstants() {
        XCTAssertEqual(MemoryTopicType.user.rawValue,      "user")
        XCTAssertEqual(MemoryTopicType.feedback.rawValue,  "feedback")
        XCTAssertEqual(MemoryTopicType.project.rawValue,   "project")
        XCTAssertEqual(MemoryTopicType.reference.rawValue, "reference")
    }

    // MARK: - parse

    func test_parse_validLowercaseValues_returnsCorrectCase() {
        XCTAssertEqual(MemoryTopicType.parse("user"),      .user)
        XCTAssertEqual(MemoryTopicType.parse("feedback"),  .feedback)
        XCTAssertEqual(MemoryTopicType.parse("project"),   .project)
        XCTAssertEqual(MemoryTopicType.parse("reference"), .reference)
    }

    func test_parse_unknownString_returnsNil() {
        XCTAssertNil(MemoryTopicType.parse("bogus"))
        XCTAssertNil(MemoryTopicType.parse("User"))   // 大小写敏感
        XCTAssertNil(MemoryTopicType.parse(""))
    }

    func test_parse_nil_returnsNil() {
        XCTAssertNil(MemoryTopicType.parse(nil))
    }
}

import XCTest
@testable import agentGui

final class MemorySemanticTypeTests: XCTestCase {

    func test_allCasesExist() {
        // 确保四个语义类型都存在
        let all: [MemorySemanticType] = [.user, .feedback, .project, .reference]
        XCTAssertEqual(all.count, 4)
    }

    func test_rawValues_matchClaudeCodeSpec() {
        XCTAssertEqual(MemorySemanticType.user.rawValue,      "user")
        XCTAssertEqual(MemorySemanticType.feedback.rawValue,  "feedback")
        XCTAssertEqual(MemorySemanticType.project.rawValue,   "project")
        XCTAssertEqual(MemorySemanticType.reference.rawValue, "reference")
    }

    func test_codable_roundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for type_ in MemorySemanticType.allCases {
            let data = try encoder.encode(type_)
            let decoded = try decoder.decode(MemorySemanticType.self, from: data)
            XCTAssertEqual(decoded, type_)
        }
    }

    func test_init_fromRawValue_returnsNil_forUnknown() {
        XCTAssertNil(MemorySemanticType(rawValue: "unknown"))
        XCTAssertNil(MemorySemanticType(rawValue: ""))
    }
}

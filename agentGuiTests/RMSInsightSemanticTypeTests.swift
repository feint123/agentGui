import XCTest
@testable import agentGui

final class RMSInsightSemanticTypeTests: XCTestCase {

    // 仅测试新增字段，其余 RMSInsight 行为不在此处覆盖

    func test_defaultSemanticType_isNil() {
        let insight = RMSInsight(
            id: "test-1",
            kind: .constraint,
            summary: "Always run tests before merging",
            appliesWhen: "coding",
            changesDecision: "Run tests first",
            evidenceRefs: [],
            confidence: 0.9
        )
        XCTAssertNil(insight.semanticType)
    }

    func test_semanticType_canBeSetToFeedback() {
        var insight = RMSInsight(
            id: "test-2",
            kind: .counterexample,
            summary: "Don't mock DB in integration tests",
            appliesWhen: "testing",
            changesDecision: "Use real DB",
            evidenceRefs: [],
            confidence: 0.85
        )
        insight.semanticType = .feedback
        XCTAssertEqual(insight.semanticType, .feedback)
    }

    func test_codable_roundTrip_withSemanticType() throws {
        var insight = RMSInsight(
            id: "test-3",
            kind: .tactic,
            summary: "Use xcodebuild targeted runs",
            appliesWhen: "xcodebuild",
            changesDecision: "Use focused test",
            evidenceRefs: [],
            confidence: 0.75
        )
        insight.semanticType = .project

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(insight)
        let decoded = try decoder.decode(RMSInsight.self, from: data)
        XCTAssertEqual(decoded.semanticType, .project)
    }

    func test_codable_roundTrip_withoutSemanticType_nilPreserved() throws {
        // 模拟旧 JSON：无 semanticType 字段
        let json = """
        {
            "id": "legacy-id",
            "kind": "constraint",
            "summary": "Some old constraint",
            "appliesWhen": "coding",
            "changesDecision": "Do X instead",
            "evidenceRefs": [],
            "confidence": 0.8
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let insight = try decoder.decode(RMSInsight.self, from: json)
        XCTAssertNil(insight.semanticType,
                     "旧 JSON 缺少 semanticType 字段时应反序列化为 nil")
    }
}

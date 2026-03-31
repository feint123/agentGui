import Foundation
import Testing
@testable import agentGui

struct AgentTeamReviewReportTests {

    @Test
    func reviewReportRoundTripsThroughJSON() throws {
        let report = AgentTeamReviewReport(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            reviewer: .builtIn,
            reviewedArtifactIDs: [UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!],
            kind: .validation,
            decision: .approved,
            rationale: "全部验证通过，无遗漏。",
            issues: [],
            conflictingArtifactPairs: [],
            submittedAt: Date(timeIntervalSince1970: 1_000_000)
        )

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(AgentTeamReviewReport.self, from: data)
        #expect(decoded == report)
    }

    @Test
    func reviewReportIssueRoundTripsThroughJSON() throws {
        let issue = AgentTeamReviewIssue(
            id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
            severity: .critical,
            description: "输出缺少 acceptance criterion #3 的证明。",
            targetArtifactID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        )

        let data = try JSONEncoder().encode(issue)
        let decoded = try JSONDecoder().decode(AgentTeamReviewIssue.self, from: data)
        #expect(decoded == issue)
    }

    @Test
    func payloadReviewReportRoundTripsThroughJSON() throws {
        let report = AgentTeamReviewReport(
            id: UUID(),
            reviewer: .builtIn,
            reviewedArtifactIDs: [],
            kind: .approval,
            decision: .conflictDetected,
            rationale: "PR #1 与 PR #2 修改了同一文件的相同行。",
            issues: [],
            conflictingArtifactPairs: [
                [UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                 UUID(uuidString: "22222222-2222-2222-2222-222222222222")!]
            ],
            submittedAt: Date(timeIntervalSince1970: 2_000_000)
        )
        let payload = AgentTeamArtifactPayload.reviewReport(report)

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(AgentTeamArtifactPayload.self, from: data)
        #expect(decoded == payload)
    }

    @Test
    func payloadLegacyTextDecodesWithoutCrash() throws {
        // 旧 .text payload JSON 在新代码下仍能 decode
        let legacyJSON = """
        {"type":"text","text":"hello world"}
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(AgentTeamArtifactPayload.self, from: legacyJSON)
        #expect(payload == .text("hello world"))
    }

    @Test
    func payloadReviewReportTextContentReturnRationale() {
        let report = AgentTeamReviewReport(
            id: UUID(), reviewer: .builtIn, reviewedArtifactIDs: [],
            kind: .semantic, decision: .needsWork,
            rationale: "缺少错误处理。", issues: [], conflictingArtifactPairs: [],
            submittedAt: Date()
        )
        let payload = AgentTeamArtifactPayload.reviewReport(report)
        #expect(payload.textContent == "缺少错误处理。")
    }
}

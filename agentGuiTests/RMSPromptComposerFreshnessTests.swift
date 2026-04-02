import XCTest
@testable import agentGui

final class RMSPromptComposerFreshnessTests: XCTestCase {

    private let composer = RMSPromptComposer()

    private func makeState() -> RMSState {
        RMSState(taskID: "t1", sessionID: "s1", threadID: "th1", summary: "coding task")
    }

    private func makeConstraintInsight(updatedAt: Date?) -> RMSInsight {
        RMSInsight(
            id: "insight-constraint",
            kind: .constraint,
            summary: "Always run tests before merging",
            appliesWhen: "coding",
            changesDecision: "Run tests first",
            evidenceRefs: [],
            updatedAt: updatedAt
        )
    }

    private func makeTacticInsight(updatedAt: Date?) -> RMSInsight {
        RMSInsight(
            id: "insight-tactic",
            kind: .tactic,
            summary: "Use xcodebuild targeted runs",
            appliesWhen: "xcodebuild",
            changesDecision: "Use focused invocation",
            evidenceRefs: [],
            updatedAt: updatedAt
        )
    }

    // MARK: - 新鲜 insight（今天更新）— 不应有警告

    func test_freshInsight_noFreshnessWarning() {
        // updatedAt = 当前时间，ageDays = 0
        let insight = makeConstraintInsight(updatedAt: .now)
        let output = composer.compose(state: makeState(), activatedInsights: [insight])
        XCTAssertFalse(output.contains("days old"),
                       "今天更新的 insight 不应附加 freshness warning")
    }

    // MARK: - 陈旧 insight（7 天前）— 应有警告

    func test_staleInsight_constraintKind_containsFreshnessWarning() {
        let sevenDaysAgo = Date.now.addingTimeInterval(-86_400 * 7)
        let insight = makeConstraintInsight(updatedAt: sevenDaysAgo)
        let output = composer.compose(state: makeState(), activatedInsights: [insight])
        XCTAssertTrue(output.contains("7 days old"),
                      "7 天前的 constraint insight 应在 prompt 中包含 '7 days old' 警告")
    }

    func test_staleInsight_tacticKind_containsFreshnessWarning() {
        let tenDaysAgo = Date.now.addingTimeInterval(-86_400 * 10)
        let insight = makeTacticInsight(updatedAt: tenDaysAgo)
        let output = composer.compose(state: makeState(), activatedInsights: [insight])
        XCTAssertTrue(output.contains("10 days old"),
                      "10 天前的 tactic insight 应在 prompt 中包含警告")
    }

    // MARK: - nil updatedAt — 不应有警告

    func test_nilUpdatedAt_noFreshnessWarning() {
        let insight = makeConstraintInsight(updatedAt: nil)
        let output = composer.compose(state: makeState(), activatedInsights: [insight])
        XCTAssertFalse(output.contains("days old"),
                       "nil updatedAt 的 insight 不应附加 freshness warning")
    }

    // MARK: - 昨天更新 — 不应有警告（边界值）

    func test_yesterdayInsight_noFreshnessWarning() {
        let yesterday = Date.now.addingTimeInterval(-86_400)
        let insight = makeConstraintInsight(updatedAt: yesterday)
        let output = composer.compose(state: makeState(), activatedInsights: [insight])
        XCTAssertFalse(output.contains("days old"),
                       "昨天更新的 insight（ageDays=1）不应有警告")
    }

    // MARK: - evidenceRefs + freshness 共存

    func test_staleInsight_withEvidenceRefs_bothPresent() {
        let sevenDaysAgo = Date.now.addingTimeInterval(-86_400 * 7)
        let insightWithEvidence = RMSInsight(
            id: "e-insight",
            kind: .constraint,
            summary: "Always run tests",
            appliesWhen: "coding",
            changesDecision: "Run tests first",
            evidenceRefs: ["round-42"],
            updatedAt: sevenDaysAgo
        )
        let output = composer.compose(state: makeState(), activatedInsights: [insightWithEvidence])
        XCTAssertTrue(output.contains("round-42"),
                      "evidenceRefs 应保留")
        XCTAssertTrue(output.contains("7 days old"),
                      "freshness warning 应与 evidenceRefs 共存")
    }
}

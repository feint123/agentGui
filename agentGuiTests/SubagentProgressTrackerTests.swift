import XCTest
import SwiftAnthropic
@testable import agentGui

final class SubagentProgressTrackerTests: XCTestCase {

    // MARK: - ToolActivity

    func test_toolActivity_equatable() {
        let a = ToolActivity(toolName: "bash", activityDescription: "Running tests", isRead: false, isSearch: false)
        let b = ToolActivity(toolName: "bash", activityDescription: "Running tests", isRead: false, isSearch: false)
        XCTAssertEqual(a, b)
    }

    // MARK: - SubagentProgressTracker 初始状态

    func test_freshTracker_zerosAndEmpties() {
        let tracker = SubagentProgressTracker()
        XCTAssertEqual(tracker.toolUseCount, 0)
        XCTAssertEqual(tracker.tokenCount, 0)
        XCTAssertNil(tracker.lastActivity)
        XCTAssertTrue(tracker.recentActivities.isEmpty)
    }

    // MARK: - 输入 token 覆盖语义（最新值覆盖，不累加）

    func test_update_latestInputTokens_overridesPrevious() {
        var tracker = SubagentProgressTracker()
        // 第一轮：inputTokens=100
        tracker.update(
            usage: makeUsage(inputTokens: 100, outputTokens: 50),
            pendingTools: []
        )
        XCTAssertEqual(tracker.latestInputTokens, 100)

        // 第二轮：inputTokens=350（累计，Claude API 特性）→ 应覆盖而非累加
        tracker.update(
            usage: makeUsage(inputTokens: 350, outputTokens: 80),
            pendingTools: []
        )
        XCTAssertEqual(tracker.latestInputTokens, 350)
    }

    // MARK: - 输出 token 累加语义

    func test_update_cumulativeOutputTokens_accumulates() {
        var tracker = SubagentProgressTracker()
        tracker.update(usage: makeUsage(inputTokens: 100, outputTokens: 50), pendingTools: [])
        tracker.update(usage: makeUsage(inputTokens: 200, outputTokens: 80), pendingTools: [])
        XCTAssertEqual(tracker.cumulativeOutputTokens, 130)
    }

    // MARK: - tokenCount = latestInput + cumulativeOutput

    func test_tokenCount_computation() {
        var tracker = SubagentProgressTracker()
        tracker.update(usage: makeUsage(inputTokens: 300, outputTokens: 40), pendingTools: [])
        tracker.update(usage: makeUsage(inputTokens: 500, outputTokens: 60), pendingTools: [])
        // latestInput=500, cumulativeOutput=40+60=100
        XCTAssertEqual(tracker.tokenCount, 600)
    }

    // MARK: - cache token 计入 latestInputTokens

    func test_update_cacheTokens_countedInLatestInput() {
        var tracker = SubagentProgressTracker()
        tracker.update(
            usage: makeUsage(inputTokens: 100, outputTokens: 0, cacheCreation: 200, cacheRead: 50),
            pendingTools: []
        )
        // 100 + 200 + 50 = 350
        XCTAssertEqual(tracker.latestInputTokens, 350)
    }

    // MARK: - 工具计数

    func test_update_toolUseCount_incrementsPerTool() {
        var tracker = SubagentProgressTracker()
        tracker.update(
            usage: makeUsage(inputTokens: 100, outputTokens: 10),
            pendingTools: [
                makeToolStub(name: "bash", input: [:]),
                makeToolStub(name: "str_replace_based_edit_tool", input: ["command": "view", "path": "/foo.swift"])
            ]
        )
        XCTAssertEqual(tracker.toolUseCount, 2)
    }

    // MARK: - recentActivities 上限为 5

    func test_update_recentActivities_cappedAtFive() {
        var tracker = SubagentProgressTracker()
        for i in 0..<7 {
            tracker.update(
                usage: makeUsage(inputTokens: 100, outputTokens: 5),
                pendingTools: [makeToolStub(name: "bash", input: ["command": "echo \(i)"])]
            )
        }
        XCTAssertEqual(tracker.recentActivities.count, 5)
        XCTAssertEqual(tracker.toolUseCount, 7)   // count 不受 cap 影响
    }

    // MARK: - lastActivity = 最后一个工具

    func test_lastActivity_isLatestTool() {
        var tracker = SubagentProgressTracker()
        tracker.update(
            usage: makeUsage(inputTokens: 100, outputTokens: 10),
            pendingTools: [
                makeToolStub(name: "bash", input: [:]),
                makeToolStub(name: "str_replace_based_edit_tool", input: ["command": "view", "path": "/bar.swift"])
            ]
        )
        XCTAssertEqual(tracker.lastActivity?.toolName, "str_replace_based_edit_tool")
    }

    // MARK: - nil usage 时仅更新工具（不崩溃）

    func test_update_nilUsage_onlyUpdateTools() {
        var tracker = SubagentProgressTracker()
        tracker.update(usage: nil, pendingTools: [makeToolStub(name: "bash", input: [:])])
        XCTAssertEqual(tracker.toolUseCount, 1)
        XCTAssertEqual(tracker.tokenCount, 0)
    }

    // MARK: - snapshot

    func test_snapshot_reflectsCurrentState() {
        var tracker = SubagentProgressTracker()
        tracker.update(
            usage: makeUsage(inputTokens: 200, outputTokens: 30),
            pendingTools: [makeToolStub(name: "bash", input: [:])]
        )
        let progress = tracker.snapshot()
        XCTAssertEqual(progress.toolUseCount, 1)
        XCTAssertEqual(progress.tokenCount, 230)
        XCTAssertNotNil(progress.lastActivity)
    }

    // MARK: - Helpers

    private func makeUsage(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreation: Int = 0,
        cacheRead: Int = 0
    ) -> MessageResponse.Usage {
        var dict: [String: Any] = [
            "input_tokens": inputTokens,
            "output_tokens": outputTokens
        ]
        if cacheCreation != 0 { dict["cache_creation_input_tokens"] = cacheCreation }
        if cacheRead != 0 { dict["cache_read_input_tokens"] = cacheRead }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(MessageResponse.Usage.self, from: data)
    }

    private func makeToolStub(name: String, input: [String: String]) -> AgentLoopPendingTool {
        var tool = AgentLoopPendingTool(id: UUID().uuidString, name: name)
        let jsonInput = try! JSONSerialization.data(withJSONObject: input)
        tool.partialJson = String(data: jsonInput, encoding: .utf8) ?? "{}"
        return tool
    }
}

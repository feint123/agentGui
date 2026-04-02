// agentGuiTests/SubagentTaskRecordTests.swift
import XCTest
import SwiftData
@testable import agentGui

final class SubagentTaskRecordTests: XCTestCase {

    // MARK: - 辅助

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([SubagentTaskRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - 初始化默认值测试

    func test_init_defaultStatus_isPending() {
        let record = SubagentTaskRecord(
            sessionID: UUID(),
            parentToolCallID: UUID(),
            agentName: "verifier",
            taskDescription: "运行测试套件",
            task: "Run the full test suite and report results."
        )
        XCTAssertEqual(record.status, .pending)
    }

    func test_init_toolUseCount_isZero() {
        let record = SubagentTaskRecord(
            sessionID: UUID(),
            parentToolCallID: UUID(),
            agentName: "explore",
            taskDescription: "探索代码库",
            task: "Find all usages of ClaudeService."
        )
        XCTAssertEqual(record.toolUseCount, 0)
        XCTAssertEqual(record.tokenCount, 0)
    }

    func test_init_optionalFields_areNil() {
        let record = SubagentTaskRecord(
            sessionID: UUID(),
            parentToolCallID: UUID(),
            agentName: "worker",
            taskDescription: "修改文件",
            task: "Refactor the login flow."
        )
        XCTAssertNil(record.modelID)
        XCTAssertNil(record.completedAt)
        XCTAssertNil(record.result)
        XCTAssertNil(record.errorMessage)
        XCTAssertNil(record.lastActivity)
        XCTAssertNil(record.progressSummary)
        XCTAssertNil(record.transcriptPath)
    }

    // MARK: - status 计算属性测试

    func test_statusRoundTrip_allCases() {
        let record = SubagentTaskRecord(
            sessionID: UUID(),
            parentToolCallID: UUID(),
            agentName: "verifier",
            taskDescription: "验证",
            task: "Verify the fix."
        )

        for caseValue in SubagentTaskStatus.allCases {
            record.status = caseValue
            XCTAssertEqual(record.status, caseValue,
                "状态 \(caseValue) 经 rawValue 往返后应保持一致")
        }
    }

    func test_statusRaw_defaultValue_isPending() {
        let record = SubagentTaskRecord(
            sessionID: UUID(),
            parentToolCallID: UUID(),
            agentName: "verifier",
            taskDescription: "验证",
            task: "Verify the fix."
        )
        XCTAssertEqual(record.statusRaw, SubagentTaskStatus.pending.rawValue)
    }

    func test_status_unknownRaw_fallsBackToPending() {
        let record = SubagentTaskRecord(
            sessionID: UUID(),
            parentToolCallID: UUID(),
            agentName: "verifier",
            taskDescription: "验证",
            task: "Verify the fix."
        )
        record.statusRaw = "unknown_future_value"
        XCTAssertEqual(record.status, .pending,
            "未知 rawValue 应 fallback 到 .pending")
    }

    // MARK: - SwiftData 持久化测试

    func test_persistAndFetch_roundTripsAllFields() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let sessionID = UUID()
        let toolCallID = UUID()

        let record = SubagentTaskRecord(
            sessionID: sessionID,
            parentToolCallID: toolCallID,
            agentName: "verifier",
            taskDescription: "运行集成测试",
            task: "Run ConversationExecutionRuntimeCoordinatorTests and report verdict.",
            modelID: "claude-sonnet-4-6"
        )
        record.status = .running
        record.toolUseCount = 12
        record.tokenCount = 4800
        record.lastActivity = "Running xcodebuild test"
        record.progressSummary = "Running integration tests"

        context.insert(record)
        try context.save()

        let descriptor = FetchDescriptor<SubagentTaskRecord>()
        let fetched = try context.fetch(descriptor)

        XCTAssertEqual(fetched.count, 1)
        let r = fetched[0]
        XCTAssertEqual(r.sessionID, sessionID)
        XCTAssertEqual(r.parentToolCallID, toolCallID)
        XCTAssertEqual(r.agentName, "verifier")
        XCTAssertEqual(r.taskDescription, "运行集成测试")
        XCTAssertEqual(r.task, "Run ConversationExecutionRuntimeCoordinatorTests and report verdict.")
        XCTAssertEqual(r.modelID, "claude-sonnet-4-6")
        XCTAssertEqual(r.status, .running)
        XCTAssertEqual(r.toolUseCount, 12)
        XCTAssertEqual(r.tokenCount, 4800)
        XCTAssertEqual(r.lastActivity, "Running xcodebuild test")
        XCTAssertEqual(r.progressSummary, "Running integration tests")
    }

    func test_persistAndFetch_multipleRecords_sameSession() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let sessionID = UUID()

        let r1 = SubagentTaskRecord(
            sessionID: sessionID,
            parentToolCallID: UUID(),
            agentName: "explore",
            taskDescription: "探索代码库",
            task: "Find ClaudeService usages."
        )
        let r2 = SubagentTaskRecord(
            sessionID: sessionID,
            parentToolCallID: UUID(),
            agentName: "verifier",
            taskDescription: "验证修复",
            task: "Run tests."
        )
        r1.status = .completed
        r2.status = .running

        context.insert(r1)
        context.insert(r2)
        try context.save()

        var descriptor = FetchDescriptor<SubagentTaskRecord>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        descriptor.sortBy = [SortDescriptor(\SubagentTaskRecord.startedAt)]
        let fetched = try context.fetch(descriptor)

        XCTAssertEqual(fetched.count, 2)
        let names = fetched.map(\.agentName)
        XCTAssertTrue(names.contains("explore"))
        XCTAssertTrue(names.contains("verifier"))
    }

    // MARK: - SubagentTaskStatus allCases 覆盖

    func test_allStatusCases_haveDistinctRawValues() {
        let rawValues = SubagentTaskStatus.allCases.map(\.rawValue)
        let uniqueRawValues = Set(rawValues)
        XCTAssertEqual(rawValues.count, uniqueRawValues.count,
            "所有状态的 rawValue 必须唯一")
    }

    func test_allStatusCases_nonEmpty() {
        XCTAssertFalse(SubagentTaskStatus.allCases.isEmpty)
    }
}

// agentGuiTests/SubagentProgressSummarizerTests.swift
import XCTest
import SwiftAnthropic
import SwiftData
@testable import agentGui

@MainActor
final class SubagentProgressSummarizerTests: XCTestCase {

    // MARK: - Helpers

    private func makeRecord() throws -> (SubagentTaskRecord, ModelContext) {
        let schema = Schema([SubagentTaskRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let record = SubagentTaskRecord(
            id: UUID(), sessionID: UUID(), parentToolCallID: UUID(),
            agentName: "verifier", taskDescription: "Testing", task: "Run tests",
            status: .running
        )
        context.insert(record)
        return (record, context)
    }

    private func makeSummarizer(
        record: SubagentTaskRecord,
        modelContext: ModelContext,
        apiProvider: @escaping @Sendable (
            _ systemPrompt: MessageParameter.System?,
            _ currentMessages: [MessageParameter.Message],
            _ previousSummary: String?
        ) async throws -> String?,
        intervalSeconds: Duration = .seconds(30)
    ) -> SubagentProgressSummarizer {
        SubagentProgressSummarizer(
            record: record,
            modelContext: modelContext,
            apiProvider: apiProvider,
            intervalSeconds: intervalSeconds
        )
    }

    // MARK: - 不足 3 条消息时跳过

    func test_skipsSummaryWhenFewerThan3Messages() async throws {
        let (record, ctx) = try makeRecord()
        var apiCalled = false

        let summarizer = makeSummarizer(
            record: record,
            modelContext: ctx,
            apiProvider: { _, _, _ in
                apiCalled = true
                return "Reading file"
            },
            intervalSeconds: .milliseconds(50)
        )

        await summarizer.start()
        // 只推送 2 条消息（不足 3 条）
        await summarizer.updateMessages([
            .init(role: .user, content: .text("hello")),
            .init(role: .assistant, content: .text("hi"))
        ])
        try await Task.sleep(for: .milliseconds(150))
        await summarizer.stop()

        XCTAssertFalse(apiCalled, "API 不应被调用，消息数不足 3 条")
        XCTAssertNil(record.progressSummary)
    }

    // MARK: - 足够消息时生成摘要

    func test_generatesSummaryWith3OrMoreMessages() async throws {
        let (record, ctx) = try makeRecord()
        let expectedSummary = "Reading ClaudeService.swift"
        var callCount = 0

        let summarizer = makeSummarizer(
            record: record,
            modelContext: ctx,
            apiProvider: { _, _, _ in
                callCount += 1
                return expectedSummary
            },
            intervalSeconds: .milliseconds(50)
        )

        await summarizer.start()
        let msgs: [MessageParameter.Message] = [
            .init(role: .user,      content: .text("task")),
            .init(role: .assistant, content: .text("thinking")),
            .init(role: .user,      content: .text("tool_result_placeholder"))
        ]
        await summarizer.updateMessages(msgs)
        try await Task.sleep(for: .milliseconds(150))
        await summarizer.stop()

        XCTAssertGreaterThanOrEqual(callCount, 1)
        XCTAssertEqual(record.progressSummary, expectedSummary)
    }

    // MARK: - API 失败时静默不影响 record

    func test_silentlyIgnoresAPIFailure() async throws {
        let (record, ctx) = try makeRecord()

        let summarizer = makeSummarizer(
            record: record,
            modelContext: ctx,
            apiProvider: { _, _, _ in
                throw URLError(.notConnectedToInternet)
            },
            intervalSeconds: .milliseconds(50)
        )

        await summarizer.start()
        await summarizer.updateMessages([
            .init(role: .user,      content: .text("t1")),
            .init(role: .assistant, content: .text("t2")),
            .init(role: .user,      content: .text("t3"))
        ])
        try await Task.sleep(for: .milliseconds(150))
        await summarizer.stop()

        XCTAssertNil(record.progressSummary, "API 失败时 progressSummary 应保持 nil")
    }

    // MARK: - 摘要不重叠（上次完成再调度下次）

    func test_summariesDoNotOverlap() async throws {
        let (record, ctx) = try makeRecord()
        var concurrentCallCount = 0
        var maxConcurrent = 0

        let summarizer = makeSummarizer(
            record: record,
            modelContext: ctx,
            apiProvider: { _, _, _ in
                concurrentCallCount += 1
                maxConcurrent = max(maxConcurrent, concurrentCallCount)
                try await Task.sleep(for: .milliseconds(60))
                concurrentCallCount -= 1
                return "Working"
            },
            intervalSeconds: .milliseconds(50)
        )

        await summarizer.start()
        await summarizer.updateMessages([
            .init(role: .user,      content: .text("t1")),
            .init(role: .assistant, content: .text("t2")),
            .init(role: .user,      content: .text("t3"))
        ])
        try await Task.sleep(for: .milliseconds(500))
        await summarizer.stop()

        XCTAssertEqual(maxConcurrent, 1, "同时最多只有一个摘要在进行")
    }

    // MARK: - stop 后不再触发摘要

    func test_stopPreventsSubsequentSummaries() async throws {
        let (record, ctx) = try makeRecord()
        var callCount = 0

        let summarizer = makeSummarizer(
            record: record,
            modelContext: ctx,
            apiProvider: { _, _, _ in
                callCount += 1
                return "Working"
            },
            intervalSeconds: .milliseconds(50)
        )

        await summarizer.start()
        await summarizer.updateMessages([
            .init(role: .user,      content: .text("t1")),
            .init(role: .assistant, content: .text("t2")),
            .init(role: .user,      content: .text("t3"))
        ])
        try await Task.sleep(for: .milliseconds(150))
        await summarizer.stop()

        let countAfterStop = callCount
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(callCount, countAfterStop, "stop 后不应有新的摘要调用")
    }

    // MARK: - prevSummary 传递给下一次调用

    func test_previousSummaryPassedToNextCall() async throws {
        let (record, ctx) = try makeRecord()
        var receivedPreviousSummaries: [String?] = []

        let summarizer = makeSummarizer(
            record: record,
            modelContext: ctx,
            apiProvider: { _, _, prev in
                receivedPreviousSummaries.append(prev)
                return "New summary"
            },
            intervalSeconds: .milliseconds(50)
        )

        await summarizer.start()
        await summarizer.updateMessages([
            .init(role: .user,      content: .text("t1")),
            .init(role: .assistant, content: .text("t2")),
            .init(role: .user,      content: .text("t3"))
        ])
        try await Task.sleep(for: .milliseconds(250))
        await summarizer.stop()

        // 第一次调用 prev 应为 nil，第二次应为 "New summary"
        XCTAssertNil(receivedPreviousSummaries.first ?? "unexpected")
        if receivedPreviousSummaries.count >= 2 {
            XCTAssertEqual(receivedPreviousSummaries[1], "New summary")
        }
    }

    // MARK: - filterIncompleteToolCalls — 移除无 result 的 tool_use

    func test_filterIncompleteToolCalls_removesOrphanedToolUse() {
        let toolUseId = "tool_123"
        let msgs: [MessageParameter.Message] = [
            .init(role: .user, content: .text("do something")),
            .init(role: .assistant, content: .list([
                .toolUse(toolUseId, "bash", ["command": .string("ls")])
            ]))
            // 没有 user 消息返回 tool_result
        ]

        let filtered = SubagentProgressSummarizer.filterIncompleteToolCalls(msgs)

        XCTAssertFalse(
            filtered.contains(where: { msg in
                guard case .list(let items) = msg.content else { return false }
                return items.contains(where: {
                    if case .toolUse(let id, _, _) = $0 { return id == toolUseId }
                    return false
                })
            }),
            "未完成的 tool_use assistant 消息应被过滤"
        )
    }

    func test_filterIncompleteToolCalls_keepsCompletedToolUse() {
        let toolUseId = "tool_456"
        let msgs: [MessageParameter.Message] = [
            .init(role: .user, content: .text("do something")),
            .init(role: .assistant, content: .list([
                .toolUse(toolUseId, "bash", ["command": .string("ls")])
            ])),
            .init(role: .user, content: .list([
                .toolResult(toolUseId, "output", nil, nil)
            ]))
        ]

        let filtered = SubagentProgressSummarizer.filterIncompleteToolCalls(msgs)

        XCTAssertEqual(filtered.count, 3, "完整的 tool_use/tool_result 对应保留所有消息")
    }

    // MARK: - buildSummaryPrompt

    func test_buildSummaryPrompt_withNoPrevious() {
        let prompt = SubagentProgressSummarizer.buildSummaryPrompt(previousSummary: nil)
        XCTAssertTrue(prompt.contains("Describe your most recent action"))
        XCTAssertFalse(prompt.contains("Previous:"))
        XCTAssertTrue(prompt.contains("Do not use tools"))
    }

    func test_buildSummaryPrompt_withPreviousSummary() {
        let prompt = SubagentProgressSummarizer.buildSummaryPrompt(previousSummary: "Reading file.swift")
        XCTAssertTrue(prompt.contains("Previous: \"Reading file.swift\""))
        XCTAssertTrue(prompt.contains("say something NEW"))
    }

    func test_buildSummaryPrompt_withEmptyPreviousSummary() {
        let prompt = SubagentProgressSummarizer.buildSummaryPrompt(previousSummary: "")
        XCTAssertFalse(prompt.contains("Previous:"))
    }

    // MARK: - 集成：context 先于 messages 注入后仍能生成摘要

    func test_contextInjectedAfterStart_stillGeneratesSummary() async throws {
        let (record, ctx) = try makeRecord()
        var summaryGenerated = false

        let summarizer = makeSummarizer(
            record: record,
            modelContext: ctx,
            apiProvider: { systemPrompt, messages, _ in
                summaryGenerated = true
                // context 为 nil 时也能工作（systemPrompt 为 nil，但不 crash）
                return "Writing tests"
            },
            intervalSeconds: .milliseconds(50)
        )

        // 先 start，再更新 messages（模拟 context 还没注入的情况）
        await summarizer.start()
        await summarizer.updateMessages([
            .init(role: .user,      content: .text("t1")),
            .init(role: .assistant, content: .text("t2")),
            .init(role: .user,      content: .text("t3"))
        ])
        // context 延迟注入（此时 timerTask 可能已触发，但 systemPrompt 为 nil 也不 crash）
        await summarizer.updateContext(SubagentSummaryContext(
            systemPrompt: nil,
            modelId: "claude-sonnet-4-5",
            service: AnthropicServiceFactory.service(apiKey: "test", betaHeaders: [String]?.none),
            apiKey: "test-key"
        ))

        try await Task.sleep(for: .milliseconds(200))
        await summarizer.stop()

        XCTAssertTrue(summaryGenerated)
        XCTAssertEqual(record.progressSummary, "Writing tests")
    }
}

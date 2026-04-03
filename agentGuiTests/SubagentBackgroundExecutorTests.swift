// agentGuiTests/SubagentBackgroundExecutorTests.swift
import XCTest
import SwiftData
@testable import agentGui

@MainActor
final class SubagentBackgroundExecutorTests: XCTestCase {

    // MARK: - 辅助

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([SubagentTaskRecord.self, Session.self, Message.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - 同步路径不注册 Task

    func test_launchSync_doesNotRegisterBackgroundTask() async throws {
        let executor = SubagentBackgroundExecutor()
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(title: "Test")
        context.insert(session)

        let toolCall = ToolCall(toolCallId: UUID().uuidString, kind: .subagent, message: nil)
        context.insert(toolCall)

        let params = SubagentBackgroundLaunchParams(
            agentName: "explore",
            task: "Find files",
            taskDescription: "Finding files",
            toolCallRecord: toolCall,
            sessionID: UUID(uuidString: session.sessionId) ?? UUID(),
            session: session,
            runInBackground: false, // 同步路径
            definition: WorkflowRoleDefinition.explorerFixture(),
            launchSubagent: { _, _ in
                .sync(message: .text("done", sender: "explore", metadata: [:]))
            }
        )

        let result = await executor.launch(params: params, modelContext: context)
        XCTAssertFalse(result.isAsync)

        let activeCount = await executor.activeTaskCount
        XCTAssertEqual(activeCount, 0)
    }

    // MARK: - 后台路径立即返回 async_launched

    func test_launchAsync_returnsAsyncLaunched() async throws {
        let executor = SubagentBackgroundExecutor()
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(title: "Test")
        context.insert(session)

        let toolCall = ToolCall(toolCallId: UUID().uuidString, kind: .subagent, message: nil)
        context.insert(toolCall)

        let taskID = UUID()
        let params = SubagentBackgroundLaunchParams(
            agentName: "verifier",
            task: "Run tests",
            taskDescription: "Running verifier",
            toolCallRecord: toolCall,
            sessionID: UUID(uuidString: session.sessionId) ?? UUID(),
            session: session,
            runInBackground: true, // 后台路径
            definition: WorkflowRoleDefinition.verifierFixture(),
            launchSubagent: { _, _ in
                // 模拟耗时操作保证后台 Task 在 launch() 返回后才完成
                try? await Task.sleep(for: .seconds(10))
                return .sync(message: .text("VERDICT: PASS", sender: "verifier", metadata: [:]))
            },
            overrideTaskID: taskID
        )

        let result = await executor.launch(params: params, modelContext: context)
        XCTAssertTrue(result.isAsync)
        XCTAssertTrue(result.toolResultText.contains("async_launched"))

        // SubagentTaskRecord 应被插入
        let descriptor = FetchDescriptor<SubagentTaskRecord>()
        let records = try context.fetch(descriptor)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].agentName, "verifier")
        XCTAssertEqual(records[0].status, .running)

        // 后台 Task 应仍在运行
        let activeCount = await executor.activeTaskCount
        XCTAssertGreaterThan(activeCount, 0)

        // 清理
        await executor.cancel(agentID: taskID)
    }

    func test_launchAsync_invokesLaunchClosureOnMainActor() async throws {
        let executor = SubagentBackgroundExecutor()
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(title: "Test")
        context.insert(session)

        let toolCall = ToolCall(toolCallId: UUID().uuidString, kind: .subagent, message: nil)
        context.insert(toolCall)

        let started = expectation(description: "launch closure started")
        let finished = expectation(description: "background task finished")
        let taskID = UUID()
        var ranOnMainThread = false

        let params = SubagentBackgroundLaunchParams(
            agentName: "verifier",
            task: "Run tests",
            taskDescription: "Running verifier",
            toolCallRecord: toolCall,
            sessionID: UUID(uuidString: session.sessionId) ?? UUID(),
            session: session,
            runInBackground: true,
            definition: WorkflowRoleDefinition.verifierFixture(),
            launchSubagent: { _, _ in
                ranOnMainThread = Thread.isMainThread
                started.fulfill()
                return .sync(message: .text("VERDICT: PASS", sender: "verifier", metadata: [:]))
            },
            overrideTaskID: taskID
        )

        _ = await executor.launch(params: params, modelContext: context)
        await fulfillment(of: [started], timeout: 2.0)

        XCTAssertTrue(ranOnMainThread, "后台子代理闭包应在 MainActor 上执行")

        let descriptor = FetchDescriptor<SubagentTaskRecord>()
        let predicateTaskID = taskID
        try await Task.sleep(for: .milliseconds(100))
        let records = try context.fetch(descriptor)
        XCTAssertEqual(records.first(where: { $0.id == predicateTaskID })?.status, .completed)

        finished.fulfill()
        await fulfillment(of: [finished], timeout: 0.1)
    }

    // MARK: - cancel() 终止运行中的 Task

    func test_cancel_stopsRunningTask() async throws {
        let executor = SubagentBackgroundExecutor()
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(title: "Test")
        context.insert(session)

        let toolCall = ToolCall(toolCallId: UUID().uuidString, kind: .subagent, message: nil)
        context.insert(toolCall)

        let started = expectation(description: "task started")
        let taskID = UUID()

        let params = SubagentBackgroundLaunchParams(
            agentName: "worker",
            task: "Long running task",
            taskDescription: "Running worker",
            toolCallRecord: toolCall,
            sessionID: UUID(uuidString: session.sessionId) ?? UUID(),
            session: session,
            runInBackground: true,
            definition: WorkflowRoleDefinition.workerFixture(),
            launchSubagent: { _, _ in
                started.fulfill()
                try? await Task.sleep(for: .seconds(60)) // 会被取消
                return .sync(message: .text("done", sender: "worker", metadata: [:]))
            },
            overrideTaskID: taskID
        )

        _ = await executor.launch(params: params, modelContext: context)
        await fulfillment(of: [started], timeout: 2.0)

        let activeCountBefore = await executor.activeTaskCount
        XCTAssertEqual(activeCountBefore, 1)

        // 取消
        await executor.cancel(agentID: taskID)

        // 等待 Task 清理
        try await Task.sleep(for: .milliseconds(100))
        let activeCountAfter = await executor.activeTaskCount
        XCTAssertEqual(activeCountAfter, 0)
    }

    // MARK: - status() 返回正确状态

    func test_status_afterLaunch_isRunning() async throws {
        let executor = SubagentBackgroundExecutor()
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(title: "Test")
        context.insert(session)

        let toolCall = ToolCall(toolCallId: UUID().uuidString, kind: .subagent, message: nil)
        context.insert(toolCall)

        let taskID = UUID()
        let params = SubagentBackgroundLaunchParams(
            agentName: "explore",
            task: "Explore code",
            taskDescription: "Exploring",
            toolCallRecord: toolCall,
            sessionID: UUID(uuidString: session.sessionId) ?? UUID(),
            session: session,
            runInBackground: true,
            definition: WorkflowRoleDefinition.explorerFixture(),
            launchSubagent: { _, _ in
                try? await Task.sleep(for: .seconds(10))
                return .sync(message: .text("done", sender: "explore", metadata: [:]))
            },
            overrideTaskID: taskID
        )

        _ = await executor.launch(params: params, modelContext: context)
        let status = await executor.status(agentID: taskID)
        XCTAssertEqual(status, .running)
        await executor.cancel(agentID: taskID)
    }
}

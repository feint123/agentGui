// agentGuiTests/SubagentCoordinatorIntegrationTests.swift
import XCTest
import SwiftData
import SwiftAnthropic
@testable import agentGui

@MainActor
final class SubagentCoordinatorIntegrationTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([SubagentTaskRecord.self, Session.self, Message.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - 同步路径通过 launchSubagent 正常返回

    func test_execute_syncSubagent_returnsAgentMessageResult() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(title: "Test")
        context.insert(session)

        let executor = SubagentBackgroundExecutor()
        var capturedResult: AgentMessage?

        let coordinator = AgentLoopToolExecutionCoordinator(
            dependencies: .init(
                sessionID: session.sessionId,
                session: session,
                launchSubagent: { input, record, definitionResolver, backgroundExecutor, ctx, forkParentContext in
                    let msg = AgentMessage.text("explored!", sender: "explore", metadata: [:])
                    capturedResult = msg
                    return SubagentLaunchResult.sync(message: msg)
                },
                requestApprovalIfNeeded: { _, _, _ in nil },
                executeTool: { _, _ in ToolExecutionResult("ok") },
                normalizeBashRequest: { _ in throw NSError(domain: "test", code: 0) },
                startForegroundBashObservation: { _, _ in nil },
                finishBashObservation: { _, _, _ in },
                hookPipeline: nil,
                backgroundExecutor: executor,
                modelContext: context
            )
        )

        let toolCallRecord = ToolCall(toolCallId: "tc-1", kind: .subagent, message: nil)
        context.insert(toolCallRecord)

        var pendingTool = AgentLoopPendingTool(id: "tc-1", name: "run_subagent")
        pendingTool.partialJson = #"{"agent_name":"explore","task":"Find usages of ClaudeService"}"#

        let outcome = await coordinator.execute(pendingTool: pendingTool, record: toolCallRecord)

        XCTAssertFalse(outcome.result.isError)
        XCTAssertTrue(outcome.result.text.contains("explored!"))
        XCTAssertNotNil(capturedResult)

        // 不应有后台任务
        let activeCount = await executor.activeTaskCount
        XCTAssertEqual(activeCount, 0)
    }

    // MARK: - run_in_background = true 路径触发后台执行

    func test_execute_backgroundSubagent_returnsAsyncLaunchedImmediately() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(title: "Test")
        context.insert(session)

        let executor = SubagentBackgroundExecutor()
        let taskID = UUID()

        // 模拟 launchSubagent：后台路径直接调用 executor.launch
        let capturedSession = session
        let capturedContext = context
        let coordinator = AgentLoopToolExecutionCoordinator(
            dependencies: .init(
                sessionID: session.sessionId,
                session: session,
                launchSubagent: { input, record, _, theExecutor, ctx, forkParentContext in
                    // 手动解析 run_in_background 以避免类型推断歧义
                    let runInBg: Bool
                    if case .bool(let b) = input["run_in_background"] { runInBg = b } else { runInBg = false }
                    let agentNameStr: String
                    if case .string(let s) = input["agent_name"] { agentNameStr = s } else { agentNameStr = "" }
                    let taskStr: String
                    if case .string(let s) = input["task"] { taskStr = s } else { taskStr = "" }
                    let definition = WorkflowRoleDefinition.verifierFixture()

                    guard runInBg || definition.background, let ctx else {
                        return .sync(message: .text("VERDICT: PASS", sender: agentNameStr, metadata: [:]))
                    }

                    let sessionUUID = UUID(uuidString: capturedSession.sessionId) ?? UUID()
                    let params = SubagentBackgroundLaunchParams(
                        agentName: agentNameStr,
                        task: taskStr,
                        taskDescription: String(taskStr.prefix(50)),
                        toolCallRecord: record,
                        sessionID: sessionUUID,
                        session: capturedSession,
                        runInBackground: true,
                        definition: definition,
                        launchSubagent: { _, _, _ in
                            try? await Task.sleep(for: .seconds(10))
                            return .sync(message: .text("VERDICT: PASS", sender: agentNameStr, metadata: [:]))
                        },
                        overrideTaskID: taskID
                    )
                    return await theExecutor.launch(params: params, modelContext: ctx)
                },
                requestApprovalIfNeeded: { _, _, _ in nil },
                executeTool: { _, _ in ToolExecutionResult("ok") },
                normalizeBashRequest: { _ in throw NSError(domain: "test", code: 0) },
                startForegroundBashObservation: { _, _ in nil },
                finishBashObservation: { _, _, _ in },
                hookPipeline: nil,
                backgroundExecutor: executor,
                modelContext: context
            )
        )

        let toolCallRecord = ToolCall(toolCallId: "tc-bg-1", kind: .subagent, message: nil)
        context.insert(toolCallRecord)

        var pendingTool = AgentLoopPendingTool(id: "tc-bg-1", name: "run_subagent")
        pendingTool.partialJson = #"{"agent_name":"verifier","task":"Run the full test suite","run_in_background":true}"#

        let outcome = await coordinator.execute(pendingTool: pendingTool, record: toolCallRecord)

        // 应立即返回
        XCTAssertFalse(outcome.result.isError)
        XCTAssertTrue(outcome.result.text.contains("async_launched"),
            "期望后台启动占位响应，实际: \(outcome.result.text)")

        // 清理
        await executor.cancel(agentID: taskID)
    }

    // MARK: - S-F2: implicit fork 路径

    func test_runSubagent_withoutAgentName_usesImplicitForkAndReturnsAsyncLaunched() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(title: "Test")
        context.insert(session)

        let executor = SubagentBackgroundExecutor()
        var capturedForkContext: ForkParentContext?

        let coordinator = AgentLoopToolExecutionCoordinator(
            dependencies: .init(
                sessionID: session.sessionId,
                session: session,
                launchSubagent: { input, record, definitionResolver, backgroundExecutor, ctx, forkParentContext in
                    // fork 路径： agent_name 缺失
                    capturedForkContext = forkParentContext
                    let msg = AgentMessage.text("fork result", sender: FORK_SUBAGENT_TYPE, metadata: [:])
                    return .sync(message: msg)
                },
                requestApprovalIfNeeded: { _, _, _ in nil },
                executeTool: { _, _ in ToolExecutionResult("ok") },
                normalizeBashRequest: { _ in throw NSError(domain: "test", code: 0) },
                startForegroundBashObservation: { _, _ in nil },
                finishBashObservation: { _, _, _ in },
                hookPipeline: nil,
                backgroundExecutor: executor,
                modelContext: context
            )
        )

        let toolCallRecord = ToolCall(toolCallId: "tc-fork-1", kind: .subagent, message: nil)
        context.insert(toolCallRecord)

        // agent_name 缺失 → implicit fork 路径
        var pendingTool = AgentLoopPendingTool(id: "tc-fork-1", name: "run_subagent")
        pendingTool.partialJson = #"{"task":"Analyze the auth module"}"#

        // 提供包含 tool_use 的父上下文
        let parentHistory: [MessageParameter.Message] = [
            .init(role: .user, content: .text("User task"))
        ]
        let assistantMsg = MessageParameter.Message(
            role: .assistant,
            content: .list([
                .text("I will delegate."),
                .toolUse("tc-fork-1", "run_subagent", ["task": .string("Analyze the auth module")])
            ])
        )
        let forkCtx = ForkParentContext(parentHistory: parentHistory, assistantMessage: assistantMsg)

        let outcome = await coordinator.execute(
            pendingTool: pendingTool,
            record: toolCallRecord,
            forkParentContext: forkCtx
        )

        XCTAssertFalse(outcome.result.isError)
        // fork context 应被传递
        XCTAssertNotNil(capturedForkContext)
        // record 中的 agentName 应为 fork 类型
        XCTAssertEqual(toolCallRecord.subagentAgentName, FORK_SUBAGENT_TYPE)
    }

    func test_runSubagent_namedAgent_stillWorks() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(title: "Test")
        context.insert(session)

        let executor = SubagentBackgroundExecutor()
        var capturedAgentName: String?

        let coordinator = AgentLoopToolExecutionCoordinator(
            dependencies: .init(
                sessionID: session.sessionId,
                session: session,
                launchSubagent: { input, record, definitionResolver, backgroundExecutor, ctx, forkParentContext in
                    if case .string(let s) = input["agent_name"] { capturedAgentName = s } else { capturedAgentName = nil }
                    return .sync(message: .text("done", sender: capturedAgentName ?? "", metadata: [:]))
                },
                requestApprovalIfNeeded: { _, _, _ in nil },
                executeTool: { _, _ in ToolExecutionResult("ok") },
                normalizeBashRequest: { _ in throw NSError(domain: "test", code: 0) },
                startForegroundBashObservation: { _, _ in nil },
                finishBashObservation: { _, _, _ in },
                hookPipeline: nil,
                backgroundExecutor: executor,
                modelContext: context
            )
        )

        let toolCallRecord = ToolCall(toolCallId: "tc-named-1", kind: .subagent, message: nil)
        context.insert(toolCallRecord)

        var pendingTool = AgentLoopPendingTool(id: "tc-named-1", name: "run_subagent")
        pendingTool.partialJson = #"{"agent_name":"explore","task":"Find files"}"#

        let outcome = await coordinator.execute(pendingTool: pendingTool, record: toolCallRecord)

        XCTAssertFalse(outcome.result.isError)
        XCTAssertEqual(capturedAgentName, "explore")
    }

    func test_runSubagent_schema_taskOnlyRequired() {
        // ToolRegistry 现在只要求 "task"，不再要求 "agent_name"
        let registry = DefaultToolRegistry()
        guard let def = registry.definition(for: "run_subagent") else {
            return XCTFail("run_subagent definition not found")
        }
        let context = ToolDefinitionBuildContext.default
        let schema = def.inputSchemaBuilder(context)
        XCTAssertTrue(schema.required?.contains("task") == true, "task 应在 required 中")
        XCTAssertFalse(schema.required?.contains("agent_name") == true, "agent_name 不应在 required 中")
    }
}

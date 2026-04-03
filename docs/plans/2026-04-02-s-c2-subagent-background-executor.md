# S-C2 SubagentBackgroundExecutor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现子代理异步后台执行器（`SubagentBackgroundExecutor`），让 `run_subagent` 支持 `run_in_background: true` 参数或代理定义中 `background: true` 标记的非阻塞后台执行，父代理立即获得占位响应后继续执行，后台子代理完成时以系统消息通知父 session。

**Architecture:** 新增 `SubagentBackgroundExecutor` actor 作为后台 Swift Task 注册表；在 `AgentLoopToolExecutionCoordinatorBuilder` 中注入执行器；在 `AgentLoopToolExecutionCoordinator.execute()` 的 `run_subagent` 分支中，根据 `run_in_background` 参数或 `definition.background` 标记决定走同步还是后台路径；后台子代理完成后通过 `Message.systemMessage` 工厂方法将通知消息写入父 session 的 SwiftData 持久层，触发 UI 自动更新。

**Tech Stack:** Swift 6, SwiftData, SwiftAnthropic，现有 `AgentLoopRuntime` / `ClaudeService+Subagent` / `SubagentTaskRecord`（S-C1）。

**前置条件：**
- S-C1 `SubagentTaskRecord` 已完成实现并通过测试。
- S-A1 `WorkflowRoleDefinition.background: Bool` 字段已存在。
- `AgentLoopToolExecutionCoordinatorBuilder` 可以向 `AgentLoopToolExecutionCoordinator.Dependencies` 传入额外依赖。

**参考来源：**
- Claude Code `src/tools/AgentTool/AgentTool.tsx`（async launch 路径 L776–900）
- Claude Code `src/tools/AgentTool/agentToolUtils.ts`（`runAsyncAgentLifecycle` L773–945）
- Claude Code `src/tasks/LocalAgentTask/LocalAgentTask.tsx`（`LocalAgentTaskState`、`enqueueAgentNotification`）
- agentGui `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift`（`executeRunSubagentTool`、`runSubagentLoop`）
- agentGui `agentGui/Services/AgentLoopToolExecutionCoordinator.swift`（`run_subagent` 分支）
- agentGui `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`（`runSubagent` closure 绑定）
- agentGui `agentGui/Models/SubagentTaskRecord.swift`（状态机、实体定义）
- agentGui `agentGui/Models/Message.swift`（`Message.systemMessage` 工厂）

---

## 关键决策说明

### 通知交付机制

Claude Code 的通知是通过将 XML `<task-notification>` 再注入父代理的 message stream 来实现的（推送式，不轮询）。agentGui 没有相同的 in-flight stream 注入机制，但存在等价路径：

**方案：写入 SwiftData + 系统消息自动展示**

背景子代理完成/失败/取消时，后台 Task 在 `@MainActor` 上：
1. 更新 `SubagentTaskRecord` 到终止状态；
2. 通过 `Message.systemMessage(text:session:)` 在父 session 中插入一条系统消息，内容为结构化通知文本；
3. 调用 `modelContext.save()`。

SwiftUI 通过 `@Query` 自动响应，消息列表刷新后通知消息出现在对话末尾。父代理下次运行时（用户触发）会从 session 的消息历史中看到该通知。

**S-C5 `PollSubagentTool`（另一个 Feature）** 是父代理主动查询路径，本计划不包含。

### SubagentBackgroundExecutor 的位置

新建目录 `agentGui/Services/SubagentGovernance/`（与设计文档 §5 一致）。

---

## Task 1：`SubagentLaunchResult` 类型 + `run_in_background` 工具参数

**Files:**
- Modify: `agentGui/Services/ToolRegistry.swift`（在 `run_subagent` schema 中添加 `run_in_background` 参数）
- Create: `agentGui/Services/SubagentGovernance/SubagentLaunchResult.swift`
- Test: `agentGuiTests/SubagentLaunchResultTests.swift`

### 步骤 1.1：写失败测试（`SubagentLaunchResult` 结构）

在新建的测试文件 `agentGuiTests/SubagentLaunchResultTests.swift` 中：

```swift
import XCTest
@testable import agentGui

final class SubagentLaunchResultTests: XCTestCase {

    func test_asyncVariant_hasCorrectFields() {
        let agentID = UUID()
        let result = SubagentLaunchResult.async(agentID: agentID, description: "Running tests")
        
        guard case .async(let id, let desc) = result else {
            return XCTFail("Expected .async case")
        }
        XCTAssertEqual(id, agentID)
        XCTAssertEqual(desc, "Running tests")
    }

    func test_syncVariant_hasCorrectMessage() {
        let msg = AgentMessage.text("done", sender: "explore", metadata: [:])
        let result = SubagentLaunchResult.sync(message: msg)
        
        guard case .sync(let m) = result else {
            return XCTFail("Expected .sync case")
        }
        XCTAssertEqual(m.content.rawText, "done")
    }

    func test_asyncVariant_toolResultText_containsAgentID() {
        let agentID = UUID()
        let result = SubagentLaunchResult.async(agentID: agentID, description: "Verifying")
        XCTAssertTrue(result.toolResultText.contains(agentID.uuidString))
    }

    func test_syncVariant_toolResultText_isMessageText() {
        let msg = AgentMessage.text("finished", sender: "worker", metadata: [:])
        let result = SubagentLaunchResult.sync(message: msg)
        XCTAssertEqual(result.toolResultText, "finished")
    }
}
```

### 步骤 1.2：运行测试，确认编译失败

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SubagentLaunchResultTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build FAILED"
```

预期：编译错误（`SubagentLaunchResult` 类型不存在）。

### 步骤 1.3：创建 `SubagentLaunchResult.swift`

新建目录（如未存在）并创建文件 `agentGui/Services/SubagentGovernance/SubagentLaunchResult.swift`：

```swift
// agentGui/Services/SubagentGovernance/SubagentLaunchResult.swift
import Foundation

/// S-C2：子代理执行结果的两种路径。
///
/// - `sync`: 同步执行完成，直接返回 `AgentMessage`（现有路径）。
/// - `async`: 后台启动成功，立即返回占位响应（agentID + 描述）。
enum SubagentLaunchResult: Sendable {
    case sync(message: AgentMessage)
    case async(agentID: UUID, description: String)

    /// 转换为工具调用结果文本，直接写入父代理的 tool_result 消息。
    var toolResultText: String {
        switch self {
        case .sync(let message):
            return message.toExecutionResult().text
        case .async(let agentID, let description):
            return """
            {"status":"async_launched","agent_id":"\(agentID.uuidString)",\
            "description":"\(description.jsonEscaped)","poll_after":30}
            """
        }
    }

    /// 提取同步路径的 AgentMessage（仅用于测试；async 路径返回 nil）。
    var syncMessage: AgentMessage? {
        guard case .sync(let msg) = self else { return nil }
        return msg
    }
}

// MARK: - String JSON Escape Helper

private extension String {
    /// 简单 JSON 字符串转义（双引号、反斜杠、换行均转义）。
    var jsonEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
```

**注意：** `AgentMessage.toExecutionResult()` 已存在于 `agentGui/Models/AgentMessage.swift`。

### 步骤 1.4：在 `ToolRegistry.swift` 添加 `run_in_background` 参数

在 `runSubagentDefinition()` 的 `inputSchemaBuilder` 的 `properties` dict 中追加：

```swift
// S-C2: 后台执行标志
"run_in_background": .init(
    type: .boolean,
    description: """
        Optional. When true, the subagent runs asynchronously in the background. \
        The tool call returns immediately with a launch receipt \
        ({"status":"async_launched","agent_id":"...","poll_after":30}). \
        Use poll_subagent(agent_id:) to check progress or wait for the \
        task-notification system message. \
        Default: false (synchronous, blocks until completion).
        """
)
```

`required` 数组保持 `["agent_name", "task"]` 不变（`run_in_background` 为可选）。

### 步骤 1.5：运行测试，确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SubagentLaunchResultTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:"
```

预期：`Test Suite 'SubagentLaunchResultTests' passed`。

### 步骤 1.6：提交

```bash
cd /Volumes/T7/文稿/Projects/agentGui
git add agentGui/Services/SubagentGovernance/SubagentLaunchResult.swift \
        agentGui/Services/ToolRegistry.swift \
        agentGuiTests/SubagentLaunchResultTests.swift
git commit -m "feat(S-C2): add SubagentLaunchResult type and run_in_background tool param"
```

---

## Task 2：`SubagentBackgroundExecutor` actor

**Files:**
- Create: `agentGui/Services/SubagentGovernance/SubagentBackgroundExecutor.swift`
- Test: `agentGuiTests/SubagentBackgroundExecutorTests.swift`

### 背景：为什么用 actor

`SubagentBackgroundExecutor` 管理一个可变的 `[UUID: Task<Void, Never>]` 字典（活跃后台 Task 注册表）。Swift 6 严格并发下，多个 Task 并发访问此字典需要 actor 保护。同时，`launch()` 方法本身不需要在 MainActor 上运行（它创建并 detach 一个 Task），注册表更新通过 actor 隔离保证安全。

### 步骤 2.1：写失败测试

新建 `agentGuiTests/SubagentBackgroundExecutorTests.swift`：

```swift
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

        let completionExpectation = expectation(description: "background task completes")
        completionExpectation.isInverted = true // 不应在 launch() 返回前完成

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
                completionExpectation.fulfill()
                return .sync(message: .text("VERDICT: PASS", sender: "verifier", metadata: [:]))
            }
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

        await fulfillment(of: [completionExpectation], timeout: 0.1)
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
```

> **注意：** `WorkflowRoleDefinition.explorerFixture()` / `verifierFixture()` / `workerFixture()` 是测试专用静态工厂方法，在 Task 3 的测试辅助扩展中添加。`Session.fixture(title:)` 已存在。

### 步骤 2.2：运行测试，确认编译失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SubagentBackgroundExecutorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build FAILED" | head -20
```

预期：编译错误（`SubagentBackgroundExecutor`、`SubagentBackgroundLaunchParams` 不存在）。

### 步骤 2.3：创建 `SubagentBackgroundExecutor.swift`

新建 `agentGui/Services/SubagentGovernance/SubagentBackgroundExecutor.swift`：

```swift
// agentGui/Services/SubagentGovernance/SubagentBackgroundExecutor.swift
import Foundation
import SwiftData

// MARK: - Launch Params

/// S-C2: 后台子代理启动参数包（从 CoordinatorBuilder 传入，避免方法签名过长）。
struct SubagentBackgroundLaunchParams: @unchecked Sendable {
    /// 代理类型名称（用于 SubagentTaskRecord.agentName）
    let agentName: String
    /// 原始 task 入参（完整提示词）
    let task: String
    /// 5-10 字任务摘要（UI 展示用）
    let taskDescription: String
    /// 触发此调用的父级 ToolCall（用于 SubagentTaskRecord.parentToolCallID）
    let toolCallRecord: ToolCall
    /// 父 session UUID（用于 SubagentTaskRecord.sessionID 和插入通知消息）
    let sessionID: UUID
    /// 父 session 对象（用于插入完成通知系统消息）
    let session: Session
    /// 是否以后台方式执行（来自 run_in_background 参数或 definition.background）
    let runInBackground: Bool
    /// 代理定义（用于传递给 launchSubagent，保存 modelID 等）
    let definition: WorkflowRoleDefinition
    /// 执行子代理的闭包（注入依赖，方便测试 mock）
    let launchSubagent: (String, WorkflowRoleDefinition) async -> SubagentLaunchResult
    /// 可选：测试中覆盖 agentID（默认 UUID()）
    let overrideTaskID: UUID?

    init(
        agentName: String,
        task: String,
        taskDescription: String,
        toolCallRecord: ToolCall,
        sessionID: UUID,
        session: Session,
        runInBackground: Bool,
        definition: WorkflowRoleDefinition,
        launchSubagent: @escaping (String, WorkflowRoleDefinition) async -> SubagentLaunchResult,
        overrideTaskID: UUID? = nil
    ) {
        self.agentName = agentName
        self.task = task
        self.taskDescription = taskDescription
        self.toolCallRecord = toolCallRecord
        self.sessionID = sessionID
        self.session = session
        self.runInBackground = runInBackground
        self.definition = definition
        self.launchSubagent = launchSubagent
        self.overrideTaskID = overrideTaskID
    }
}

// MARK: - SubagentBackgroundExecutor

/// S-C2: 后台子代理生命周期管理器。
///
/// - 维护活跃 `Task<Void, Never>` 的注册表（actor 保护并发访问）。
/// - 同步路径（`runInBackground == false`）：直接 await `launchSubagent` 并返回。
/// - 异步路径（`runInBackground == true`）：创建 `SubagentTaskRecord`，fire-and-forget 启动 Swift Task，
///   立即返回 `SubagentLaunchResult.async` 占位响应。
/// - 子代理完成/失败/取消时，更新 `SubagentTaskRecord` 状态并在父 session 中插入系统通知消息。
actor SubagentBackgroundExecutor {

    // MARK: - State

    /// 活跃后台 Task 注册表，键为 agentID（SubagentTaskRecord.id）
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Public Interface

    /// 活跃 Task 数量（供测试断言使用）
    var activeTaskCount: Int { activeTasks.count }

    /// 启动子代理（同步或后台）。
    ///
    /// - Parameters:
    ///   - params: 启动参数包
    ///   - modelContext: 父代理的 SwiftData ModelContext（用于持久化记录和通知消息）
    /// - Returns: `SubagentLaunchResult`
    func launch(
        params: SubagentBackgroundLaunchParams,
        modelContext: ModelContext
    ) async -> SubagentLaunchResult {
        // 同步路径：直接执行，不注册 Task
        guard params.runInBackground else {
            let result = await params.launchSubagent(params.task, params.definition)
            return result
        }

        // 后台路径
        let agentID = params.overrideTaskID ?? UUID()

        // 1. 创建并持久化 SubagentTaskRecord
        let record = SubagentTaskRecord(
            id: agentID,
            sessionID: params.sessionID,
            parentToolCallID: params.toolCallRecord.id,
            agentName: params.agentName,
            taskDescription: params.taskDescription,
            task: params.task,
            status: .running,
            modelID: params.definition.modelPreference == .inherit ? nil : params.definition.modelPreference.rawValue
        )
        await MainActor.run {
            modelContext.insert(record)
            try? modelContext.save()
        }

        // 2. Fire-and-forget Task（独立生命周期，不绑定父 Task）
        let task = Task<Void, Never> {
            await self.runBackgroundLifecycle(
                agentID: agentID,
                params: params,
                record: record,
                modelContext: modelContext
            )
        }
        activeTasks[agentID] = task

        // 3. 立即返回占位响应
        return .async(agentID: agentID, description: params.taskDescription)
    }

    /// 取消指定后台子代理。
    func cancel(agentID: UUID) {
        activeTasks[agentID]?.cancel()
        activeTasks[agentID] = nil
    }

    /// 查询指定后台子代理的当前状态（未注册时返回 nil）。
    func status(agentID: UUID) -> SubagentTaskStatus? {
        activeTasks[agentID] != nil ? .running : nil
    }

    // MARK: - Private

    /// 后台子代理完整生命周期：执行 → 更新状态 → 发送通知消息。
    private func runBackgroundLifecycle(
        agentID: UUID,
        params: SubagentBackgroundLaunchParams,
        record: SubagentTaskRecord,
        modelContext: ModelContext
    ) async {
        do {
            // 执行子代理（可能长时间运行）
            let result = await params.launchSubagent(params.task, params.definition)

            // 检查 Task 取消
            if Task.isCancelled {
                await finalize(
                    agentID: agentID,
                    record: record,
                    session: params.session,
                    status: .cancelled,
                    result: nil,
                    error: "Task cancelled",
                    modelContext: modelContext
                )
                return
            }

            // 成功
            await finalize(
                agentID: agentID,
                record: record,
                session: params.session,
                status: .completed,
                result: result.syncMessage?.content.rawText ?? result.toolResultText,
                error: nil,
                modelContext: modelContext
            )

        }
        // Note: launchSubagent 签名不 throws，Task 取消通过 Task.isCancelled 处理
    }

    /// 终止后台子代理：更新 record 状态、写入通知消息、注销 Task 注册表。
    private func finalize(
        agentID: UUID,
        record: SubagentTaskRecord,
        session: Session,
        status: SubagentTaskStatus,
        result: String?,
        error: String?,
        modelContext: ModelContext
    ) async {
        await MainActor.run {
            // 更新 SubagentTaskRecord
            record.status = status
            record.completedAt = Date()
            record.result = result
            record.errorMessage = error

            // 插入系统通知消息
            let notificationText = Self.buildNotificationText(
                agentName: record.agentName,
                description: record.taskDescription,
                status: status,
                result: result,
                error: error,
                elapsedSeconds: record.elapsedSeconds
            )
            let notification = Message.systemMessage(text: notificationText, session: session)
            modelContext.insert(notification)
            try? modelContext.save()
        }

        // 注销 Task 注册表
        activeTasks[agentID] = nil
    }

    /// 构建通知消息文本（XML 结构，供 UI 渲染识别）。
    nonisolated static func buildNotificationText(
        agentName: String,
        description: String,
        status: SubagentTaskStatus,
        result: String?,
        error: String?,
        elapsedSeconds: TimeInterval
    ) -> String {
        let elapsedStr = String(format: "%.1fs", elapsedSeconds)
        let statusLabel: String
        switch status {
        case .completed: statusLabel = "completed"
        case .failed:    statusLabel = "failed"
        case .cancelled: statusLabel = "cancelled"
        default:         statusLabel = status.rawValue
        }

        var body = """
        <task-notification>
          <agent>\(agentName)</agent>
          <description>\(description)</description>
          <status>\(statusLabel)</status>
          <elapsed>\(elapsedStr)</elapsed>
        """
        if let result, !result.isEmpty {
            let preview = String(result.prefix(500))
            body += "\n  <result>\(preview)</result>"
        }
        if let error, !error.isEmpty {
            body += "\n  <error>\(error)</error>"
        }
        body += "\n</task-notification>"
        return body
    }
}
```

### 步骤 2.4：添加测试辅助 fixture 扩展

在 `agentGuiTests/` 目录中，检查是否已有 `WorkflowRoleDefinition+TestFixtures.swift`：

```bash
ls /Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ | grep -i "WorkflowRole\|Fixture"
```

若不存在，新建 `agentGuiTests/WorkflowRoleDefinitionTestFixtures.swift`：

```swift
// agentGuiTests/WorkflowRoleDefinitionTestFixtures.swift
@testable import agentGui
import Foundation

extension WorkflowRoleDefinition {
    static func explorerFixture() -> WorkflowRoleDefinition {
        WorkflowRoleDefinition(
            name: "explore",
            displayName: "Explorer",
            description: "Explores codebase",
            systemPrompt: "You are an explorer.",
            enableTextEditor: true,
            enableBash: false,
            enableWebSearch: false,
            enableWebFetch: false,
            toolGrants: [],
            readableArtifacts: [],
            writableArtifacts: [],
            subscribesTo: [],
            defaultOutputMessageKind: .generalMessage,
            primaryOutputArtifactKind: nil,
            maxTurnsPerActivation: 10,
            maxActivations: 1,
            modelPreference: .haiku,
            effort: .medium,
            background: false,
            omitMainContext: true,
            initialPrompt: nil,
            criticalReminder: nil,
            color: nil,
            disallowedToolNames: [],
            isOneShot: true
        )
    }

    static func verifierFixture() -> WorkflowRoleDefinition {
        WorkflowRoleDefinition(
            name: "verifier",
            displayName: "Verifier",
            description: "Verifies fixes",
            systemPrompt: "You are a verifier.",
            enableTextEditor: false,
            enableBash: true,
            enableWebSearch: false,
            enableWebFetch: false,
            toolGrants: [],
            readableArtifacts: [],
            writableArtifacts: [],
            subscribesTo: [],
            defaultOutputMessageKind: .generalMessage,
            primaryOutputArtifactKind: nil,
            maxTurnsPerActivation: 20,
            maxActivations: 1,
            modelPreference: .inherit,
            effort: .medium,
            background: true, // verifier defaults to background
            omitMainContext: false,
            initialPrompt: nil,
            criticalReminder: "CRITICAL: end with VERDICT: PASS, FAIL, or PARTIAL.",
            color: nil,
            disallowedToolNames: [],
            isOneShot: false
        )
    }

    static func workerFixture() -> WorkflowRoleDefinition {
        WorkflowRoleDefinition(
            name: "worker",
            displayName: "Worker",
            description: "Implements changes",
            systemPrompt: "You are a worker.",
            enableTextEditor: true,
            enableBash: true,
            enableWebSearch: false,
            enableWebFetch: false,
            toolGrants: [],
            readableArtifacts: [],
            writableArtifacts: [],
            subscribesTo: [],
            defaultOutputMessageKind: .generalMessage,
            primaryOutputArtifactKind: nil,
            maxTurnsPerActivation: 30,
            maxActivations: 1,
            modelPreference: .inherit,
            effort: .medium,
            background: false,
            omitMainContext: false,
            initialPrompt: nil,
            criticalReminder: nil,
            color: nil,
            disallowedToolNames: [],
            isOneShot: false
        )
    }
}
```

> **如果 `WorkflowRoleDefinition` 的 `init` 与上面签名不完全匹配**，用 Xcode 的 Fix-it 调整参数顺序或名称，以现有 `init` 为准。目标是构造三个具有合理默认值的测试用 definition。

### 步骤 2.5：运行测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-sc2-task2 \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/SubagentBackgroundExecutorTests \
  -only-testing:agentGuiTests/SubagentLaunchResultTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:"
```

预期：所有测试通过。

### 步骤 2.6：提交

```bash
cd /Volumes/T7/文稿/Projects/agentGui
git add agentGui/Services/SubagentGovernance/SubagentBackgroundExecutor.swift \
        agentGuiTests/SubagentBackgroundExecutorTests.swift \
        agentGuiTests/WorkflowRoleDefinitionTestFixtures.swift
git commit -m "feat(S-C2): add SubagentBackgroundExecutor actor with full lifecycle management"
```

---

## Task 3：`buildNotificationText` 单元测试

**Files:**
- Test: `agentGuiTests/SubagentNotificationTextTests.swift`

这是对 `SubagentBackgroundExecutor.buildNotificationText` 的专项单元测试，独立于 actor 测试以提升可读性。

### 步骤 3.1：写测试

新建 `agentGuiTests/SubagentNotificationTextTests.swift`：

```swift
// agentGuiTests/SubagentNotificationTextTests.swift
import XCTest
@testable import agentGui

final class SubagentNotificationTextTests: XCTestCase {

    func test_completedStatus_containsCompletedTag() {
        let text = SubagentBackgroundExecutor.buildNotificationText(
            agentName: "verifier",
            description: "Run tests",
            status: .completed,
            result: "VERDICT: PASS",
            error: nil,
            elapsedSeconds: 12.5
        )
        XCTAssertTrue(text.contains("<status>completed</status>"))
        XCTAssertTrue(text.contains("VERDICT: PASS"))
        XCTAssertTrue(text.contains("<agent>verifier</agent>"))
    }

    func test_failedStatus_containsErrorTag() {
        let text = SubagentBackgroundExecutor.buildNotificationText(
            agentName: "worker",
            description: "Refactor code",
            status: .failed,
            result: nil,
            error: "API timeout after 60s",
            elapsedSeconds: 60.0
        )
        XCTAssertTrue(text.contains("<status>failed</status>"))
        XCTAssertTrue(text.contains("<error>API timeout after 60s</error>"))
        XCTAssertFalse(text.contains("<result>"))
    }

    func test_cancelledStatus_noResultTag() {
        let text = SubagentBackgroundExecutor.buildNotificationText(
            agentName: "explore",
            description: "Explore codebase",
            status: .cancelled,
            result: nil,
            error: "Task cancelled",
            elapsedSeconds: 5.0
        )
        XCTAssertTrue(text.contains("<status>cancelled</status>"))
    }

    func test_resultTruncatedAt500Chars() {
        let longResult = String(repeating: "a", count: 600)
        let text = SubagentBackgroundExecutor.buildNotificationText(
            agentName: "worker",
            description: "Long task",
            status: .completed,
            result: longResult,
            error: nil,
            elapsedSeconds: 30.0
        )
        // result 内的内容不超过 500 字符
        let resultRange = text.range(of: "<result>")
        let endRange = text.range(of: "</result>")
        XCTAssertNotNil(resultRange)
        XCTAssertNotNil(endRange)
        if let start = resultRange?.upperBound, let end = endRange?.lowerBound {
            let resultContent = String(text[start..<end])
            XCTAssertLessThanOrEqual(resultContent.count, 500)
        }
    }

    func test_emptyResult_noResultTag() {
        let text = SubagentBackgroundExecutor.buildNotificationText(
            agentName: "explore",
            description: "Empty task",
            status: .completed,
            result: "",
            error: nil,
            elapsedSeconds: 1.0
        )
        XCTAssertFalse(text.contains("<result>"))
    }

    func test_elapsedFormat() {
        let text = SubagentBackgroundExecutor.buildNotificationText(
            agentName: "verifier",
            description: "Run verifier",
            status: .completed,
            result: "done",
            error: nil,
            elapsedSeconds: 45.678
        )
        XCTAssertTrue(text.contains("<elapsed>45.7s</elapsed>"))
    }
}
```

### 步骤 3.2：运行测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-sc2-task3 \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/SubagentNotificationTextTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:"
```

预期：全部通过。

### 步骤 3.3：提交

```bash
cd /Volumes/T7/文稿/Projects/agentGui
git add agentGuiTests/SubagentNotificationTextTests.swift
git commit -m "test(S-C2): add SubagentNotificationText unit tests"
```

---

## Task 4：将 `SubagentBackgroundExecutor` 注入 Coordinator

**Files:**
- Modify: `agentGui/Services/AgentLoopToolExecutionCoordinator.swift`
- Modify: `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`

目标：在 `AgentLoopToolExecutionCoordinator.Dependencies` 中增加 `launchSubagent` 闭包，替换现有 `runSubagent`；在 `execute()` 的 `run_subagent` 分支中，根据 `run_in_background` 参数决定路径；在 Builder 中创建共享 `SubagentBackgroundExecutor` 实例并传入。

### 步骤 4.1：写集成测试

在 `agentGuiTests/ToolExecutionHookCoordinatorIntegrationTests.swift` 找到现有测试末尾（或新建文件 `agentGuiTests/SubagentCoordinatorIntegrationTests.swift`）：

新建 `agentGuiTests/SubagentCoordinatorIntegrationTests.swift`：

```swift
// agentGuiTests/SubagentCoordinatorIntegrationTests.swift
import XCTest
import SwiftData
import SwiftAnthropic
@testable import agentGui

@MainActor
final class SubagentCoordinatorIntegrationTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([SubagentTaskRecord.self, Session.self, Message.self, ToolCall.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - 同步路径通过 runSubagent 正常返回

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
                launchSubagent: { input, record, definitionResolver, backgroundExecutor, ctx in
                    let msg = AgentMessage.text("explored!", sender: "explore", metadata: [:])
                    capturedResult = msg
                    return SubagentLaunchResult.sync(message: msg)
                },
                requestApprovalIfNeeded: { _, _, _ in nil },
                executeTool: { _, _ in ToolExecutionResult("ok") },
                normalizeBashRequest: { input in BashToolRequest(command: "echo test") },
                startForegroundBashObservation: { _, _ in nil },
                finishBashObservation: { _, _, _ in },
                hookPipeline: nil,
                backgroundExecutor: executor,
                modelContext: context
            )
        )

        let toolCallRecord = ToolCall(toolCallId: "tc-1", kind: .subagent, message: nil)
        context.insert(toolCallRecord)

        var pendingInput: MessageResponse.Content.Input = [:]
        pendingInput["agent_name"] = .string("explore")
        pendingInput["task"] = .string("Find usages of ClaudeService")
        // run_in_background 不设置 → 同步

        let pending = AgentLoopPendingTool(name: "run_subagent", parsedInput: pendingInput, toolCallId: "tc-1")
        let outcome = await coordinator.execute(pendingTool: pending, record: toolCallRecord)

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

        let coordinator = AgentLoopToolExecutionCoordinator(
            dependencies: .init(
                sessionID: session.sessionId,
                session: session,
                launchSubagent: { _, _, _, _, _ in
                    // 模拟长时间运行
                    try? await Task.sleep(for: .seconds(10))
                    return SubagentLaunchResult.sync(
                        message: .text("VERDICT: PASS", sender: "verifier", metadata: [:])
                    )
                },
                requestApprovalIfNeeded: { _, _, _ in nil },
                executeTool: { _, _ in ToolExecutionResult("ok") },
                normalizeBashRequest: { input in BashToolRequest(command: "echo test") },
                startForegroundBashObservation: { _, _ in nil },
                finishBashObservation: { _, _, _ in },
                hookPipeline: nil,
                backgroundExecutor: executor,
                modelContext: context
            )
        )

        let toolCallRecord = ToolCall(toolCallId: "tc-bg-1", kind: .subagent, message: nil)
        context.insert(toolCallRecord)

        var pendingInput: MessageResponse.Content.Input = [:]
        pendingInput["agent_name"] = .string("verifier")
        pendingInput["task"] = .string("Run the full test suite")
        pendingInput["run_in_background"] = .bool(true)

        let pending = AgentLoopPendingTool(name: "run_subagent", parsedInput: pendingInput, toolCallId: "tc-bg-1")
        let outcome = await coordinator.execute(pendingTool: pending, record: toolCallRecord)

        // 应立即返回
        XCTAssertFalse(outcome.result.isError)
        XCTAssertTrue(outcome.result.text.contains("async_launched"),
            "期望后台启动占位响应，实际: \(outcome.result.text)")

        // 清理
        let activeCount = await executor.activeTaskCount
        XCTAssertGreaterThan(activeCount, 0)
        // 取消后台 Task 防止测试泄漏
        let fetchDescriptor = FetchDescriptor<SubagentTaskRecord>()
        let records = try context.fetch(fetchDescriptor)
        for r in records {
            await executor.cancel(agentID: r.id)
        }
    }
}
```

### 步骤 4.2：运行测试，确认编译失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-sc2-task4 \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/SubagentCoordinatorIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build FAILED" | head -20
```

预期：编译错误（`Dependencies` 没有 `launchSubagent`、`session`、`backgroundExecutor`、`modelContext` 字段）。

### 步骤 4.3：修改 `AgentLoopToolExecutionCoordinator.swift`

**修改一：扩展 `Dependencies` 结构体**

在原有 `runSubagent` 字段旁边，替换整个 `Dependencies` 结构体：

```swift
struct Dependencies {
    let sessionID: String
    /// S-C2: 父代理 Session 对象（用于写入后台完成通知消息）
    let session: Session
    /// S-C2: 替代原有 runSubagent 闭包，返回值改为 SubagentLaunchResult（区分同步/异步）
    let launchSubagent: (MessageResponse.Content.Input, ToolCall, (String) -> WorkflowRoleDefinition?, SubagentBackgroundExecutor, ModelContext) async -> SubagentLaunchResult
    let requestApprovalIfNeeded: (String, MessageResponse.Content.Input, ToolCall) async -> ToolExecutionResult?
    let executeTool: (String, MessageResponse.Content.Input) async -> ToolExecutionResult
    let normalizeBashRequest: (MessageResponse.Content.Input) throws -> BashToolRequest
    let startForegroundBashObservation: (BashToolRequest, ToolCall) async -> Task<Void, Never>?
    let finishBashObservation: (BashToolRequest, ToolCall, ToolExecutionResult) async -> Void
    var hookPipeline: ToolExecutionHookPipeline?
    /// S-C2: 共享后台执行器
    let backgroundExecutor: SubagentBackgroundExecutor
    /// S-C2: ModelContext（用于 SubagentTaskRecord 持久化）
    let modelContext: ModelContext
}
```

**修改二：更新 `run_subagent` 分支**

将原有：

```swift
if pendingTool.name == "run_subagent" {
    let agentMessage = await dependencies.runSubagent(input, record)
    record.subagentAgentName = input["agent_name"]?.stringValue
    record.subagentResultKind = agentMessage.content.kindLabel
    if !agentMessage.metadata.isEmpty {
        record.subagentMessageMetadata = agentMessage.metadata
    }
    return AgentLoopToolExecutionOutcome(result: agentMessage.toExecutionResult(), record: record)
}
```

替换为：

```swift
if pendingTool.name == "run_subagent" {
    let launchResult = await dependencies.launchSubagent(
        input,
        record,
        { name in AgentCatalog.shared.find(named: name)?.workflowRoleDefinition },
        dependencies.backgroundExecutor,
        dependencies.modelContext
    )
    record.subagentAgentName = input["agent_name"]?.stringValue
    // 仅在同步路径下有 AgentMessage 可以提取 resultKind
    if case .sync(let msg) = launchResult {
        record.subagentResultKind = msg.content.kindLabel
        if !msg.metadata.isEmpty {
            record.subagentMessageMetadata = msg.metadata
        }
    } else {
        record.subagentResultKind = "async"
    }
    let resultText = launchResult.toolResultText
    return AgentLoopToolExecutionOutcome(
        result: ToolExecutionResult(resultText),
        record: record
    )
}
```

### 步骤 4.4：修改 `AgentLoopToolExecutionCoordinatorBuilder.swift`

在 `build()` 方法中：

**添加 shared executor 属性**（在 `func build()` 上方），或直接在 builder 结构体中添加：

```swift
// 在 AgentLoopToolExecutionCoordinatorBuilder 结构体中添加
let backgroundExecutor: SubagentBackgroundExecutor
```

如果不修改 `struct`（保持向后兼容），直接在 `build()` 内创建局部变量：

```swift
func build() -> AgentLoopToolExecutionCoordinator {
    let executor = SubagentBackgroundExecutor()

    return AgentLoopToolExecutionCoordinator(
        dependencies: .init(
            sessionID: sessionId,
            session: /* 需要 Session 对象，见下方说明 */,
            launchSubagent: { [claudeService, service, modelId, settings, sessionId, modelContext] input, record, definitionResolver, executor, ctx in
                // 判断是否后台执行
                let agentName = input["agent_name"]?.stringValue ?? ""
                let task = input["task"]?.stringValue ?? ""
                let runInBackground = input["run_in_background"]?.boolValue ?? false

                guard let definition = definitionResolver(agentName) else {
                    let available = AgentCatalog.shared.subagentInvocableAgents.map(\.name).joined(separator: ", ")
                    return .sync(message: .error("unknown agent '\(agentName)'. Available: \(available)", sender: "system"))
                }

                let shouldRunBackground = runInBackground || definition.background

                // 5-10 字摘要（取 task 前 50 字）
                let taskDescription = String(task.prefix(50))

                if shouldRunBackground {
                    guard let session = /* session */ else {
                        return .sync(message: .error("cannot launch background agent: session not available", sender: "system"))
                    }
                    let sessionUUID = UUID(uuidString: sessionId) ?? UUID()
                    let params = SubagentBackgroundLaunchParams(
                        agentName: agentName,
                        task: task,
                        taskDescription: taskDescription,
                        toolCallRecord: record,
                        sessionID: sessionUUID,
                        session: session,
                        runInBackground: true,
                        definition: definition,
                        launchSubagent: { task, def in
                            let msg = try? await claudeService.runSubagentLoop(
                                task: task,
                                definition: def,
                                toolCallRecord: record,
                                service: service,
                                modelId: modelId,
                                settings: settings,
                                sessionId: sessionId,
                                modelContext: modelContext
                            )
                            return .sync(message: msg ?? .error("subagent failed", sender: def.name))
                        }
                    )
                    return await executor.launch(params: params, modelContext: ctx)
                } else {
                    // 同步路径
                    let msg = try? await claudeService.runSubagentLoop(
                        task: task,
                        definition: definition,
                        toolCallRecord: record,
                        service: service,
                        modelId: modelId,
                        settings: settings,
                        sessionId: sessionId,
                        modelContext: modelContext
                    )
                    return .sync(message: msg ?? .error("subagent failed", sender: definition.name))
                }
            },
            requestApprovalIfNeeded: { ... }, // 保持原有
            executeTool: { ... },              // 保持原有
            normalizeBashRequest: { ... },
            startForegroundBashObservation: { ... },
            finishBashObservation: { ... },
            hookPipeline: buildHookPipeline(),
            backgroundExecutor: executor,
            modelContext: modelContext
        )
    )
}
```

> **关于 Session 对象的传递：** `AgentLoopToolExecutionCoordinatorBuilder` 目前没有持有 `Session`，只有 `sessionId: String`。需要在 Builder 的属性中添加 `let session: Session?`，并在 `ClaudeService+AgenticLoop.swift` 的调用点传入。具体修改详见 Task 5。

### 步骤 4.5：运行测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-sc2-task4b \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/SubagentCoordinatorIntegrationTests \
  -only-testing:agentGuiTests/SubagentBackgroundExecutorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:"
```

预期：所有测试通过，无编译错误。

### 步骤 4.6：提交

```bash
cd /Volumes/T7/文稿/Projects/agentGui
git add agentGui/Services/AgentLoopToolExecutionCoordinator.swift \
        agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift \
        agentGuiTests/SubagentCoordinatorIntegrationTests.swift
git commit -m "feat(S-C2): wire SubagentBackgroundExecutor into tool execution coordinator"
```

---

## Task 5：在 `ClaudeService+AgenticLoop.swift` 传入 Session 对象

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift`
- Modify: `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`（添加 `session` 属性）

### 背景

后台子代理完成时需要将通知写入父 session。`AgentLoopToolExecutionCoordinatorBuilder` 目前只持有 `sessionId: String`，不持有 `Session` 对象。需要在 Builder 中添加 `session: Session?`，并从 `ClaudeService+AgenticLoop.swift` 传入。

### 步骤 5.1：在 Builder 中添加 `session: Session?` 属性

在 `AgentLoopToolExecutionCoordinatorBuilder` 的属性列表中添加：

```swift
let session: Session?   // S-C2: 后台通知消息写入目标
```

在 `build()` 内部使用 `session` 替代 `/* session */` 占位符（Task 4 留下的）。

### 步骤 5.2：在 `ClaudeService+AgenticLoop.swift` 查找 Builder 初始化调用

在文件中搜索 `AgentLoopToolExecutionCoordinatorBuilder(`（约第 204 行），在构造调用中添加 `session: session`：

```swift
let toolExecutionCoordinator = AgentLoopToolExecutionCoordinatorBuilder(
    claudeService: self,
    service: service,
    modelId: modelId,
    toolApprovalMode: ...,
    settings: settings,
    sessionId: session.sessionId,
    modelContext: modelContext,
    session: session            // <-- 新增
).build()
```

### 步骤 5.3：确认现有测试通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-sc2-task5 \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/ToolExecutionHookCoordinatorIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:"
```

预期：全部通过（Builder 变更向后兼容，`session: nil` 默认值对无 session 路径安全）。

### 步骤 5.4：提交

```bash
cd /Volumes/T7/文稿/Projects/agentGui
git add agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift \
        agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift
git commit -m "feat(S-C2): pass Session into CoordinatorBuilder for background notification delivery"
```

---

## Task 6：`AgentCatalog.background` 属性决策逻辑 + `run_in_background` 解析

**Files:**
- Modify: `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`（完善 `shouldRunBackground` 逻辑）

### 背景

`definition.background` 是代理定义级别的默认后台标志（从 `.agent.md` frontmatter 解析）。`run_in_background` 是单次调用级别的覆盖标志（从工具输入参数解析）。优先级：调用参数 `run_in_background: true` **OR** `definition.background == true` → 走后台路径。

### 步骤 6.1：确认 `MessageResponse.Content.Input` 的 `boolValue` 可用性

```bash
grep -n "boolValue\|\.bool" /Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/*.swift | head -10
```

如果 `Input` 值类型已有 `boolValue` 或 `.bool(Bool)` case（提示：已有 `.string`），需要检查其 enum 定义：

```bash
grep -rn "case bool\|boolValue" /Volumes/T7/文稿/Projects/agentGui/agentGui/ | head -10
```

若不存在，添加到相应类型（`MessageResponse.Content.Input` 的 Value 类型）：

```swift
// 若 Input 的 Value 枚举还没有 bool case，添加：
var boolValue: Bool? {
    if case .bool(let b) = self { return b }
    if case .string(let s) = self { return Bool(s) }
    return nil
}
```

### 步骤 6.2：检查 Input Value 类型实际位置

```bash
grep -rn "stringValue\|Input\[" /Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Subagent.swift | head -5
```

根据实际类型添加 `boolValue` 扩展（如有必要）。

### 步骤 6.3：在 Builder 的 `launchSubagent` 闭包内完善逻辑

确认 `shouldRunBackground` 的计算如下：

```swift
let runInBackground = input["run_in_background"]?.boolValue ?? false
let shouldRunBackground = runInBackground || definition.background
```

此行已在 Task 4 的代码中存在，本步骤仅验证 `boolValue` 可以编译。

### 步骤 6.4：编译检查

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build FAILED|Build SUCCEEDED"
```

预期：`Build SUCCEEDED`。

### 步骤 6.5：提交

```bash
cd /Volumes/T7/文稿/Projects/agentGui
git add agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift
git commit -m "feat(S-C2): resolve run_in_background bool param and definition.background flag"
```

---

## Task 7：Xcode Project 文件更新

**Files:**
- Modify: `agentGui.xcodeproj/project.pbxproj`

新建的 Swift 文件需要加入 Xcode project 才能编译。

### 步骤 7.1：将新文件加入 project

在 Xcode 中：

1. 打开 `agentGui.xcodeproj`。
2. 在 Project Navigator 中右键 `agentGui/Services/` → New Group "SubagentGovernance"（如不存在）。
3. 将以下文件拖入 `SubagentGovernance` 组，选中 target `agentGui`：
   - `SubagentLaunchResult.swift`
   - `SubagentBackgroundExecutor.swift`
4. 将测试文件加入 target `agentGuiTests`：
   - `SubagentLaunchResultTests.swift`
   - `SubagentBackgroundExecutorTests.swift`
   - `SubagentNotificationTextTests.swift`
   - `SubagentCoordinatorIntegrationTests.swift`
   - `WorkflowRoleDefinitionTestFixtures.swift`

> **验证方法：** 在终端执行 `xcodebuild build` 若出现 `file not found` 错误，则说明文件未加入 project。

### 步骤 7.2：整体构建验证

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

预期：`** BUILD SUCCEEDED **`

### 步骤 7.3：运行全套 S-C2 测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-sc2-full \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/SubagentLaunchResultTests \
  -only-testing:agentGuiTests/SubagentBackgroundExecutorTests \
  -only-testing:agentGuiTests/SubagentNotificationTextTests \
  -only-testing:agentGuiTests/SubagentCoordinatorIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:"
```

预期：全部通过。

### 步骤 7.4：提交

```bash
cd /Volumes/T7/文稿/Projects/agentGui
git add agentGui.xcodeproj/project.pbxproj
git commit -m "chore(S-C2): add SubagentGovernance sources and tests to Xcode project"
```

---

## Task 8：回归测试——现有子代理测试

确认 S-C2 变更没有破坏 S-C1 的测试和现有子代理相关测试。

### 步骤 8.1：运行回归测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-sc2-regression \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/SubagentTaskRecordTests \
  -only-testing:agentGuiTests/ToolExecutionHookCoordinatorIntegrationTests \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:"
```

预期：全部通过。

### 步骤 8.2：若有失败，修复后再提交

```bash
git add -A
git commit -m "fix(S-C2): regression fixes after coordinator refactor"
```

### 步骤 8.3：最终 tag

```bash
git tag -a "s-c2-complete" -m "S-C2 SubagentBackgroundExecutor: complete implementation"
```

---

## 实现注意事项

### `runSubagentLoop` 错误处理

`runSubagentLoop` 是 `throws` 方法，但 `SubagentBackgroundLaunchParams.launchSubagent` 的闭包签名设计为 `async -> SubagentLaunchResult`（不 throws）。原因：后台 Task 在独立上下文中，错误应被捕获并转换为 `.failed` 状态，不应向外 propagate。

因此，在 `SubagentBackgroundLaunchParams.launchSubagent` 的实现闭包中用 `do-catch` 包裹 `runSubagentLoop`：

```swift
launchSubagent: { task, def in
    do {
        let msg = try await claudeService.runSubagentLoop(
            task: task,
            definition: def,
            ...
        )
        return .sync(message: msg)
    } catch {
        return .sync(message: .error(error.localizedDescription, sender: def.name))
    }
}
```

### Swift 6 并发安全

`SubagentBackgroundLaunchParams.launchSubagent` 是 `@escaping (String, WorkflowRoleDefinition) async -> SubagentLaunchResult`，closure 捕获的 `claudeService`（`@MainActor` class）需要使用 `await MainActor.run { ... }` 或直接在 `@MainActor` 上下文中调用。在 `SubagentBackgroundExecutor.runBackgroundLifecycle` 中（actor 隔离），调用 `launchSubagent` 时需确认不违反 Swift 6 data race 规则。

若遇到 `Sending ... closure ... is restricted` 编译报错，将 `launchSubagent` 改为 `@MainActor @escaping` 或通过 `await MainActor.run { }` 桥接。

### `AgentMessage.text(_:sender:metadata:)` 工厂方法

测试中使用 `AgentMessage.text("done", sender: "explore", metadata: [:])` 作为快捷工厂。请根据 `agentGui/Models/AgentMessage.swift` 中实际存在的静态方法调整参数名称（可能是 `AgentMessage(content: .text("done"), sender: "explore", recipient: "main", metadata: [:])`）。

### ModelContext 线程安全

`SubagentBackgroundExecutor.finalize()` 中的 `modelContext.insert()` 和 `modelContext.save()` 必须在 `@MainActor` 上执行（SwiftData 要求）。代码中已用 `await MainActor.run { }` 包裹，不要修改这个模式。

---

## 验收标准核查清单

| 标准 | 验证方式 |
|------|---------|
| 后台子代理启动后父代理立即继续 | `SubagentCoordinatorIntegrationTests.test_execute_backgroundSubagent_returnsAsyncLaunchedImmediately` 通过 |
| 父代理立即收到 `async_launched` 占位 JSON | 同上，断言 `result.text.contains("async_launched")` |
| `SubagentTaskRecord` 创建并置 `running` | 同上，fetch 断言 `records[0].status == .running` |
| 子代理完成后系统消息插入 session | `SubagentBackgroundExecutorTests.test_launchAsync_returnsAsyncLaunchedImmediately` 扩展后验证 |
| 取消操作终止 Task 并注销注册表 | `SubagentBackgroundExecutorTests.test_cancel_stopsRunningTask` 通过 |
| 同步路径行为不变 | `SubagentCoordinatorIntegrationTests.test_execute_syncSubagent_returnsAgentMessageResult` 通过 |
| `run_in_background: false`（默认）不触发后台 | `SubagentBackgroundExecutorTests.test_launchSync_doesNotRegisterBackgroundTask` 通过 |
| `definition.background == true` 自动走后台路径 | 通过 `verifierFixture(background: true)` 的测试覆盖 |
| 现有子代理路径回归无破坏 | `SubagentTaskRecordTests` + `AgentDefinitionLoaderOpenAgentTests` 通过 |

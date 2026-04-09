# Conversation Execution Runtime Rearchitecture Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the current single-active-turn conversation execution path with a modular job-driven runtime that supports multi-session concurrency and per-session queued messages without blocking composer editing.

**Architecture:** Introduce durable execution jobs and attempts, a per-session mailbox plus global scheduler, a runtime pool and compatibility driver layer around the existing providers, and a dedicated UI projection store. Keep the current provider implementations alive during migration, but move orchestration, queueing, cancellation semantics, and UI state out of `ClaudeService` and into a new execution subsystem.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, existing conversation execution providers, existing ACP runtime path, `PersistenceCoordinator`, and existing chat/UI test suites.

---

## 1. 实施原则

- 这份计划应在独立 worktree 中执行；先用 @brainstorming 固化上下文，再按本计划逐 task 落地。
- 全程按 @test-driven-development 执行：先写失败测试，再写最小实现，再跑通过，再提交。
- 第一阶段坚持“单会话保序、多会话并行”，不要引入单会话内多消息并发。
- 禁止继续扩大 `ClaudeService.isStreaming` 的职责；所有新 UI 状态必须来自新的 execution projection。
- 迁移期间允许保留旧 provider，但不允许再新增第二套 active turn / queue 状态源。
- SwiftData 写入沿用仓库已有的 ModelActor 迁移方向，避免把 live `ModelContext` 在并发执行链路中四处传递。
- 全部任务完成后，使用 @requesting-code-review 进行最终 review，再考虑合并。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionJob.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionAttempt.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionPayloadDraft.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionProjection.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionPersistenceStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionSchedulingModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionExecutionMailbox.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionScheduler.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionRuntimePool.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionDriver.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/LegacyConversationExecutionDriver.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionProjectionStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionPersistenceStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionExecutionMailboxTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionSchedulerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionOrchestratorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionProjectionStoreTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/PersistenceCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionProviderRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionRuntimeCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+MessageList.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionProviderRegistryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/ChatFlowUITests.swift`

### 参考文档

- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-21-conversation-execution-runtime-rearchitecture-design.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-12-agenticloop-swiftdata-modelactor-implementation-plan.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/current-capability-baseline-2026-03-14.md`

## 3. 关键设计决策

### 3.1 `ExecutionJob` 是队列与调度的一等实体

不要把“排队中”“已入队”“已被替换”“本次尝试被取消”塞回 `MessageStatus`。消息继续服务于 transcript，执行状态统一落到新模型里：

```swift
enum ExecutionJobState: String, Codable, Sendable {
    case queued
    case admitted
    case running
    case completed
    case failed
    case cancelled
    case superseded
}

enum ExecutionAttemptState: String, Codable, Sendable {
    case running
    case completed
    case failed
    case cancelled
    case interrupted
}
```

### 3.2 新系统的输入是 enqueue command，不是直接调 provider

运行时入口必须从：

```swift
try await claudeService.sendMessage(...)
```

切换为：

```swift
let handle = try await orchestrator.enqueue(
    EnqueueExecutionCommand(
        sessionID: session.sessionId,
        providerID: providerID,
        payload: draft,
        sourceUserMessageID: userMessage.id
    )
)
```

### 3.3 UI 只消费 `SessionExecutionProjection`

聊天 UI 不能再直接绑定 `claudeService.isStreaming`：

```swift
struct SessionExecutionProjection: Equatable, Sendable {
    let sessionID: String
    let runningJobID: UUID?
    let queuedJobIDs: [UUID]
    let queuedCount: Int
    let isRunning: Bool
    let canEditComposer: Bool
    let canSubmitNewJob: Bool
}
```

## 4. 任务拆解

### Task 1: 固化 durable job / attempt 模型和执行 payload

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionJob.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionAttempt.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionPayloadDraft.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionPersistenceStoreTests.swift`

**Step 1: Write the failing test**

```swift
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ExecutionPersistenceStoreTests {
    @Test func executionJobStartsQueuedAndBindsSourceMessage() throws {
        let job = ExecutionJob(
            sessionID: "session-1",
            providerID: .githubCopilotCLI,
            payload: ExecutionPayloadDraft.userPrompt(
                text: "run tests",
                selectedFilePath: nil,
                selectedText: nil,
                directives: []
            ),
            sourceUserMessageID: UUID(),
            targetAgentMessageID: nil
        )

        #expect(job.state == .queued)
        #expect(job.sourceUserMessageID != nil)
        #expect(job.latestAttemptID == nil)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ExecutionPersistenceStoreTests`
Expected: FAIL with missing `ExecutionJob`, `ExecutionPayloadDraft`, or state symbols.

**Step 3: Write minimal implementation**

```swift
@Model
final class ExecutionJob {
    var id: UUID
    var sessionID: String
    var providerIDRaw: String
    var stateRaw: String
    var payloadJSON: String
    var sourceUserMessageID: UUID?
    var targetAgentMessageID: UUID?
    var latestAttemptID: UUID?
    var enqueuedAt: Date

    init(sessionID: String, providerID: ConversationExecutionProviderID, payload: ExecutionPayloadDraft, sourceUserMessageID: UUID?, targetAgentMessageID: UUID?) {
        self.id = UUID()
        self.sessionID = sessionID
        self.providerIDRaw = providerID.rawValue
        self.stateRaw = ExecutionJobState.queued.rawValue
        self.payloadJSON = payload.encodedJSON
        self.sourceUserMessageID = sourceUserMessageID
        self.targetAgentMessageID = targetAgentMessageID
        self.latestAttemptID = nil
        self.enqueuedAt = Date()
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ExecutionPersistenceStoreTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/ExecutionJob.swift agentGui/Models/ExecutionAttempt.swift agentGui/Models/ExecutionPayloadDraft.swift agentGuiTests/ExecutionPersistenceStoreTests.swift
git commit -m "feat: add durable execution job models"
```

### Task 2: 建立 execution 持久化存储和新 domain 边界

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionPersistenceStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/PersistenceCoordinator.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionPersistenceStoreTests.swift`

**Step 1: Write the failing test**

```swift
@MainActor
struct ExecutionPersistenceStoreTests {
    @Test func enqueuePersistsQueuedJobAndCreatesAgentPlaceholder() async throws {
        let harness = try ExecutionPersistenceHarness.make()
        let store = harness.makeStore()

        let result = try await store.enqueue(
            sessionID: harness.session.sessionId,
            providerID: .openCodeCLI,
            payload: .userPrompt(text: "queued", selectedFilePath: nil, selectedText: nil, directives: []),
            sourceUserMessageID: harness.userMessage.id
        )

        #expect(result.job.state == .queued)
        #expect(result.agentMessageID != nil)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ExecutionPersistenceStoreTests`
Expected: FAIL with missing `ExecutionPersistenceStore` or enqueue result types.

**Step 3: Write minimal implementation**

```swift
@MainActor
final class ExecutionPersistenceStore {
    struct EnqueueResult {
        let job: ExecutionJob
        let agentMessageID: UUID?
    }

    func enqueue(sessionID: String, providerID: ConversationExecutionProviderID, payload: ExecutionPayloadDraft, sourceUserMessageID: UUID) async throws -> EnqueueResult {
        let agentMessage = Message.agentMessage(text: "", session: session)
        agentMessage.status = .pending
        modelContext.insert(agentMessage)

        let job = ExecutionJob(
            sessionID: sessionID,
            providerID: providerID,
            payload: payload,
            sourceUserMessageID: sourceUserMessageID,
            targetAgentMessageID: agentMessage.id
        )
        modelContext.insert(job)
        try persistenceCoordinator.save(modelContext, domain: .execution, userMessage: "执行作业入队未成功保存")
        return EnqueueResult(job: job, agentMessageID: agentMessage.id)
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ExecutionPersistenceStoreTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Execution/ExecutionPersistenceStore.swift agentGui/Services/PersistenceCoordinator.swift agentGuiTests/ExecutionPersistenceStoreTests.swift
git commit -m "feat: add execution persistence store"
```

### Task 3: 建立每会话 mailbox 和全局 scheduler

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionSchedulingModels.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionExecutionMailbox.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionScheduler.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionExecutionMailboxTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionSchedulerTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

struct SessionExecutionMailboxTests {
    @Test func mailboxKeepsSingleSessionJobsInFifoOrder() async throws {
        let mailbox = SessionExecutionMailbox(sessionID: "s1")
        let first = UUID()
        let second = UUID()

        await mailbox.enqueue(jobID: first)
        await mailbox.enqueue(jobID: second)

        #expect(await mailbox.peekNextJobID() == first)
        _ = await mailbox.markRunning(jobID: first)
        #expect(await mailbox.peekNextJobID() == second)
    }
}

struct ExecutionSchedulerTests {
    @Test func schedulerCanAdmitJobsFromDifferentSessionsWithoutBreakingPerSessionSerialization() async throws {
        let scheduler = ExecutionScheduler(maxConcurrentJobs: 2)
        let first = try await scheduler.admitReadyJobs([
            .init(sessionID: "a", jobID: UUID()),
            .init(sessionID: "b", jobID: UUID())
        ])

        #expect(first.count == 2)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/SessionExecutionMailboxTests -only-testing:agentGuiTests/ExecutionSchedulerTests`
Expected: FAIL with missing mailbox or scheduler symbols.

**Step 3: Write minimal implementation**

```swift
actor SessionExecutionMailbox {
    private var queuedJobIDs: [UUID] = []
    private var runningJobID: UUID?

    func enqueue(jobID: UUID) {
        queuedJobIDs.append(jobID)
    }

    func peekNextJobID() -> UUID? {
        queuedJobIDs.first
    }

    func markRunning(jobID: UUID) -> Bool {
        guard runningJobID == nil, queuedJobIDs.first == jobID else { return false }
        runningJobID = jobID
        queuedJobIDs.removeFirst()
        return true
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/SessionExecutionMailboxTests -only-testing:agentGuiTests/ExecutionSchedulerTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Execution/ExecutionSchedulingModels.swift agentGui/Services/Execution/SessionExecutionMailbox.swift agentGui/Services/Execution/ExecutionScheduler.swift agentGuiTests/SessionExecutionMailboxTests.swift agentGuiTests/ExecutionSchedulerTests.swift
git commit -m "feat: add execution scheduling primitives"
```

### Task 4: 建立 UI projection store 和 orchestrator 主入口

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionProjection.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionProjectionStore.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionProjectionStoreTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionOrchestratorTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

@MainActor
struct ConversationExecutionOrchestratorTests {
    @Test func enqueueUpdatesProjectionToQueuedBeforeDispatch() async throws {
        let harness = try ExecutionOrchestratorHarness.make()

        let handle = try await harness.orchestrator.enqueue(
            .fixture(sessionID: harness.session.sessionId, providerID: .githubCopilotCLI, text: "queued prompt")
        )

        let projection = harness.projectionStore.projection(for: harness.session.sessionId)
        #expect(handle.jobID == projection.queuedJobIDs.first)
        #expect(projection.queuedCount == 1)
        #expect(projection.canEditComposer == true)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ConversationExecutionOrchestratorTests -only-testing:agentGuiTests/ExecutionProjectionStoreTests`
Expected: FAIL with missing orchestrator or projection store types.

**Step 3: Write minimal implementation**

```swift
@MainActor
@Observable
final class ExecutionProjectionStore {
    private(set) var projections: [String: SessionExecutionProjection] = [:]

    func setProjection(_ projection: SessionExecutionProjection) {
        projections[projection.sessionID] = projection
    }

    func projection(for sessionID: String) -> SessionExecutionProjection {
        projections[sessionID] ?? .empty(sessionID: sessionID)
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ConversationExecutionOrchestratorTests -only-testing:agentGuiTests/ExecutionProjectionStoreTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/ExecutionProjection.swift agentGui/Services/Execution/ExecutionProjectionStore.swift agentGui/Services/Execution/ConversationExecutionOrchestrator.swift agentGuiTests/ExecutionProjectionStoreTests.swift agentGuiTests/ConversationExecutionOrchestratorTests.swift
git commit -m "feat: add execution orchestrator and projections"
```

### Task 5: 加入 compatibility driver 层和 runtime pool，托管现有 provider

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionDriver.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/LegacyConversationExecutionDriver.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionRuntimePool.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionProviderRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionRuntimeCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionProviderRegistryTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`

**Step 1: Write the failing test**

```swift
@MainActor
struct ConversationExecutionProviderRegistryTests {
    @Test func registryBuildsCompatibilityDriverForResolvedProvider() throws {
        let registry = ConversationExecutionProviderRegistry(
            builtIn: ProviderSpy(id: .builtInAgent),
            copilot: ProviderSpy(id: .githubCopilotCLI, runtimeScope: .externalACP),
            openCode: ProviderSpy(id: .openCodeCLI, runtimeScope: .externalACP)
        )

        let driver = registry.compatibilityDriver(for: .githubCopilotCLI)
        #expect(driver.providerID == .githubCopilotCLI)
        #expect(driver.runtimeScope == .externalACP)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ConversationExecutionProviderRegistryTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests`
Expected: FAIL with missing compatibility driver APIs.

**Step 3: Write minimal implementation**

```swift
protocol ConversationExecutionDriver: Sendable {
    var providerID: ConversationExecutionProviderID { get }
    var runtimeScope: ConversationExecutionRuntimeScope? { get }

    func execute(_ job: ExecutionJob, context: ExecutionDriverContext) -> AsyncThrowingStream<ExecutionDriverEvent, Error>
    func cancel(jobID: UUID, sessionID: String) async
}

struct LegacyConversationExecutionDriver: ConversationExecutionDriver {
    let providerID: ConversationExecutionProviderID
    let runtimeScope: ConversationExecutionRuntimeScope?
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ConversationExecutionProviderRegistryTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests`
Expected: PASS, and existing provider behavior remains green.

**Step 5: Commit**

```bash
git add agentGui/Services/Execution/ConversationExecutionDriver.swift agentGui/Services/Execution/LegacyConversationExecutionDriver.swift agentGui/Services/Execution/ExecutionRuntimePool.swift agentGui/Services/ConversationExecutionProviderRegistry.swift agentGui/Services/ConversationExecutionRuntimeCoordinator.swift agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift agentGuiTests/ConversationExecutionProviderRegistryTests.swift agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift agentGuiTests/OpenCodeCLIExecutionProviderTests.swift
git commit -m "feat: add compatibility execution drivers"
```

### Task 6: 将 `ClaudeService` 和发送入口改成 enqueue facade

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionOrchestratorTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionProviderRegistryTests.swift`

**Step 1: Write the failing test**

```swift
@MainActor
struct ConversationExecutionOrchestratorTests {
    @Test func claudeServiceSendMessageEnqueuesJobInsteadOfBlockingOnProviderSend() async throws {
        let modelContext = try makeModelContext()
        let session = Session.fixture(title: "Queue Facade")
        let harness = try ClaudeServiceExecutionHarness.make(modelContext: modelContext, session: session)

        try await harness.service.sendMessage(
            text: "queued facade",
            session: session,
            modelId: "test-model",
            modelContext: modelContext
        )

        let projection = harness.projectionStore.projection(for: session.sessionId)
        #expect(projection.queuedCount == 1 || projection.isRunning)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ConversationExecutionOrchestratorTests -only-testing:agentGuiTests/ConversationExecutionProviderRegistryTests`
Expected: FAIL because `ClaudeService.sendMessage` still directly calls provider.

**Step 3: Write minimal implementation**

```swift
extension ClaudeService {
    func sendMessage(...) async throws {
        let command = try enqueueCommand(...)
        _ = try await executionOrchestrator.enqueue(command)
    }

    func cancelExecution(session: Session, modelContext: ModelContext) async {
        await executionOrchestrator.cancelRunning(in: session.sessionId)
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ConversationExecutionOrchestratorTests -only-testing:agentGuiTests/ConversationExecutionProviderRegistryTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService/ClaudeService.swift agentGui/Services/ClaudeService/ClaudeService+Messaging.swift agentGui/agentGuiApp.swift agentGuiTests/ConversationExecutionOrchestratorTests.swift agentGuiTests/ConversationExecutionProviderRegistryTests.swift
git commit -m "refactor: route conversation execution through orchestrator"
```

### Task 7: 切换聊天 UI 到 per-session projection，并加入队列交互回归测试

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+MessageList.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/ChatFlowUITests.swift`

**Step 1: Write the failing test**

```swift
import XCTest

final class ChatFlowUITests: UITestBase {
    @MainActor
    func testComposerRemainsEditableWhileSessionHasRunningJobAndNextMessageQueues() throws {
        launchApp(arguments: [
            "-com.agentgui.test.preloadMessages", "false",
            "-com.agentgui.test.executionFixture", "runningWithQueueSupport"
        ])

        let input = app.descendants(matching: .any).matching(identifier: "chat.inputField").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 2))
        XCTAssertTrue(input.isEnabled)

        input.click()
        input.typeText("queue next message")
        app.descendants(matching: .any).matching(identifier: "chat.sendButton").firstMatch.click()

        XCTAssertTrue(app.staticTexts["队列 1"].waitForExistence(timeout: 2), app.debugDescription)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiUITests/ChatFlowUITests`
Expected: FAIL because composer is still disabled when `claudeService.isStreaming == true`, or queue badge does not exist.

**Step 3: Write minimal implementation**

```swift
var sessionExecutionProjection: SessionExecutionProjection {
    claudeService.executionProjectionStore.projection(for: session.sessionId)
}

MentionAwareEditor(
    text: $inputText,
    isDisabled: !sessionExecutionProjection.canEditComposer,
    ...
)

if sessionExecutionProjection.isRunning {
    RunningQueueBadge(count: sessionExecutionProjection.queuedCount)
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiUITests/ChatFlowUITests`
Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/ChatView.swift agentGui/Views/ChatView+Actions.swift agentGui/Views/ChatView+InputArea.swift agentGui/Views/ChatView+MessageList.swift agentGuiUITests/ChatFlowUITests.swift
git commit -m "feat: switch chat ui to queue-aware execution projection"
```

### Task 8: 清理旧状态源并完成端到端验证

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionRuntimeCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+MessageList.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionOrchestratorTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/ChatFlowUITests.swift`

**Step 1: Write the failing test**

```swift
@MainActor
struct ConversationExecutionOrchestratorTests {
    @Test func cancellingRunningJobDoesNotCancelQueuedJobsInSameSession() async throws {
        let harness = try ExecutionOrchestratorHarness.makeRunningAndQueuedSession()

        await harness.orchestrator.cancelRunning(in: harness.session.sessionId)

        let projection = harness.projectionStore.projection(for: harness.session.sessionId)
        #expect(projection.isRunning == false)
        #expect(projection.queuedCount == 1)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ConversationExecutionOrchestratorTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiUITests/ChatFlowUITests`
Expected: FAIL because cancellation still assumes a single active path or queue state is lost.

**Step 3: Write minimal implementation**

```swift
@MainActor
final class ClaudeService {
    @available(*, deprecated, message: "Use executionProjectionStore per session")
    var isStreaming: Bool = false
}

func cancelRunning(in sessionID: String) async {
    await scheduler.cancelRunningAttempt(in: sessionID)
    projectionStore.markSessionStopped(sessionID)
}
```

**Step 4: Run targeted tests and smoke gate**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ConversationExecutionOrchestratorTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiUITests/ChatFlowUITests`
Expected: PASS.

Run: `./scripts/run_quality_smoke.sh`
Expected: exit code 0.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService/ClaudeService.swift agentGui/Services/ClaudeService/ClaudeService+Messaging.swift agentGui/Services/ConversationExecutionRuntimeCoordinator.swift agentGui/Views/ChatView+InputArea.swift agentGui/Views/ChatView+MessageList.swift agentGuiTests/ConversationExecutionOrchestratorTests.swift agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift agentGuiTests/OpenCodeCLIExecutionProviderTests.swift agentGuiUITests/ChatFlowUITests.swift
git commit -m "refactor: remove global execution state coupling"
```

### Task 9: 最终 review 和文档回写

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-21-conversation-execution-runtime-rearchitecture-design.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-21-conversation-execution-runtime-rearchitecture-implementation-plan.md`

**Step 1: Request final code review**

Run @requesting-code-review against the full diff after Task 8.

**Step 2: Fix any critical or important findings**

Apply the smallest necessary code changes, rerun the affected tests, and keep notes in the design doc if architecture changed.

Updated closeout note:

1. A follow-up implementation round connected real orchestrator dispatch / completion / cancel closure through the compatibility driver layer.
2. The explicit queue runtime feature gate was removed once send routing, attempt persistence, and cancel propagation were wired end-to-end.
3. `ChatView` still only switches to projection-driven execution UI when the current session actually has a running or queued projection, preventing idle-state split-brain with legacy `isStreaming`.

**Step 3: Re-run the final focused validation**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ConversationExecutionOrchestratorTests -only-testing:agentGuiTests/ConversationExecutionProviderRegistryTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiUITests/ChatFlowUITests`
Expected: PASS.

Run: `./scripts/run_quality_smoke.sh`
Expected: exit code 0.

Actual closeout validation in this worktree intentionally diverged:

1. The user explicitly prohibited UI tests, so `agentGuiUITests/ChatFlowUITests` was not executed during final closeout.
2. Final post-closeout validation was limited to non-UI suites directly affected by the runtime closure work:
    - `agentGuiTests/ConversationExecutionOrchestratorTests`
    - `agentGuiTests/ConversationExecutionProviderRegistryTests`
    - `agentGuiTests/ExecutionPersistenceStoreTests`
    - `agentGuiTests/ClaudeServiceMessagingTests`
3. Additional provider regression coverage was spot-checked in this worktree; `OpenCodeCLIExecutionProviderTests` showed no new failures, while `GitHubCopilotCLIExecutionProviderTests` still carried the known approval-mode baseline noise unrelated to this runtime closure change.
4. `Quality Smoke` was rerun successfully; its current `UI smoke` stage is only a placeholder echo and does not execute real UI tests.

**Step 4: Commit final review fixes**

```bash
git add docs/plans/2026-03-21-conversation-execution-runtime-rearchitecture-design.md docs/plans/2026-03-21-conversation-execution-runtime-rearchitecture-implementation-plan.md
git commit -m "docs: finalize conversation execution runtime plan"
```

## 5. 执行顺序建议

推荐按以下顺序执行，不要跳步：

1. Task 1 到 Task 2 先把 durable model 和 persistence 落稳。
2. Task 3 到 Task 4 建立 mailbox、scheduler、projection、orchestrator 的骨架。
3. Task 5 到 Task 6 把旧 provider 包进 compatibility driver，并把 `ClaudeService` 改成 facade。
4. Task 7 到 Task 8 再切 UI 和清理旧全局状态。
5. Task 9 做最终 review 和文档回写。

这样做的原因是：

1. 队列和并发语义先落到模型与 orchestrator，UI 才有稳定状态可消费。
2. provider 适配层晚于 scheduler，可以避免在同一阶段同时改三层状态机。
3. UI 改造放到后面，便于在命令行测试通过后再处理交互细节。

## 6. 风险提示

- 如果在 Task 5 前就直接改 UI，极容易出现 `claudeService.isStreaming` 和 projection 双状态源并存，必须避免。
- 如果在 Task 2 前就让 scheduler 依赖 live `Message` 或 live `Session`，后续 SwiftData 并发边界会很难收口。
- 如果在 Task 6 前就删除旧 provider 入口，现有 Copilot / OpenCode 回归测试会失去对照面。
- 如果 UI 测试依赖当前 placeholder fixture，不要把“运行中 + 队列中”场景硬编码到生产默认路径，应通过测试启动参数注入。

## 7. 2026-03-21 实际收尾结果

1. Task 1 到 Task 7 已完成，并通过相关非 UI 验证。
2. Task 8 的取消回归保护已补齐，同时把旧全局状态源收敛为 deprecated fallback。
3. 后续实现轮次已经把 orchestrator dispatch、completion、cancel 真正接通，并移除了显式 feature gate。
4. 当前生产发送路径默认经由 queue runtime；`regenerate` / `editAndResend` 也已经迁移到同一套 job runtime，并复用同一套 job/attempt/projection 生命周期。
5. scheduler 当前已放开到最多 2 个并发 job，但继续按 `builtIn` 与 `externalACP` runtime scope 保持同 scope 单活；同时 orchestrator 在 service/bootstrap 时会恢复持久化的 queued/running jobs，避免产生永久 pending 的 placeholder 与僵尸 job。
6. 下一步若继续推进，应把关注点转到更细粒度的 queued job 编辑/替换能力。
7. 如果未来还要继续放宽并发，必须先把 built-in 从 `ClaudeService` 的全局状态彻底改造成 per-session 隔离执行状态；在此之前，不应进一步提升 built-in 相关并发限制。

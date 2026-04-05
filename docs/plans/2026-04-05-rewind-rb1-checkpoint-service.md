# R-B1 ConversationCheckpointService Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现 `ConversationCheckpointService`，在每次用户消息提交、agent loop 开始执行时创建文件系统快照（`ConversationCheckpoint`），并修复 `buildHookPipeline` 中 accumulator messageID 占位符问题。

**Architecture:** `ConversationCheckpointService` 是一个 `actor`，持有对 `FileBackupStore` 的引用和 `ModelContext`。服务提供两个调用点：（1）pre-loop：由 `resumeSendBuiltIn` 创建 `ActiveCheckpointAccumulator` 并注入 `sessionCheckpointAccumulators`；（2）post-loop：调用 `makeSnapshot` 将 accumulator 收集的条目持久化为 `ConversationCheckpoint`。`buildHookPipeline` 修改为复用已存在的 accumulator 而非创建新实例（从而修复 messageID 占位符 bug）。

**Tech Stack:** Swift 6, SwiftData, Swift Testing (`@Suite`/`@Test`), `ModelContainer(isStoredInMemoryOnly: true)`

---

## 现有代码上下文速查

| 文件 | 关键点 |
|------|--------|
| `agentGui/Models/ConversationCheckpoint.swift` | R-A1 已完成：`@Model ConversationCheckpoint`，`trackedFileBackupsJSON`，`hasFileChanges`，`decodedTrackedFileBackups()`，`setTrackedFileBackups(_:)` |
| `agentGui/Services/Rewind/FileCheckpointHook.swift` | R-A3 已完成：`ActiveCheckpointAccumulator` actor，`FileCheckpointHook` struct。accumulator 的 `snapshot()` 方法返回 `[String: FileBackupEntry]` |
| `agentGui/Services/Rewind/FileBackupStore.swift` | R-A2 已完成：`createBackup(filePath:sessionID:version:)`，`hasFileChanged(filePath:entry:)`，`restoreFile(filePath:from:)` |
| `agentGui/Services/ClaudeService/ClaudeService.swift` | `var fileBackupStore: FileBackupStore`，`var sessionCheckpointAccumulators: [String: ActiveCheckpointAccumulator]` |
| `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift` | `buildHookPipeline()` 方法（约 L242-L265）：当前用 `UUID()` 占位符创建 accumulator，需修改为复用已有 accumulator |
| `agentGui/Services/ClaudeService/ClaudeService+Messaging.swift` | `resumeSendBuiltIn(...)` 方法（约 L507-L582）：调用 `runAgenticLoop` 的地方，是 R-B1 pre/post-loop 钩子的宿主 |
| `agentGuiTests/FileBackupStoreTests.swift` | 测试模式参考：Swift Testing framework，`@Suite` + `@Test`，isolate tmp dir，`FileBackupStore(baseURL:)` |
| `agentGuiTests/SubagentProgressSummarizerTests.swift` | SwiftData in-memory 测试模式：`ModelContainer(for: schema, configurations: [config])` where `config = ModelConfiguration(isStoredInMemoryOnly: true)` |

## 关键数据流

```
ChatView.sendMessage()
  → resolveEnqueueCommand() → inserts userMessage to DB
  → orchestrator.enqueue(command) with sourceUserMessageID
  → LegacyConversationExecutionDriver → ConversationExecutionRequest
  → BuiltInConversationExecutionProvider.send(request)
  → claudeService.sendMessageBuiltIn(...)
  → resumeSendBuiltIn(...)
      [PRE-LOOP] ← R-B1 插入点 1：创建 acc，写入 sessionCheckpointAccumulators
  → runAgenticLoop(apiMessages: assistantMessage: ...)
      → runCoreAgentLoop(...)
          → AgentLoopToolExecutionCoordinatorBuilder.build()
              → buildHookPipeline()           ← R-B1 修改点：复用已有 acc
                  → FileCheckpointHook(acc: existing_acc)
          → AgentLoopRunner.run(...)
              loop → executeStreamingRound → tools execute
              → FileCheckpointHook.preExecute → acc.record(...)
      [POST-LOOP] ← R-B1 插入点 2：ConversationCheckpointService.makeSnapshot(acc)
  → try? modelContext.save()
```

---

## Task 1: 创建 `ConversationCheckpointService` actor

**Files:**
- Create: `agentGui/Services/Rewind/ConversationCheckpointService.swift`
- Test: `agentGuiTests/ConversationCheckpointServiceTests.swift`

### Step 1: 写失败测试（makeSnapshot，有文件条目）

**Run:** 
```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rb1-derived \
  -only-testing:agentGuiTests/ConversationCheckpointServiceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

创建测试文件 `agentGuiTests/ConversationCheckpointServiceTests.swift`：

```swift
// agentGuiTests/ConversationCheckpointServiceTests.swift
import Foundation
import Testing
import SwiftData
@testable import agentGui

// MARK: - Helpers

private func makeInMemoryContainer() throws -> ModelContainer {
    let schema = Schema([ConversationCheckpoint.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

private func makeTempDir() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

@Suite("ConversationCheckpointService Tests")
struct ConversationCheckpointServiceTests {

    // MARK: - makeSnapshot: 有条目

    @Test
    func makeSnapshot_withEntries_persistsCheckpointToSwiftData() async throws {
        let container = try makeInMemoryContainer()
        let ctx = ModelContext(container)
        let tmp = try makeTempDir()
        let store = FileBackupStore(baseURL: tmp.appendingPathComponent("backups"))
        let service = ConversationCheckpointService(fileBackupStore: store)

        let msgID = UUID()
        let sessionID = "session-test-1"
        let acc = ActiveCheckpointAccumulator(messageID: msgID, workspaceRoot: tmp.path)

        // 模拟 FileCheckpointHook 记录了一个条目
        await acc.record(
            relativePath: "src/main.swift",
            entry: FileBackupEntry(
                backupKey: "abc123",
                version: 1,
                backupTime: Date(),
                originalRelativePath: "src/main.swift"
            )
        )

        try await service.makeSnapshot(
            accumulator: acc,
            sessionID: sessionID,
            modelContext: ctx
        )

        let descriptor = FetchDescriptor<ConversationCheckpoint>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        let checkpoints = try ctx.fetch(descriptor)

        #expect(checkpoints.count == 1)
        let cp = try #require(checkpoints.first)
        #expect(cp.messageID == msgID)
        #expect(cp.sessionID == sessionID)
        #expect(cp.workspaceRoot == tmp.path)
        #expect(cp.hasFileChanges == true)
        #expect(cp.snapshotSequence == 0)

        let backups = try cp.decodedTrackedFileBackups()
        #expect(backups["src/main.swift"]?.backupKey == "abc123")
    }
}
```

**Expected:** FAIL — `ConversationCheckpointService` 不存在。

### Step 2: 写最小实现

创建 `agentGui/Services/Rewind/ConversationCheckpointService.swift`：

```swift
// agentGui/Services/Rewind/ConversationCheckpointService.swift
import Foundation
import SwiftData

/// R-B1: 在每次用户消息触发时创建文件系统快照，持久化为 ConversationCheckpoint。
///
/// 调用时序：
///   1. Pre-loop：外部调用 `prepareAccumulator(messageID:sessionID:workspaceRoot:)` 创建
///      accumulator，写入 `ClaudeService.sessionCheckpointAccumulators`。
///   2. Post-loop：外部调用 `makeSnapshot(accumulator:sessionID:modelContext:)` 读取
///      accumulator 条目，创建 ConversationCheckpoint 并保存。
actor ConversationCheckpointService: Sendable {

    private let fileBackupStore: FileBackupStore

    init(fileBackupStore: FileBackupStore) {
        self.fileBackupStore = fileBackupStore
    }

    // MARK: - Public API

    /// 创建新的 ActiveCheckpointAccumulator，供 FileCheckpointHook 填充。
    /// 返回值应由调用方存入 ClaudeService.sessionCheckpointAccumulators[sessionID]。
    func prepareAccumulator(
        messageID: UUID,
        sessionID: String,
        workspaceRoot: String
    ) -> ActiveCheckpointAccumulator {
        ActiveCheckpointAccumulator(messageID: messageID, workspaceRoot: workspaceRoot)
    }

    /// Post-loop: 从 accumulator 读取本轮追踪的条目，创建 ConversationCheckpoint 并 insert。
    /// ModelContext 操作在 @MainActor 上执行。
    func makeSnapshot(
        accumulator: ActiveCheckpointAccumulator,
        sessionID: String,
        modelContext: ModelContext
    ) async throws {
        let messageID = await accumulator.messageID
        let workspaceRoot = await accumulator.workspaceRoot
        let entries = await accumulator.snapshot()

        // 计算本 session 下一个 snapshotSequence
        let sequence = await nextSnapshotSequence(sessionID: sessionID, modelContext: modelContext)

        let checkpoint = try ConversationCheckpoint(
            sessionID: sessionID,
            messageID: messageID,
            snapshotSequence: sequence,
            workspaceRoot: workspaceRoot,
            trackedFileBackups: entries,
            hasFileChanges: !entries.isEmpty
        )

        await MainActor.run {
            modelContext.insert(checkpoint)
            try? modelContext.save()
        }
    }

    /// 返回 session 最近 `limit` 个快照，按 snapshotSequence 降序（最新在前）。
    func fetchCheckpoints(
        sessionID: String,
        limit: Int,
        modelContext: ModelContext
    ) async throws -> [ConversationCheckpoint] {
        let descriptor = FetchDescriptor<ConversationCheckpoint>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.snapshotSequence, order: .reverse)]
        )
        return try await MainActor.run {
            var desc = descriptor
            desc.fetchLimit = limit
            return try modelContext.fetch(desc)
        }
    }

    // MARK: - Private

    private func nextSnapshotSequence(
        sessionID: String,
        modelContext: ModelContext
    ) async -> Int {
        await MainActor.run {
            let descriptor = FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == sessionID },
                sortBy: [SortDescriptor(\.snapshotSequence, order: .reverse)]
            )
            var desc = descriptor
            desc.fetchLimit = 1
            let existing = try? modelContext.fetch(desc)
            return (existing?.first?.snapshotSequence ?? -1) + 1
        }
    }
}
```

### Step 3: 运行测试，验证通过

**Run:**
```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rb1-derived \
  -only-testing:agentGuiTests/ConversationCheckpointServiceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

**Expected:** PASS

### Step 4: 补充测试（空条目 + snapshotSequence 递增）

在 `agentGuiTests/ConversationCheckpointServiceTests.swift` 中追加：

```swift
    // MARK: - makeSnapshot: 无条目

    @Test
    func makeSnapshot_emptyEntries_hasFileChanges_isFalse() async throws {
        let container = try makeInMemoryContainer()
        let ctx = ModelContext(container)
        let tmp = try makeTempDir()
        let store = FileBackupStore(baseURL: tmp.appendingPathComponent("backups"))
        let service = ConversationCheckpointService(fileBackupStore: store)

        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: tmp.path)
        // 不记录任何条目

        try await service.makeSnapshot(
            accumulator: acc,
            sessionID: "session-empty",
            modelContext: ctx
        )

        let descriptor = FetchDescriptor<ConversationCheckpoint>(
            predicate: #Predicate { $0.sessionID == "session-empty" }
        )
        let checkpoints = try ctx.fetch(descriptor)
        let cp = try #require(checkpoints.first)
        #expect(cp.hasFileChanges == false)
        #expect(cp.snapshotSequence == 0)
    }

    // MARK: - snapshotSequence 单调递增

    @Test
    func makeSnapshot_multipleSnapshots_sequenceIsMonotonic() async throws {
        let container = try makeInMemoryContainer()
        let ctx = ModelContext(container)
        let tmp = try makeTempDir()
        let store = FileBackupStore(baseURL: tmp.appendingPathComponent("backups"))
        let service = ConversationCheckpointService(fileBackupStore: store)
        let sessionID = "session-seq"

        for i in 0..<3 {
            let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: tmp.path)
            await acc.record(
                relativePath: "file\(i).swift",
                entry: FileBackupEntry(backupKey: "key\(i)", version: 1, backupTime: Date(), originalRelativePath: "file\(i).swift")
            )
            try await service.makeSnapshot(accumulator: acc, sessionID: sessionID, modelContext: ctx)
        }

        let descriptor = FetchDescriptor<ConversationCheckpoint>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.snapshotSequence)]
        )
        let checkpoints = try ctx.fetch(descriptor)
        #expect(checkpoints.count == 3)
        #expect(checkpoints.map(\.snapshotSequence) == [0, 1, 2])
    }

    // MARK: - fetchCheckpoints 

    @Test
    func fetchCheckpoints_returnsLatestFirst() async throws {
        let container = try makeInMemoryContainer()
        let ctx = ModelContext(container)
        let tmp = try makeTempDir()
        let store = FileBackupStore(baseURL: tmp.appendingPathComponent("backups"))
        let service = ConversationCheckpointService(fileBackupStore: store)
        let sessionID = "session-fetch"

        for _ in 0..<5 {
            let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: tmp.path)
            try await service.makeSnapshot(accumulator: acc, sessionID: sessionID, modelContext: ctx)
        }

        let checkpoints = try await service.fetchCheckpoints(sessionID: sessionID, limit: 3, modelContext: ctx)
        #expect(checkpoints.count == 3)
        // 最新的 snapshotSequence 在前
        #expect(checkpoints[0].snapshotSequence > checkpoints[1].snapshotSequence)
        #expect(checkpoints[1].snapshotSequence > checkpoints[2].snapshotSequence)
    }
```

### Step 5: 运行全部新测试

**Run:**
```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rb1-derived \
  -only-testing:agentGuiTests/ConversationCheckpointServiceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```

**Expected:** 5 tests PASS

### Step 6: Commit

```bash
cd /Volumes/T7/文稿/Projects/agentGui
git add agentGui/Services/Rewind/ConversationCheckpointService.swift \
        agentGuiTests/ConversationCheckpointServiceTests.swift
git commit -m "feat(R-B1): add ConversationCheckpointService actor"
```

---

## Task 2: 加入 ClaudeService 并修复 buildHookPipeline 的 messageID 占位符

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService.swift` — 加 checkpointService 属性
- Modify: `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift` — `buildHookPipeline` 复用已有 accumulator
- Test: `agentGuiTests/ConversationCheckpointServiceTests.swift` — 添加集成测试验证 messageID 正确性

### Step 1: 写失败测试（messageID 正确传播）

在 `agentGuiTests/ConversationCheckpointServiceTests.swift` 末尾追加：

```swift
    // MARK: - prepareAccumulator messageID 传播

    @Test
    func prepareAccumulator_returnsAccumulatorWithCorrectMessageID() async {
        let tmp = try! makeTempDir()
        let store = FileBackupStore(baseURL: tmp.appendingPathComponent("backups"))
        let service = ConversationCheckpointService(fileBackupStore: store)

        let expectedID = UUID()
        let acc = await service.prepareAccumulator(
            messageID: expectedID,
            sessionID: "s",
            workspaceRoot: "/ws"
        )
        let actualID = await acc.messageID
        #expect(actualID == expectedID)
    }
```

**Expected:** PASS（已实现 `prepareAccumulator`，此测试应直接通过）

### Step 2: 修改 `ClaudeService.swift`，添加 checkpointService 属性

在 `agentGui/Services/ClaudeService/ClaudeService.swift` 中，在 `fileBackupStore` 属性之后添加：

```swift
    /// R-B1: 快照服务，在每次 agent loop 前后创建/更新 ConversationCheckpoint。
    lazy var checkpointService: ConversationCheckpointService = {
        ConversationCheckpointService(fileBackupStore: fileBackupStore)
    }()
```

### Step 3: 修改 `buildHookPipeline` 复用已有 accumulator

打开 `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`，找到 `buildHookPipeline()` 方法中的这段代码（约 L242-L255）：

```swift
        // R-A3: FileCheckpointHook — 必须在 ChangeReviewHook 之前（preExecute 备份原始内容）
        let workspaceRoot: String = {
            if let wd = session?.workingDirectory, !wd.isEmpty { return wd }
            if !settings.workingDirectory.isEmpty { return settings.workingDirectory }
            return FileManager.default.currentDirectoryPath
        }()
        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: workspaceRoot)
        claudeService.sessionCheckpointAccumulators[sessionId] = acc
        hooks.append(FileCheckpointHook(
            fileBackupStore: claudeService.fileBackupStore,
            accumulator: acc,
            workspaceRoot: workspaceRoot
        ))
```

将其替换为：

```swift
        // R-A3: FileCheckpointHook — 必须在 ChangeReviewHook 之前（preExecute 备份原始内容）
        let workspaceRoot: String = {
            if let wd = session?.workingDirectory, !wd.isEmpty { return wd }
            if !settings.workingDirectory.isEmpty { return settings.workingDirectory }
            return FileManager.default.currentDirectoryPath
        }()
        // R-B1: 复用 resumeSendBuiltIn 预先安装的 accumulator（含正确的 messageID）；
        // 若不存在（子代理路径），则创建新实例（messageID 不影响子代理场景）。
        let acc: ActiveCheckpointAccumulator
        if let existing = claudeService.sessionCheckpointAccumulators[sessionId] {
            acc = existing
        } else {
            acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: workspaceRoot)
            claudeService.sessionCheckpointAccumulators[sessionId] = acc
        }
        hooks.append(FileCheckpointHook(
            fileBackupStore: claudeService.fileBackupStore,
            accumulator: acc,
            workspaceRoot: workspaceRoot
        ))
```

### Step 4: 运行已有 FileCheckpointHook 测试，确认无回归

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rb1-derived \
  -only-testing:agentGuiTests/FileCheckpointHookTests \
  -only-testing:agentGuiTests/ConversationCheckpointServiceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

**Expected:** 所有测试 PASS

### Step 5: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService.swift \
        agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift \
        agentGuiTests/ConversationCheckpointServiceTests.swift
git commit -m "feat(R-B1): add checkpointService to ClaudeService, fix buildHookPipeline accumulator reuse"
```

---

## Task 3: 集成到 resumeSendBuiltIn（pre-loop + post-loop 钩子）

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Messaging.swift` — `resumeSendBuiltIn` 方法

### Step 1: 定位修改点

打开 `agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`，找到 `resumeSendBuiltIn` 方法。关键结构如下：

```swift
private func resumeSendBuiltIn(
    apiMessages: [MessageParameter.Message],
    service: any AnthropicService,
    session: Session,
    modelId: String,
    ...
    modelContext: ModelContext
) async throws {
    let settings = AppSettings.getOrCreate(in: modelContext)
    // ... skill context, system prompt, tools, LSP 初始化 ...

    let assistantMessage = resolveOrCreateAssistantMessage(...)

    do {
        let result = try await runAgenticLoop(...)
        assistantMessage.status = ...
    } catch ...

    session.updatedAt = Date()
    try? modelContext.save()
}
```

### Step 2: 写失败的集成测试

> ⚠️ `resumeSendBuiltIn` 是 `private`，无法直接测试。此处改为测试端到端行为的验收标准：
> 运行 xcodebuild 后，手动验证 checkpoint 在 SwiftData 中正确出现（或在 Task 4 的功能冒烟测试中验证）。
>
> 但我们可以用单元测试验证 service 方法的组合行为：

在 `agentGuiTests/ConversationCheckpointServiceTests.swift` 末尾追加：

```swift
    // MARK: - prepare + makeSnapshot 完整生命周期

    @Test
    func fullLifecycle_prepareAndMakeSnapshot_matchesMessageID() async throws {
        let container = try makeInMemoryContainer()
        let ctx = ModelContext(container)
        let tmp = try makeTempDir()
        let store = FileBackupStore(baseURL: tmp.appendingPathComponent("backups"))
        let service = ConversationCheckpointService(fileBackupStore: store)

        let userMsgID = UUID()
        let sessionID = "session-full"

        // Pre-loop: 创建 accumulator
        let acc = await service.prepareAccumulator(
            messageID: userMsgID,
            sessionID: sessionID,
            workspaceRoot: tmp.path
        )

        // 模拟 FileCheckpointHook 在 loop 中写入
        await acc.record(
            relativePath: "app.swift",
            entry: FileBackupEntry(backupKey: "deadbeef", version: 1, backupTime: Date(), originalRelativePath: "app.swift")
        )

        // Post-loop: 创建快照
        try await service.makeSnapshot(accumulator: acc, sessionID: sessionID, modelContext: ctx)

        // 验证 checkpoint 已持久化，且 messageID 与 userMsgID 一致
        let descriptor = FetchDescriptor<ConversationCheckpoint>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        let checkpoints = try ctx.fetch(descriptor)
        let cp = try #require(checkpoints.first)
        #expect(cp.messageID == userMsgID)
        #expect(cp.hasFileChanges == true)
    }
```

**Run:**
```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rb1-derived \
  -only-testing:agentGuiTests/ConversationCheckpointServiceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

**Expected:** PASS

### Step 3: 修改 resumeSendBuiltIn

在 `agentGui/Services/ClaudeService/ClaudeService+Messaging.swift` 中，找到 `resumeSendBuiltIn` 的 `let assistantMessage = resolveOrCreateAssistantMessage(...)` 行前后：

**原代码（约 L534-L570）：**

```swift
        let assistantMessage = resolveOrCreateAssistantMessage(
            session: session,
            targetAgentMessageID: targetAgentMessageID,
            modelContext: modelContext
        )

        do {
            let result = try await runAgenticLoop(
                apiMessages: apiMessages,
                assistantMessage: assistantMessage,
                service: service,
                modelId: modelId,
                tools: tools,
                systemPrompt: systemPrompt,
                session: session,
                settings: settings,
                modelContext: modelContext,
            )
            assistantMessage.status = result.completedSuccessfully ? .completed : .failed
            if assistantMessage.textContent?.isEmpty ?? true {
                assistantMessage.textContent = "(无响应)"
            }
        } catch is CancellationError {
            assistantMessage.status = .cancelled
            if assistantMessage.textContent?.isEmpty ?? true {
                assistantMessage.textContent = "(已取消)"
            }
            session.updatedAt = Date()
            try? modelContext.save()
            throw CancellationError()
        } catch {
            assistantMessage.status = .failed
            assistantMessage.textContent = "错误: \(error.localizedDescription)"
            lastError = error.localizedDescription
            throw ClaudeError.streamFailed(error)
        }
```

**新代码（在 `let assistantMessage` 行之前插入 pre-loop，并在 loop 完成后插入 post-loop）：**

```swift
        let assistantMessage = resolveOrCreateAssistantMessage(
            session: session,
            targetAgentMessageID: targetAgentMessageID,
            modelContext: modelContext
        )

        // R-B1 pre-loop: 找到触发此 loop 的用户消息 ID，创建 accumulator
        let checkpointAcc: ActiveCheckpointAccumulator = {
            let userMsgID = session.messages
                .sorted { $0.sequence < $1.sequence }
                .last(where: { $0.direction == .user })?.id ?? UUID()
            let wsRoot = settings.workingDirectory.isEmpty
                ? FileManager.default.currentDirectoryPath
                : settings.workingDirectory
            // checkpointService 是 actor，但 prepareAccumulator 是同步等价操作；
            // 此闭包在 @MainActor 上运行，暂用同步路径构造（actor 异步方法在后续步骤中调用）。
            let acc = ActiveCheckpointAccumulator(messageID: userMsgID, workspaceRoot: wsRoot)
            sessionCheckpointAccumulators[session.sessionId] = acc
            return acc
        }()

        do {
            let result = try await runAgenticLoop(
                apiMessages: apiMessages,
                assistantMessage: assistantMessage,
                service: service,
                modelId: modelId,
                tools: tools,
                systemPrompt: systemPrompt,
                session: session,
                settings: settings,
                modelContext: modelContext,
            )
            assistantMessage.status = result.completedSuccessfully ? .completed : .failed
            if assistantMessage.textContent?.isEmpty ?? true {
                assistantMessage.textContent = "(无响应)"
            }

            // R-B1 post-loop: 将本轮 accumulator 条目持久化为 ConversationCheckpoint
            try? await checkpointService.makeSnapshot(
                accumulator: checkpointAcc,
                sessionID: session.sessionId,
                modelContext: modelContext
            )
        } catch is CancellationError {
            // 取消时仍尝试保存已收集的快照（loop 可能已完成部分工具调用）
            try? await checkpointService.makeSnapshot(
                accumulator: checkpointAcc,
                sessionID: session.sessionId,
                modelContext: modelContext
            )
            assistantMessage.status = .cancelled
            if assistantMessage.textContent?.isEmpty ?? true {
                assistantMessage.textContent = "(已取消)"
            }
            session.updatedAt = Date()
            try? modelContext.save()
            throw CancellationError()
        } catch {
            assistantMessage.status = .failed
            assistantMessage.textContent = "错误: \(error.localizedDescription)"
            lastError = error.localizedDescription
            throw ClaudeError.streamFailed(error)
        }
```

### Step 4: 编译验证（无测试运行）

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-rb1-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning:|BUILD"
```

**Expected:** `BUILD SUCCEEDED`（无编译错误）

### Step 5: 运行所有相关测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rb1-derived \
  -only-testing:agentGuiTests/FileCheckpointHookTests \
  -only-testing:agentGuiTests/ConversationCheckpointServiceTests \
  -only-testing:agentGuiTests/FileBackupStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```

**Expected:** 所有测试 PASS

### Step 6: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+Messaging.swift \
        agentGuiTests/ConversationCheckpointServiceTests.swift
git commit -m "feat(R-B1): integrate CheckpointService into resumeSendBuiltIn (pre/post-loop hooks)"
```

---

## Task 4: 冒烟测试验证端到端 checkpoint 创建

**Files:**
- Test: `agentGuiTests/ConversationCheckpointServiceTests.swift` — 追加集成冒烟测试

此测试验证：当通过 `FileCheckpointHook` + `ConversationCheckpointService` 的完整链路触发时，实际磁盘文件备份 + SwiftData checkpoint 均正确创建。

### Step 1: 写冒烟测试

在 `agentGuiTests/ConversationCheckpointServiceTests.swift` 末尾追加：

```swift
    // MARK: - 冒烟: Hook → Accumulator → Checkpoint 完整链路

    @Test
    func smokeTest_hookFillsAccumulator_snapshotPersistedWithBackupKey() async throws {
        let container = try makeInMemoryContainer()
        let ctx = ModelContext(container)
        let tmp = try makeTempDir()
        let store = FileBackupStore(baseURL: tmp.appendingPathComponent("backups"))
        let service = ConversationCheckpointService(fileBackupStore: store)

        let sessionID = "smoke-session"
        let userMsgID = UUID()

        // 1. 在 workspaceRoot 创建待备份文件
        let wsRoot = tmp.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: wsRoot, withIntermediateDirectories: true)
        let targetFile = wsRoot.appendingPathComponent("Foo.swift")
        try "original content".write(to: targetFile, atomically: true, encoding: .utf8)

        // 2. Pre-loop: 创建 accumulator
        let acc = await service.prepareAccumulator(
            messageID: userMsgID,
            sessionID: sessionID,
            workspaceRoot: wsRoot.path
        )

        // 3. 模拟 FileCheckpointHook.preExecute：
        //    直接用 FileBackupStore 备份文件并记录到 accumulator
        let entry = try await store.createBackup(
            filePath: targetFile.path,
            sessionID: sessionID,
            version: 1
        )
        let backupEntry = FileBackupEntry(
            backupKey: entry.backupKey,
            version: entry.version,
            backupTime: entry.backupTime,
            originalRelativePath: "Foo.swift"
        )
        await acc.record(relativePath: "Foo.swift", entry: backupEntry)

        // 4. Post-loop: makeSnapshot
        try await service.makeSnapshot(accumulator: acc, sessionID: sessionID, modelContext: ctx)

        // 5. 验证 SwiftData 中有 checkpoint，且 backupKey 非 nil
        let descriptor = FetchDescriptor<ConversationCheckpoint>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        let checkpoints = try ctx.fetch(descriptor)
        let cp = try #require(checkpoints.first)
        #expect(cp.messageID == userMsgID)
        #expect(cp.hasFileChanges == true)

        let backups = try cp.decodedTrackedFileBackups()
        let persistedEntry = try #require(backups["Foo.swift"])
        #expect(persistedEntry.backupKey != nil)

        // 6. 验证磁盘上备份文件存在
        let key = try #require(persistedEntry.backupKey)
        let backupFile = tmp
            .appendingPathComponent("backups/\(sessionID)/\(String(key.prefix(2)))/\(key).bak")
        #expect(FileManager.default.fileExists(atPath: backupFile.path))
        let backedContent = try String(contentsOf: backupFile, encoding: .utf8)
        #expect(backedContent == "original content")
    }
```

### Step 2: 运行冒烟测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rb1-derived \
  -only-testing:agentGuiTests/ConversationCheckpointServiceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```

**Expected:** 所有 7 个测试 PASS

### Step 3: 运行全套 Rewind 相关测试，确认无回归

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rb1-derived \
  -only-testing:agentGuiTests/FileBackupStoreTests \
  -only-testing:agentGuiTests/FileCheckpointHookTests \
  -only-testing:agentGuiTests/ConversationCheckpointServiceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -50
```

**Expected:** 所有测试 PASS

### Step 4: 最终 Commit

```bash
git add agentGuiTests/ConversationCheckpointServiceTests.swift
git commit -m "test(R-B1): add smoke test for Hook→Accumulator→Checkpoint pipeline"
```

---

## 验收标准总结

| 标准 | 验证方式 |
|------|---------|
| `ConversationCheckpointService.makeSnapshot` 将 accumulator 条目持久化为 `ConversationCheckpoint` | Task 1 单元测试 |
| `hasFileChanges == false` 当无条目时 | Task 1 单元测试 |
| `snapshotSequence` 在同 session 下单调递增 | Task 1 单元测试 |
| `fetchCheckpoints` 返回最新在前，支持 limit | Task 1 单元测试 |
| `buildHookPipeline` 复用已有 accumulator，不覆盖 messageID | Task 2 代码修改 + Task 2 unit test |
| `resumeSendBuiltIn` pre-loop 注入正确 messageID 的 accumulator | Task 3 代码修改 |
| `resumeSendBuiltIn` post-loop 持久化 checkpoint（含取消场景） | Task 3 代码修改 |
| 完整链路：文件备份 + SwiftData checkpoint 均正确 | Task 4 冒烟测试 |

---

## 注意事项

### `@MainActor` 与 actor 边界

- `ClaudeService` 是 `@MainActor`；`resumeSendBuiltIn` 是 `@MainActor` 方法
- `ConversationCheckpointService` 是 `actor`；在 `@MainActor` 上调用 actor 方法需 `await`
- `ModelContext` 操作必须在 `@MainActor` 上执行，`makeSnapshot` 内部已通过 `await MainActor.run { ... }` 处理

### 子代理场景

- `runSubagentLoop` 也调用 `buildHookPipeline`。子代理场景下 `sessionCheckpointAccumulators[sessionId]` 可能不存在（`resumeSendBuiltIn` 只注入主代理 sessionID），此时 `buildHookPipeline` 会创建新 accumulator（UUID messageID），不影响功能。
- 子代理不需要 post-loop snapshot：子代理的文件修改已由主代理的 accumulator 追踪（子代理和主代理共享 sessionID）。若子代理用不同 sessionID，其文件修改不在 Rewind 范围内（符合预期）。

### 取消场景

- `CancellationError` catch 块中也调用了 `makeSnapshot`。这确保在用户中断执行时，已完成的部分工具调用的文件备份仍被记录（对应 Claude Code 的 lossless path 设计）。

### 不要修改的内容

- 不要修改 `FileCheckpointHook` 和 `ActiveCheckpointAccumulator`（R-A3 已完成）
- 不要修改 `FileBackupStore`（R-A2 已完成）
- 不要修改 `ConversationCheckpoint` 模型（R-A1 已完成）
- 子代理路径（`ClaudeService+Subagent.swift`）无需修改（子代理 checkpoint 是 P2 范围）

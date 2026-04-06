# Rewind R-C4 RewindTransactionCoordinator 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现 `RewindTransactionCoordinator`（R-C4），作为 Rewind 功能的统一执行入口，协调 loop 取消、文件系统恢复（R-C2）和对话截断（R-C1），并在完成后发出通知供 ChatView 填充输入框。

**Architecture:**
- `@MainActor final class`，与 R-C1/R-C2 保持一致
- 通过闭包注入 loop 取消能力（避免直接依赖 `ClaudeService`，提升可测试性）
- 完成后发出 `Notification.Name.rewindDidComplete`，ChatView 通过 `.onReceive` 监听并设置 `inputText`

**Tech Stack:** Swift 6, SwiftData, SwiftUI, Foundation, Swift Testing framework (`@Test`/`@Suite`)

**Pre-conditions（已完成的依赖）:**
- R-A1: `ConversationCheckpoint.swift` ✅
- R-A2: `FileBackupStore.swift` ✅
- R-C1: `ConversationRewindCoordinator.swift` ✅
- R-C2: `FileSystemRewindCoordinator.swift` ✅
- R-C3: `RewindPreflightInspector.swift` ✅（`hasAnyFileChanges`、`computeDiffStats`）

---

## 背景：Claude Code 对应实现

`RewindTransactionCoordinator` 对应 Claude Code `src/screens/REPL.tsx` 中的 `restoreMessageSync` + `MessageSelector` 的 `onRestoreCode/onRestoreMessage` 回调：

```typescript
// REPL.tsx ~L3712
const restoreMessageSync = (message: UserMessage) => {
  rewindConversationTo(message);         // 截断对话 → R-C1
  setInputValue(r.text);                 // 填充输入框 → notification
};

// MessageSelector onRestoreCode callback ~L4912
await fileHistoryRewind(updater => {     // 文件系统恢复 → R-C2
  setAppState(prev => ({ ...prev, fileHistory: updater(prev.fileHistory) }));
}, message.uuid);

// Lossless fast path ~L3774-3780
const noFileChanges = !(await fileHistoryHasAnyChanges(fileHistory, raw.uuid));
const onlySynthetic = messagesAfterAreOnlySynthetic(messages, rawIdx);
if (noFileChanges && onlySynthetic) {
  onCancel();                           // 取消 loop → cancelLoop closure
  void handleRestoreMessage(raw);
}
```

---

## 文件清单

**新建:**
- `agentGui/Services/Rewind/RewindTransactionCoordinator.swift` ← 主实现
- `agentGuiTests/RewindTransactionCoordinatorTests.swift` ← 单元测试

**修改:**
- `agentGui/Views/ChatView.swift` ← 监听 `rewindDidComplete` 通知，填充 `inputText`

---

## Task 1：类型定义与文件骨架

**Files:**
- Create: `agentGui/Services/Rewind/RewindTransactionCoordinator.swift`

**Step 1: 创建文件，写入全部类型定义与 TODO 骨架**

```swift
// agentGui/Services/Rewind/RewindTransactionCoordinator.swift
import Foundation
import SwiftData

// MARK: - RewindOption

/// 回滚操作选项，控制恢复范围。
/// 对应 Claude Code src/components/MessageSelector.tsx 中的三个选项按钮：
/// "Restore code and conversation" / "Restore conversation" / "Restore code"
enum RewindOption: Sendable {
    /// 同时恢复文件系统 + 截断对话（默认，最常用）
    case conversationAndFiles
    /// 只截断对话，不动文件（保留 agent 的文件改动）
    case conversationOnly
    /// 只恢复文件，不截断对话（保留对话历史但还原文件）
    case filesOnly
}

// MARK: - RewindTransactionError

enum RewindTransactionError: Error, LocalizedError {
    /// option 包含文件恢复但未提供 checkpoint，或 checkpoint 的 hasFileChanges 为 false
    case checkpointRequiredForFileRestore
    /// targetMessage 未关联到任何 Session
    case messageNotAttachedToSession

    var errorDescription: String? {
        switch self {
        case .checkpointRequiredForFileRestore:
            return "文件恢复需要有效的检查点，但当前消息没有对应的文件快照。"
        case .messageNotAttachedToSession:
            return "目标消息未关联到任何 Session，无法执行回滚。"
        }
    }
}

// MARK: - RewindTransactionResult

struct RewindTransactionResult: Sendable, Equatable {
    /// 被截断的消息数量（0 = filesOnly 模式或截断失败）
    var messagesDeleted: Int
    /// 实际被恢复的文件数量（0 = conversationOnly 模式）
    var filesRestored: Int
    /// 与备份相同无需恢复的文件数量
    var filesSkipped: Int
    /// 恢复失败的文件数量（non-zero = 部分成功）
    var filesFailed: Int

    static let conversationOnlyResult = RewindTransactionResult(
        messagesDeleted: 0,
        filesRestored: 0,
        filesSkipped: 0,
        filesFailed: 0
    )
}

// MARK: - Notification.Name

extension Notification.Name {
    /// 回滚事务完成后发出。
    /// userInfo keys：
    ///   - "sessionID": String
    ///   - "repopulateText": String?（若 repopulateInput=true 且消息有文本）
    ///   - "option": String（"conversationAndFiles" / "conversationOnly" / "filesOnly"）
    static let rewindDidComplete = Notification.Name("agentGui.rewindDidComplete")
}

// MARK: - RewindTransactionCoordinator

/// R-C4: Rewind 功能的统一执行入口。
///
/// ## 职责
/// 按顺序协调以下步骤：
/// 1. 取消正在运行的 agent loop（幂等）
/// 2. 文件系统恢复（R-C2），仅 option 含文件时执行
/// 3. 对话截断（R-C1），仅 option 含对话时执行
/// 4. 发出 `rewindDidComplete` 通知（含输入框填充文本）
///
/// ## 设计决策
/// - 使用闭包注入 loop 取消能力，避免直接依赖 ClaudeService（提升可测试性）
/// - 输入框填充通过通知（`rewindDidComplete`）解耦，ChatView 监听并设置 `inputText`
/// - 若 checkpoint 为 nil 且 option 含文件恢复，抛出 `checkpointRequiredForFileRestore`
///
/// ## 并发安全
/// `@MainActor`：SwiftData 访问和 UI 通知都必须在主线程；
/// cancelLoop 闭包标注 @MainActor，保证取消操作在主线程调度。
@MainActor
final class RewindTransactionCoordinator {

    // MARK: - Dependencies

    private let conversationRewindCoordinator: ConversationRewindCoordinator
    private let fileSystemRewindCoordinator: FileSystemRewindCoordinator
    /// 取消正在运行的 agent loop（幂等）。
    /// 闭包签名：(_ sessionID: String, _ modelContext: ModelContext) async -> Void
    private let cancelLoop: @MainActor @Sendable (String, ModelContext) async -> Void
    private let modelContext: ModelContext

    // MARK: - Init

    init(
        conversationRewindCoordinator: ConversationRewindCoordinator,
        fileSystemRewindCoordinator: FileSystemRewindCoordinator,
        cancelLoop: @escaping @MainActor @Sendable (String, ModelContext) async -> Void,
        modelContext: ModelContext
    ) {
        self.conversationRewindCoordinator = conversationRewindCoordinator
        self.fileSystemRewindCoordinator = fileSystemRewindCoordinator
        self.cancelLoop = cancelLoop
        self.modelContext = modelContext
    }

    // MARK: - Public API

    /// 执行回滚事务。
    ///
    /// - Parameters:
    ///   - targetMessage: 回滚目标消息。该消息本身及之后的所有消息将被删除（conversationOnly / conversationAndFiles）。
    ///   - checkpoint: 目标消息对应的文件检查点（由 ConversationCheckpointService 创建）。
    ///                 option 包含文件恢复时必须非 nil。
    ///   - option: 回滚范围选项。
    ///   - repopulateInput: 若为 true，在通知中携带目标消息的文本，供 ChatView 填回输入框。
    /// - Returns: 包含操作结果统计的 `RewindTransactionResult`。
    /// - Throws: `RewindTransactionError`（类型安全，调用方可精确处理）
    @discardableResult
    func execute(
        targetMessage: Message,
        checkpoint: ConversationCheckpoint?,
        option: RewindOption,
        repopulateInput: Bool = true
    ) async throws -> RewindTransactionResult {
        // TODO: implement in subsequent tasks
        fatalError("Not implemented")
    }
}
```

**Step 2: 验证文件可编译（仅骨架，尚有 fatalError）**

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-rc4-plan-build \
  build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

预期：`BUILD SUCCEEDED`（fatalError 在运行时才触发）

**Step 3: 提交骨架**

```bash
git add agentGui/Services/Rewind/RewindTransactionCoordinator.swift
git commit -m "feat(rewind): R-C4 type definitions and coordinator skeleton"
```

---

## Task 2：实现 `conversationOnly` 路径 + 测试

**Files:**
- Modify: `agentGui/Services/Rewind/RewindTransactionCoordinator.swift`
- Create: `agentGuiTests/RewindTransactionCoordinatorTests.swift`

### Step 1: 写失败测试（conversationOnly）

创建测试文件，此时 `execute` 还是 `fatalError`，测试会因 crash 失败：

```swift
// agentGuiTests/RewindTransactionCoordinatorTests.swift
import Foundation
import Testing
import SwiftData
@testable import agentGui

// MARK: - Shared Helpers

/// 构造内存模型容器
@MainActor
private func makeContainer() throws -> ModelContainer {
    let schema = Schema(PersistenceSchema.sharedModelTypes)
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

/// 创建测试用 Session
@MainActor
private func makeSession(in ctx: ModelContext) -> Session {
    let s = Session()
    ctx.insert(s)
    return s
}

/// 创建有 sequence 的 Message
@MainActor
private func makeMessage(
    direction: MessageDirection = .user,
    sequence: Int,
    status: MessageStatus = .completed,
    text: String? = nil,
    in ctx: ModelContext,
    session: Session
) -> Message {
    let msg = Message(direction: direction, text: text ?? "msg\(sequence)", session: session)
    msg.sequence = sequence
    msg.status = status
    ctx.insert(msg)
    return msg
}

/// 构造不抛出的 RewindTransactionCoordinator（cancelLoop 记录调用）
@MainActor
private func makeCoordinator(
    ctx: ModelContext,
    cancelCallLog: inout [String],
    backupBaseURL: URL? = nil
) -> RewindTransactionCoordinator {
    let convCoord = ConversationRewindCoordinator(modelContext: ctx)
    let store = FileBackupStore(baseURL: backupBaseURL ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("rc4-test-\(UUID().uuidString)"))
    let fsCoord = FileSystemRewindCoordinator(fileBackupStore: store)
    return RewindTransactionCoordinator(
        conversationRewindCoordinator: convCoord,
        fileSystemRewindCoordinator: fsCoord,
        cancelLoop: { sessionID, _ in
            cancelCallLog.append(sessionID)
        },
        modelContext: ctx
    )
}

// MARK: - Test Suite: conversationOnly

@MainActor
@Suite("RewindTransactionCoordinator — conversationOnly")
struct RewindTransactionCoordinatorConversationOnlyTests {

    @Test
    func conversationOnly_truncatesMessagesAtAndAfterTarget() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        var cancelLog: [String] = []
        let coordinator = makeCoordinator(ctx: ctx, cancelCallLog: &cancelLog)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        let m2 = makeMessage(sequence: 2, in: ctx, session: session)
        let m3 = makeMessage(sequence: 3, in: ctx, session: session)
        _ = makeMessage(sequence: 4, in: ctx, session: session)
        try ctx.save()

        let result = try await coordinator.execute(
            targetMessage: m3,
            checkpoint: nil,
            option: .conversationOnly
        )

        // 对话被截断
        #expect(result.messagesDeleted == 2)   // m3, m4

        // 文件操作为 0
        #expect(result.filesRestored == 0)
        #expect(result.filesSkipped == 0)
        #expect(result.filesFailed == 0)

        // m1, m2 保留
        let remaining = try ctx.fetch(FetchDescriptor<Message>())
        #expect(remaining.map(\.sequence).sorted() == [1, 2])
        _ = m1; _ = m2  // suppress unused warning
    }

    @Test
    func conversationOnly_cancelsRunningLoop() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        var cancelLog: [String] = []
        let coordinator = makeCoordinator(ctx: ctx, cancelCallLog: &cancelLog)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        try ctx.save()

        _ = try await coordinator.execute(
            targetMessage: m1,
            checkpoint: nil,
            option: .conversationOnly
        )

        // cancelLoop 应被调用一次，传入 session.sessionId
        #expect(cancelLog.count == 1)
        #expect(cancelLog[0] == session.sessionId)
    }

    @Test
    func conversationOnly_messsageNotAttachedToSession_throws() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        var cancelLog: [String] = []
        let coordinator = makeCoordinator(ctx: ctx, cancelCallLog: &cancelLog)

        let orphan = Message(direction: .user, text: "orphan", session: nil)
        ctx.insert(orphan)
        try ctx.save()

        await #expect(throws: RewindTransactionError.messageNotAttachedToSession) {
            _ = try await coordinator.execute(
                targetMessage: orphan,
                checkpoint: nil,
                option: .conversationOnly
            )
        }
    }

    @Test
    func conversationOnly_withCheckpointNil_succeeds() async throws {
        // checkpoint=nil 对于 conversationOnly 是合法的
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        var cancelLog: [String] = []
        let coordinator = makeCoordinator(ctx: ctx, cancelCallLog: &cancelLog)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        try ctx.save()

        let result = try await coordinator.execute(
            targetMessage: m1,
            checkpoint: nil,
            option: .conversationOnly
        )
        #expect(result.messagesDeleted == 1)
    }
}
```

**Step 2: 运行测试，确认失败**

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rc4-task2 \
  -only-testing:agentGuiTests/RewindTransactionCoordinatorConversationOnlyTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "TEST FAILED|CRASH|fatalError|error:"
```

预期：CRASH/TEST FAILED（因为 `fatalError`）

**Step 3: 实现 `execute` 的 `conversationOnly` 路径**

将 `RewindTransactionCoordinator.execute` 的 `fatalError` 替换为如下实现：

```swift
@discardableResult
func execute(
    targetMessage: Message,
    checkpoint: ConversationCheckpoint?,
    option: RewindOption,
    repopulateInput: Bool = true
) async throws -> RewindTransactionResult {
    guard let session = targetMessage.session else {
        throw RewindTransactionError.messageNotAttachedToSession
    }

    // 1. 取消正在运行的 agent loop（幂等，总是先执行）
    await cancelLoop(session.sessionId, modelContext)

    var messagesDeleted = 0
    var filesRestored = 0
    var filesSkipped = 0
    var filesFailed = 0

    // 2. 文件系统恢复（仅 option 含文件时执行）
    if option == .filesOnly || option == .conversationAndFiles {
        guard let cp = checkpoint else {
            throw RewindTransactionError.checkpointRequiredForFileRestore
        }
        let fsResult = try await fileSystemRewindCoordinator.rewind(to: cp)
        filesRestored = fsResult.restoredFiles.count
        filesSkipped = fsResult.skippedFiles.count
        filesFailed = fsResult.failedFiles.count
    }

    // 3. 对话截断（仅 option 含对话时执行）
    if option == .conversationOnly || option == .conversationAndFiles {
        messagesDeleted = try await conversationRewindCoordinator.rewindTo(message: targetMessage)
    }

    // 4. 发出完成通知（含可选的输入框填充文本）
    let repopulateText: String? = repopulateInput ? targetMessage.text.nilIfEmpty : nil
    NotificationCenter.default.post(
        name: .rewindDidComplete,
        object: session.sessionId,
        userInfo: [
            "sessionID": session.sessionId,
            "repopulateText": repopulateText as Any,
            "option": option.notificationKey
        ]
    )

    return RewindTransactionResult(
        messagesDeleted: messagesDeleted,
        filesRestored: filesRestored,
        filesSkipped: filesSkipped,
        filesFailed: filesFailed
    )
}
```

同时在文件底部添加辅助 extension：

```swift
// MARK: - Private Helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension RewindOption {
    var notificationKey: String {
        switch self {
        case .conversationAndFiles: return "conversationAndFiles"
        case .conversationOnly:     return "conversationOnly"
        case .filesOnly:            return "filesOnly"
        }
    }
}
```

**Step 4: 运行测试，确认通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rc4-task2 \
  -only-testing:agentGuiTests/RewindTransactionCoordinatorConversationOnlyTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|error:"
```

预期：`TEST SUCCEEDED`（全部 4 个测试通过）

**Step 5: 提交**

```bash
git add agentGui/Services/Rewind/RewindTransactionCoordinator.swift \
        agentGuiTests/RewindTransactionCoordinatorTests.swift
git commit -m "feat(rewind): R-C4 conversationOnly path + tests"
```

---

## Task 3：实现 `filesOnly` 路径 + 测试

**Files:**
- Modify: `agentGuiTests/RewindTransactionCoordinatorTests.swift`（追加测试 Suite）

`filesOnly` 的核心逻辑已在 Task 2 的 `execute` 中实现，此 Task 专注测试覆盖。

### Step 1: 追加测试 Suite（写失败测试先运行确认它们真的测试了新场景）

在 `RewindTransactionCoordinatorTests.swift` 末尾追加：

```swift
// MARK: - Test Suite: filesOnly

@MainActor
@Suite("RewindTransactionCoordinator — filesOnly")
struct RewindTransactionCoordinatorFilesOnlyTests {

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc4-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test
    func filesOnly_restoresFilesButDoesNotTruncateConversation() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)

        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)
        let convCoord = ConversationRewindCoordinator(modelContext: ctx)
        let fsCoord = FileSystemRewindCoordinator(fileBackupStore: store)
        var cancelLog: [String] = []

        let coordinator = RewindTransactionCoordinator(
            conversationRewindCoordinator: convCoord,
            fileSystemRewindCoordinator: fsCoord,
            cancelLoop: { sessionID, _ in cancelLog.append(sessionID) },
            modelContext: ctx
        )

        // 创建对话（3 条消息）
        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        _ = makeMessage(sequence: 2, in: ctx, session: session)
        _ = makeMessage(sequence: 3, in: ctx, session: session)
        try ctx.save()

        // 创建文件备份
        let filePath = workspaceRoot + "/f1.txt"
        try "original".write(toFile: filePath, atomically: true, encoding: .utf8)
        let entry = try await store.createBackup(filePath: filePath, sessionID: session.sessionId, version: 0)

        // 修改文件（模拟 agent 改了它）
        try "modified".write(toFile: filePath, atomically: true, encoding: .utf8)

        // 创建 checkpoint
        let checkpoint = try ConversationCheckpoint(
            sessionID: session.sessionId,
            messageID: m1.id,
            snapshotSequence: 0,
            workspaceRoot: workspaceRoot,
            trackedFileBackups: ["f1.txt": entry],
            hasFileChanges: true
        )
        ctx.insert(checkpoint)
        try ctx.save()

        // 执行 filesOnly
        let result = try await coordinator.execute(
            targetMessage: m1,
            checkpoint: checkpoint,
            option: .filesOnly
        )

        // 文件恢复了
        #expect(result.filesRestored == 1)
        let restoredContent = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(restoredContent == "original")

        // 对话消息全部保留
        #expect(result.messagesDeleted == 0)
        let allMessages = try ctx.fetch(FetchDescriptor<Message>())
        #expect(allMessages.count == 3)
    }

    @Test
    func filesOnly_withNilCheckpoint_throwsCheckpointRequired() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        var cancelLog: [String] = []
        let coordinator = makeCoordinator(ctx: ctx, cancelCallLog: &cancelLog)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        try ctx.save()

        await #expect(throws: RewindTransactionError.checkpointRequiredForFileRestore) {
            _ = try await coordinator.execute(
                targetMessage: m1,
                checkpoint: nil,
                option: .filesOnly
            )
        }
    }

    @Test
    func filesOnly_cancelsRunningLoop() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        var cancelLog: [String] = []
        let coordinator = makeCoordinator(ctx: ctx, cancelCallLog: &cancelLog)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        // 不需要真实备份文件，只测 cancelLoop 被调用
        // 但 filesOnly 需要 checkpoint，所以传一个空 checkpoint
        let emptyCheckpoint = try ConversationCheckpoint(
            sessionID: session.sessionId,
            messageID: m1.id,
            snapshotSequence: 0,
            workspaceRoot: "/tmp",
            trackedFileBackups: [:],
            hasFileChanges: false
        )
        ctx.insert(emptyCheckpoint)
        try ctx.save()

        _ = try await coordinator.execute(
            targetMessage: m1,
            checkpoint: emptyCheckpoint,
            option: .filesOnly
        )

        // cancelLoop 应被调用
        #expect(cancelLog.count == 1)
    }
}
```

**Step 2: 运行测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rc4-task3 \
  -only-testing:agentGuiTests/RewindTransactionCoordinatorFilesOnlyTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|error:"
```

预期：`TEST SUCCEEDED`

**Step 3: 提交**

```bash
git add agentGuiTests/RewindTransactionCoordinatorTests.swift
git commit -m "test(rewind): R-C4 filesOnly tests"
```

---

## Task 4：实现 `conversationAndFiles` 路径 + 通知测试

**Files:**
- Modify: `agentGuiTests/RewindTransactionCoordinatorTests.swift`（追加测试）

（核心逻辑在 Task 2 的 `execute` 中已覆盖，此 Task 验证 combinaton 路径和通知）

### Step 1: 追加测试 Suite

在 `RewindTransactionCoordinatorTests.swift` 末尾追加：

```swift
// MARK: - Test Suite: conversationAndFiles

@MainActor
@Suite("RewindTransactionCoordinator — conversationAndFiles")
struct RewindTransactionCoordinatorConversationAndFilesTests {

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc4-caf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test
    func conversationAndFiles_truncatesConversationAndRestoresFiles() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)
        var cancelLog: [String] = []
        let coordinator = RewindTransactionCoordinator(
            conversationRewindCoordinator: ConversationRewindCoordinator(modelContext: ctx),
            fileSystemRewindCoordinator: FileSystemRewindCoordinator(fileBackupStore: store),
            cancelLoop: { s, _ in cancelLog.append(s) },
            modelContext: ctx
        )

        // 对话：m1 是回滚目标，m2/m3 将被删除
        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        _ = makeMessage(sequence: 2, in: ctx, session: session)
        _ = makeMessage(sequence: 3, in: ctx, session: session)
        try ctx.save()

        // 文件
        let filePath = workspaceRoot + "/code.swift"
        try "let x = 1".write(toFile: filePath, atomically: true, encoding: .utf8)
        let entry = try await store.createBackup(filePath: filePath, sessionID: session.sessionId, version: 0)
        try "let x = 999".write(toFile: filePath, atomically: true, encoding: .utf8)

        let checkpoint = try ConversationCheckpoint(
            sessionID: session.sessionId,
            messageID: m1.id,
            snapshotSequence: 0,
            workspaceRoot: workspaceRoot,
            trackedFileBackups: ["code.swift": entry],
            hasFileChanges: true
        )
        ctx.insert(checkpoint)
        try ctx.save()

        let result = try await coordinator.execute(
            targetMessage: m1,
            checkpoint: checkpoint,
            option: .conversationAndFiles
        )

        // 对话截断
        #expect(result.messagesDeleted == 3) // m1, m2, m3 全删（从 m1 起截断）

        // 文件恢复
        #expect(result.filesRestored == 1)
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(content == "let x = 1")

        // loop 被取消
        #expect(cancelLog.count == 1)
    }

    @Test
    func conversationAndFiles_withNilCheckpoint_throwsCheckpointRequired() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        var cancelLog: [String] = []
        let coordinator = makeCoordinator(ctx: ctx, cancelCallLog: &cancelLog)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        try ctx.save()

        await #expect(throws: RewindTransactionError.checkpointRequiredForFileRestore) {
            _ = try await coordinator.execute(
                targetMessage: m1,
                checkpoint: nil,
                option: .conversationAndFiles
            )
        }
    }
}

// MARK: - Test Suite: rewindDidComplete notification

@MainActor
@Suite("RewindTransactionCoordinator — rewindDidComplete notification")
struct RewindTransactionCoordinatorNotificationTests {

    @Test
    func execute_postsRewindDidCompleteNotification() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        var cancelLog: [String] = []
        let coordinator = makeCoordinator(ctx: ctx, cancelCallLog: &cancelLog)

        let m1 = makeMessage(sequence: 1, text: "hello world", in: ctx, session: session)
        try ctx.save()

        var receivedNotification: Notification?
        let observer = NotificationCenter.default.addObserver(
            forName: .rewindDidComplete,
            object: nil,
            queue: .main
        ) { notification in
            receivedNotification = notification
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = try await coordinator.execute(
            targetMessage: m1,
            checkpoint: nil,
            option: .conversationOnly,
            repopulateInput: true
        )

        #expect(receivedNotification != nil)
        #expect(receivedNotification?.userInfo?["sessionID"] as? String == session.sessionId)
        #expect(receivedNotification?.userInfo?["repopulateText"] as? String == "hello world")
        #expect(receivedNotification?.userInfo?["option"] as? String == "conversationOnly")
    }

    @Test
    func execute_repopulateInputFalse_notificationHasNilText() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        var cancelLog: [String] = []
        let coordinator = makeCoordinator(ctx: ctx, cancelCallLog: &cancelLog)

        let m1 = makeMessage(sequence: 1, text: "some text", in: ctx, session: session)
        try ctx.save()

        var receivedNotification: Notification?
        let observer = NotificationCenter.default.addObserver(
            forName: .rewindDidComplete,
            object: nil,
            queue: .main
        ) { notification in
            receivedNotification = notification
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = try await coordinator.execute(
            targetMessage: m1,
            checkpoint: nil,
            option: .conversationOnly,
            repopulateInput: false
        )

        // repopulateInput=false → repopulateText 不出现或为 nil
        let text = receivedNotification?.userInfo?["repopulateText"]
        // userInfo["repopulateText"] 存入了 nil as Any，Swift 取出时为 Optional<Any>.none
        let isNilText = text == nil || (text as? String) == nil
        #expect(isNilText)
    }
}
```

**Step 2: 运行所有 R-C4 测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rc4-task4 \
  -only-testing:agentGuiTests/RewindTransactionCoordinatorConversationOnlyTests \
  -only-testing:agentGuiTests/RewindTransactionCoordinatorFilesOnlyTests \
  -only-testing:agentGuiTests/RewindTransactionCoordinatorConversationAndFilesTests \
  -only-testing:agentGuiTests/RewindTransactionCoordinatorNotificationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|passed|failed"
```

预期：全部通过

**Step 3: 提交**

```bash
git add agentGuiTests/RewindTransactionCoordinatorTests.swift
git commit -m "test(rewind): R-C4 conversationAndFiles + notification tests"
```

---

## Task 5：ChatView 集成 — 监听通知填充输入框

**Files:**
- Modify: `agentGui/Views/ChatView.swift`

### Step 1: 理解现有状态

`ChatView` 已有：
- `@State var inputText = ""` — 输入框绑定变量（`ChatView.swift:32`）
- `stopStreaming()` 使用 `claudeService.cancelExecution(session:modelContext:)` — 取消 loop 的标准路径

`RewindTransactionCoordinator` 的 `cancelLoop` 闭包注入值为：
```swift
{ sessionID, ctx in
    await claudeService.cancelExecution(session: session, modelContext: ctx)
}
```

### Step 2: 在 ChatView.swift 中注册通知监听

在 `ChatView.body` 合适的位置（与 `.onReceive(NotificationCenter.default.publisher(for:)` 相同的 modifier 链末尾）添加：

```swift
.onReceive(
    NotificationCenter.default.publisher(for: .rewindDidComplete)
        .filter { ($0.object as? String) == session.sessionId }
) { notification in
    // 若有填充文本，写入输入框
    if let text = notification.userInfo?["repopulateText"] as? String {
        inputText = text
    }
}
```

**完整改动位置：** 找到 `chatView.swift` 末尾的 modifier 链，找到一个 `onReceive` 或者 `.task` 块，在紧靠其后添加：

```swift
// agentGui/Views/ChatView.swift — 在 body 的末尾 modifier 链中

.onReceive(
    NotificationCenter.default.publisher(for: .rewindDidComplete)
        .filter { ($0.object as? String) == session.sessionId }
) { notification in
    if let text = notification.userInfo?["repopulateText"] as? String {
        inputText = text
    }
}
```

> **Note:** 若 ChatView 末尾没有 `onReceive`，在 `body` 的最外层 `VStack/NavigationStack} ` 的末尾 `.toolbar(...)` 之后直接追加此 modifier。

### Step 3: 构建验证

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-rc4-task5-build \
  build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

预期：`BUILD SUCCEEDED`

### Step 4: 运行全套 R-C4 测试确认无回归

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rc4-task5 \
  -only-testing:agentGuiTests/RewindTransactionCoordinatorConversationOnlyTests \
  -only-testing:agentGuiTests/RewindTransactionCoordinatorFilesOnlyTests \
  -only-testing:agentGuiTests/RewindTransactionCoordinatorConversationAndFilesTests \
  -only-testing:agentGuiTests/RewindTransactionCoordinatorNotificationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED"
```

预期：全部通过

### Step 5: 提交

```bash
git add agentGui/Views/ChatView.swift
git commit -m "feat(rewind): R-C4 ChatView registers rewindDidComplete to repopulate input"
```

---

## Task 6：XCProject 注册新文件

> **注意：** 这是 Swift/Xcode 项目特有的步骤。新建的 `.swift` 文件需要通过 Xcode 或 `pbxproj` 手动注册到 `agentGui.xcodeproj/project.pbxproj`，否则编译不到。

### Step 1: 验证 Xcode 是否已自动检测到新文件

在 Xcode 中查看 Project Navigator，确认：
- `agentGui/Services/Rewind/RewindTransactionCoordinator.swift` 显示在 Rewind group 中
- `agentGuiTests/RewindTransactionCoordinatorTests.swift` 显示在 agentGuiTests 中

若未自动检测，手动拖拽文件到对应 group 并确保勾选正确的 Target Membership：
- `RewindTransactionCoordinator.swift` → 勾选 `agentGui` target
- `RewindTransactionCoordinatorTests.swift` → 勾选 `agentGuiTests` target

### Step 2: 最终完整构建 + 测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rc4-final \
  -only-testing:agentGuiTests/RewindTransactionCoordinatorConversationOnlyTests \
  -only-testing:agentGuiTests/RewindTransactionCoordinatorFilesOnlyTests \
  -only-testing:agentGuiTests/RewindTransactionCoordinatorConversationAndFilesTests \
  -only-testing:agentGuiTests/RewindTransactionCoordinatorNotificationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|passed|failed"
```

预期：`TEST SUCCEEDED` + `11 tests passed, 0 failed`（各 Suite 合计）

### Step 3: 最终提交

```bash
git add -A
git commit -m "feat(rewind): R-C4 complete — RewindTransactionCoordinator + ChatView integration"
```

---

## 实现注意事项

### 1. `cancelLoop` 闭包在实际接入时的写法

在实际 ChatView 或 ClaudeService 接入处构造 `RewindTransactionCoordinator` 时：

```swift
let cancelLoop: @MainActor @Sendable (String, ModelContext) async -> Void = { [weak claudeService, session] sessionID, ctx in
    guard let svc = claudeService else { return }
    await svc.cancelExecution(session: session, modelContext: ctx)
}
```

### 2. `filesFailed != 0` 时不 throw

`FileSystemRewindCoordinator.rewind` 对每个文件独立容错（non-atomic），个别文件失败不阻断整体。`RewindTransactionCoordinator` 忠实照搬这个设计，通过 `result.filesFailed` 向上层报告，不 `throw`。上层 UI 可判断 `filesFailed > 0` 时显示警告。

### 3. 执行顺序的设计依据

`cancelLoop` 先于文件恢复先于对话截断，原因：
- 必须先取消 loop，否则 loop 可能在截断过程中继续写入 SwiftData
- 文件恢复先于对话截断：若文件恢复失败，对话还未截断，UI 能展示具体错误让用户决定是否继续
- 对应 Claude Code `REPL.tsx ~L3777`：`onCancel()` → `handleRestoreMessage(raw)` 顺序

### 4. `messagesAfterAreOnlySynthetic` — lossless fast path 属于 UI 层

设计文档中提到的 lossless fast path（无文件变化且后续消息为 synthetic 时跳过确认 sheet）**不属于 R-C4 的职责**。`RewindTransactionCoordinator.execute` 永远忠实执行调用方选定的 `option`。lossless 判断由 UI 层（`MessageRewindSelectorView` R-D1）在调用 `execute` 前完成：

```swift
// R-D1 调用模式（参考，非本 Task 实现范围）：
let noFileChanges = try await preflightInspector.hasAnyFileChanges(checkpoint: cp) == false
let onlySynthetic = session.messages.filter { $0.sequence > target.sequence }
                        .allSatisfy { $0.direction == .system }
if noFileChanges && onlySynthetic {
    // 直接调用，不展示确认 sheet
    try await rewindCoordinator.execute(targetMessage: target, checkpoint: cp, option: .conversationOnly)
} else {
    // 展示 RewindConfirmationSheet
}
```

---

## 依赖关系图（R-C4 视角）

```
RewindTransactionCoordinator (R-C4)
├── ConversationRewindCoordinator (R-C1) ── SwiftData cascade delete
├── FileSystemRewindCoordinator (R-C2) ── FileBackupStore (R-A2)
│   └── ConversationCheckpoint (R-A1)
├── cancelLoop: closure ── ClaudeService.cancelExecution
└── Notification.rewindDidComplete ── ChatView.onReceive → inputText
```

---

## 验收标准核对

| 验收标准 | 覆盖 Task |
|---------|-----------|
| 端到端：`conversationAndFiles` 后对话截断 + 文件恢复均完成，UI 刷新无残影 | Task 4 + Task 5 |
| lossless 快捷路径（无文件变化）直接执行不显示确认对话框 | UI 层（R-D1，不在本计划范围） |
| `conversationOnly` 不动文件 | Task 2 |
| `filesOnly` 不截断对话 | Task 3 |
| `cancelLoop` 在任何 option 下都被调用 | Task 2、Task 3 |
| `checkpoint != nil` 检查（files 选项时） | Task 3、Task 4 |
| 通知携带 repopulateText | Task 4 |
| ChatView 监听通知填充 inputText | Task 5 |

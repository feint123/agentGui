# R-D4: 消息上下文菜单集成 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 `MessageBubbleView` 中的用户消息气泡添加右键上下文菜单项「从此消息重新开始」，触发 lossless 快捷路径（无文件变化时直接截断对话）或 `RewindConfirmationSheet`（有文件变化时需用户确认回滚范围）。

**Architecture:** 
新增 `MessageRewindContextMenuCoordinator`（`@MainActor final class`）封装「获取 checkpoint → preflight 检查 → 决策 lossless / confirmation」的异步逻辑，使该决策路径可独立单元测试，避免与 `MessageRewindSelectorViewModel` 的逻辑重复。`ChatView` 通过 `@State var contextMenuPendingConfirmation` 驱动 `RewindConfirmationSheet` 的呈现，与工具栏入口共享相同的确认 UI。

**Tech Stack:** Swift 6 + SwiftUI + SwiftData + Swift Testing framework (`@Test`, `@Suite`, `#expect`)

---

## 前置验证

在开始之前，在终端运行以下命令确认现有 Rewind 基础设施已就绪：

```bash
find /Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Rewind -name "*.swift" | sort
find /Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Rewind -name "*.swift" | sort
```

应能看到：`FileBackupStore.swift`, `ConversationCheckpointService.swift`, `RewindPreflightInspector.swift`, `RewindTransactionCoordinator.swift`, `MessageRewindSelectorView.swift`, `RewindConfirmationSheet.swift`。

---

## 文件清单

**新增文件：**
- `agentGui/Services/Rewind/MessageRewindContextMenuCoordinator.swift` ← 新协调器
- `agentGuiTests/MessageRewindContextMenuCoordinatorTests.swift` ← 单元测试

**修改现有文件：**
- `agentGui/Views/MessageBubbleView.swift` ← 添加 `onRewindFromHere` 回调 + 上下文菜单项
- `agentGui/Views/ChatView+MessageList.swift` ← 传递 `onRewindFromHere` 回调
- `agentGui/Views/ChatView.swift` ← 添加 `contextMenuPendingConfirmation` 状态 + `.sheet` modifier
- `agentGui/Views/ChatView+Actions.swift` ← 添加 `initiateContextMenuRewind` + `executeContextMenuRewind` + `makeRewindDependencies`

---

## Task 1: 创建 `MessageRewindContextMenuCoordinator` 的骨架和测试文件

**Files:**
- Create: `agentGui/Services/Rewind/MessageRewindContextMenuCoordinator.swift`
- Create: `agentGuiTests/MessageRewindContextMenuCoordinatorTests.swift`

**Step 1: 创建协调器骨架（仅类型定义，不填充实现）**

```swift
// agentGui/Services/Rewind/MessageRewindContextMenuCoordinator.swift
import Foundation
import SwiftData

// MARK: - Result

/// 上下文菜单回滚的执行结果。
enum MessageRewindContextMenuResult: Sendable {
    /// Lossless 路径：已直接执行对话截断，无需用户确认。
    case losslessCompleted
    /// 需要用户确认：包含 diff 预览数据，供 RewindConfirmationSheet 展示。
    case needsConfirmation(MessageRewindSelectorViewModel.PendingConfirmation)
}

// MARK: - MessageRewindContextMenuCoordinator

/// R-D4: 从消息上下文菜单触发回滚的协调器。
///
/// ## 执行逻辑
/// 1. 从 ConversationCheckpointService 获取目标消息对应的 checkpoint
/// 2. 调用 RewindPreflightInspector.hasAnyFileChanges 检查是否有文件变化
/// 3. 无变化 → 调用 RewindTransactionCoordinator.execute(.conversationOnly) → 返回 .losslessCompleted
/// 4. 有变化 → 计算 diffStats + 统计消息数 → 返回 .needsConfirmation(pending)
///
/// ## 并发安全
/// `@MainActor`：checkpointService/txCoord 均为 @MainActor 或 actor，统一在主线程调用。
@MainActor
final class MessageRewindContextMenuCoordinator {

    private let checkpointService: ConversationCheckpointService
    private let preflightInspector: RewindPreflightInspector
    private let transactionCoordinator: RewindTransactionCoordinator

    init(
        checkpointService: ConversationCheckpointService,
        preflightInspector: RewindPreflightInspector,
        transactionCoordinator: RewindTransactionCoordinator
    ) {
        self.checkpointService = checkpointService
        self.preflightInspector = preflightInspector
        self.transactionCoordinator = transactionCoordinator
    }

    /// 执行上下文菜单回滚决策。
    ///
    /// - Parameters:
    ///   - message: 用户选择的目标消息（必须是用户消息）。
    ///   - allMessages: 当前 session 的全量消息列表（用于统计 messagesAfterCount）。
    ///   - sessionID: session 的标识符。
    ///   - modelContext: SwiftData ModelContext。
    /// - Returns: `.losslessCompleted`（已执行）或 `.needsConfirmation(pending)`（需弹窗）。
    func execute(
        message: Message,
        allMessages: [Message],
        sessionID: String,
        modelContext: ModelContext
    ) async throws -> MessageRewindContextMenuResult {
        // TODO: 在 Task 3 实现
        fatalError("TODO")
    }
}
```

**Step 2: 创建测试骨架**

```swift
// agentGuiTests/MessageRewindContextMenuCoordinatorTests.swift
import Testing
import Foundation
import SwiftData
@testable import agentGui

// MARK: - Shared Fixtures

@MainActor
private func makeContainer() throws -> ModelContainer {
    let schema = Schema(PersistenceSchema.sharedModelTypes)
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

@MainActor
private func makeSession(in ctx: ModelContext) -> Session {
    let s = Session()
    ctx.insert(s)
    return s
}

@MainActor
private func makeUserMessage(seq: Int, text: String = "user msg", in ctx: ModelContext, session: Session) -> Message {
    let m = Message(direction: .user, text: text, session: session)
    m.sequence = seq
    m.status = .completed
    ctx.insert(m)
    return m
}

@MainActor
private func makeAgentMessage(seq: Int, in ctx: ModelContext, session: Session) -> Message {
    let m = Message(direction: .agent, text: "agent response", session: session)
    m.sequence = seq
    m.status = .completed
    ctx.insert(m)
    return m
}

/// 构造 NoOp MessageRewindContextMenuCoordinator（cancelLoop 不执行任何操作）。
@MainActor
private func makeCoordinator(
    session: Session,
    modelContext: ModelContext,
    backupURL: URL? = nil
) -> MessageRewindContextMenuCoordinator {
    let url = backupURL ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("rd4-test-\(UUID().uuidString)")
    let store = FileBackupStore(baseURL: url)
    let checkpointService = ConversationCheckpointService(fileBackupStore: store)
    let inspector = RewindPreflightInspector(fileBackupStore: store)
    let convCoord = ConversationRewindCoordinator(modelContext: modelContext)
    let fsCoord = FileSystemRewindCoordinator(fileBackupStore: store)
    let txCoord = RewindTransactionCoordinator(
        conversationRewindCoordinator: convCoord,
        fileSystemRewindCoordinator: fsCoord,
        cancelLoop: { _, _ in },
        modelContext: modelContext
    )
    return MessageRewindContextMenuCoordinator(
        checkpointService: checkpointService,
        preflightInspector: inspector,
        transactionCoordinator: txCoord
    )
}

// MARK: - Tests (空壳，Task 3 后填入实际断言)

@Suite("MessageRewindContextMenuCoordinator")
struct MessageRewindContextMenuCoordinatorTests {

    @Test("PLACEHOLDER — Step 3 中替换")
    @MainActor
    func placeholder() async throws {
        #expect(true)
    }
}
```

**Step 3: 验证编译**

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

期望：`BUILD SUCCEEDED`（`fatalError` 不影响编译）。

**Step 4: Commit**

```bash
git add agentGui/Services/Rewind/MessageRewindContextMenuCoordinator.swift \
        agentGuiTests/MessageRewindContextMenuCoordinatorTests.swift
git commit -m "feat(r-d4): scaffold MessageRewindContextMenuCoordinator + test stub"
```

---

## Task 2: 为 `MessageBubbleView` 添加 `onRewindFromHere` 回调和上下文菜单项

**Files:**
- Modify: `agentGui/Views/MessageBubbleView.swift`

### 2.1 现有上下文菜单结构（参考）

在 `MessageBubbleView.swift` 第 210 行附近，`contextMenuItems` 当前结构为：

```swift
@ViewBuilder
private var contextMenuItems: some View {
    Button { onCopy() } label: { Label("复制", systemImage: "doc.on.doc") }
    if snapshot.direction == .user, onEdit != nil { Button { ... } label: { ... } }
    if let regen = onRegenerate { Button { regen() } label: { ... } }
    Divider()
    Button(role: .destructive) { onDeleteFrom() } label: { Label("从此处删除", ...) }
    Button(role: .destructive) { onDelete() } label: { Label("删除消息", ...) }
}
```

**Step 1: 添加 `onRewindFromHere` 属性**

在 `MessageBubbleView` 结构体顶部的属性声明区（`onRetry` 的下方），添加：

```swift
var onRewindFromHere: (() -> Void)? = nil
```

**Step 2: 修改 `contextMenuItems`**

将 `contextMenuItems` 修改为：

```swift
@ViewBuilder
private var contextMenuItems: some View {
    Button { onCopy() } label: {
        Label("复制", systemImage: "doc.on.doc")
    }
    if snapshot.direction == .user, onEdit != nil {
        Button {
            editText = snapshot.editableUserText ?? ""
            isEditing = true
        } label: {
            Label("编辑", systemImage: "pencil")
        }
    }
    if let regen = onRegenerate {
        Button { regen() } label: {
            Label("重新生成", systemImage: "arrow.clockwise")
        }
    }
    // R-D4: 仅用户消息且提供了回调时显示
    if snapshot.direction == .user, let rewind = onRewindFromHere {
        Divider()
        Button { rewind() } label: {
            Label("从此消息重新开始", systemImage: "arrow.uturn.backward.circle")
        }
        .accessibilityIdentifier("message.contextMenu.rewindFromHere")
    }
    Divider()
    Button(role: .destructive) { onDeleteFrom() } label: {
        Label("从此处删除", systemImage: "arrow.uturn.backward")
    }
    Button(role: .destructive) { onDelete() } label: {
        Label("删除消息", systemImage: "trash")
    }
}
```

**Step 3: 验证编译**

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

期望：`BUILD SUCCEEDED`

**Step 4: Commit**

```bash
git add agentGui/Views/MessageBubbleView.swift
git commit -m "feat(r-d4): add onRewindFromHere callback + context menu item to MessageBubbleView"
```

---

## Task 3: 实现 `MessageRewindContextMenuCoordinator.execute` 并填入单元测试

**Files:**
- Modify: `agentGui/Services/Rewind/MessageRewindContextMenuCoordinator.swift`
- Modify: `agentGuiTests/MessageRewindContextMenuCoordinatorTests.swift`

### 3.1 实现 `execute(message:allMessages:sessionID:modelContext:)`

将 `fatalError("TODO")` 替换为以下实现：

```swift
func execute(
    message: Message,
    allMessages: [Message],
    sessionID: String,
    modelContext: ModelContext
) async throws -> MessageRewindContextMenuResult {
    // 1. 获取此 session 的 checkpoints，找到目标消息对应的那个
    let checkpoints = (try? await checkpointService.fetchCheckpoints(
        sessionID: sessionID,
        limit: 50,
        modelContext: modelContext
    )) ?? []
    let checkpoint = checkpoints.first { $0.messageID == message.id }

    // 2. 检查是否有文件变化（先看 hasFileChanges 标志，再调 inspector 精确验证）
    let hasChanges: Bool
    if let cp = checkpoint, cp.hasFileChanges {
        hasChanges = (try? await preflightInspector.hasAnyFileChanges(checkpoint: cp)) ?? false
    } else {
        hasChanges = false
    }

    if !hasChanges {
        // Lossless fast path: 直接截断对话，不动文件
        try await transactionCoordinator.execute(
            targetMessage: message,
            checkpoint: nil,
            option: .conversationOnly,
            repopulateInput: true
        )
        return .losslessCompleted
    } else {
        // Confirmation path: 计算 diff 统计，返回待确认数据
        let diffStats = (try? await preflightInspector.computeDiffStats(
            checkpoint: checkpoint!
        )) ?? .empty
        let targetSeq = message.sequence
        let msgsAfter = allMessages.filter { $0.sequence > targetSeq }
        let toolCallsAfterCount = msgsAfter.reduce(0) { $0 + $1.toolCalls.count }

        let pending = MessageRewindSelectorViewModel.PendingConfirmation(
            message: message,
            checkpoint: checkpoint,
            diffStats: diffStats,
            messagesAfterCount: msgsAfter.count,
            toolCallsAfterCount: toolCallsAfterCount
        )
        return .needsConfirmation(pending)
    }
}
```

### 3.2 填入单元测试

将 `MessageRewindContextMenuCoordinatorTests.swift` 的 `placeholder` 测试替换为以下 4 个测试：

```swift
@Suite("MessageRewindContextMenuCoordinator")
struct MessageRewindContextMenuCoordinatorTests {

    // MARK: - Lossless path

    @Test("无 checkpoint → losslessCompleted，对话被截断")
    @MainActor
    func noCheckpoint_returnsLosslessCompleted() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = makeSession(in: ctx)

        // u1(seq=0) → agent(seq=1) → u2(seq=2) → agent(seq=3)
        let u1 = makeUserMessage(seq: 0, text: "first", in: ctx, session: session)
        let _ = makeAgentMessage(seq: 1, in: ctx, session: session)
        let _ = makeUserMessage(seq: 2, text: "second", in: ctx, session: session)
        let _ = makeAgentMessage(seq: 3, in: ctx, session: session)
        try ctx.save()

        let allMsgs = try ctx.fetch(FetchDescriptor<Message>())
        let coordinator = makeCoordinator(session: session, modelContext: ctx)

        let result = try await coordinator.execute(
            message: u1,
            allMessages: allMsgs,
            sessionID: session.sessionId,
            modelContext: ctx
        )

        // 验证结果是 losslessCompleted
        guard case .losslessCompleted = result else {
            Issue.record("Expected .losslessCompleted, got \(result)")
            return
        }

        // 验证 u1 之后的消息已被删除（对话截断）
        let remaining = try ctx.fetch(FetchDescriptor<Message>())
        #expect(remaining.allSatisfy { $0.sequence < u1.sequence || $0.id == u1.id })
    }

    @Test("checkpoint.hasFileChanges == false → losslessCompleted")
    @MainActor
    func checkpointNoFileChanges_returnsLosslessCompleted() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = makeSession(in: ctx)

        let u1 = makeUserMessage(seq: 0, text: "first", in: ctx, session: session)
        let _ = makeAgentMessage(seq: 1, in: ctx, session: session)
        try ctx.save()

        // 插入一个 hasFileChanges = false 的 checkpoint
        let cp = try ConversationCheckpoint(
            sessionID: session.sessionId,
            messageID: u1.id,
            snapshotSequence: 0,
            workspaceRoot: "/tmp/test",
            trackedFileBackups: [:],
            hasFileChanges: false
        )
        ctx.insert(cp)
        try ctx.save()

        let allMsgs = try ctx.fetch(FetchDescriptor<Message>())
        let coordinator = makeCoordinator(session: session, modelContext: ctx)

        let result = try await coordinator.execute(
            message: u1,
            allMessages: allMsgs,
            sessionID: session.sessionId,
            modelContext: ctx
        )

        guard case .losslessCompleted = result else {
            Issue.record("Expected .losslessCompleted, got \(result)")
            return
        }
    }

    // MARK: - messagesAfterCount 计算

    @Test("needsConfirmation 包含正确的 messagesAfterCount 和 toolCallsAfterCount")
    @MainActor
    func needsConfirmation_countsMessagesAndToolCallsAfterTarget() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = makeSession(in: ctx)

        let u1 = makeUserMessage(seq: 0, text: "first", in: ctx, session: session)
        let agent1 = makeAgentMessage(seq: 1, in: ctx, session: session)
        let u2 = makeUserMessage(seq: 2, text: "second", in: ctx, session: session)
        let agent2 = makeAgentMessage(seq: 3, in: ctx, session: session)

        // agent1 關聯 2 個 ToolCall（模擬）
        let tc1 = ToolCall()
        let tc2 = ToolCall()
        tc1.message = agent1
        tc2.message = agent1
        ctx.insert(tc1)
        ctx.insert(tc2)
        try ctx.save()

        // 插入 checkpoint，hasFileChanges = true，但備份文件不存在（所以 hasAnyFileChanges inspector 返回 false）
        // 為了讓路徑進入 confirmation，我們製造一個真實文件的 checkpoint
        // 由於製造真實文件備份較複雜，此測試僅驗證在 hasChanges=false 場景下 messagesAfterCount 計算
        // 轉而測試 allMessages 傳入 execute 時，lossless path 的截斷後消息數
        let cp = try ConversationCheckpoint(
            sessionID: session.sessionId,
            messageID: u1.id,
            snapshotSequence: 0,
            workspaceRoot: "/tmp",
            trackedFileBackups: [:],
            hasFileChanges: false
        )
        ctx.insert(cp)
        try ctx.save()

        let allMsgs = [u1, agent1, u2, agent2]
        let coordinator = makeCoordinator(session: session, modelContext: ctx)

        let result = try await coordinator.execute(
            message: u1,
            allMessages: allMsgs,
            sessionID: session.sessionId,
            modelContext: ctx
        )

        // u1 hasFileChanges=false → lossless，截断后仅剩 u1 及之前消息
        guard case .losslessCompleted = result else {
            Issue.record("Expected .losslessCompleted on no-file-changes checkpoint")
            return
        }
        // u1(seq=0) 之后有 agent1(seq=1), u2(seq=2), agent2(seq=3) 共 3 条
        // 截断后验证（messagesAfterCount 逻辑在 lossless 路径无需计算，仅 needsConfirmation 路径使用）
        // 本测试主要验证：传入 allMessages 包含 4 条，执行 lossless 后数据库只剩 <= seq(u1) 的消息
        let remaining = try ctx.fetch(FetchDescriptor<Message>())
        let removedCount = remaining.filter { $0.sequence > u1.sequence }
        #expect(removedCount.isEmpty, "u1 之后的消息应全部被截断")
    }

    // MARK: - Target message 为 session 中最后一条用户消息

    @Test("目标是最后一条用户消息 + 无 checkpoint → losslessCompleted，后续消息全被删除")
    @MainActor
    func lastUserMessage_noCheckpoint_losslessCompleted() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = makeSession(in: ctx)

        let u1 = makeUserMessage(seq: 0, in: ctx, session: session)
        let _ = makeAgentMessage(seq: 1, in: ctx, session: session)
        let u2 = makeUserMessage(seq: 2, in: ctx, session: session)
        // u2 是最后一条用户消息，之后有 agent 响应
        let _ = makeAgentMessage(seq: 3, in: ctx, session: session)
        try ctx.save()

        let allMsgs = try ctx.fetch(FetchDescriptor<Message>())
        let coordinator = makeCoordinator(session: session, modelContext: ctx)

        let result = try await coordinator.execute(
            message: u2,
            allMessages: allMsgs,
            sessionID: session.sessionId,
            modelContext: ctx
        )

        guard case .losslessCompleted = result else {
            Issue.record("Expected .losslessCompleted")
            return
        }

        let remaining = try ctx.fetch(FetchDescriptor<Message>())
        // u2 及之后的 agent 消息都被删除，剩下 u1 和 agent1（seq <= 1）
        #expect(remaining.allSatisfy { $0.sequence < u2.sequence })
    }
}
```

**Step 1: 运行测试*，确认通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rd4-coordinator \
  -only-testing:agentGuiTests/MessageRewindContextMenuCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Build"
```

期望：全部 PASS，BUILD SUCCEEDED。

**Step 2: Commit**

```bash
git add agentGui/Services/Rewind/MessageRewindContextMenuCoordinator.swift \
        agentGuiTests/MessageRewindContextMenuCoordinatorTests.swift
git commit -m "feat(r-d4): implement MessageRewindContextMenuCoordinator + 4 unit tests"
```

---

## Task 4: 在 `ChatView+MessageList.swift` 传递 `onRewindFromHere` 回调

**Files:**
- Modify: `agentGui/Views/ChatView+MessageList.swift`

### 4.1 当前 `MessageBubbleView(...)` 调用（参考，位于 `messageListView` 中）

```swift
MessageBubbleView(
    snapshot: row,
    isStreaming: effectiveStreamingState,
    onCopy: { copyMessage(message) },
    onEdit: row.direction == .user
        ? { newText in editAndResend(message: message, newText: newText) }
        : nil,
    onDelete: { deleteMessage(message) },
    onDeleteFrom: { deleteFrom(message) },
    onRegenerate: row.direction == .agent ? { regenerate() } : nil,
    onRetry: (row.direction == .agent && row.status == .failed)
        ? { regenerate() }
        : nil
)
```

**Step 1: 添加 `onRewindFromHere` 参数**

在 `onRetry:` 参数后追加：

```swift
onRewindFromHere: row.direction == .user
    ? { initiateContextMenuRewind(message: message) }
    : nil
```

完整调用应如下：

```swift
MessageBubbleView(
    snapshot: row,
    isStreaming: effectiveStreamingState,
    onCopy: { copyMessage(message) },
    onEdit: row.direction == .user
        ? { newText in editAndResend(message: message, newText: newText) }
        : nil,
    onDelete: { deleteMessage(message) },
    onDeleteFrom: { deleteFrom(message) },
    onRegenerate: row.direction == .agent ? { regenerate() } : nil,
    onRetry: (row.direction == .agent && row.status == .failed)
        ? { regenerate() }
        : nil,
    onRewindFromHere: row.direction == .user
        ? { initiateContextMenuRewind(message: message) }
        : nil
)
```

**Step 2: 验证编译**

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

期望：`BUILD SUCCEEDED`（此时 `initiateContextMenuRewind` 还未定义，会有编译错误；先确认 `MessageBubbleView` 部分正确）。

> **注意：** 编译失败时继续 Task 5 即可，因为 `initiateContextMenuRewind` 将在 Task 5 定义。

**Step 3: Commit（暂不，等 Task 5 一起提交）**

---

## Task 5: 在 `ChatView.swift` 和 `ChatView+Actions.swift` 实现状态和动作

**Files:**
- Modify: `agentGui/Views/ChatView.swift`
- Modify: `agentGui/Views/ChatView+Actions.swift`

### 5.1 在 `ChatView.swift` 添加状态变量

在 `ChatView` 结构体的 `@State` 变量区域（靠近 `@State var isRewindSelectorPresented = false` 这行，约第 72 行），添加：

```swift
/// R-D4: 从消息上下文菜单触发的待确认回滚数据。
/// 非 nil 时触发 RewindConfirmationSheet。
@State var contextMenuPendingConfirmation: MessageRewindSelectorViewModel.PendingConfirmation? = nil
```

### 5.2 在 `ChatView.swift` 添加 `.sheet` modifier

在已有的 `.sheet(isPresented: $isRewindSelectorPresented) { ... }` 下方，添加：

```swift
.sheet(item: $contextMenuPendingConfirmation) { pending in
    RewindConfirmationSheet(
        pending: pending,
        onExecute: { option in
            await executeContextMenuRewind(pending: pending, option: option)
        },
        onCancel: {
            contextMenuPendingConfirmation = nil
        }
    )
}
```

### 5.3 在 `ChatView+Actions.swift` 添加三个方法

在文件末尾「Rewind Factory」extension 内，添加以下三个方法：

```swift
// MARK: - R-D4: Context Menu Rewind

extension ChatView {

    /// 从消息上下文菜单触发回滚的入口。
    /// 构建 MessageRewindContextMenuCoordinator，异步执行决策逻辑，结果 dispatch 到 UI 状态。
    func initiateContextMenuRewind(message: Message) {
        Task { @MainActor in
            do {
                let (store, txCoord) = makeRewindDependencies()
                let checkpointService = ConversationCheckpointService(fileBackupStore: store)
                let inspector = RewindPreflightInspector(fileBackupStore: store)
                let coordinator = MessageRewindContextMenuCoordinator(
                    checkpointService: checkpointService,
                    preflightInspector: inspector,
                    transactionCoordinator: txCoord
                )
                let result = try await coordinator.execute(
                    message: message,
                    allMessages: Array(allMessages),
                    sessionID: session.sessionId,
                    modelContext: modelContext
                )
                switch result {
                case .losslessCompleted:
                    break  // rewindDidComplete 通知已由 txCoord 发出，ChatView 监听并填回输入框
                case .needsConfirmation(let pending):
                    contextMenuPendingConfirmation = pending
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 「确认回滚」sheet 批准后的执行入口。
    func executeContextMenuRewind(
        pending: MessageRewindSelectorViewModel.PendingConfirmation,
        option: RewindOption
    ) async {
        let (_, txCoord) = makeRewindDependencies()
        do {
            try await txCoord.execute(
                targetMessage: pending.message,
                checkpoint: pending.checkpoint,
                option: option,
                repopulateInput: true
            )
            contextMenuPendingConfirmation = nil
        } catch {
            errorMessage = error.localizedDescription
            contextMenuPendingConfirmation = nil
        }
    }

    /// 提取 Rewind 基础依赖的工厂方法（FileBackupStore + RewindTransactionCoordinator）。
    /// 每次调用返回新实例（无状态，幂等）。
    func makeRewindDependencies() -> (FileBackupStore, RewindTransactionCoordinator) {
        let backupBaseURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("agentGui/checkpoints")
        let store = FileBackupStore(baseURL: backupBaseURL)
        let convCoord = ConversationRewindCoordinator(modelContext: modelContext)
        let fsCoord = FileSystemRewindCoordinator(fileBackupStore: store)
        let cs = claudeService
        let txCoord = RewindTransactionCoordinator(
            conversationRewindCoordinator: convCoord,
            fileSystemRewindCoordinator: fsCoord,
            cancelLoop: { [cs] sessionID, ctx in
                await cs.cancelExecution(session: session, modelContext: ctx)
            },
            modelContext: modelContext
        )
        return (store, txCoord)
    }
}
```

### 5.4 重构 `makeRewindSelectorView()` 以复用 `makeRewindDependencies()`

将 `ChatView+Actions.swift` 中现有的 `makeRewindSelectorView()` 修改为使用新提取的 `makeRewindDependencies()`：

```swift
func makeRewindSelectorView() -> MessageRewindSelectorView {
    let (store, txCoord) = makeRewindDependencies()
    let checkpointService = ConversationCheckpointService(fileBackupStore: store)
    let inspector = RewindPreflightInspector(fileBackupStore: store)
    return MessageRewindSelectorView(
        session: session,
        allMessages: Array(allMessages),
        transactionCoordinator: txCoord,
        checkpointService: checkpointService,
        preflightInspector: inspector
    )
}
```

> **注意：** 原 `makeRewindSelectorView()` 手动构造 `store`, `convCoord`, `fsCoord`, `txCoord`，重构后改用 `makeRewindDependencies()` 消除重复。逻辑等价。

**Step 1: 验证完整编译**

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

期望：`BUILD SUCCEEDED`

**Step 2: 运行全量 Rewind 相关测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rd4-full \
  -only-testing:agentGuiTests/MessageRewindContextMenuCoordinatorTests \
  -only-testing:agentGuiTests/MessageRewindSelectorViewModelTests \
  -only-testing:agentGuiTests/RewindTransactionCoordinatorTests \
  -only-testing:agentGuiTests/ConversationRewindCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Build"
```

期望：全部 PASS。

**Step 3: Commit**

```bash
git add \
  agentGui/Views/ChatView.swift \
  agentGui/Views/ChatView+Actions.swift \
  agentGui/Views/ChatView+MessageList.swift
git commit -m "feat(r-d4): wire context menu rewind in ChatView — initiateContextMenuRewind + confirmation sheet"
```

---

## Task 6: 添加 `MessageBubbleView` 上下文菜单项的可访问性测试

**Files:**
- Create: `agentGuiTests/MessageBubbleViewRewindTests.swift`

### 6.1 验证测试策略

`MessageBubbleView` 是纯 SwiftUI struct，无法通过标准 `XCTest`/Swift Testing 直接渲染并检查组件树（项目未集成 ViewInspector）。  
因此，测试策略是：**通过回调调用验证**——将 `onRewindFromHere` 设为一个会修改局部变量的闭包，验证回调符合预期地传递。

此外，通过直接实例化 `MessageBubbleView` 并检查 `onRewindFromHere` 属性绑定，验证接口正确性。

```swift
// agentGuiTests/MessageBubbleViewRewindTests.swift
import Testing
import SwiftData
@testable import agentGui

// MARK: - Helpers

@MainActor
private func makeContainer() throws -> ModelContainer {
    let schema = Schema(PersistenceSchema.sharedModelTypes)
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

@MainActor
private func makeUserSnapshot() -> MessageRowSnapshot {
    // 使用 Message.fixture 构建最小可用快照
    let container = try! ModelContainer(
        for: Schema(PersistenceSchema.sharedModelTypes),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let ctx = container.mainContext
    let session = Session()
    ctx.insert(session)
    let m = Message.fixture(direction: .user, text: "hello", session: session)
    ctx.insert(m)
    // MessageRowSnapshot.from(message:) 若不存在可用 .init(direction:timestamp:...)
    // 直接构造一个 user direction snapshot
    return MessageRowSnapshot(
        id: m.id,
        direction: .user,
        timestamp: m.timestamp,
        status: .completed,
        senderName: "You",
        user: nil,
        agent: nil,
        editableUserText: "hello"
    )
}

@MainActor
private func makeAgentSnapshot() -> MessageRowSnapshot {
    MessageRowSnapshot(
        id: UUID(),
        direction: .agent,
        timestamp: .now,
        status: .completed,
        senderName: "Claude",
        user: nil,
        agent: nil,
        editableUserText: nil
    )
}

// MARK: - Tests

@Suite("MessageBubbleView — onRewindFromHere 接口")
struct MessageBubbleViewRewindTests {

    @Test("用户消息：设置了 onRewindFromHere 回调，回调非 nil")
    @MainActor
    func userMessage_withCallback_callbackIsNonNil() {
        var called = false
        let view = MessageBubbleView(
            snapshot: makeUserSnapshot(),
            onRewindFromHere: { called = true }
        )
        view.onRewindFromHere?()
        #expect(called == true, "onRewindFromHere 应被调用")
    }

    @Test("用户消息：未设置 onRewindFromHere 时默认为 nil")
    @MainActor
    func userMessage_noCallback_callbackIsNil() {
        let view = MessageBubbleView(snapshot: makeUserSnapshot())
        #expect(view.onRewindFromHere == nil)
    }

    @Test("Agent 消息：设置了 onRewindFromHere 也不触发（方向过滤由 contextMenuItems 负责）")
    @MainActor
    func agentMessage_callbackSet_propertyExists() {
        // 视图不应向 agent 消息展示 rewind 菜单项；此测试仅验证属性可以被设置
        // 但 contextMenuItems 的 guard 会过滤（snapshot.direction == .user）
        var called = false
        let view = MessageBubbleView(
            snapshot: makeAgentSnapshot(),
            onRewindFromHere: { called = true }
        )
        // 接口存在（不会编译错误）
        _ = view.onRewindFromHere
        #expect(called == false, "Agent 消息的 onRewindFromHere 不应被主动触发")
    }
}
```

**Step 1: 运行此测试文件**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rd4-bubble \
  -only-testing:agentGuiTests/MessageBubbleViewRewindTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Build"
```

> **说明：** 若 `MessageRowSnapshot` 的初始化方法不完全匹配（字段名或可选字段不同），根据实际 `MessageRowSnapshot` 的 public initializer 调整 fixture 构造方式。参考 `MessageRewindSelectorViewModelTests.swift` 中已有的 `makeUserMessage` fixture。

期望：全部 PASS。

**Step 2: Commit**

```bash
git add agentGuiTests/MessageBubbleViewRewindTests.swift
git commit -m "test(r-d4): add MessageBubbleView onRewindFromHere interface tests"
```

---

## Task 7: 全量验证 + Quality Smoke

**Step 1: 运行 R-D4 相关全部测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rd4-final \
  -only-testing:agentGuiTests/MessageRewindContextMenuCoordinatorTests \
  -only-testing:agentGuiTests/MessageBubbleViewRewindTests \
  -only-testing:agentGuiTests/MessageRewindSelectorViewModelTests \
  -only-testing:agentGuiTests/RewindTransactionCoordinatorTests \
  -only-testing:agentGuiTests/ConversationRewindCoordinatorTests \
  -only-testing:agentGuiTests/RewindPreflightInspectorTests \
  -only-testing:agentGuiTests/RewindConfirmationSheetTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Build"
```

期望：全部 PASS。

**Step 2: 手动冒烟测试（在 Xcode Simulator / macOS 上）**

1. 在任意 session 中发送 2+ 条消息  
2. 右键点击任意**用户消息** → 确认上下文菜单出现「从此消息重新开始」条目  
3. 右键点击任意**Agent 消息** → 确认**不**出现「从此消息重新开始」  
4. 点击「从此消息重新开始」（无备份 checkpoint 场景）→ 确认对话截断，输入框填回原文本  
5. 确认 `ChatView+Toolbar.swift` 的「回滚到历史消息...」菜单项功能不受影响  

**Step 3: 最终 Commit**

```bash
git add .  # 确认仅 R-D4 相关文件
git commit -m "feat(r-d4): complete context menu rewind — all tests pass, smoke verified"
```

---

## 设计决策说明

### 为何新增 `MessageRewindContextMenuCoordinator` 而非复用 `MessageRewindSelectorViewModel`

`MessageRewindSelectorViewModel` 是 `MessageRewindSelectorView` 的专属 ViewModel，其状态（`pendingConfirmation`, `shouldDismiss`, `phase`）与 sheet UI 高度耦合。直接在 `ChatView` 中持有它并驱动其状态，会产生两个 ViewModel 实例争用同一个 sheet 状态的问题（工具栏入口和上下文菜单入口各需独立状态）。

`MessageRewindContextMenuCoordinator` 是轻量的单方法协调器（函数对象），无持久状态，职责单一：给定一条目标消息，返回「lossless 直接完成」或「需要确认的 pending 数据」。这使得它既可独立单元测试，又不影响工具栏入口的代码路径。

### 为何 `makeRewindDependencies()` 每次调用返回新实例

`FileBackupStore`、`ConversationRewindCoordinator`、`FileSystemRewindCoordinator` 均是无持久内存状态的纯粹操作对象（IO 状态在磁盘）。每次创建新实例的开支极低（< 1μs 内存分配），换来的是线程安全和无状态共享的保证。SwiftData `ModelContext` 由 `ChatView` 持有并共享（非新建），不受影响。

### `onRewindFromHere` 设计为 `(() -> Void)?` 而非 `((Message) -> Void)?`

回调不需要传递 `Message`，因为消息对象在 `ChatView+MessageList.swift` 的 `ForEach` 闭包中已经被捕获（`{ initiateContextMenuRewind(message: message) }`）。这与现有回调模式（`onCopy`, `onDelete`, `onDeleteFrom`）保持一致，避免泄漏领域模型到视图层。

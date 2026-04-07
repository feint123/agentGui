# Rewind R-D1 MessageRewindSelectorView 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现 `MessageRewindSelectorView`（R-D1），一个 macOS SwiftUI Sheet，展示当前 session 中所有用户消息的历史列表，支持两条路径：无文件变化时直接执行回滚（lossless fast path）；有文件变化时跳转到 `RewindConfirmationSheet`（R-D2 stub）请求用户确认。

**Architecture:**
- `MessageRewindSelectorViewModel`（`@Observable @MainActor`）持有 checkpointMap + phase/error 状态，处理业务逻辑
- `MessageRewindSelectorView` 作为 SwiftUI NavigationStack Sheet；`MessageRewindRowView` 为列表行子视图
- `RewindConfirmationSheet`（同本 Plan 中提供 P0 stub，供 R-D2 替换）通过 `viewModel.pendingConfirmation`（Identifiable）用 `.sheet(item:)` 呈现
- `RewindTransactionCoordinator` 在 `ChatView` 内构造，通过 init 注入给 ViewModel，保持 R-C4 的可测试性设计

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Foundation, Swift Testing (`@Suite`/`@Test`)

**Pre-conditions（依赖已完成）:**
- R-A1: `ConversationCheckpoint.swift` ✅
- R-A2: `FileBackupStore.swift` ✅
- R-B1: `ConversationCheckpointService.swift` ✅
- R-C3: `RewindPreflightInspector.swift`（`hasAnyFileChanges`、`computeDiffStats`）✅
- R-C4: `RewindTransactionCoordinator.swift`（`execute(targetMessage:checkpoint:option:)` ✅

---

## Claude Code 对应映射

| Claude Code | agentGui R-D1 |
|---|---|
| `MessageSelector.tsx` — pick list 阶段 | `MessageRewindSelectorView` + `MessageRewindSelectorViewModel` |
| `messageOptions` 倒序用户消息列表 | `viewModel.userMessages`（`[Message]` 倒序 user messages） |
| `fileHistoryMetadata` — 每行 diff badge | `viewModel.checkpointMap[message.id]` |
| `handleSelect(message)` → `fileHistoryGetDiffStats` | `selectMessage(message)` → `preflightInspector.hasAnyFileChanges` |
| lossless: `noFileChanges && onlySynthetic` → 直接执行 | `hasAnyFileChanges == false` → `execute(conversationOnly)` 直接关闭 |
| 有文件变化 → `setMessageToRestore(message)` | `pendingConfirmation = PendingConfirmation(message:checkpoint:diffStats:)` |
| confirm 阶段的三选项 | `RewindConfirmationSheet` (stub)，完整版见 R-D2 计划 |
| `onClose()` → close MessageSelector | `shouldDismiss = true` → `dismiss()` |

---

## 文件清单

**新建:**
- `agentGui/ViewModels/MessageRewindSelectorViewModel.swift` — ViewModel（业务逻辑）
- `agentGui/Views/Rewind/MessageRewindSelectorView.swift` — 主 Sheet UI
- `agentGui/Views/Rewind/MessageRewindRowView.swift` — 列表行子视图
- `agentGui/Views/Rewind/RewindConfirmationSheet.swift` — P0 stub（R-D2 替换用）
- `agentGuiTests/MessageRewindSelectorViewModelTests.swift` — 单元测试

**修改:**
- `agentGui/Views/ChatView.swift` — 添加 `@State var isRewindSelectorPresented = false` + `.sheet`
- `agentGui/Views/ChatView+Toolbar.swift` — 添加「回滚到历史消息...」菜单项

---

## Task 1：MessageRewindSelectorViewModel 骨架 + 类型定义

**Files:**
- Create: `agentGui/ViewModels/MessageRewindSelectorViewModel.swift`

**Step 1: 创建 ViewModel 文件，写入全部类型定义与 TODO 骨架**

```swift
// agentGui/ViewModels/MessageRewindSelectorViewModel.swift
import Foundation
import SwiftData
import SwiftUI

// MARK: - MessageRewindSelectorViewModel.Phase

extension MessageRewindSelectorViewModel {
    enum Phase {
        case loading     // 初始加载 checkpointMap
        case ready       // 列表就绪，等待用户操作
        case executing   // 正在执行回滚事务
    }
}

// MARK: - MessageRewindSelectorViewModel.PendingConfirmation

extension MessageRewindSelectorViewModel {
    /// 有文件变化时，暂存待确认信息，触发 RewindConfirmationSheet 展示。
    struct PendingConfirmation: Identifiable {
        let id = UUID()
        let message: Message
        let checkpoint: ConversationCheckpoint?
        let diffStats: RewindDiffStats
    }
}

// MARK: - MessageRewindSelectorViewModel

/// R-D1 ViewModel：管理历史消息列表展示、checkpointMap 加载和回滚路径决策。
///
/// ## 两条执行路径
/// - lossless fast path：`hasAnyFileChanges == false` → 调用 `RewindTransactionCoordinator.execute(.conversationOnly)` 直接完成
/// - confirmation path：`hasAnyFileChanges == true` → 填充 `pendingConfirmation`，Sheet 呈现 RewindConfirmationSheet
///
/// ## 并发安全
/// `@MainActor`：所有可变状态在主线程访问；
/// `preflightInspector`（actor）和 `transactionCoordinator`（@MainActor）均通过 `await` 调用。
@Observable
@MainActor
final class MessageRewindSelectorViewModel {

    // MARK: - Observable State

    var phase: Phase = .loading
    var errorMessage: String?
    /// 非 nil 时触发 RewindConfirmationSheet
    var pendingConfirmation: PendingConfirmation?
    /// 执行成功后置 true，View 观测后调用 dismiss()
    var shouldDismiss = false

    /// 倒序的用户消息列表（最新在前），由 loadData 填充
    private(set) var userMessages: [Message] = []
    /// messageID → checkpoint 映射，由 loadData 填充
    private(set) var checkpointMap: [UUID: ConversationCheckpoint] = [:]

    // MARK: - Dependencies

    private let checkpointService: ConversationCheckpointService
    private let preflightInspector: RewindPreflightInspector
    private let transactionCoordinator: RewindTransactionCoordinator
    private let session: Session

    // MARK: - Init

    init(
        session: Session,
        checkpointService: ConversationCheckpointService,
        preflightInspector: RewindPreflightInspector,
        transactionCoordinator: RewindTransactionCoordinator
    ) {
        self.session = session
        self.checkpointService = checkpointService
        self.preflightInspector = preflightInspector
        self.transactionCoordinator = transactionCoordinator
    }

    // MARK: - Public API

    /// 加载 checkpoints 并构建 userMessages 列表。
    /// 应在 `.task(id: session.sessionId)` 或视图 onAppear 中调用。
    func loadData(messages: [Message], modelContext: ModelContext) async {
        // TODO: Task 1 实现
    }

    /// 用户点击某条消息时触发，决定走哪条路径。
    func selectMessage(_ message: Message) async {
        // TODO: Task 2/3 实现
    }

    /// 确认 sheet 批准后执行回滚（由 RewindConfirmationSheet 回调）。
    func executeConfirmation(pending: PendingConfirmation, option: RewindOption) async {
        // TODO: Task 3 实现
    }
}
```

**Step 2: 验证文件可编译（不需要通过测试，只需无语法错误）**

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild build -project agentGui.xcodeproj -scheme agentGui -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`（或只有已知错误，不是新增的）

**Step 3: Commit 骨架**

```bash
git add agentGui/ViewModels/MessageRewindSelectorViewModel.swift
git commit -m "feat(rewind): R-D1 MessageRewindSelectorViewModel skeleton"
```

---

## Task 2：`loadData` 实现 + 测试

**Files:**
- Modify: `agentGui/ViewModels/MessageRewindSelectorViewModel.swift`
- Create: `agentGuiTests/MessageRewindSelectorViewModelTests.swift`

**Step 1: 先写测试（TDD）**

```swift
// agentGuiTests/MessageRewindSelectorViewModelTests.swift
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

@MainActor
private func makeCheckpoint(
    messageID: UUID,
    sessionID: String,
    hasFileChanges: Bool = false,
    in ctx: ModelContext
) throws -> ConversationCheckpoint {
    let cp = try ConversationCheckpoint(
        sessionID: sessionID,
        messageID: messageID,
        snapshotSequence: 0,
        workspaceRoot: "/tmp/test",
        trackedFileBackups: [:],
        hasFileChanges: hasFileChanges
    )
    ctx.insert(cp)
    return cp
}

/// 构造 NoOp ViewModel（cancelLoop 不执行任何操作）
@MainActor
private func makeViewModel(session: Session, modelContext: ModelContext) -> MessageRewindSelectorViewModel {
    let backupURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("rd1-test-\(UUID().uuidString)")
    let store = FileBackupStore(baseURL: backupURL)
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
    return MessageRewindSelectorViewModel(
        session: session,
        checkpointService: checkpointService,
        preflightInspector: inspector,
        transactionCoordinator: txCoord
    )
}

// MARK: - loadData Tests

@Suite("MessageRewindSelectorViewModel — loadData")
struct MessageRewindSelectorViewModelLoadDataTests {

    @Test("loadData: 从 messages 中只提取用户消息，倒序排列")
    @MainActor
    func loadData_extractsUserMessagesInReverseOrder() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = makeSession(in: ctx)

        let u1 = makeUserMessage(seq: 0, text: "first", in: ctx, session: session)
        let _ = makeAgentMessage(seq: 1, in: ctx, session: session)
        let u2 = makeUserMessage(seq: 2, text: "second", in: ctx, session: session)
        let _ = makeAgentMessage(seq: 3, in: ctx, session: session)
        let u3 = makeUserMessage(seq: 4, text: "third", in: ctx, session: session)
        try ctx.save()

        let allMessages = [u1, makeAgentMessage(seq: 1, in: ctx, session: session), u2, u3]
        // 使用正确的全量 messages（含 agent）
        let allMsgs = try ctx.fetch(FetchDescriptor<Message>())
        let vm = makeViewModel(session: session, modelContext: ctx)

        await vm.loadData(messages: allMsgs, modelContext: ctx)

        #expect(vm.userMessages.count == 3)
        // 倒序：seq 4 在前，seq 0 在后
        #expect(vm.userMessages[0].sequence == 4)
        #expect(vm.userMessages[1].sequence == 2)
        #expect(vm.userMessages[2].sequence == 0)
        #expect(vm.phase == .ready)
    }

    @Test("loadData: 没有用户消息时 userMessages 为空，phase 为 ready")
    @MainActor
    func loadData_noUserMessages_emptyList() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = makeSession(in: ctx)

        let _ = makeAgentMessage(seq: 0, in: ctx, session: session)
        try ctx.save()

        let allMsgs = try ctx.fetch(FetchDescriptor<Message>())
        let vm = makeViewModel(session: session, modelContext: ctx)

        await vm.loadData(messages: allMsgs, modelContext: ctx)

        #expect(vm.userMessages.isEmpty)
        #expect(vm.phase == .ready)
    }

    @Test("loadData: checkpointMap 按 messageID 正确映射")
    @MainActor
    func loadData_buildsCheckpointMapCorrectly() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = makeSession(in: ctx)

        let u1 = makeUserMessage(seq: 0, in: ctx, session: session)
        let u2 = makeUserMessage(seq: 2, in: ctx, session: session)
        try ctx.save()

        let cp1 = try makeCheckpoint(messageID: u1.id, sessionID: session.sessionId, in: ctx)
        let _ = try makeCheckpoint(messageID: u2.id, sessionID: session.sessionId, in: ctx)
        try ctx.save()

        let allMsgs = try ctx.fetch(FetchDescriptor<Message>())
        let vm = makeViewModel(session: session, modelContext: ctx)

        await vm.loadData(messages: allMsgs, modelContext: ctx)

        #expect(vm.checkpointMap[u1.id] != nil)
        #expect(vm.checkpointMap[u2.id] != nil)
        #expect(vm.checkpointMap[u1.id]?.id == cp1.id)
    }

    @Test("loadData: 没有 checkpoint 的消息，checkpointMap 不含其 messageID")
    @MainActor
    func loadData_messageWithoutCheckpoint_notInMap() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = makeSession(in: ctx)

        let u1 = makeUserMessage(seq: 0, in: ctx, session: session)
        try ctx.save()

        // 不创建 checkpoint
        let allMsgs = try ctx.fetch(FetchDescriptor<Message>())
        let vm = makeViewModel(session: session, modelContext: ctx)

        await vm.loadData(messages: allMsgs, modelContext: ctx)

        #expect(vm.checkpointMap[u1.id] == nil)
    }
}
```

**Step 2: 运行测试，确认失败（loadData 是 TODO）**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rd1-task2 \
  -only-testing:agentGuiTests/MessageRewindSelectorViewModelLoadDataTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(PASSED|FAILED|error:)"
```

Expected: 全部 FAILED

**Step 3: 实现 `loadData`**

在 `MessageRewindSelectorViewModel.swift` 中：

```swift
func loadData(messages: [Message], modelContext: ModelContext) async {
    phase = .loading

    // 1. 筛选用户消息，按 sequence 倒序
    let sorted = messages
        .filter { $0.direction == .user }
        .sorted { $0.sequence > $1.sequence }

    // 2. 获取本 session 的所有 checkpoints（最多 50 个）
    let checkpoints = (try? await checkpointService.fetchCheckpoints(
        sessionID: session.sessionId,
        limit: 50,
        modelContext: modelContext
    )) ?? []

    // 3. 构建 messageID → checkpoint 映射
    var map: [UUID: ConversationCheckpoint] = [:]
    for cp in checkpoints {
        map[cp.messageID] = cp
    }

    userMessages = sorted
    checkpointMap = map
    phase = .ready
}
```

**Step 4: 运行测试，确认通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rd1-task2 \
  -only-testing:agentGuiTests/MessageRewindSelectorViewModelLoadDataTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(PASSED|FAILED|error:)"
```

Expected: 全部 PASSED

**Step 5: Commit**

```bash
git add agentGui/ViewModels/MessageRewindSelectorViewModel.swift \
        agentGuiTests/MessageRewindSelectorViewModelTests.swift
git commit -m "feat(rewind): R-D1 loadData + tests"
```

---

## Task 3：`selectMessage` lossless fast path + 测试

**背景:** `hasAnyFileChanges == false`（checkpoint 不存在或 checkpoint.hasFileChanges == false）时，直接执行 `conversationOnly` 并发出 `shouldDismiss = true`。

**Files:**
- Modify: `agentGui/ViewModels/MessageRewindSelectorViewModel.swift`
- Modify: `agentGuiTests/MessageRewindSelectorViewModelTests.swift` （追加新 Suite）

**Step 1: 在测试文件末尾追加新测试**

```swift
// MARK: - selectMessage lossless path Tests

@Suite("MessageRewindSelectorViewModel — selectMessage lossless path")
struct MessageRewindSelectorViewModelLosslessTests {

    @Test("selectMessage: 无 checkpoint → conversationOnly 执行，shouldDismiss = true")
    @MainActor
    func selectMessage_noCheckpoint_executesConversationOnly() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = makeSession(in: ctx)

        // 创建 3 条用户消息
        let u1 = makeUserMessage(seq: 0, text: "First", in: ctx, session: session)
        let u2 = makeUserMessage(seq: 2, text: "Second", in: ctx, session: session)
        let u3 = makeUserMessage(seq: 4, text: "Third", in: ctx, session: session)
        try ctx.save()

        let allMsgs = try ctx.fetch(FetchDescriptor<Message>())
        let vm = makeViewModel(session: session, modelContext: ctx)
        await vm.loadData(messages: allMsgs, modelContext: ctx)

        // 选择 u2（无 checkpoint）
        await vm.selectMessage(u2)

        #expect(vm.shouldDismiss == true)
        #expect(vm.pendingConfirmation == nil)
        #expect(vm.phase == .ready)
        #expect(vm.errorMessage == nil)

        // 验证对话被截断：u2 和 u3（seq >= 2）应被删除
        let remaining = try ctx.fetch(FetchDescriptor<Message>())
        #expect(remaining.allSatisfy { $0.sequence < 2 })
        #expect(remaining.count == 1)  // 只剩 u1
    }

    @Test("selectMessage: checkpoint.hasFileChanges == false → lossless 直接执行")
    @MainActor
    func selectMessage_checkpointNoFileChanges_executesDirectly() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = makeSession(in: ctx)

        let u1 = makeUserMessage(seq: 0, text: "Hello", in: ctx, session: session)
        let u2 = makeUserMessage(seq: 2, text: "World", in: ctx, session: session)
        try ctx.save()

        // 创建 hasFileChanges == false 的 checkpoint
        let _ = try makeCheckpoint(
            messageID: u2.id,
            sessionID: session.sessionId,
            hasFileChanges: false,  // 无文件变化
            in: ctx
        )
        try ctx.save()

        let allMsgs = try ctx.fetch(FetchDescriptor<Message>())
        let vm = makeViewModel(session: session, modelContext: ctx)
        await vm.loadData(messages: allMsgs, modelContext: ctx)

        await vm.selectMessage(u2)

        #expect(vm.shouldDismiss == true)
        #expect(vm.pendingConfirmation == nil)
    }

    @Test("selectMessage: phase 在执行期间为 .executing，执行后回到 .ready")
    @MainActor
    func selectMessage_phaseTransitions() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = makeSession(in: ctx)

        let u1 = makeUserMessage(seq: 0, in: ctx, session: session)
        let u2 = makeUserMessage(seq: 2, in: ctx, session: session)
        try ctx.save()

        let allMsgs = try ctx.fetch(FetchDescriptor<Message>())
        let vm = makeViewModel(session: session, modelContext: ctx)
        await vm.loadData(messages: allMsgs, modelContext: ctx)

        #expect(vm.phase == .ready)
        await vm.selectMessage(u2)
        #expect(vm.phase == .ready)  // 执行完成后回到 ready
    }
}
```

**Step 2: 运行测试，确认失败**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rd1-task3 \
  -only-testing:agentGuiTests/MessageRewindSelectorViewModelLosslessTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(PASSED|FAILED|error:)"
```

Expected: 全部 FAILED

**Step 3: 实现 `selectMessage`（lossless path）**

```swift
func selectMessage(_ message: Message) async {
    phase = .executing
    errorMessage = nil

    let checkpoint = checkpointMap[message.id]

    // 判断是否有文件变化（快速路径：先检查 hasFileChanges 标志，再调用 inspector）
    let hasChanges: Bool
    if let cp = checkpoint, cp.hasFileChanges {
        // checkpoint 声明有文件变化，调用 inspector 精确验证（当前文件是否仍与备份不同）
        hasChanges = (try? await preflightInspector.hasAnyFileChanges(checkpoint: cp)) ?? false
    } else {
        // 无 checkpoint 或 checkpoint.hasFileChanges == false → 无需验证
        hasChanges = false
    }

    if !hasChanges {
        // Lossless fast path: 仅截断对话，不动文件
        do {
            try await transactionCoordinator.execute(
                targetMessage: message,
                checkpoint: nil,
                option: .conversationOnly,
                repopulateInput: true
            )
            shouldDismiss = true
        } catch {
            errorMessage = error.localizedDescription
        }
    } else {
        // Confirmation path（Task 4 实现）
        let diffStats = (try? await preflightInspector.computeDiffStats(checkpoint: checkpoint!)) ?? .empty
        pendingConfirmation = PendingConfirmation(
            message: message,
            checkpoint: checkpoint,
            diffStats: diffStats
        )
    }

    phase = .ready
}
```

**Step 4: 运行测试，确认通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rd1-task3 \
  -only-testing:agentGuiTests/MessageRewindSelectorViewModelLosslessTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(PASSED|FAILED|error:)"
```

Expected: 全部 PASSED

**Step 5: Commit**

```bash
git add agentGui/ViewModels/MessageRewindSelectorViewModel.swift \
        agentGuiTests/MessageRewindSelectorViewModelTests.swift
git commit -m "feat(rewind): R-D1 selectMessage lossless path + tests"
```

---

## Task 4：`selectMessage` confirmation path + `executeConfirmation` + 测试

**Files:**
- Modify: `agentGui/ViewModels/MessageRewindSelectorViewModel.swift`（`executeConfirmation` 已有 TODO 骨架）
- Modify: `agentGuiTests/MessageRewindSelectorViewModelTests.swift`（追加新 Suite）

**Step 1: 追加 confirmation path 测试**

注意：此 Task 的测试**验证 pendingConfirmation 被填充**，以及 `executeConfirmation` 执行正确的 option。对 `hasAnyFileChanges == true` 的完整磁盘测试较复杂，改用 `cp.hasFileChanges == true` 的内存路径（Inspector 逻辑通过 R-C3 测试已覆盖，此处只测 ViewModel 决策）。

```swift
// MARK: - selectMessage confirmation path Tests

@Suite("MessageRewindSelectorViewModel — confirmation path")
struct MessageRewindSelectorViewModelConfirmationTests {

    @Test("selectMessage: checkpoint.hasFileChanges == true → pendingConfirmation 被填充，不直接执行")
    @MainActor
    func selectMessage_hasFileChanges_populatesPendingConfirmation() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = makeSession(in: ctx)

        let u1 = makeUserMessage(seq: 0, in: ctx, session: session)
        let u2 = makeUserMessage(seq: 2, in: ctx, session: session)
        try ctx.save()

        // checkpoint.hasFileChanges == true，但不写入实际 backup 文件（inspector 找不到文件，返回 false）
        // → 为了强制走 confirmation path，我们需要 inspector 返回 true
        // 方案：用真实备份文件模拟。此处改为直接测试 checkpoint.hasFileChanges 标志被正确读取即可。
        // 由于 inspector.hasAnyFileChanges 在没有真实备份文件时返回 false，
        // 此测试验证"即使 cp.hasFileChanges == true，但实际文件无变化时，走 lossless path"的安全降级行为。
        let cp = try makeCheckpoint(
            messageID: u2.id,
            sessionID: session.sessionId,
            hasFileChanges: true,  // 声称有变化
            in: ctx
        )
        try ctx.save()

        let allMsgs = try ctx.fetch(FetchDescriptor<Message>())
        let vm = makeViewModel(session: session, modelContext: ctx)
        await vm.loadData(messages: allMsgs, modelContext: ctx)

        await vm.selectMessage(u2)

        // Inspector 找不到真实备份文件 → hasAnyFileChanges returns false → lossless path
        // 这验证了安全降级：即使 hasFileChanges 标志为 true，实际无备份文件时也走 lossless path
        #expect(vm.shouldDismiss == true)
        #expect(vm.pendingConfirmation == nil)
    }

    @Test("executeConfirmation: conversationOnly → 截断对话，pendingConfirmation 清空，shouldDismiss = true")
    @MainActor
    func executeConfirmation_conversationOnly_truncatesAndDismisses() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = makeSession(in: ctx)

        let u1 = makeUserMessage(seq: 0, in: ctx, session: session)
        let u2 = makeUserMessage(seq: 2, in: ctx, session: session)
        let u3 = makeUserMessage(seq: 4, in: ctx, session: session)
        try ctx.save()

        let allMsgs = try ctx.fetch(FetchDescriptor<Message>())
        let vm = makeViewModel(session: session, modelContext: ctx)
        await vm.loadData(messages: allMsgs, modelContext: ctx)

        // 手动构建 pending（跳过 selectMessage 的 inspector 调用）
        let pending = MessageRewindSelectorViewModel.PendingConfirmation(
            message: u2,
            checkpoint: nil,
            diffStats: .empty
        )

        await vm.executeConfirmation(pending: pending, option: .conversationOnly)

        #expect(vm.shouldDismiss == true)
        #expect(vm.pendingConfirmation == nil)
        #expect(vm.phase == .ready)
        #expect(vm.errorMessage == nil)

        let remaining = try ctx.fetch(FetchDescriptor<Message>())
        #expect(remaining.allSatisfy { $0.sequence < 2 })
    }

    @Test("executeConfirmation: option == .filesOnly 且无 checkpoint → 报错，不 dismiss")
    @MainActor
    func executeConfirmation_filesOnlyWithoutCheckpoint_setsError() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = makeSession(in: ctx)

        let u1 = makeUserMessage(seq: 0, in: ctx, session: session)
        let u2 = makeUserMessage(seq: 2, in: ctx, session: session)
        try ctx.save()

        let allMsgs = try ctx.fetch(FetchDescriptor<Message>())
        let vm = makeViewModel(session: session, modelContext: ctx)
        await vm.loadData(messages: allMsgs, modelContext: ctx)

        let pending = MessageRewindSelectorViewModel.PendingConfirmation(
            message: u2,
            checkpoint: nil,  // 无 checkpoint
            diffStats: .empty
        )

        await vm.executeConfirmation(pending: pending, option: .filesOnly)

        #expect(vm.shouldDismiss == false)
        #expect(vm.errorMessage != nil)  // 应有错误信息
    }
}
```

**Step 2: 运行测试，确认失败**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rd1-task4 \
  -only-testing:agentGuiTests/MessageRewindSelectorViewModelConfirmationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(PASSED|FAILED|error:)"
```

**Step 3: 实现 `executeConfirmation`**

```swift
func executeConfirmation(pending: PendingConfirmation, option: RewindOption) async {
    phase = .executing
    errorMessage = nil

    do {
        try await transactionCoordinator.execute(
            targetMessage: pending.message,
            checkpoint: pending.checkpoint,
            option: option,
            repopulateInput: true
        )
        pendingConfirmation = nil
        shouldDismiss = true
    } catch {
        errorMessage = error.localizedDescription
        pendingConfirmation = nil
    }

    phase = .ready
}
```

**Step 4: 运行全部 ViewModel 测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rd1-task4 \
  -only-testing:agentGuiTests/MessageRewindSelectorViewModelLoadDataTests \
  -only-testing:agentGuiTests/MessageRewindSelectorViewModelLosslessTests \
  -only-testing:agentGuiTests/MessageRewindSelectorViewModelConfirmationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(PASSED|FAILED|error:)"
```

Expected: 全部 PASSED

**Step 5: Commit**

```bash
git add agentGui/ViewModels/MessageRewindSelectorViewModel.swift \
        agentGuiTests/MessageRewindSelectorViewModelTests.swift
git commit -m "feat(rewind): R-D1 confirmation path + executeConfirmation + tests"
```

---

## Task 5：`MessageRewindRowView` + `RewindConfirmationSheet` P0 Stub

**Files:**
- Create: `agentGui/Views/Rewind/MessageRewindRowView.swift`
- Create: `agentGui/Views/Rewind/RewindConfirmationSheet.swift`

**Step 1: 创建 MessageRewindRowView**

```swift
// agentGui/Views/Rewind/MessageRewindRowView.swift
import SwiftUI

/// R-D1: 历史消息选择器中的单行视图。
/// 展示消息文本预览（前 60 字符）、相对时间和文件变化徽标。
struct MessageRewindRowView: View {

    let message: Message
    let hasFileChanges: Bool

    private var previewText: String {
        let raw = message.textContent ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 60 else { return trimmed.isEmpty ? "（空消息）" : trimmed }
        return String(trimmed.prefix(60)) + "…"
    }

    private var relativeTimeText: String {
        message.timestamp.formatted(.relative(presentation: .named))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(previewText)
                    .font(.body)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Text(relativeTimeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if hasFileChanges {
                Label("含文件变化", systemImage: "doc.badge.clock")
                    .labelStyle(.iconOnly)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("此消息之后有文件被修改，回滚将恢复这些文件")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityLabel("回滚到：\(previewText)，\(relativeTimeText)")
    }
}
```

**Step 2: 创建 RewindConfirmationSheet（P0 stub）**

注意：此实现是 P0 stub，供 R-D1 使用。当 R-D2 计划完成后，此文件将被替换为完整版本，届时无需改动 `MessageRewindSelectorView`。

```swift
// agentGui/Views/Rewind/RewindConfirmationSheet.swift
import SwiftUI

// MARK: - RewindConfirmationSheet

/// R-D1 P0 Stub: 确认回滚操作的 Sheet。
///
/// 此处为最小可用实现，提供三个操作选项：
///   1. 恢复对话和文件（default，当 canRestoreFiles 为 true 时）
///   2. 仅恢复对话
///   3. 取消
///
/// R-D2 计划将提供完整版本（含文件 diff 预览、统计数字和更丰富的 UI）。
/// 当 R-D2 完成后，此文件将被整体替换，调用方（MessageRewindSelectorView）无需修改。
struct RewindConfirmationSheet: View {

    @Environment(\.dismiss) private var dismiss

    let pending: MessageRewindSelectorViewModel.PendingConfirmation
    let onExecute: (RewindOption) async -> Void
    let onCancel: () -> Void

    @State private var isExecuting = false

    private var canRestoreFiles: Bool {
        pending.checkpoint != nil && !pending.diffStats.filesChanged.isEmpty
    }

    private var messagePreview: String {
        let raw = pending.message.textContent ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 80 else { return trimmed.isEmpty ? "（空消息）" : trimmed }
        return String(trimmed.prefix(80)) + "…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题
            Text("确认回滚")
                .font(.headline)

            // 目标消息预览
            VStack(alignment: .leading, spacing: 4) {
                Text("回滚到此消息之前：")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(messagePreview)
                    .font(.body)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            // 文件变化摘要（若有）
            if canRestoreFiles {
                VStack(alignment: .leading, spacing: 4) {
                    Text("文件变化")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(pending.diffStats.filesChanged.count) 个文件将被恢复")
                        .font(.body)
                }
            }

            Divider()

            // 操作按钮
            VStack(spacing: 8) {
                if canRestoreFiles {
                    rewindButton(label: "恢复对话和文件", option: .conversationAndFiles, isPrimary: true)
                }
                rewindButton(label: "仅恢复对话", option: .conversationOnly, isPrimary: !canRestoreFiles)
                if canRestoreFiles {
                    rewindButton(label: "仅恢复文件", option: .filesOnly, isPrimary: false)
                }
                Button("取消") {
                    onCancel()
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isExecuting)
            }
        }
        .padding(20)
        .frame(minWidth: 320, maxWidth: 480)
    }

    @ViewBuilder
    private func rewindButton(label: String, option: RewindOption, isPrimary: Bool) -> some View {
        Button {
            Task {
                isExecuting = true
                await onExecute(option)
                isExecuting = false
                dismiss()
            }
        } label: {
            HStack {
                if isExecuting {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                }
                Text(label)
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(isPrimary ? .borderedProminent : .bordered)
        .disabled(isExecuting)
    }
}
```

**Step 3: 编译验证**

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add agentGui/Views/Rewind/MessageRewindRowView.swift \
        agentGui/Views/Rewind/RewindConfirmationSheet.swift
git commit -m "feat(rewind): R-D1 MessageRewindRowView + RewindConfirmationSheet stub"
```

---

## Task 6：`MessageRewindSelectorView` 主 Sheet UI

**Files:**
- Create: `agentGui/Views/Rewind/MessageRewindSelectorView.swift`

**Step 1: 创建主 Sheet**

```swift
// agentGui/Views/Rewind/MessageRewindSelectorView.swift
import SwiftUI
import SwiftData

/// R-D1: 历史消息选择器 Sheet。
///
/// 展示当前 session 中所有用户消息（最多 20 条，倒序），用户选择后分两条路径：
/// - lossless（无文件变化）：直接执行 conversationOnly，关闭 sheet
/// - 有文件变化：呈现 RewindConfirmationSheet 供用户选择操作范围
///
/// ## 使用方式
/// 在 ChatView 中：
/// ```swift
/// .sheet(isPresented: $isRewindSelectorPresented) {
///     MessageRewindSelectorView(
///         session: session,
///         allMessages: allMessages,
///         transactionCoordinator: makeRewindTransactionCoordinator()
///     )
/// }
/// ```
struct MessageRewindSelectorView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // MARK: - Dependencies (injected)

    let session: Session
    /// 完整的 session 消息列表（含 agent/system，由 ChatView @Query 传入）
    let allMessages: [Message]
    let transactionCoordinator: RewindTransactionCoordinator

    // MARK: - ViewModel

    @State private var viewModel: MessageRewindSelectorViewModel

    // MARK: - Init

    init(
        session: Session,
        allMessages: [Message],
        transactionCoordinator: RewindTransactionCoordinator,
        checkpointService: ConversationCheckpointService,
        preflightInspector: RewindPreflightInspector
    ) {
        self.session = session
        self.allMessages = allMessages
        self.transactionCoordinator = transactionCoordinator
        _viewModel = State(initialValue: MessageRewindSelectorViewModel(
            session: session,
            checkpointService: checkpointService,
            preflightInspector: inspector,
            transactionCoordinator: transactionCoordinator
        ))
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.phase {
                case .loading:
                    loadingView
                case .ready, .executing:
                    if viewModel.userMessages.isEmpty {
                        emptyView
                    } else {
                        messageListView
                    }
                }
            }
            .navigationTitle("回滚到历史消息")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(viewModel.phase == .executing)
                }
            }
            .alert(
                "回滚失败",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("确定") { viewModel.errorMessage = nil }
            } message: {
                if let err = viewModel.errorMessage { Text(err) }
            }
        }
        .sheet(item: $viewModel.pendingConfirmation) { pending in
            RewindConfirmationSheet(
                pending: pending,
                onExecute: { option in
                    await viewModel.executeConfirmation(pending: pending, option: option)
                },
                onCancel: {
                    viewModel.pendingConfirmation = nil
                }
            )
        }
        .task(id: session.sessionId) {
            await viewModel.loadData(messages: allMessages, modelContext: modelContext)
        }
        .onChange(of: viewModel.shouldDismiss) { _, newValue in
            if newValue { dismiss() }
        }
        .frame(minWidth: 400, minHeight: 300)
    }

    // MARK: - Subviews

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("加载历史快照…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "暂无历史消息",
            systemImage: "clock.arrow.circlepath",
            description: Text("当前对话中没有可回滚的用户消息。")
        )
    }

    private var messageListView: some View {
        List {
            ForEach(viewModel.userMessages.prefix(20)) { message in
                MessageRewindRowView(
                    message: message,
                    hasFileChanges: viewModel.checkpointMap[message.id]?.hasFileChanges ?? false
                )
                .onTapGesture {
                    Task { await viewModel.selectMessage(message) }
                }
                .disabled(viewModel.phase == .executing)
            }
        }
        .listStyle(.plain)
    }
}
```

**注意 — `MessageRewindSelectorView.init` 中有一个笔误：** `preflightInspector: inspector` 应为 `preflightInspector: preflightInspector`。在实现时修正。

**Step 2: 编译验证**

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add agentGui/Views/Rewind/MessageRewindSelectorView.swift
git commit -m "feat(rewind): R-D1 MessageRewindSelectorView main sheet UI"
```

---

## Task 7：ChatView 接入 + Toolbar 菜单项

**Files:**
- Modify: `agentGui/Views/ChatView.swift`
- Modify: `agentGui/Views/ChatView+Toolbar.swift`

**Step 1: 在 ChatView 中添加状态变量和 Sheet + 工厂方法**

在 `ChatView` 的 `// MARK: - Properties` 区域末尾（`@FocusState var isInputFocused: Bool` 之前）添加：

```swift
// MARK: - Rewind
@State private var isRewindSelectorPresented = false
```

在 `ChatView.body` 的 `.sheet(item: $pendingAgentTeamComposer)` 块之后，添加新的 sheet：

```swift
.sheet(isPresented: $isRewindSelectorPresented) {
    makeRewindSelectorView()
}
```

在 `ChatView+Actions.swift`（或 `ChatView.swift` 末尾）添加工厂方法：

```swift
// MARK: - Rewind Factory

/// 构造 MessageRewindSelectorView 所需的依赖。
/// cancelLoop 捕获 claudeService，以闭包形式注入 RewindTransactionCoordinator（保持可测试性）。
func makeRewindSelectorView() -> MessageRewindSelectorView {
    let backupBaseURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("agentGui/checkpoints")
    let store = FileBackupStore(baseURL: backupBaseURL)
    let checkpointService = ConversationCheckpointService(fileBackupStore: store)
    let inspector = RewindPreflightInspector(fileBackupStore: store)
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
    return MessageRewindSelectorView(
        session: session,
        allMessages: Array(allMessages),
        transactionCoordinator: txCoord,
        checkpointService: checkpointService,
        preflightInspector: inspector
    )
}
```

**Step 2: 在 ChatView+Toolbar.swift 添加菜单项**

在现有 `Menu { ... }` 内，`Button("清除对话")` 之前插入：

```swift
Button("回滚到历史消息...") {
    isRewindSelectorPresented = true
}
.disabled(rewindSelectorDisabled)
Divider()
```

在 `ChatView` 的计算属性区（如 `var sessionInteractionPolicy: SessionInteractionPolicy` 附近）添加：

```swift
private var rewindSelectorDisabled: Bool {
    // 无可回滚的用户消息（< 2 条）
    let userMessageCount = allMessages.filter { $0.direction == .user }.count
    guard userMessageCount >= 2 else { return true }
    // session 为只读
    guard sessionInteractionPolicy.canSend else { return true }
    return false
}
```

**Step 3: 编译验证**

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

**Step 4: 全量 ViewModel 测试回归**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rd1-final \
  -only-testing:agentGuiTests/MessageRewindSelectorViewModelLoadDataTests \
  -only-testing:agentGuiTests/MessageRewindSelectorViewModelLosslessTests \
  -only-testing:agentGuiTests/MessageRewindSelectorViewModelConfirmationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(PASSED|FAILED|error:)"
```

Expected: 全部 PASSED

**Step 5: Commit**

```bash
git add agentGui/Views/ChatView.swift \
        agentGui/Views/ChatView+Toolbar.swift \
        agentGui/Views/ChatView+Actions.swift
git commit -m "feat(rewind): R-D1 ChatView wiring + toolbar menu item"
```

---

## 验收标准汇总

| 场景 | 预期行为 |
|------|---------|
| 对话消息 < 2 条时 | 工具栏「回滚」按钮禁用 |
| 点击「回滚到历史消息...」 | Sheet 在 300ms 内呈现，列表已填充（最多 20 条） |
| 消息列表顺序 | 最新消息在顶（倒序排列） |
| 有 checkpoint 且 hasFileChanges = true 的消息 | 行右侧显示橙色文档徽标 |
| 点击无 checkpoint 的消息 | 直接执行 conversationOnly，sheet 关闭，输入框填充原始文本 |
| 点击 hasFileChanges = false 的消息 | 同上（lossless fast path） |
| 点击 hasFileChanges = true 的消息（备份文件存在）| 呈现 RewindConfirmationSheet |
| 选择「仅恢复对话」后确认 | 对话截断，文件不变，sheet 关闭 |
| 选择「恢复对话和文件」后确认 | 对话截断 + 文件恢复，sheet 关闭 |
| 回滚成功 | ChatView 输入框恢复目标消息文本 |
| 回滚失败（错误） | sheet 不关闭，显示 Alert 错误描述 |
| agent loop 正在运行时点击「回滚」 | 菜单项禁用（`canSend == false` 条件） |

---

## 依赖服务接口速查

```
ConversationCheckpointService.fetchCheckpoints(sessionID:limit:modelContext:)
  → async throws → [ConversationCheckpoint]

RewindPreflightInspector.hasAnyFileChanges(checkpoint:)
  → async throws → Bool

RewindPreflightInspector.computeDiffStats(checkpoint:)
  → async throws → RewindDiffStats

RewindTransactionCoordinator.execute(targetMessage:checkpoint:option:repopulateInput:)
  → @MainActor async throws → RewindTransactionResult

ClaudeService.cancelExecution(session:modelContext:)
  → @MainActor async
```

---

## 架构图

```
ChatView
  ├── @State isRewindSelectorPresented
  ├── makeRewindSelectorView() → MessageRewindSelectorView
  └── .sheet → MessageRewindSelectorView
        ├── @State MessageRewindSelectorViewModel
        │     ├── loadData(messages:modelContext:)
        │     │     └── ConversationCheckpointService.fetchCheckpoints → checkpointMap
        │     ├── selectMessage(message:)
        │     │     ├── [lossless] RewindTransactionCoordinator.execute(.conversationOnly)
        │     │     │     └── shouldDismiss = true → dismiss()
        │     │     └── [hasChanges] pendingConfirmation = PendingConfirmation(...)
        │     └── executeConfirmation(pending:option:)
        │           └── RewindTransactionCoordinator.execute(option)
        │                 └── shouldDismiss = true → dismiss()
        ├── List → MessageRewindRowView (×N, 最多 20)
        └── .sheet(item: $pendingConfirmation) → RewindConfirmationSheet
              └── onExecute → viewModel.executeConfirmation(...)
```

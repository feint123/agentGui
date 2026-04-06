# Feature R-C1: ConversationRewindCoordinator 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现 `ConversationRewindCoordinator` — 通过 SwiftData cascade delete 截断指定用户消息（含该消息本身）及其之后的所有对话记录，级联清理 `AgentRound`/`ToolCall`，并发出 `rewindDidPruneConversation` 通知供 UI 响应。

**Architecture:** `@MainActor final class`，注入 `ModelContext`，`rewindTo(message:)` 查找 `sequence >= targetMessage.sequence` 的所有消息并 cascade delete。语义与 Claude Code `rewindConversationTo(message)` 对齐（即 `messages.slice(0, messageIndex)`，目标消息本身也被移除）。Agent loop 取消由上层 R-C4 `RewindTransactionCoordinator` 在调用本类之前完成，**R-C1 专注 SwiftData 截断**，无外部服务依赖。

**Tech Stack:** Swift 6+, SwiftData (`@MainActor ModelContext`), Swift Testing (`@Suite`, `@Test`, `#expect`)

---

## 背景与边界

### R-C1 在 Rewind 系统中的位置

```
R-C4 RewindTransactionCoordinator
  ├─ Step 1: cancelExecution(...)          ← 取消 agent loop（ClaudeService）
  ├─ Step 2: R-C2 FileSystemRewindCoordinator.rewind(...)   ← 文件恢复
  ├─ Step 3: R-C1 ConversationRewindCoordinator.rewindTo(message:)  ← ← 本任务
  └─ Step 4: repopulateInput(...)          ← 恢复输入框文字
```

R-C1 **不负责**：
- 取消 agent loop（由 R-C4 在调用前完成）
- 文件系统恢复（R-C2）
- Team Session 的 AgentTeamWorkbenchPresentation 内存镜像清理（通过通知解耦，团队 ViewModel 自行观察）
- 往输入框填充文字（R-C4）

### Claude Code 对应实现参考

```typescript
// REPL.tsx - rewindConversationTo(message: UserMessage)
const messageIndex = prev.lastIndexOf(message);   // 找目标位置
setMessages(prev.slice(0, messageIndex));          // 截断（不含目标消息本身）
setConversationId(randomUUID());                   // 重置 conversationId
resetMicrocompactState();                          // 清 compaction 缓存
```

agentGui 对应逻辑（持久化语义，非内存状态）：
- `session.messages.filter { $0.sequence >= targetMessage.sequence }` → delete
- cascade delete 自动清理 `AgentRound`、`ToolCall`
- conversationId 重置 → agentGui 中无此概念，由 R-C4 通知外部重置 context state
- compaction 缓存清除 → 发出通知由 AgentLoopRunner 观察响应

### SwiftData Cascade 链路

```
Message (delete)
  ├─ @Relationship(.cascade) toolCalls: [ToolCall]
  └─ @Relationship(.cascade) agentRounds: [AgentRound]
       └─ @Relationship(.cascade) toolCalls: [ToolCall]
```

仅需 `modelContext.delete(message)`，无需手动删子对象。

---

## 新增文件

| 路径 | 说明 |
|------|------|
| `agentGui/Services/Rewind/ConversationRewindCoordinator.swift` | 主实现（R-C1）|
| `agentGuiTests/ConversationRewindCoordinatorTests.swift` | 单元测试 |

**需要修改的文件（Xcode 项目注册）：**

| 路径 | 操作 |
|------|------|
| `agentGui.xcodeproj/project.pbxproj` | 注册两个新文件 |

---

## Task 1: 创建测试文件（TDD 先行）

**Files:**
- Create: `agentGuiTests/ConversationRewindCoordinatorTests.swift`

### Step 1: 编写测试文件（此时测试必然编译失败，因为目标类型不存在）

新建文件，内容如下：

```swift
// agentGuiTests/ConversationRewindCoordinatorTests.swift
import Foundation
import Testing
import SwiftData
@testable import agentGui

// MARK: - Helpers

@MainActor
private func makeContainer() throws -> ModelContainer {
    let schema = Schema([Session.self, Message.self, AgentRound.self, ToolCall.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

@MainActor
private func makeSession(in ctx: ModelContext) -> Session {
    let session = Session()
    ctx.insert(session)
    return session
}

/// sequence 从 1 开始，direction 默认 .user
@MainActor
private func makeMessage(
    direction: MessageDirection = .user,
    sequence: Int,
    status: MessageStatus = .completed,
    in ctx: ModelContext,
    session: Session
) -> Message {
    let msg = Message(direction: direction, text: "content-\(sequence)", session: session)
    msg.sequence = sequence
    msg.status = status
    ctx.insert(msg)
    return msg
}

/// 在 message 上挂一个 AgentRound，再在 AgentRound 上挂一个 ToolCall
@MainActor
private func attachAgentRound(to message: Message, in ctx: ModelContext) -> (AgentRound, ToolCall) {
    let round = AgentRound()
    round.message = message
    round.roundIndex = 0
    ctx.insert(round)

    let tool = ToolCall()
    tool.agentRound = round
    ctx.insert(tool)

    return (round, tool)
}

// MARK: - Test Suite

@MainActor
@Suite("ConversationRewindCoordinator Tests")
struct ConversationRewindCoordinatorTests {

    // MARK: - rewindTo: 基础截断

    @Test
    func rewindTo_deletesTargetMessageAndAllSubsequentMessages() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let coordinator = ConversationRewindCoordinator(modelContext: ctx)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        let m2 = makeMessage(sequence: 2, in: ctx, session: session)
        let m3 = makeMessage(sequence: 3, in: ctx, session: session)
        _ = makeMessage(sequence: 4, in: ctx, session: session)
        try ctx.save()

        // 回滚到 m3（删 m3、m4，保留 m1、m2）
        let deletedCount = try await coordinator.rewindTo(message: m3)

        #expect(deletedCount == 2)

        let descriptor = FetchDescriptor<Message>()
        let remaining = try ctx.fetch(descriptor)
        let remainingSeqs = remaining.map(\.sequence).sorted()
        #expect(remainingSeqs == [1, 2])
        #expect(remaining.contains(where: { $0.id == m1.id }))
        #expect(remaining.contains(where: { $0.id == m2.id }))
    }

    @Test
    func rewindTo_preservesMessagesBeforeTarget() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let coordinator = ConversationRewindCoordinator(modelContext: ctx)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        let m2 = makeMessage(sequence: 2, in: ctx, session: session)
        try ctx.save()

        // 回滚到 sequence=2（只删 m2）
        _ = try await coordinator.rewindTo(message: m2)

        let descriptor = FetchDescriptor<Message>()
        let remaining = try ctx.fetch(descriptor)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == m1.id)
    }

    @Test
    func rewindTo_returnsCorrectDeletedCount() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let coordinator = ConversationRewindCoordinator(modelContext: ctx)

        _ = makeMessage(sequence: 1, in: ctx, session: session)
        _ = makeMessage(sequence: 2, in: ctx, session: session)
        let m3 = makeMessage(sequence: 3, in: ctx, session: session)
        _ = makeMessage(sequence: 4, in: ctx, session: session)
        _ = makeMessage(sequence: 5, in: ctx, session: session)
        try ctx.save()

        let count = try await coordinator.rewindTo(message: m3)
        #expect(count == 3) // m3, m4, m5
    }

    // MARK: - Cascade Delete

    @Test
    func rewindTo_cascadesDeleteToAgentRoundsAndToolCalls() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let coordinator = ConversationRewindCoordinator(modelContext: ctx)

        _ = makeMessage(sequence: 1, in: ctx, session: session)
        let m2 = makeMessage(sequence: 2, in: ctx, session: session)

        // m2 上挂一个 AgentRound + 一个 ToolCall
        let (round, tool) = attachAgentRound(to: m2, in: ctx)
        try ctx.save()

        let roundID = round.id
        let toolID = tool.id

        _ = try await coordinator.rewindTo(message: m2)

        let rounds = try ctx.fetch(FetchDescriptor<AgentRound>())
        let tools = try ctx.fetch(FetchDescriptor<ToolCall>())
        #expect(!rounds.contains(where: { $0.id == roundID }), "AgentRound 应被 cascade 删除")
        #expect(!tools.contains(where: { $0.id == toolID }), "ToolCall 应被 cascade 删除")
    }

    @Test
    func rewindTo_doesNotDeleteUnrelatedSessionMessages() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session1 = makeSession(in: ctx)
        let session2 = makeSession(in: ctx)
        let coordinator = ConversationRewindCoordinator(modelContext: ctx)

        _ = makeMessage(sequence: 1, in: ctx, session: session1)
        let m2 = makeMessage(sequence: 2, in: ctx, session: session1)

        // session2 中有独立消息，不应被影响
        _ = makeMessage(sequence: 1, in: ctx, session: session2)
        _ = makeMessage(sequence: 2, in: ctx, session: session2)
        try ctx.save()

        _ = try await coordinator.rewindTo(message: m2)

        let descriptor = FetchDescriptor<Message>()
        let remaining = try ctx.fetch(descriptor)
        // session1 剩 1 条，session2 保留 2 条
        #expect(remaining.count == 3)
    }

    // MARK: - 边界情况

    @Test
    func rewindTo_singleMessage_deletesIt_returnsOne() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let coordinator = ConversationRewindCoordinator(modelContext: ctx)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        try ctx.save()

        let count = try await coordinator.rewindTo(message: m1)

        #expect(count == 1)
        let remaining = try ctx.fetch(FetchDescriptor<Message>())
        #expect(remaining.isEmpty)
    }

    @Test
    func rewindTo_messageNotAttachedToSession_throwsError() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let coordinator = ConversationRewindCoordinator(modelContext: ctx)

        // 创建一个未关联到 session 的 message
        let orphan = Message(direction: .user, text: "orphan", session: nil)
        orphan.sequence = 1
        ctx.insert(orphan)
        try ctx.save()

        do {
            _ = try await coordinator.rewindTo(message: orphan)
            #expect(Bool(false), "应抛出 RewindError.messageNotAttachedToSession")
        } catch RewindError.messageNotAttachedToSession {
            // expected
        }
    }

    // MARK: - 通知

    @Test
    func rewindTo_postsNotification_withSessionID() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let coordinator = ConversationRewindCoordinator(modelContext: ctx)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        _ = makeMessage(sequence: 2, in: ctx, session: session)
        try ctx.save()

        let sessionID = session.sessionId

        var receivedSessionIDs: [String] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .rewindDidPruneConversation,
            object: nil,
            queue: .main
        ) { notification in
            if let id = notification.object as? String {
                receivedSessionIDs.append(id)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = try await coordinator.rewindTo(message: m1)

        // 等一个 runloop tick 让通知分发
        try await Task.sleep(for: .milliseconds(50))
        #expect(receivedSessionIDs.contains(sessionID))
    }
}
```

### Step 2: 确认测试文件已加入 Xcode Target

将 `ConversationRewindCoordinatorTests.swift` 加入 `agentGuiTests` target（在 Xcode 中拖入，或直接编辑 `project.pbxproj`）。编译时应报错：`cannot find type 'ConversationRewindCoordinator' in scope`。

---

## Task 2: 实现 ConversationRewindCoordinator

**Files:**
- Create: `agentGui/Services/Rewind/ConversationRewindCoordinator.swift`

### Step 1: 创建实现文件

```swift
// agentGui/Services/Rewind/ConversationRewindCoordinator.swift
import Foundation
import SwiftData

// MARK: - RewindError

/// ConversationRewindCoordinator 的错误类型
enum RewindError: Error, LocalizedError {
    case messageNotAttachedToSession

    var errorDescription: String? {
        switch self {
        case .messageNotAttachedToSession:
            return "目标消息未关联到任何 Session，无法执行对话截断。"
        }
    }
}

// MARK: - Notification.Name

extension Notification.Name {
    /// 对话截断完成后发出。object 为 sessionID (String)。
    /// 观察者：AgentLoopRunner（清除 compaction 缓存），AgentTeamWorkbenchPresentation（清除内存镜像）
    static let rewindDidPruneConversation = Notification.Name("agentGui.rewindDidPruneConversation")
}

// MARK: - ConversationRewindCoordinator

/// R-C1: 负责通过 SwiftData cascade delete 截断指定用户消息（含该消息本身）及其之后的所有对话记录。
///
/// ## 截断语义
/// 对齐 Claude Code `rewindConversationTo(message)` 的行为：
/// - `targetMessage` 及所有 `sequence >= targetMessage.sequence` 的 `Message` 都被删除
/// - SwiftData cascade 自动清理关联的 `AgentRound` 和 `ToolCall`
///
/// ## 职责边界
/// - 本类 **只做 SwiftData 截断**，不负责取消 agent loop（由 R-C4 先完成）
/// - 不负责文件系统恢复（R-C2）
/// - 不负责填充输入框（R-C4）
/// - Agent team 的内存镜像清理通过 `rewindDidPruneConversation` 通知解耦
@MainActor
final class ConversationRewindCoordinator {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Public API

    /// 截断对话到指定消息（含目标消息）之前。
    ///
    /// - Parameter targetMessage: 对话截断的起始点。此消息本身及其后所有消息均被删除。
    /// - Returns: 实际被删除的消息数量。
    /// - Throws: `RewindError.messageNotAttachedToSession` 若消息未关联 session。
    @discardableResult
    func rewindTo(message targetMessage: Message) async throws -> Int {
        guard let session = targetMessage.session else {
            throw RewindError.messageNotAttachedToSession
        }

        let targetSequence = targetMessage.sequence
        let toDelete = session.messages.filter { $0.sequence >= targetSequence }
        let deletedCount = toDelete.count

        for message in toDelete {
            modelContext.delete(message)
        }

        try modelContext.save()

        NotificationCenter.default.post(
            name: .rewindDidPruneConversation,
            object: session.sessionId
        )

        return deletedCount
    }
}
```

### Step 2: 将文件加入 agentGui target

在 Xcode 中将 `ConversationRewindCoordinator.swift` 加入 **agentGui** target（主 app target）。

---

## Task 3: 运行测试

### Step 1: 运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rc1-rewind-derived \
  -only-testing:agentGuiTests/ConversationRewindCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```

**预期输出（成功）：**

```
Test Suite 'ConversationRewindCoordinatorTests' started
Test Case 'rewindTo_deletesTargetMessageAndAllSubsequentMessages' passed (0.0xx seconds)
Test Case 'rewindTo_preservesMessagesBeforeTarget' passed (0.0xx seconds)
Test Case 'rewindTo_returnsCorrectDeletedCount' passed (0.0xx seconds)
Test Case 'rewindTo_cascadesDeleteToAgentRoundsAndToolCalls' passed (0.0xx seconds)
Test Case 'rewindTo_doesNotDeleteUnrelatedSessionMessages' passed (0.0xx seconds)
Test Case 'rewindTo_singleMessage_deletesIt_returnsOne' passed (0.0xx seconds)
Test Case 'rewindTo_messageNotAttachedToSession_throwsError' passed (0.0xx seconds)
Test Case 'rewindTo_postsNotification_withSessionID' passed (0.0xx seconds)
** TEST SUCCEEDED **
```

**如果测试失败（常见原因和排查）：**

| 错误信息 | 原因 | 修复方式 |
|----------|------|----------|
| `cannot find type 'ConversationRewindCoordinator'` | 文件未加入 target | 检查 pbxproj，确认文件在 agentGui target 的 Sources 中 |
| `cascade delete did not remove AgentRound` | Schema 未包含 AgentRound | 确认 `makeContainer()` 中 Schema 包含所有四个模型 |
| `notification not received` | 通知在非主线程发出 | 确认测试和实现都在 `@MainActor` 上 |
| `remaining.count == 3` 但期望 1 | session.messages 解析问题 | 检查 session 的 messages 关系是否通过 inverse 正确建立 |

### Step 2: 若测试全部通过，继续下一步

---

## Task 4: AgentRound 模型补充检查

在写 Task 2 的实现之前，需要确认 `AgentRound` 是否有 `id` 字段（测试中用 `round.id`）。

```bash
grep -n "var id" /Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentRound.swift | head
```

**预期：** 输出包含 `var id: UUID`。若无，将测试中 `round.id` 改为其他唯一标识字段（如 `roundIndex`）。

同样确认 `ToolCall` 的 `id` 字段：

```bash
grep -n "var id" /Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift | head
```

---

## Task 5: 注册到 Xcode 项目（pbxproj）

### Step 1: 确认两个文件已被 Xcode 识别

在 Xcode 中检查 Project Navigator，确认：
1. `agentGui/Services/Rewind/ConversationRewindCoordinator.swift` 在 **agentGui** target 的 Compile Sources 中
2. `agentGuiTests/ConversationRewindCoordinatorTests.swift` 在 **agentGuiTests** target 的 Compile Sources 中

如果通过命令行创建了文件但 Xcode 没有识别，在 Xcode 中右键 Services/Rewind 目录 → "Add Files to agentGui"。

### Step 2: 全量 smoke test（可选，验证没有破坏其他测试）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rc1-smoke-derived \
  -only-testing:agentGuiTests/ConversationRewindCoordinatorTests \
  -only-testing:agentGuiTests/ConversationCheckpointServiceTests \
  -only-testing:agentGuiTests/ConversationCheckpointModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Case|TEST SUCCEEDED|TEST FAILED"
```

---

## Task 6: Commit

```bash
cd /Volumes/T7/文稿/Projects/agentGui

git add \
  agentGui/Services/Rewind/ConversationRewindCoordinator.swift \
  agentGuiTests/ConversationRewindCoordinatorTests.swift \
  agentGui.xcodeproj/project.pbxproj

git commit -m "feat(rewind): implement R-C1 ConversationRewindCoordinator

- Add ConversationRewindCoordinator (@MainActor) with rewindTo(message:)
- Cascade-deletes targetMessage and all subsequent messages (sequence >=)
- Posts rewindDidPruneConversation notification with sessionID
- Add RewindError.messageNotAttachedToSession
- Add Notification.Name.rewindDidPruneConversation
- Add 8 unit tests covering deletion, cascade, isolation, notification

Follows Claude Code rewindConversationTo semantics:
target message itself is removed (slice(0, messageIndex) equivalent).
Loop cancellation is R-C4's responsibility, not R-C1.

Refs: docs/plans/2026-04-04-rewind-feature-design.md#R-C1"
```

---

## 附录 A: 关键设计决策

### A.1 为何目标消息本身也被删除

Claude Code 的 `rewindConversationTo(message)` 执行 `prev.slice(0, messageIndex)` — 索引 `messageIndex` **不包含**在结果中，即目标 `UserMessage` 也被移除。agentGui 的語義保持一致：删除 `sequence >= targetMessage.sequence` 的所有消息。

上层 R-C4 `RewindTransactionCoordinator` 若设置 `repopulateInput: true`，会在截断后把目标消息的 `textContent` 填回输入框，让用户可以重新提交或修改。

### A.2 为何不在 R-C1 中注入 runtimeCoordinator

设计文档示例中的 `init(modelContext:runtimeCoordinator:)` 是早期草案。经探索，`ConversationExecutionRuntimeCoordinator.reconcileRuntimeRetention` 需要 `registry` 和 `modelContext` 参数，不适合在 cascade delete 中途调用。且 R-C1 的依赖标注为"无"，注入外部服务违反此约束。运行时清理由 R-C4 统一协调。

### A.3 通知 vs. 回调 vs. Combine

选用 `NotificationCenter` 的理由：
1. `AgentTeamWorkbenchPresentation` 是 `struct`（值类型），无法持有回调
2. `AgentLoopRunner` 可能在 rewind 后被重新创建，闭包引用不稳定
3. 全局通知与 `session.sessionId` 作为 `object` 使过滤精准，不依赖调用方传入闭包

### A.4 `@MainActor` 与 SwiftData 线程安全

SwiftData 的 `mainContext` 必须在主线程访问。`ConversationRewindCoordinator` 标 `@MainActor`，确保 `modelContext.delete` 和 `modelContext.save` 都在主队列执行。测试文件同样标 `@MainActor` 与 `@Suite`，让 Swift Testing 在主 actor 上运行所有测试。

---

## 附录 B: 与 R-C2 的协作（供参考）

R-C2 `FileSystemRewindCoordinator` 对应 Claude Code 的 `fileHistoryRewind(messageId)` — 文件系统层面的恢复。R-C1 和 R-C2 是平级组件，均在 R-C4 中被顺序调用：

```swift
// R-C4 伪代码（实际在 RewindTransactionCoordinator.execute 中）
try await fileSystemCoordinator.rewind(to: checkpoint)     // R-C2
try await conversationCoordinator.rewindTo(message: msg)   // R-C1
```

R-C1 完成后发出的 `.rewindDidPruneConversation` 通知，R-C2 的文件恢复结果由 R-C4 汇总后一并展示给用户（R-D5 RewindStatusHUD）。

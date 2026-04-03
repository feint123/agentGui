# F-B3 CompactionCoordinator Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现 `CompactionCoordinator`，在 built-in agent loop 每轮 round 结束后，当 `ContextWindowBudgetTracker` 报告 `.autoCompactReady` 状态时，自动调用 Claude API 生成对话历史摘要并替换旧消息数组，通过三次连续失败熔断机制防止反复无效 API 消耗。同时**移除**已有的 `ClaudeService+ContextCompression.swift` 旧压缩机制（70% 阈值，JSON 提取），并集成 M-11 `SessionMemoryService` 写入的 `summary.md` 作为压缩消息中的 session 历史上下文。

**Architecture:** 分三层设计，各层单独测试：
1. `CompactionEngine`（纯消息变换，无副作用）—— 用 `MessageInvariantValidator` 计算安全截断点，并构建压缩后消息数组。
2. `CompactionCoordinator`（actor）—— 管理熔断状态（`consecutiveFailures`）和并发锁（`isCompacting`），持有 `CompactionEngine` 并协调 API 调用。
3. `ClaudeService+Compaction`（API 扩展）—— 使用 `service.createMessage()` 非流式调用生成摘要文本，包含完整压缩 system prompt。

集成路径：在 `AgentLoopSharedStateAccess` 新增两个闭包（`readContextBudget` + `runCompactionIfNeeded`），在 `AgentLoopRunner.run()` 的每轮末尾触发；`ClaudeService+AgenticLoop.swift` 负责闭包实现；`BuiltInSessionExecutionContext` 持有 per-session `CompactionCoordinator` 实例。

**Tech Stack:** Swift 6.0+, SwiftAnthropic, 现有 `ContextWindowBudgetTracker` (F-B1), `MessageInvariantValidator` (F-B2)

**参考源码（Claude Code）：**
- `src/services/compact/autoCompact.ts` —— 熔断逻辑、`autoCompactIfNeeded()`、`MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES = 3`
- `src/services/compact/compact.ts` —— `compactConversation()`、`buildPostCompactMessages()`、`CompactionResult`
- `src/services/compact/sessionMemoryCompact.ts` —— `adjustIndexToPreserveAPIInvariants()` 不变量对齐
- `src/services/compact/prompt.ts` —— `BASE_COMPACT_PROMPT`（9 节摘要结构）

---

## 关键设计决策

### 1. CompactionCoordinator 是 actor，不是 @MainActor struct

`CompactionCoordinator` 的 `beginCompaction()` 和 `recordResult()` 需要原子性：begin-check 和 lock-acquire 必须是不可中断的单个 actor hop，防止并发触发两次压缩。`@MainActor struct` 做不到这一点，因为两次 `await sharedState.xxx` 之间可能有 suspension point。

### 2. 摘要以 user 角色注入，不使用系统消息

`MessageParameter.Message` 只有 `.user` / `.assistant` 两种 role。压缩边界和摘要以一条 user 角色消息注入，格式为：

```
[Conversation history has been compacted]

<summary>
...9 节摘要...
</summary>
```

这与 Claude Code `createCompactBoundaryMessage` + `summaryMessages` 合并的效果等价。

### 3. 保留尾部比例 25%，最少 8 条

`CompactionEngine.proposeCutIndex()` 默认保留末尾 25% 的消息（最少 8 条），然后通过 `MessageInvariantValidator.adjustedStartIndex()` 向前调整，确保 `tool_use/tool_result` 配对不被拆断。不使用固定条数截断，因为消息长度差异大（一条工具结果可能有 16 KB）。

### 4. `summary.md` 覆盖了 ContextMemory 的职责，不需要 ContextMemory

`SessionMemoryService`（M-11）写入的 `summary.md` 已包含会话中积累的目标、已完成动作、关键文件、失败记录等结构化信息，与旧 `ContextMemory` struct 的内容高度重叠。F-B3 直接读取 `summary.md` 注入压缩消息，无需维护额外的 `ContextMemory` 层。

因此：`loopMemory: ContextMemory` 字段从 `AgentLoopRunState` 移除；`ContextMemory.swift` 不需要创建；`ClaudeService+ContextCompression.swift` 整体删除，不迁移任何内容。

### 5. 对应 Claude Code 参数映射

| Claude Code 常量 | agentGui 等价 |
|---|---|
| `MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES = 3` | `CompactionCoordinator.maxConsecutiveFailures = 3` |
| `AUTOCOMPACT_BUFFER_TOKENS = 13_000` | 已在 `ContextWindowBudgetTracker` 实现 (F-B1) |
| `buildPostCompactMessages()` | `CompactionEngine.buildCompactedMessages()` |
| `adjustIndexToPreserveAPIInvariants()` | `MessageInvariantValidator.adjustedStartIndex()` (F-B2) |

### 6. 移除旧有压缩机制（`ClaudeService+ContextCompression.swift`）

代码审查发现项目中已存在一个早期压缩实现：

| 旧机制 | 新 F-B3 机制 |
|---|---|
| `ClaudeService+ContextCompression.swift` | `CompactionCoordinator` + `CompactionEngine` + `ClaudeService+Compaction.swift` |
| 触发阈值：70% context window（`compressionThreshold = 0.7`） | 触发阈值：`autoCompactReady`（`ContextWindowBudgetTracker` F-B1，~93% 有效窗口） |
| 保留最近 6 条消息（固定数量） | 保留末尾 25%（最少 8 条），并通过 `MessageInvariantValidator` 调整不变量 |
| JSON 结构化提取 → `ContextMemory`（`buildHierarchicalMemory()`） | 9 节 Markdown 摘要（对应 Claude Code `BASE_COMPACT_PROMPT`） |
| 无熔断器、无并发互斥 | 三次连续失败熔断（`maxConsecutiveFailures = 3`），`isCompacting` 互斥锁 |
| `memory: inout ContextMemory` —— 结构化 JSON 记忆 | 不再需要（由 `summary.md` 替代） |

**实施要求（Task 0）：**
1. 整体删除 `agentGui/Services/ClaudeService/ClaudeService+ContextCompression.swift`（含 `ContextMemory` struct，不迁移）
2. 移除 `AgentLoopRunState.swift` 中的 `var loopMemory: ContextMemory` 字段及其初始化
3. 移除 `AgentLoopRoundExecutor.swift` 第 182 行的 `compressIfNeeded()` 调用及其参数

### 7. `summary.md` 集成（M-11 已实现的 session memory）

代码审查确认 `SessionMemoryService`（M-11）已完整实现，且写入 `~/.agentgui/sessions/{sessionId}/session-memory/summary.md`。当前该文件**只写不读**（未在主 agent loop 中注入）。

F-B3 在 `runCompactionIfNeeded` 闭包中集成 `summary.md`：压缩前读取已有 session summary，将其作为"已积累的 session 上下文"注入到压缩后消息的首条 user 消息中，充当 Claude Code `trySessionMemoryCompaction()` 的 agentGui 等价路径。

这样压缩后的上下文持有两层信息：
1. **session memory**（`summary.md`，M-11 写入的 Markdown 摘要，含目标/已完成动作/关键文件等）
2. **本次压缩摘要**（对被截断历史的 9 节 Markdown 摘要，Claude API 生成）

对应 Claude Code 参数映射更新：

| Claude Code 常量 | agentGui 等价 |
|---|---|
| `trySessionMemoryCompaction()` | `runCompactionIfNeeded` 读取并注入 `summary.md` |
| session memory 注入到 compact 摘要 | `summary.md` 内容作为压缩消息首节 |

---

## 新增 / 修改 / 删除文件一览

**新增：**
```
agentGui/Services/ContextGovernance/CompactionEngine.swift
agentGui/Services/ContextGovernance/CompactionCoordinator.swift
agentGui/Services/ClaudeService/ClaudeService+Compaction.swift
agentGuiTests/CompactionEngineTests.swift
agentGuiTests/CompactionCoordinatorTests.swift
```

**修改：**
```
agentGui/Services/Execution/BuiltInSessionExecutionRegistry.swift  ← 新增 compactionCoordinator per-session
agentGui/Models/AgentLoopSharedStateAccess.swift                   ← 新增两个闭包
agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift    ← 实现闭包（含读 summary.md）
agentGui/Services/AgentLoopRunner.swift                            ← 触发压缩
agentGui/Models/AgentLoopRunState.swift                            ← 移除 loopMemory: ContextMemory 字段（Task 0）
agentGui.xcodeproj/project.pbxproj                                 ← 新文件注册（最后 Task）
```

**删除：**
```
agentGui/Services/ClaudeService/ClaudeService+ContextCompression.swift  ← 旧机制，被 F-B3 替代（Task 0）
```

**同时移除的调用点：**
```
agentGui/Services/AgentLoopRoundExecutor.swift:182  ← compressIfNeeded() 调用（Task 0）
agentGui/Models/AgentLoopRunState.swift              ← loopMemory: ContextMemory 字段（Task 0）
```

---

## 验收标准总览

- [x] 对话在 `autoCompactReady` 状态触发压缩后，消息数组长度显著减少（< 原来的 50%）
- [x] 压缩后 agent 继续正常运行，不出现 400 API 错误（tool_use/tool_result 配对完整）
- [x] 连续 3 次压缩失败后，不再发起新的压缩 API 调用（熔断器生效）
- [x] 同时只有一次压缩在进行（`isCompacting` 互斥锁）
- [x] `summary.md`（M-11）内容被注入到压缩消息中，保留 session 历史上下文
- [x] 单元测试覆盖所有 `CompactionEngine` 边界条件
- [x] 单元测试覆盖所有 `CompactionCoordinator` 状态转换

---

## Task 0：移除旧有压缩机制（前置清理）

> **⚠️ 必须先于 Task 1-9 完成。** 旧机制占用相同调用路径；`ContextMemory` struct 不再需要（由 `summary.md` 覆盖），整体删除。

**Files:**
- Delete: `agentGui/Services/ClaudeService/ClaudeService+ContextCompression.swift`（整体删除，不迁移任何内容）
- Modify: `agentGui/Models/AgentLoopRunState.swift` ← 移除 `loopMemory: ContextMemory` 字段
- Modify: `agentGui/Services/AgentLoopRoundExecutor.swift` ← 移除 `compressIfNeeded()` 调用

---

### Step 1: 删除 `ClaudeService+ContextCompression.swift`

先确认无其他调用点：
```bash
grep -rn "buildCombinedMemoryText\|compressIfNeeded\|buildHierarchicalMemory\|ContextMemory" \
  agentGui/ --include="*.swift"
```

预期只有 `ClaudeService+ContextCompression.swift`、`AgentLoopRunState.swift`（`loopMemory` 字段，Step 2 处理）、`AgentLoopRoundExecutor.swift`（`memory: &state.loopMemory`，Step 3 处理）三处。确认无其他引用后，删除文件：
```bash
git rm agentGui/Services/ClaudeService/ClaudeService+ContextCompression.swift
```

### Step 2: 移除 `AgentLoopRunState.swift` 中的 `loopMemory` 字段

找到 `AgentLoopRunState.swift` 中包含 `loopMemory` 的行，将该字段定义及初始化参数全部移除。`ContextMemory` 类型引用随之消失，无需额外 import 清理（`ContextMemory` 定义在被删除的文件中）。

---

### Step 3: 移除 `AgentLoopRoundExecutor.swift` 中的 `compressIfNeeded()` 调用

找到 `AgentLoopRoundExecutor.swift` 中：
```swift
// 压缩发生在真正发起下一次模型调用之前，这样 token 统计和 stream 输入看到的是同一份 messages。
await claudeService.compressIfNeeded(
    messages: &messages,
    memory: &state.loopMemory,
    service: request.service,
    modelId: modelId,
    sessionId: sessionId
)
```

将整个调用块（含注释）删除。

---

### Step 4: 编译验证

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：Build succeeded，无 `compressIfNeeded` / `ContextMemory` / `loopMemory` 相关编译错误。

---

### Step 5: Commit

```bash
git add agentGui/Models/AgentLoopRunState.swift \
        agentGui/Services/AgentLoopRoundExecutor.swift
git rm agentGui/Services/ClaudeService/ClaudeService+ContextCompression.swift
git commit -m "refactor(F-B3/Task0): remove legacy compressIfNeeded and ContextMemory entirely"
```

---

## Task 1：CompactionEngine（纯消息变换）

**Files:**
- Create: `agentGui/Services/ContextGovernance/CompactionEngine.swift`
- Test: `agentGuiTests/CompactionEngineTests.swift`

**Step 1: 写失败测试——proposeCutIndex 基础场景**

```swift
// agentGuiTests/CompactionEngineTests.swift
import XCTest
import SwiftAnthropic
@testable import agentGui

final class CompactionEngineTests: XCTestCase {

    private let engine = CompactionEngine()

    // MARK: - Helper factories

    private func textMsg(_ role: MessageParameter.Message.Role, _ text: String = "x") -> MessageParameter.Message {
        MessageParameter.Message(role: role, content: .text(text))
    }

    private func assistantMsg(toolUseIds: [String]) -> MessageParameter.Message {
        .init(role: .assistant, content: .list(toolUseIds.map { .toolUse($0, "bash", [:]) }))
    }

    private func userMsg(toolUseIds: [String]) -> MessageParameter.Message {
        .init(role: .user, content: .list(toolUseIds.map { .toolResult($0, "out", isError: nil) }))
    }

    // MARK: - proposeCutIndex

    func test_proposeCutIndex_emptyMessages_returnsZero() {
        let idx = engine.proposeCutIndex(in: [])
        XCTAssertEqual(idx, 0)
    }

    func test_proposeCutIndex_fewerThanMinimum_returnsZero() {
        // 4 条消息 < minimumKeepRecentCount(8) → cut at 0
        let msgs = (0..<4).map { _ in textMsg(.user) }
        let idx = engine.proposeCutIndex(in: msgs)
        XCTAssertEqual(idx, 0)
    }

    func test_proposeCutIndex_exactlyMinimum_returnsZero() {
        let msgs = (0..<8).map { _ in textMsg(.user) }
        let idx = engine.proposeCutIndex(in: msgs)
        XCTAssertEqual(idx, 0)
    }

    func test_proposeCutIndex_largeHistory_keepsApproximatelyQuarter() {
        // 40 条 → keep 25% = 10；raw cut = 30
        let msgs = (0..<40).map { _ in textMsg(.user) }
        let idx = engine.proposeCutIndex(in: msgs)
        XCTAssertEqual(idx, 30)
    }

    func test_proposeCutIndex_adjustsForOrphanToolResult() {
        // index [0]: text-user
        // index [1]: assistant (tool_use A)
        // index [2]: user (tool_result A)
        // index [3..]: 20 more messages
        // 若 raw cut = 2（keep [2...]），tool_result A 需要前面的 tool_use A（index 1），故调整到 1
        var msgs: [MessageParameter.Message] = [
            textMsg(.user),
            assistantMsg(toolUseIds: ["A"]),
            userMsg(toolUseIds: ["A"])
        ]
        msgs += (0..<25).map { _ in textMsg(.user) }   // 28 total
        // raw keep = max(8, 28*0.25=7) = 8 → raw cut = 20；index 20 is a text-user, no adjustment needed
        // Make a tighter scenario: 12 items, cut prob at index 9
        let smallMsgs: [MessageParameter.Message] = [
            textMsg(.user, "first"),                    // 0
            textMsg(.user, "second"),                   // 1
            textMsg(.user, "third"),                    // 2
            textMsg(.user, "fourth"),                   // 3
            assistantMsg(toolUseIds: ["T1"]),           // 4  tool_use T1
            userMsg(toolUseIds: ["T1"]),                // 5  tool_result T1
            textMsg(.assistant),                       // 6
            textMsg(.user),                            // 7
            textMsg(.assistant),                       // 8
            textMsg(.user),                            // 9
            textMsg(.assistant),                      // 10
            textMsg(.user),                           // 11
        ]
        // 12 msgs, keep 25% = 3, rawCut = 9; kept[9...] = [9,10,11]
        // index 9 is user text, no tool_result → no adjustment needed → cut stays at 9
        let idx2 = engine.proposeCutIndex(in: smallMsgs)
        XCTAssertEqual(idx2, 9)
    }

    func test_proposeCutIndex_adjustsBack_whenToolResultIsAtCutBoundary() {
        // Build 12 messages where kept range starts with a user/tool_result
        // that needs the preceding assistant/tool_use
        // [0..7]: text messages (8 items)
        // [8]: assistant tool_use X
        // [9]: user tool_result X
        // [10]: assistant text
        // [11]: user text
        // 12 total, keep 25% = 3, rawCut = 9
        // kept = [9,10,11]; index 9 has tool_result X → needs tool_use X at index 8 → adjust to 8
        let msgs: [MessageParameter.Message] = (0..<8).map { _ in textMsg(.user) }
            + [
                assistantMsg(toolUseIds: ["X"]),      // 8
                userMsg(toolUseIds: ["X"]),            // 9
                textMsg(.assistant),                  // 10
                textMsg(.user),                       // 11
            ]
        let idx = engine.proposeCutIndex(in: msgs)
        XCTAssertEqual(idx, 8)  // adjusted back from 9 to 8
    }

    // MARK: - buildCompactedMessages

    func test_buildCompactedMessages_replacesHeadWithSummaryUserMessage() {
        let msgs = (0..<10).map { i in textMsg(i % 2 == 0 ? .user : .assistant, "msg\(i)") }
        let result = engine.buildCompactedMessages(original: msgs, summaryText: "summary text", cutIndex: 6)
        // result = [summary user msg] + msgs[6..9]
        XCTAssertEqual(result.count, 5)  // 1 summary + 4 kept
        guard case .text(let first) = result[0].content else {
            XCTFail("First message must be text"); return
        }
        XCTAssertTrue(first.contains("summary text"))
        XCTAssertTrue(first.contains("[Conversation history has been compacted]"))
    }

    func test_buildCompactedMessages_summaryMessageHasUserRole() {
        let msgs = (0..<10).map { _ in textMsg(.user) }
        let result = engine.buildCompactedMessages(original: msgs, summaryText: "s", cutIndex: 8)
        XCTAssertEqual(result[0].role, "user")
    }

    func test_buildCompactedMessages_cutIndexAtEnd_returnsJustSummary() {
        let msgs = (0..<5).map { _ in textMsg(.user) }
        let result = engine.buildCompactedMessages(original: msgs, summaryText: "s", cutIndex: 5)
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - buildCompactedMessages with sessionSummary (M-11 summary.md integration)

    func test_buildCompactedMessages_withSessionSummary_includesSummarySection() {
        let msgs = (0..<10).map { _ in textMsg(.user) }
        let result = engine.buildCompactedMessages(
            original: msgs, summaryText: "compact summary", cutIndex: 8,
            sessionSummary: "Session memory: previously worked on X")
        guard case .text(let text) = result[0].content else { XCTFail(); return }
        XCTAssertTrue(text.contains("Session memory: previously worked on X"))
        XCTAssertTrue(text.contains("Session Memory"))
    }

    func test_buildCompactedMessages_nilSessionSummary_noSessionMemorySection() {
        let msgs = (0..<10).map { _ in textMsg(.user) }
        let result = engine.buildCompactedMessages(
            original: msgs, summaryText: "s", cutIndex: 8, sessionSummary: nil)
        guard case .text(let text) = result[0].content else { XCTFail(); return }
        XCTAssertFalse(text.contains("Session Memory"))
    }
}
```

**Step 2: 运行测试验证失败**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CompactionEngineTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译失败（`CompactionEngine` 不存在）

**Step 3: 实现 CompactionEngine**

```swift
// agentGui/Services/ContextGovernance/CompactionEngine.swift
import Foundation
import SwiftAnthropic

// MARK: - CompactionEngine

/// 纯无副作用的消息压缩变换器。
/// 职责：
///   1. 用 MessageInvariantValidator 计算安全截断起点（proposeCutIndex）
///   2. 将摘要文本 + 保留尾部拼装成新消息数组，可选附加 session memory（buildCompactedMessages）
///
/// 摘要消息结构（两层）：
///   1. `<summary>` —— Claude API 生成的 9 节 Markdown 摘要
///   2. `### Session Memory` —— M-11 summary.md 内容（可选，文件不存在时省略）
///
/// 对应 Claude Code compact.ts 中 buildPostCompactMessages() + sessionMemoryCompact.ts 的不变量对齐逻辑。
struct CompactionEngine: Sendable {

    private let validator = MessageInvariantValidator()

    /// 保留末尾消息的默认比例（25%），最少 8 条。
    static let defaultKeepRecentFraction: Double = 0.25
    static let minimumKeepRecentCount: Int = 8

    // MARK: - Public API

    /// 计算安全截断起点。保留 `messages[cutIndex...]`，截断 `messages[..<cutIndex]`。
    ///
    /// 先按比例算 rawCut，再通过 `MessageInvariantValidator.adjustedStartIndex()` 向前调整，
    /// 确保 kept range 内的 tool_result 都能在 kept range 内找到对应 tool_use。
    ///
    /// - Parameters:
    ///   - messages: 完整消息数组。
    ///   - keepRecentFraction: 末尾保留比例（默认 0.25）。
    /// - Returns: 安全截断起点，范围 `[0, messages.count]`。
    func proposeCutIndex(
        in messages: [MessageParameter.Message],
        keepRecentFraction: Double = CompactionEngine.defaultKeepRecentFraction
    ) -> Int {
        guard !messages.isEmpty else { return 0 }
        let keepCount = max(
            Self.minimumKeepRecentCount,
            Int(Double(messages.count) * keepRecentFraction)
        )
        let rawCut = max(0, messages.count - keepCount)
        return validator.adjustedStartIndex(rawCut, in: messages)
    }

    /// 构建压缩后消息数组。
    ///
    /// 结构：`[summaryUserMessage] + messages[cutIndex...]`
    ///
    /// summaryUserMessage 格式：
    /// ```
    /// [Conversation history has been compacted]
    ///
    /// <summary>
    /// {summaryText}
    /// </summary>
    ///
    /// --- (仅在 sessionSummary 非空时出现)
    /// ### Session Memory
    /// {sessionSummary}
    /// ```
    ///
    /// - Parameters:
    ///   - original: 压缩前完整消息数组。
    ///   - summaryText: 对话历史摘要（来自 ClaudeService API）。
    ///   - cutIndex: proposeCutIndex() 的返回值。
    ///   - sessionSummary: 可选 M-11 session memory（summary.md 内容），作为附加节注入。
    /// - Returns: 新消息数组。
    func buildCompactedMessages(
        original: [MessageParameter.Message],
        summaryText: String,
        cutIndex: Int,
        sessionSummary: String? = nil
    ) -> [MessageParameter.Message] {
        let keptMessages = cutIndex < original.count ? Array(original[cutIndex...]) : []

        var content = "[Conversation history has been compacted]\n\n<summary>\n\(summaryText)\n</summary>"

        // 注入 M-11 session memory（summary.md）—— 对应 Claude Code trySessionMemoryCompaction() 路径
        if let sessionMem = sessionSummary, !sessionMem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content += "\n\n---\n### Session Memory\n\(sessionMem)"
        }

        let summaryMessage = MessageParameter.Message(role: .user, content: .text(content))
        return [summaryMessage] + keptMessages
    }
}
```

**Step 4: 运行测试验证通过**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CompactionEngineTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：所有 `CompactionEngineTests` 通过（含新增的 `sessionSummary` 测试）

**Step 5: Commit**

```bash
git add agentGui/Services/ContextGovernance/CompactionEngine.swift \
        agentGuiTests/CompactionEngineTests.swift
git commit -m "feat(F-B3): add CompactionEngine with sessionSummary (summary.md) injection support"
```

---

## Task 2：CompactionCoordinator actor（熔断状态机）

**Files:**
- Create: `agentGui/Services/ContextGovernance/CompactionCoordinator.swift`
- Test: `agentGuiTests/CompactionCoordinatorTests.swift`

**Step 1: 写失败测试**

```swift
// agentGuiTests/CompactionCoordinatorTests.swift
import XCTest
@testable import agentGui

final class CompactionCoordinatorTests: XCTestCase {

    // MARK: - Initial State

    func test_initialState_canAttempt_isTrue() async {
        let c = CompactionCoordinator()
        let state = await c.trackingState
        XCTAssertTrue(state.canAttempt)
        XCTAssertFalse(state.isCircuitBreakerTripped)
        XCTAssertFalse(state.isCompacting)
        XCTAssertFalse(state.hasCompacted)
    }

    // MARK: - beginCompaction

    func test_beginCompaction_returnsTrue_andSetsIsCompacting() async {
        let c = CompactionCoordinator()
        let started = await c.beginCompaction()
        XCTAssertTrue(started)
        let state = await c.trackingState
        XCTAssertTrue(state.isCompacting)
    }

    func test_beginCompaction_returnsFalse_whenAlreadyCompacting() async {
        let c = CompactionCoordinator()
        _ = await c.beginCompaction()
        let second = await c.beginCompaction()
        XCTAssertFalse(second)
    }

    // MARK: - recordSuccess

    func test_recordSuccess_resetsFailureCount_andClearsCompacting() async {
        let c = CompactionCoordinator()
        _ = await c.beginCompaction()
        await c.recordFailure()
        _ = await c.beginCompaction()
        await c.recordSuccess()
        let state = await c.trackingState
        XCTAssertEqual(state.consecutiveFailures, 0)
        XCTAssertFalse(state.isCompacting)
        XCTAssertTrue(state.hasCompacted)
    }

    // MARK: - recordFailure

    func test_recordFailure_incrementsCount_andClearsCompacting() async {
        let c = CompactionCoordinator()
        _ = await c.beginCompaction()
        await c.recordFailure()
        let state = await c.trackingState
        XCTAssertEqual(state.consecutiveFailures, 1)
        XCTAssertFalse(state.isCompacting)
    }

    // MARK: - Circuit Breaker

    func test_circuitBreaker_tripsAfterThreeFailures() async {
        let c = CompactionCoordinator()
        for _ in 0..<3 {
            _ = await c.beginCompaction()
            await c.recordFailure()
        }
        let state = await c.trackingState
        XCTAssertTrue(state.isCircuitBreakerTripped)
        XCTAssertFalse(state.canAttempt)
    }

    func test_circuitBreaker_preventsBeginCompaction_afterTripping() async {
        let c = CompactionCoordinator()
        for _ in 0..<3 {
            _ = await c.beginCompaction()
            await c.recordFailure()
        }
        let result = await c.beginCompaction()
        XCTAssertFalse(result)
    }

    func test_circuitBreaker_doesNotTrip_afterTwoFailures() async {
        let c = CompactionCoordinator()
        for _ in 0..<2 {
            _ = await c.beginCompaction()
            await c.recordFailure()
        }
        let state = await c.trackingState
        XCTAssertFalse(state.isCircuitBreakerTripped)
        XCTAssertTrue(state.canAttempt)
    }

    func test_successResetsCircuitBreaker_allowsFurtherAttempts() async {
        let c = CompactionCoordinator()
        // 2 failures then succeed
        for _ in 0..<2 {
            _ = await c.beginCompaction()
            await c.recordFailure()
        }
        _ = await c.beginCompaction()
        await c.recordSuccess()
        // failure count reset to 0
        _ = await c.beginCompaction()
        await c.recordFailure()
        let state = await c.trackingState
        XCTAssertEqual(state.consecutiveFailures, 1)
        XCTAssertFalse(state.isCircuitBreakerTripped)
    }
}
```

**Step 2: 运行测试验证失败**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CompactionCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译失败

**Step 3: 实现 CompactionCoordinator**

```swift
// agentGui/Services/ContextGovernance/CompactionCoordinator.swift
import Foundation

// MARK: - CompactionTrackingState

/// CompactionCoordinator 的只读状态快照。在 @MainActor 上下文中安全传递。
struct CompactionTrackingState: Equatable, Sendable {
    let consecutiveFailures: Int
    let hasCompacted: Bool
    let isCompacting: Bool

    /// 连续失败达到上限，停止重试。对应 Claude Code MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES = 3。
    var isCircuitBreakerTripped: Bool { consecutiveFailures >= CompactionCoordinator.maxConsecutiveFailures }

    /// 当前是否可发起新的压缩。
    var canAttempt: Bool { !isCompacting && !isCircuitBreakerTripped }
}

// MARK: - CompactionCoordinator

/// per-session actor：管理 auto-compact 的熔断状态与并发互斥。
///
/// 对应 Claude Code autoCompact.ts `AutoCompactTrackingState` + 熔断逻辑。
///
/// 调用方式：
/// ```swift
/// guard await coordinator.beginCompaction() else { return }
/// do {
///     let summary = try await generateSummary(...)
///     messages = engine.buildCompactedMessages(...)
///     await coordinator.recordSuccess()
/// } catch {
///     await coordinator.recordFailure()
/// }
/// ```
actor CompactionCoordinator {

    // MARK: - Constants

    /// 连续失败上限。BQ 2026-03-10: 1,279 个 session 出现 50+ 次连续失败，
    /// 每天浪费 ~25 万次 API 调用。对应 Claude Code MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES = 3。
    static let maxConsecutiveFailures: Int = 3

    // MARK: - State

    private(set) var consecutiveFailures: Int = 0
    private(set) var hasCompacted: Bool = false
    private(set) var isCompacting: Bool = false

    // MARK: - State Machine

    /// 尝试开始一次压缩。
    /// - Returns: `true` 表示成功取得锁，调用方应继续执行压缩；`false` 表示条件不满足（熔断或重入）。
    func beginCompaction() -> Bool {
        guard !isCompacting, consecutiveFailures < Self.maxConsecutiveFailures else { return false }
        isCompacting = true
        return true
    }

    /// 记录压缩成功：重置失败计数、释放锁、标记 hasCompacted。
    func recordSuccess() {
        consecutiveFailures = 0
        hasCompacted = true
        isCompacting = false
    }

    /// 记录压缩失败：增加失败计数、释放锁。
    func recordFailure() {
        consecutiveFailures += 1
        isCompacting = false
    }

    /// 返回当前只读快照（用于外部轮询、日志、测试）。
    var trackingState: CompactionTrackingState {
        CompactionTrackingState(
            consecutiveFailures: consecutiveFailures,
            hasCompacted: hasCompacted,
            isCompacting: isCompacting
        )
    }
}
```

**Step 4: 运行测试验证通过**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CompactionCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：所有 `CompactionCoordinatorTests` 通过

**Step 5: Commit**

```bash
git add agentGui/Services/ContextGovernance/CompactionCoordinator.swift \
        agentGuiTests/CompactionCoordinatorTests.swift
git commit -m "feat(F-B3): add CompactionCoordinator actor with circuit breaker"
```

---

## Task 3：ClaudeService+Compaction（API 调用 + 压缩提示词）

**Files:**
- Create: `agentGui/Services/ClaudeService/ClaudeService+Compaction.swift`
- No unit tests for this task（依赖真实 AnthropicService，由集成测试覆盖）

**Step 1: 创建文件**

```swift
// agentGui/Services/ClaudeService/ClaudeService+Compaction.swift
import Foundation
import SwiftAnthropic

// MARK: - CompactionError

enum CompactionError: LocalizedError {
    case serviceNotConfigured
    case emptySummaryResponse
    case circuitBreakerTripped

    var errorDescription: String? {
        switch self {
        case .serviceNotConfigured:  return "CompactionError: AnthropicService is not configured."
        case .emptySummaryResponse:  return "CompactionError: API returned empty summary text."
        case .circuitBreakerTripped: return "CompactionError: circuit breaker tripped, skipping compaction."
        }
    }
}

// MARK: - ClaudeService+Compaction

extension ClaudeService {

    // MARK: - Prompt

    /// 遵循 Claude Code BASE_COMPACT_PROMPT 的 9 节结构摘要提示词。
    /// 以 user 消息形式追加到消息列表尾部，不需要单独 system 参数。
    private static let compactionRequestMessage = """
    Please create a detailed summary of the conversation above. This summary will replace the full conversation history to preserve context while reducing token usage.

    Your summary MUST include these sections:

    1. **Primary Request and Intent** — What the user wants to accomplish (full detail, not abbreviated)
    2. **Key Technical Concepts** — Technologies, frameworks, APIs, architectures discussed
    3. **Files and Code Sections** — Every file examined or modified; include key code snippets, function signatures, and why each file mattered
    4. **Errors and Fixes** — Problems encountered, error messages, and how they were resolved; note any user-specific feedback or corrections
    5. **Problem Solving** — Decisions made, trade-offs discussed, approaches tried and discarded
    6. **All User Messages** — Verbatim or very close paraphrase of every user message (not tool results); these capture changing intent
    7. **Pending Tasks** — All work explicitly requested but not yet completed
    8. **Current Work** — Exactly what was being worked on immediately before this summary, with file paths and code snippets where relevant
    9. **Next Step** — The single most logical next action, directly derived from the most recent user request

    Output plain Markdown. Do not include XML tags, code fences around the whole response, or meta-commentary.
    Be thorough: this summary is the only context the assistant will have going forward.
    """

    // MARK: - Public

    /// 调用 Claude API 为当前对话历史生成压缩摘要文本。
    ///
    /// 使用 `service.createMessage()` 非流式调用，不影响主 agent loop 的消息时间线。
    /// 最大输出 token 设为 8192（同 Claude Code COMPACT_MAX_OUTPUT_TOKENS = 8192）。
    ///
    /// - Parameters:
    ///   - messages: 压缩前的完整消息数组（不含摘要请求消息本身）。
    ///   - modelId: 用于生成摘要的模型 ID（通常与主 loop 相同）。
    /// - Returns: 摘要文本（非空）。
    /// - Throws: `CompactionError.serviceNotConfigured` 或 `CompactionError.emptySummaryResponse`，或来自 API 的错误。
    func generateCompactionSummary(
        messages: [MessageParameter.Message],
        modelId: String
    ) async throws -> String {
        guard let service else { throw CompactionError.serviceNotConfigured }

        // 构建消息序列：完整历史 + 摘要请求
        var summaryMessages = messages
        summaryMessages.append(
            MessageParameter.Message(role: .user, content: .text(Self.compactionRequestMessage))
        )

        let params = MessageParameter(
            model: .other(modelId),
            messages: summaryMessages,
            maxTokens: 8192
        )

        let response = try await service.createMessage(params)
        let summaryText = response.content.compactMap { block -> String? in
            if case .text(let text, _) = block { return text }
            return nil
        }.joined()

        guard !summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompactionError.emptySummaryResponse
        }

        return summaryText
    }
}
```

**Step 2: 编译验证**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning:|Build succeeded"
```

预期：Build succeeded（无编译错误）

**Step 3: Commit**

```bash
git add agentGui/Services/ClaudeService/ClaudeService+Compaction.swift
git commit -m "feat(F-B3): add ClaudeService+Compaction with 9-section summary prompt"
```

---

## Task 4：BuiltInSessionExecutionContext / Registry——添加 compactionCoordinator

**Files:**
- Modify: `agentGui/Services/Execution/BuiltInSessionExecutionRegistry.swift`

**Step 1: 阅读现有文件结构**

打开 `agentGui/Services/Execution/BuiltInSessionExecutionRegistry.swift`，当前 `BuiltInSessionExecutionContext` 的结构：

```swift
@Observable
@MainActor
final class BuiltInSessionExecutionContext {
    let sessionID: String
    var currentInputTokens: Int = 0
    var currentModelID: String = ""
    var pendingUserQuestion: AskUserQuestionRequest?
    var contextBudgetState: ContextBudgetState?    // F-B1
}
```

**Step 2: 添加 compactionCoordinator 属性**

在 `contextBudgetState` 后新增一行：

```swift
    let compactionCoordinator: CompactionCoordinator = CompactionCoordinator()  // F-B3
```

完整 context 修改示意（精确 oldString/newString）：

```diff
-    var contextBudgetState: ContextBudgetState?    // F-B1
+    var contextBudgetState: ContextBudgetState?    // F-B1
+    let compactionCoordinator: CompactionCoordinator = CompactionCoordinator()  // F-B3
```

**Step 3: 编译验证**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

**Step 4: Commit**

```bash
git add agentGui/Services/Execution/BuiltInSessionExecutionRegistry.swift
git commit -m "feat(F-B3): add compactionCoordinator to BuiltInSessionExecutionContext"
```

---

## Task 5：AgentLoopSharedStateAccess——新增两个闭包

**Files:**
- Modify: `agentGui/Models/AgentLoopSharedStateAccess.swift`

**Step 1: 阅读当前文件**

```swift
struct AgentLoopSharedStateAccess {
    let readVerification: @MainActor (String) -> CompletionVerification?
    ...
    let updateContextBudget: @MainActor (ContextBudgetState) -> Void   // F-B1
}
```

**Step 2: 新增两个闭包**

在 `updateContextBudget` 后追加：

```swift
    // F-B3: 读取当前 session 的 context budget 状态（供 AgentLoopRunner 判断是否触发压缩）
    let readContextBudget: @MainActor () -> ContextBudgetState?
    // F-B3: 若 budget 状态满足触发条件，执行压缩并返回新消息数组；否则返回 nil
    let runCompactionIfNeeded: @MainActor ([MessageParameter.Message]) async -> [MessageParameter.Message]?
```

**Step 3: 更新所有 AgentLoopSharedStateAccess 构造点**

搜索所有创建 `AgentLoopSharedStateAccess(...)` 的地方：

```bash
grep -rn "AgentLoopSharedStateAccess(" agentGui/ --include="*.swift"
```

对每个构造点，补充两个新闭包的 stub 实现（Task 6 中完整实现）：

**主要构造点** 在 `ClaudeService+AgenticLoop.swift`，Task 6 完整实现。

**测试用构造点**（若有）：补充：
```swift
readContextBudget: { nil },
runCompactionIfNeeded: { _ in nil },
```

**Step 4: 编译验证**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

**Step 5: Commit**

```bash
git add agentGui/Models/AgentLoopSharedStateAccess.swift
git commit -m "feat(F-B3): add readContextBudget + runCompactionIfNeeded closures to AgentLoopSharedStateAccess"
```

---

## Task 6：ClaudeService+AgenticLoop——实现压缩闭包

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift`

**Step 1: 找到构建 AgentLoopSharedStateAccess 的代码段**

在该文件中搜索：
```bash
grep -n "AgentLoopSharedStateAccess\|updateContextBudget" \
  agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift
```

当前结构（概略）：
```swift
let sharedState = AgentLoopSharedStateAccess(
    readVerification: { ... },
    ...
    setCurrentInputTokens: { self.builtInExecutionContext(for: runtime.sessionId).currentInputTokens = $0 },
    updateContextBudget: { [weak self] state in
        self?.builtInExecutionContext(for: runtime.sessionId).contextBudgetState = state
    }
)
```

**Step 2: 添加两个闭包实现**

在 `updateContextBudget` 闭包之后添加：

```swift
            readContextBudget: { [weak self] in
                self?.builtInExecutionContext(for: runtime.sessionId).contextBudgetState
            },
            runCompactionIfNeeded: { [weak self] messages async -> [MessageParameter.Message]? in
                guard let self else { return nil }

                let context = self.builtInExecutionContext(for: runtime.sessionId)
                guard let budget = context.contextBudgetState,
                      budget.isAutoCompactReady else { return nil }

                let coordinator = context.compactionCoordinator
                guard await coordinator.beginCompaction() else { return nil }

                let engine = CompactionEngine()
                let cutIndex = engine.proposeCutIndex(in: messages)

                // 读取 M-11 SessionMemoryService 写入的 summary.md，作为 session 历史上下文
                // 对应 Claude Code trySessionMemoryCompaction() 的 agentGui 等价路径
                let summaryURL = ConfigDirectoryManager.shared.sessionMemorySummaryURL(sessionId: runtime.sessionId)
                let existingSessionSummary = (try? String(contentsOf: summaryURL, encoding: .utf8)) ?? ""

                do {
                    let summaryText = try await self.generateCompactionSummary(
                        messages: Array(messages[..<cutIndex]),  // 只摘要将被截断的部分
                        modelId: context.currentModelID
                    )
                    let newMessages = engine.buildCompactedMessages(
                        original: messages,
                        summaryText: summaryText,
                        cutIndex: cutIndex,
                        sessionSummary: existingSessionSummary.isEmpty ? nil : existingSessionSummary
                    )
                    await coordinator.recordSuccess()
                    return newMessages
                } catch {
                    await coordinator.recordFailure()
                    return nil
                }
            }
```

> **关键细节 1：** `generateCompactionSummary` 接收 `messages[..<cutIndex]`（仅截断部分），而不是完整数组。这减少了摘要请求的 token 数，并避免摘要请求本身因消息太多而触发 prompt-too-long。
>
> **关键细节 2：** `existingSessionSummary` 从 `ConfigDirectoryManager.shared.sessionMemorySummaryURL(sessionId:)` 读取，文件不存在时为空字符串，`buildCompactedMessages()` 以 `nil` 传入时不渲染 session memory 节。不需要 `ContextMemory`，两层（摘要 + session memory）已足够。

**Step 3: 编译验证**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

**Step 4: Commit**

```bash
git add agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift
git commit -m "feat(F-B3): implement runCompactionIfNeeded closure in ClaudeService+AgenticLoop"
```

---

## Task 7：AgentLoopRunner——触发压缩

**Files:**
- Modify: `agentGui/Services/AgentLoopRunner.swift`

**Step 1: 阅读当前循环体结构**

```swift
while state.loopCtx.shouldContinue && state.loopCtx.roundIndex < request.maxRounds {
    try Task.checkCancellation()

    let outcome = try await roundExecutor.executeStreamingRound(state: &state, messages: &messages)
    try await roundExecutor.applyPhaseOutcome(outcome: outcome, state: &state, messages: &messages)

    // Session Memory hook：每轮结束后检查阈值
    await emitter.emit(
        .willFinishRound,
        state: state,
        messages: messages,
        overrides: .init(metadata: [
            "roundIndex": state.loopCtx.roundIndex,
            "toolCallsThisRound": outcome.pendingTools.count
        ])
    )
}
```

**Step 2: 在 willFinishRound emit 之后添加压缩检查**

```swift
    // F-B3: AutoCompact — 若 budget 达到阈值，触发对话压缩
    if let budget = sharedState.readContextBudget(), budget.isAutoCompactReady {
        if let compactedMessages = await sharedState.runCompactionIfNeeded(messages) {
            messages = compactedMessages
        }
    }
```

完整修改后循环体：

```swift
while state.loopCtx.shouldContinue && state.loopCtx.roundIndex < request.maxRounds {
    try Task.checkCancellation()

    let outcome = try await roundExecutor.executeStreamingRound(state: &state, messages: &messages)
    try await roundExecutor.applyPhaseOutcome(outcome: outcome, state: &state, messages: &messages)

    await emitter.emit(
        .willFinishRound,
        state: state,
        messages: messages,
        overrides: .init(metadata: [
            "roundIndex": state.loopCtx.roundIndex,
            "toolCallsThisRound": outcome.pendingTools.count
        ])
    )

    // F-B3: AutoCompact — 若 budget 达到阈值，触发对话压缩
    if let budget = sharedState.readContextBudget(), budget.isAutoCompactReady {
        if let compactedMessages = await sharedState.runCompactionIfNeeded(messages) {
            messages = compactedMessages
        }
    }
}
```

**Step 3: 编译验证**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

**Step 4: Commit**

```bash
git add agentGui/Services/AgentLoopRunner.swift
git commit -m "feat(F-B3): trigger auto-compaction in AgentLoopRunner after each round"
```

---

## Task 8：注册新文件到 Xcode project

**Files:**
- Modify: `agentGui.xcodeproj/project.pbxproj`

**Step 1: 用 Xcode 打开项目**

在 Xcode 中，将以下新文件拖入对应 Group（确保 target `agentGui` 被勾选）：

```
agentGui/Services/ContextGovernance/CompactionEngine.swift
agentGui/Services/ContextGovernance/CompactionCoordinator.swift
agentGui/Services/ClaudeService/ClaudeService+Compaction.swift
```

将测试文件拖入 `agentGuiTests` group（target `agentGuiTests`）：

```
agentGuiTests/CompactionEngineTests.swift
agentGuiTests/CompactionCoordinatorTests.swift
```

**Step 2: 全量编译 + 测试**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CompactionEngineTests \
  -only-testing:agentGuiTests/CompactionCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：所有新增测试通过，无编译错误

**Step 3: 运行回归质量 smoke 测试**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/ContextWindowBudgetTrackerTests \
  -only-testing:agentGuiTests/MessageInvariantValidatorTests \
  -only-testing:agentGuiTests/CompactionEngineTests \
  -only-testing:agentGuiTests/CompactionCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：全部通过

**Step 4: Commit**

```bash
git add agentGui.xcodeproj/project.pbxproj
git commit -m "feat(F-B3): register new CompactionEngine, CompactionCoordinator, ClaudeService+Compaction files in Xcode"
```

---

## Task 9：查漏补缺——在所有 AgentLoopSharedStateAccess 构造点补全新闭包

**Files:**
- 根据 Task 5 Step 3 的搜索结果修改所有剩余的构造点

**Step 1: 搜索所有构造点**

```bash
grep -rn "AgentLoopSharedStateAccess(" agentGui/ agentGuiTests/ --include="*.swift"
```

**Step 2: 对非主路径构造点（通常在测试文件的 mock 构建中）补充 stub**

对每个测试辅助构造点追加：
```swift
readContextBudget: { nil },
runCompactionIfNeeded: { _ in nil },
```

**Step 3: 编译 + 全量现有测试**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:" | tail -40
```

预期：无新增失败

**Step 4: Final Commit**

```bash
git add -A
git commit -m "feat(F-B3): complete CompactionCoordinator integration — stub all AgentLoopSharedStateAccess construction sites"
```

---

## 验收检查清单

实现完成后，逐项确认：

- [ ] `CompactionEngineTests` 全部通过（尤其 `adjustsBack_whenToolResultIsAtCutBoundary`）
- [ ] `CompactionCoordinatorTests` 全部通过（尤其 `circuitBreaker_tripsAfterThreeFailures`）
- [ ] `MessageInvariantValidatorTests` 无回归
- [ ] `ContextWindowBudgetTrackerTests` 无回归
- [ ] `AgentLoopRunner.swift` 编译无 warning（Swift 6 concurrency）
- [ ] 在 `BuiltInSessionExecutionContext` 中每个 session 有独立 `CompactionCoordinator` 实例
- [ ] `generateCompactionSummary` 仅接收截断前半段消息（`messages[..<cutIndex]`）
- [ ] `runCompactionIfNeeded` 闭包在 `!budget.isAutoCompactReady` 时直接 return nil，不调用 actor
- [ ] `summary.md`（M-11 SessionMemoryService 写入）被读取并注入到压缩消息的 `Session Memory` 节
- [ ] 若 `summary.md` 不存在，压缩消息中无 `Session Memory` 节（不报错，优雅降级）
- [ ] `ClaudeService+ContextCompression.swift` 已整体删除，`compressIfNeeded()` 调用已移除
- [ ] `AgentLoopRunState.loopMemory: ContextMemory` 字段已移除
- [ ] xcodeproj 中所有新增 `.swift` 文件已注册，已删除文件已从 project 移除

---

## 已知限制与后续扩展点

| 限制 | 后续 Feature |
|------|------|
| `summary.md` 只读入、不更新（M-11 仍负责写入） | 压缩后可触发 M-11 强制刷新 summary.md（可选优化） |
| 压缩摘要不区分 pre-compaction 历史与当前 round | F-B5（ToolBatchSummaryService）可补充工具批次标签 |
| `generateCompactionSummary` 使用主模型，成本较高 | 后续可用 Haiku 等小模型替代（参考 F-B5 的 small model 模式） |
| 不记录压缩事件到执行时间线 | 可通过 `HookAttachment` 模型（F-C2 后续）注入可观测事件 |

# Message Refresh Trigger Slimming Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Shrink chat message refresh invalidation so workspace changes and tool-call payload churn rebuild only the rows whose rendered output actually changed.

**Architecture:** Keep the Feature 6 background projection pipeline intact, but replace the current monolithic row fingerprint with layered invalidation tokens. Separate row semantic data, workspace-local dependency data, and bounded tool/round summary digests so the refresh key and cache reuse logic compare only what the rendered row consumes, not raw payload blobs.

**Tech Stack:** Swift 6, SwiftUI, Foundation, existing chat message projection pipeline, Swift Testing, current ChatMessageList background worker.

---

## 1. 实施原则

- 我正在使用 writing-plans skill 来编写这份 implementation plan。
- 这份计划依赖 Feature 6 已完成的后台 projection worker；不要把构建流程拉回 `@MainActor`。
- 先锁测试，再收窄 fingerprint；不要先改字段再补测试，否则很难判断是“漏刷新”还是“减少重建”。
- `workspaceRoot` 只能作为局部依赖输入存在，不能继续作为整个消息列表 refresh key 的全局放大器。
- 对大字段采用有界摘要或局部 detail invalidation，禁止把原始 `JSON`、长文本、长数组直接塞回 row-level fingerprint。
- 任何仍然会影响当前 UI 的字段必须保留在语义 fingerprint 内，尤其是 `ToolCallRowPresentation`、`AgentExecutionProjection`、用户消息路径解析直接消费的字段。
- 目标不是“永远不重建”，而是“只在可见输出变化时重建”；宁可保守重建单行，也不要漏掉实际显示变化。
- 全程按 `@test-driven-development` 执行：先写失败测试，再写最小实现，再跑 focused tests，再提交。
- 任务全部完成后，用 `@requesting-code-review` 做最终 review，重点检查 workspace 切换、tool call 大字段、streaming 尾行三类场景。

## 2. 当前问题摘要

当前实现主要集中在以下位置：

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MessageRowSnapshot.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentExecutionProjection.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ToolCallRowPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+MessageList.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionPerformanceTests.swift`

现状里的三个核心问题：

1. `ChatMessageListRefreshKey` 直接带着 `workspaceRoot`，导致工作目录变化时整个列表 refresh task 一定重新触发。
2. `MessageRowFingerprint`、`ToolCallFingerprint`、`AgentRoundFingerprint` 把大量深层字段直接纳入比较，比较成本和无意义失效面一起变大。
3. tool call 的长文本和深层结构既参与 row cache reuse，又参与列表 trigger，比对路径没有区分“当前可见摘要”和“仅 detail 面板消费的数据”。

## 3. 目标文件清单

### 主要修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MessageRowSnapshot.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentExecutionProjection.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ToolCallRowPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+MessageList.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionPerformanceTests.swift`

### 可选新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MessageRefreshTriggerSlimmingTests.swift`

只有在现有两个测试文件难以保持可读性时才新增；否则优先复用现有 projection focused tests。

## 4. 设计约束

### 4.1 分层 invalidation 模型

执行阶段应把当前单体 `MessageRowFingerprint` 收敛为三层概念：

1. `MessageRowSemanticFingerprint`
   只包含会影响 `MessageRowSnapshot.make(for:workspaceRoot:)` 最终可见输出的字段。
2. `WorkspaceDependencyFingerprint`
   只描述该 row 是否真的依赖 `workspaceRoot`，并只在 user message 路径解析结果改变时参与无效化。
3. `ToolCall` / `Round` bounded summary fingerprint
   只保留 UI 当前消费的摘要字段，禁止把完整 `terminalAgentActionsJSON`、完整 metadata map、完整 round transcript、完整 memory id 列表等深层结构直接纳入 row key。

### 4.2 比较成本预算

实现完成后，需要在代码注释里明确以下预算：

- message-level fingerprint 只比较固定数量的 message 标量字段，加上 tool-call / round 的摘要数组。
- tool-call summary fingerprint 只比较当前列表 UI 直接消费的状态、标题、摘要、路径、时间、有限状态位。
- 大文本只允许通过有界摘要参与比较，例如长度、首个非空摘要行、状态枚举、或显式的 summary string；不得按全文逐字符参与 row-level 相等判断。
- 深层数组 / 字典只允许通过固定上限的派生信息参与 row fingerprint，例如 `count`、稳定 `id` 列表、已渲染 verdict / summary，而不是整个 payload 内容。

最终要把比较复杂度限制为“与消息数、tool call 数、round 数线性相关”，而不是与 `terminalOutput`、`diffContent`、`JSON` payload 大小线性相关。

## 5. Task 1: 先锁定 Feature 7 的回归面

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionPerformanceTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MessageRefreshTriggerSlimmingTests.swift`（仅在现有文件不够清晰时创建）

**Step 1: Write the failing test**

先补 4 组 focused tests，固定目标行为：

- 只有不依赖路径解析的消息存在时，`workspaceRoot` 变化不应触发 refresh key 变化。
- 只有依赖路径解析的 user row 存在时，`workspaceRoot` 变化只应重建该 row。
- tool call 深层大字段变化但可见摘要不变时，不应让对应 agent row 失效。
- planner summary / phase / status 等当前 theater 卡片直接显示的字段变化时，仍必须重建对应 row。

建议示例：

```swift
@Test
func refreshKeyIgnoresWorkspaceRootWhenNoRowsDependOnWorkspace() {
    let session = Session.fixture(sessionId: "refresh-key-stable", title: "Refresh Key Stable")
    let user = Message.userMessage(text: "hello", session: session)
    user.status = .completed

    let keyA = ChatMessageListRefreshKey(messages: [user], workspaceRoot: "/tmp/a")
    let keyB = ChatMessageListRefreshKey(messages: [user], workspaceRoot: "/tmp/b")

    #expect(keyA == keyB)
}
```

```swift
@Test
func deepToolPayloadUpdateDoesNotInvalidateAgentRowWhenSummaryIsStable() async throws {
    // same visible summary, only deep metadata / JSON payload changed
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature7-plan-1 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests -only-testing:agentGuiTests/ChatMessageListProjectionPerformanceTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because `workspaceRoot` is still part of the list refresh key and deep tool payloads still flow into row-level fingerprint equality.

**Step 3: Write minimal implementation**

这里先只补测试 fixture 和 helper，不改生产逻辑。必要时新增轻量 helper 让测试更容易构造“大字段变化但可见摘要不变”的输入。

```swift
private func makeLargeJSONPayload(seed: String) -> String {
    let item = "{\"step\":\"" + seed + "\"}"
    return String(repeating: item, count: 200)
}
```

**Step 4: Run test to verify it passes**

再次运行同一条 `xcodebuild` 命令。

Expected: PASS for the new test scaffolding and characterization coverage.

**Step 5: Commit**

```bash
git add agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests.swift agentGuiTests/ChatMessageListProjectionPerformanceTests.swift
git commit -m "test: lock message refresh trigger slimming behavior"
```

## 6. Task 2: 把 row fingerprint 拆成语义层和 workspace 依赖层

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+MessageList.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests.swift`

**Step 1: Write the failing test**

新增两类测试：

- `ChatMessageListRefreshKey` 在 message 集合与行语义不变时，不因 `workspaceRoot` 纯变化而变化。
- `ChatMessageListProjectionTrigger` / cache reuse 仍然能在“路径 mention 真正变化”的 row 上触发重建。

建议示例：

```swift
@Test
func workspaceRootChangeKeepsRefreshKeyStableForNonDependentRows() {
    let inputs = [MessageRowBuildInput.fixture(textContent: "plain text")]
    let keyA = ChatMessageListRefreshKey(messages: inputs.map(TestMessageFactory.make), workspaceRoot: "/tmp/a")
    let keyB = ChatMessageListRefreshKey(messages: inputs.map(TestMessageFactory.make), workspaceRoot: "/tmp/b")
    #expect(keyA == keyB)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature7-plan-2 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because `ChatMessageListRefreshKey` still stores raw `workspaceRoot`.

**Step 3: Write minimal implementation**

在 `ChatMessageListSnapshotBuilder.swift` 中做最小收敛：

- 用新的 `MessageRowSemanticFingerprint` 替代当前 `MessageRowFingerprint` 的职责命名。
- 让 `ChatMessageListProjectionTrigger` 和 `ChatMessageListRefreshKey` 都只比较 row order、row semantic fingerprint、workspace dependency token，而不是全局 `workspaceRoot` 字符串。
- 保留现有 `WorkspaceDependencyFingerprint` 思路，但让它成为局部 dependency token，而不是全局刷新锚点。

建议目标接口：

```swift
struct ChatMessageListRefreshKey: Equatable, @unchecked Sendable {
    let rowFingerprints: [MessageRowSemanticFingerprint]
    let workspaceDependencies: [WorkspaceDependencyFingerprint?]
}
```

**Step 4: Run test to verify it passes**

再次运行同一条 `xcodebuild` 命令。

Expected: PASS; workspace 变化不再让纯非依赖列表整体刷新，但依赖路径解析的 row 仍然正确失效。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift agentGui/Views/ChatView+MessageList.swift agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests.swift
git commit -m "refactor: localize workspace invalidation for message refresh"
```

## 7. Task 3: 为 tool call / round 引入分层 summary fingerprint

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ToolCallRowPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentExecutionProjection.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MessageRowSnapshot.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionPerformanceTests.swift`

**Step 1: Write the failing test**

补三类精确测试：

- `terminalAgentActionsJSON`、memory 冲突 ID 列表、subagent 深层 round 内容变化，但当前行可见摘要不变时，row 必须复用。
- `terminalPlannerSummary`、`terminalInteractionPhase`、`toolResultSummary`、`diffContent` 摘要、`verifierSummary` 这类直接影响当前列表展示的字段变化时，row 必须重建。
- 当 `terminalOutput` 或 `diffContent` 变化只影响 detail 文本而不影响列表摘要时，先保持保守单行重建；若决定进一步拆 detail invalidation，必须补测试说明新的局部刷新策略。

建议示例：

```swift
@Test
func terminalAgentActionsPayloadChangeDoesNotInvalidateProjectedRow() async throws {
    // visible planner/status summary unchanged, opaque JSON differs
}
```

```swift
@Test
func verifierSummaryChangeStillInvalidatesProjectedRow() async throws {
    // tertiary text changes, row must rebuild
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature7-plan-3 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ChatMessageListProjectionPerformanceTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because current `ToolCallFingerprint` / `AgentRoundFingerprint` still compare deep payloads directly.

**Step 3: Write minimal implementation**

在 `ChatMessageListSnapshotBuilder.swift` 中引入 bounded summary fingerprints，建议结构如下：

```swift
struct ToolCallSummaryFingerprint: Hashable, @unchecked Sendable {
    let id: UUID
    let kind: ToolKind
    let status: ToolStatus
    let title: String?
    let visibleSummary: String?
    let visibleTertiary: String?
    let timingBucket: ToolCallTimingFingerprint
    let artifactPath: String?
}
```

```swift
struct AgentRoundSummaryFingerprint: Hashable, @unchecked Sendable {
    let id: UUID
    let roundIndex: Int
    let transcriptSummary: String?
    let stopReason: String?
    let toolCalls: [ToolCallSummaryFingerprint]
}
```

实现要求：

- 只把 `ToolCallRowPresentation.make(for:)` 和 `AgentExecutionProjection.make(for:audit:)` 当前直接消费的字段纳入 summary fingerprint。
- 对大文本先派生摘要，再纳入 fingerprint；不要把完整 `terminalOutput`、完整 `diffContent`、完整 `terminalAgentActionsJSON` 或完整 metadata map 直接纳入比较。
- 如果某个 UI 仍然直接依赖完整大字段，先把它明确标记为“保守单行重建字段”，不要静默遗漏。

**Step 4: Run test to verify it passes**

再次运行同一条 `xcodebuild` 命令。

Expected: PASS; 深层 payload 变化不再误伤整行，真正影响 theater / transcript / artifact 摘要的字段仍能触发单行重建。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift agentGui/ViewModels/ToolCallRowPresentation.swift agentGui/ViewModels/AgentExecutionProjection.swift agentGui/ViewModels/MessageRowSnapshot.swift agentGuiTests/ChatMessageListProjectionPerformanceTests.swift
git commit -m "refactor: layer tool call refresh fingerprints"
```

## 8. Task 4: 明确 fingerprint 成本上限并跑完整 focused suite

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionPerformanceTests.swift`

**Step 1: Write the failing test**

补一组最终回归测试，覆盖：

- 大量历史消息下，只改最后一条 streaming message 时仍只重建尾行。
- 切换工作目录时，只重建依赖 workspace 的 user rows。
- 更新超大 tool payload 时，非相关 rows 的 `reusedRowCount` 保持稳定。

必要时补一个 smoke-style 测试，验证大 payload 的更新不会让 `rebuiltRowIDs.count` 意外膨胀。

```swift
@Test
func largeOpaquePayloadUpdateKeepsRebuiltRowsBounded() async throws {
    #expect(result.rebuiltRowIDs.count == 1)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature7-plan-4 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests -only-testing:agentGuiTests/ChatMessageListProjectionPerformanceTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL until the final fingerprint budget and trigger slimming changes are all wired together.

**Step 3: Write minimal implementation**

补齐两项交付：

- 在 `ChatMessageListSnapshotBuilder.swift` 的 fingerprint 类型上方增加简短注释，写明字段来源、禁止纳入的 payload 类型、比较复杂度上限。
- 清理遗留命名，保证 `semanticFingerprint`、`workspaceDependency`、summary digest 的职责边界在代码里一眼可见。

建议注释形式：

```swift
// Row refresh compares only message semantics plus bounded tool/round summaries.
// Never add raw terminal output, diff bodies, JSON payloads, or unbounded metadata here.
// Comparison cost must stay O(message + toolCalls + rounds), independent of payload size.
```

**Step 4: Run test to verify it passes**

先运行 focused projection tests：

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature7-plan-4 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests -only-testing:agentGuiTests/ChatMessageListProjectionPerformanceTests -only-testing:agentGuiTests/ChatMessageListProjectionModelConcurrencyTests CODE_SIGNING_ALLOWED=NO
```

然后运行 sample baseline，确认没有把增量复用退化回全量重建：

```bash
./scripts/sample_quality_baseline.sh unit 5
```

Expected: PASS; focused tests 证明触发器瘦身生效，baseline 没有出现明显回归。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests.swift agentGuiTests/ChatMessageListProjectionPerformanceTests.swift
git commit -m "docs: document message refresh fingerprint budget"
```

## 9. 完成定义

满足以下条件才算 Feature 7 完成：

1. `workspaceRoot` 不再作为整个列表 refresh key 的全局比较字段。
2. 未依赖路径展示的消息行在工作目录切换时保持复用。
3. tool call / round 的 row-level fingerprint 不再直接比较深层大字段。
4. 当前列表 UI 真正消费的 planner/status/verdict/path/summary 字段变化仍能稳定触发单行重建。
5. `ChatMessageListSnapshotBuilder.swift` 中有清晰注释说明 fingerprint 字段边界和比较复杂度上限。
6. focused tests 和 sample baseline 全部通过。

## 10. 风险提醒

- 不要为了“零重建”把真实影响 UI 的字段从 fingerprint 中移除，否则会得到视觉陈旧而不是性能优化。
- 不要把大字段一律改成 hash；如果 hash 不能对应当前 UI 的可见摘要，就会把可理解性和调试性一起丢掉。
- 如果 detail 面板仍然直接依赖完整 `terminalOutput` / `diffContent`，本轮优先保证列表行触发器瘦身；是否继续拆“列表摘要 vs 展开详情”刷新链，可以作为后续小改进，不要在本轮过度设计。

Plan complete and saved to `docs/plans/2026-03-29-message-refresh-trigger-slimming-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
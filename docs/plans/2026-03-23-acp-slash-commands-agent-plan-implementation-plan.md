# ACP Slash Commands And Agent Plan Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 external ACP provider 补齐 `available_commands_update` 与 `plan` 两类会话级协议能力，并把它们稳定接入当前输入区 slash 补全、会话计划持久化与 todo 展示链路。

**Architecture:** 在现有 external ACP 执行框架上增加独立的 feature 流，而不是继续把所有 update 塞进文本与工具 normalizer。协议层先 typed 化 `ACPSessionUpdate` 新分支，再通过 `ACPExternalSessionFeatureExtractor`、`ACPExternalSessionFeatureStore` 与 `ACPPlanProjector` 形成 “协议快照 -> 本地状态 -> UI 投影” 三段链路；provider 差异则收口到单独 adapter，OpenCode 与 Copilot 都只以远端 ACP 广告为真源。

**Tech Stack:** Swift 6, SwiftData, Swift Testing, existing ACP runtime stack, `ACPExternalExecutionProviderBase`, `SessionTaskStateStore`, current slash command input pipeline, existing GitHub Copilot and OpenCode ACP providers.

---

## 1. 实施原则

- 这份计划默认在独立 worktree 中执行，避免和并行 ACP 改动互相污染。
- 全程按 @test-driven-development 执行：先写失败测试，再写最小实现，再跑通过，再提交。
- 不解析模型 Markdown 输出或 CLI 文档目录来伪造 slash commands 或 plan；只消费 ACP typed update。
- 不在本次实现里本地执行 slash command；Client 只负责发现、补全、缓存和原样发送 `/command args` 文本。
- OpenCode 作为协议黄金路径优先打通；Copilot 保持兼容，但不强假设 preview ACP 行为一定广告 commands 或发送 plan。
- `plan` 必须按“完整替换”处理，禁止做增量 merge。
- 完成全部任务后，使用 @requesting-code-review 做一次最终 review，重点看 provider 回归、计划替换语义和 slash 补全冲突。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionFeatureExtractor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionFeatureStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPPlanProjector.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderFeatureAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPChatSlashCommandProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalSessionFeatureExtractorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalSessionFeatureStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPPlanProjectorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatInputCommandParserTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentEventNormalizer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionPlan.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TodoItem.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SlashCommandModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChatInputDirective.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/SlashCommandRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChatInputCommandParser.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChatComposerSlashState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/SessionTaskStateStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalAgentEventNormalizerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SlashCommandRegistryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerSlashStateTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerTodoCardPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`

### 参考文件

- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-23-acp-slash-commands-agent-plan-design.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-22-external-acp-provider-abstraction-implementation-plan.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-20-opencode-acp-integration-implementation-plan.md`

## 3. 分阶段目标

### Phase 1: Typed protocol updates

- `ACPModels` 明确支持 `available_commands_update` 与 `plan`
- `ACPModelTests` 锁定 decode/encode 行为

### Phase 2: Feature flow 基础设施

- 提取 commands 与 plan 事件
- 持久化 feature 快照
- 投影到 `ExecutionPlan` 与 `TodoItem`

### Phase 3: Runtime 接线

- `ACPExternalExecutionProviderBase` 同时驱动 execution 流与 feature 流
- OpenCode 与 Copilot 通过 adapter 注入 provider 差异

### Phase 4: Slash UI 集成

- 输入区读取 ACP commands
- 本地 skill 命令与 ACP commands 并存
- 选择 ACP command 只插入文本，不生成 directive

### Phase 5: Agent plan UI 集成与恢复

- `plan` 更新驱动会话计划和 todo 卡片刷新
- 支持 app 重启或 `session/load` 后回放最近的 feature 状态

## 4. 任务拆解

### Task 1: 在协议层 typed 化 `available_commands_update` 与 `plan`

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPModels.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPModelTests.swift`

**Step 1: Write the failing test**

在 `ACPModelTests.swift` 新增两组 decode/encode 测试，验证：

- `sessionUpdate = available_commands_update` 能解出 commands 列表与 input hint
- `sessionUpdate = plan` 能解出完整 entries 列表和 `pending / in_progress / completed`

示例：

```swift
@Test func sessionUpdateDecodesAvailableCommandsUpdate() throws {
    let payload = """
    {
      "sessionUpdate": "available_commands_update",
      "availableCommands": [
        {
          "name": "plan",
          "description": "Create a plan",
          "input": { "hint": "what to plan" }
        }
      ]
    }
    """.data(using: .utf8)!

    let update = try JSONDecoder().decode(ACPSessionUpdate.self, from: payload)
    guard case .availableCommandsUpdate(let value) = update else {
        Issue.record("expected availableCommandsUpdate")
        return
    }
    #expect(value.availableCommands.first?.name == "plan")
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPModelTests`

Expected: FAIL with missing session update cases or missing typed payload models.

**Step 3: Write minimal implementation**

在 `ACPModels.swift` 新增：

```swift
struct ACPAvailableCommandInput: Codable, Equatable, Sendable {
    var hint: String
}

struct ACPAvailableCommand: Codable, Equatable, Sendable {
    var name: String
    var description: String
    var input: ACPAvailableCommandInput?
}

struct ACPAvailableCommandsUpdatePayload: Codable, Equatable, Sendable {
    var availableCommands: [ACPAvailableCommand]
}

enum ACPPlanEntryPriority: String, Codable, Equatable, Sendable {
    case high
    case medium
    case low
}

enum ACPPlanEntryStatus: String, Codable, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
}

struct ACPPlanEntry: Codable, Equatable, Sendable {
    var content: String
    var priority: ACPPlanEntryPriority
    var status: ACPPlanEntryStatus
}

struct ACPPlanUpdatePayload: Codable, Equatable, Sendable {
    var entries: [ACPPlanEntry]
}
```

并为 `ACPSessionUpdate` 增加：

```swift
case availableCommandsUpdate(ACPAvailableCommandsUpdatePayload)
case plan(ACPPlanUpdatePayload)
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPModelTests`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPModels.swift agentGuiTests/ACPModelTests.swift
git commit -m "feat: type acp slash commands and plan updates"
```

### Task 2: 新增 feature extractor，提取 commands 与 plan，不污染现有 normalizer

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionFeatureExtractor.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalSessionFeatureExtractorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentEventNormalizer.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalAgentEventNormalizerTests.swift`

**Step 1: Write the failing test**

新增 extractor 测试，验证：

- `available_commands_update` 会产出 `replaceCommands`
- `plan` 会产出 `replacePlan`
- 普通文本、工具、权限 update 不产出 feature 事件

示例：

```swift
@Test func extractorBuildsReplaceCommandsEventFromSessionUpdate() {
    let extractor = ACPExternalSessionFeatureExtractor()
    let events = extractor.extract(
        update: .session(.availableCommandsUpdate(.init(availableCommands: [
            .init(name: "review", description: "Run review", input: nil)
        ]))),
        providerID: .openCodeCLI,
        remoteSessionID: "remote-1"
    )

    #expect(events.count == 1)
}
```

同时给 `ACPExternalAgentEventNormalizerTests.swift` 增一条回归测试，确认新 session update 不会被误投影成文本或 tool event。

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPExternalSessionFeatureExtractorTests -only-testing:agentGuiTests/ACPExternalAgentEventNormalizerTests`

Expected: FAIL with missing extractor type or feature event definitions.

**Step 3: Write minimal implementation**

新增：

```swift
enum ACPExternalSessionFeatureEvent: Equatable, Sendable {
    case replaceCommands([ACPCommandDescriptor])
    case replacePlan(ACPPlanSnapshotDraft)
}
```

新增 extractor：

```swift
struct ACPExternalSessionFeatureExtractor {
    func extract(
        update: ACPExternalAgentUpdate,
        providerID: ConversationExecutionProviderID,
        remoteSessionID: String
    ) -> [ACPExternalSessionFeatureEvent] {
        ...
    }
}
```

保持 `ACPExternalAgentEventNormalizer` 只处理文本、思考、工具、权限，不增加 feature event 分支。

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPExternalSessionFeatureExtractorTests -only-testing:agentGuiTests/ACPExternalAgentEventNormalizerTests`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalSessionFeatureExtractor.swift agentGui/Services/ACP/ACPExternalAgentEventNormalizer.swift agentGuiTests/ACPExternalSessionFeatureExtractorTests.swift agentGuiTests/ACPExternalAgentEventNormalizerTests.swift
git commit -m "feat: add external acp feature extractor"
```

### Task 3: 新增 feature store 与 plan projector，把协议快照投影到本地状态

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionFeatureStore.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPPlanProjector.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionPlan.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TodoItem.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/SessionTaskStateStore.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalSessionFeatureStoreTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPPlanProjectorTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerTodoCardPresentationTests.swift`

**Step 1: Write the failing test**

新增 projector 测试，验证：

- ACP `pending / in_progress / completed` 分别映射到本地 `TodoStatus.pending / inProgress / done`
- ACP priority 被保留到 `ExecutionPlan` step 或可序列化字段
- 空 plan 会清空现有 todo 列表

示例：

```swift
@Test func planProjectorMapsInProgressEntryToTodoInProgress() {
    let snapshot = ACPPlanSnapshot(
        entries: [
            .init(content: "Inspect code", priority: .high, status: .inProgress)
        ],
        providerID: .openCodeCLI,
        remoteSessionID: "remote-1",
        updatedAt: .now
    )

    let todos = ACPPlanProjector().makeTodoItems(from: snapshot)
    #expect(todos == [TodoItem(title: "Inspect code", status: .inProgress)])
}
```

同时新增 feature store 测试，验证：

- `replaceCommands` 会更新 commands cache
- `replacePlan` 会调用 projector 并写入 `SessionTaskStateStore`
- 重复 plan 更新采用完整替换语义

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPPlanProjectorTests -only-testing:agentGuiTests/ACPExternalSessionFeatureStoreTests -only-testing:agentGuiTests/ChatComposerTodoCardPresentationTests`

Expected: FAIL with missing store or unsupported `in_progress` plan status in internal model.

**Step 3: Write minimal implementation**

扩展 `ExecutionPlan.swift`：

```swift
enum PlanStepStatus: String, Codable, CaseIterable {
    case pending
    case inProgress = "in_progress"
    case done = "done"
    case skipped = "skipped"
    case failed = "failed"
}

struct PlanStep: Codable, Identifiable {
    var priority: String?
    ...
}
```

新增 `ACPPlanProjector`，明确把 ACP 原始 snapshot 投影为：

- `ExecutionPlan`
- `[TodoItem]`

新增 `ACPExternalSessionFeatureStore`，负责：

- 维护 commands cache
- 维护 raw plan snapshot
- 通过 `SessionTaskStateStore.savePlan` 与 `saveTodoItems` 写入 UI 兼容状态

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPPlanProjectorTests -only-testing:agentGuiTests/ACPExternalSessionFeatureStoreTests -only-testing:agentGuiTests/ChatComposerTodoCardPresentationTests`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalSessionFeatureStore.swift agentGui/Services/ACP/ACPPlanProjector.swift agentGui/Models/ExecutionPlan.swift agentGui/Models/TodoItem.swift agentGui/Services/SessionTaskStateStore.swift agentGuiTests/ACPPlanProjectorTests.swift agentGuiTests/ACPExternalSessionFeatureStoreTests.swift agentGuiTests/ChatComposerTodoCardPresentationTests.swift
git commit -m "feat: project external acp plan into local task state"
```

### Task 4: 把 feature 流接进 external ACP provider base，并加上 provider adapter

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderFeatureAdapter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`

**Step 1: Write the failing test**

扩展 provider 测试，验证：

- OpenCode provider 收到 `available_commands_update` 后，feature store 中出现远端 commands
- OpenCode provider 收到 `plan` 后，session todo 状态被替换
- Copilot provider 在没有远端广告时不会崩溃，并可暴露种子 commands

示例：

```swift
@Test func openCodeProviderProjectsPlanUpdateIntoSessionTaskState() async throws {
    let harness = try OpenCodeProviderHarness.make(
        updates: [.session(.plan(.init(entries: [
            .init(content: "Run tests", priority: .medium, status: .inProgress)
        ])))]
    )

    try await harness.provider.send(harness.request(text: "hello"))

    let items = SessionTaskStateStore(modelContext: harness.modelContext).todoItems(for: harness.session.sessionId)
    #expect(items.map(\.title) == ["Run tests"])
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests`

Expected: FAIL because provider base still only routes updates through normalizer and projector.

**Step 3: Write minimal implementation**

新增 provider feature adapter 协议：

```swift
protocol ACPExternalProviderFeatureAdapter {
    var providerID: ConversationExecutionProviderID { get }
    func documentedSlashCommands() -> [ACPCommandDescriptor]
    func mergeCommands(cached: [ACPCommandDescriptor], remote: [ACPCommandDescriptor]?) -> [ACPCommandDescriptor]
}
```

在 `ACPExternalExecutionProviderBase.consume(update:)` 中先跑 feature extractor/store，再跑现有 execution event 投影：

```swift
let featureEvents = featureExtractor.extract(...)
featureStore.apply(featureEvents, localSessionID: localSessionID, ...)

let projectedEvents = updateProjector.project(...)
```

OpenCode adapter：远端广告优先，默认无种子列表。

Copilot adapter：无远端广告时提供保守的文档种子命令，如 `plan`, `review`, `agent`, `model`, `mcp`, `resume`, `share`, `usage`, `cwd`。

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalProviderFeatureAdapter.swift agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift agentGuiTests/ACPExternalExecutionProviderBaseTests.swift agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift agentGuiTests/OpenCodeCLIExecutionProviderTests.swift
git commit -m "feat: route external acp feature updates through provider base"
```

### Task 5: 扩展 slash command 模型与解析器，让 ACP commands 能进入补全但不生成 directive

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPChatSlashCommandProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SlashCommandModels.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChatInputDirective.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/SlashCommandRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChatInputCommandParser.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChatComposerSlashState.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SlashCommandRegistryTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerSlashStateTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatInputCommandParserTests.swift`

**Step 1: Write the failing test**

新增三组测试：

- registry 能同时返回 skill item 与 ACP command item，并按 provider 命令优先排序
- `ChatInputCommandParser.makeDirective` 对 ACP command 返回 `nil`
- 选择 ACP command 时，slash token 被替换成 `/command ` 而不是移除全文

示例：

```swift
@Test func selectingACPCommandInsertsCommandTextWithoutDirective() {
    let item = ChatSlashCommandItem(
        id: "acp:plan",
        kind: .agent,
        title: "plan",
        subtitle: "Create an implementation plan",
        aliases: [],
        badge: "OpenCode",
        isEnabledByDefault: true,
        payload: .acpCommand(name: "plan", argumentHint: "what to plan", source: .remoteAdvertised)
    )

    let result = ChatInputCommandParser.replacingSlashToken(in: "/pl", selectedItem: item)
    #expect(result.updatedText == "/plan ")
    #expect(result.directive == nil)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/SlashCommandRegistryTests -only-testing:agentGuiTests/ChatComposerSlashStateTests -only-testing:agentGuiTests/ChatInputCommandParserTests`

Expected: FAIL with missing payload case or parser behavior mismatch.

**Step 3: Write minimal implementation**

扩展 payload：

```swift
enum ChatSlashCommandPayload: Hashable, Codable {
    case skill(directoryName: String)
    case acpCommand(name: String, argumentHint: String?, source: ACPCommandSource)
}
```

更新 parser：

- skill item 仍生成 `ChatInputDirective.skill`
- ACP command item 不生成 directive
- `replacingSlashToken` 对 ACP command 改为插入 `/command `

新增 `ACPChatSlashCommandProvider`，把 feature store 中的 commands 投影成 `ChatSlashCommandItem`。

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/SlashCommandRegistryTests -only-testing:agentGuiTests/ChatComposerSlashStateTests -only-testing:agentGuiTests/ChatInputCommandParserTests`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPChatSlashCommandProvider.swift agentGui/Models/SlashCommandModels.swift agentGui/Models/ChatInputDirective.swift agentGui/Services/SlashCommandRegistry.swift agentGui/Services/ChatInputCommandParser.swift agentGui/Models/ChatComposerSlashState.swift agentGuiTests/SlashCommandRegistryTests.swift agentGuiTests/ChatComposerSlashStateTests.swift agentGuiTests/ChatInputCommandParserTests.swift
git commit -m "feat: expose acp slash commands in composer registry"
```

### Task 6: 把 ACP commands 与 plan 状态接进输入区和 todo 卡片

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/SessionTaskStateStore.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerTodoCardPresentationTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SlashCommandRegistryTests.swift`

**Step 1: Write the failing test**

补测试验证：

- 当前 provider 为 OpenCode 或 Copilot 时，输入区 slash candidate 包含 ACP commands
- 当前 session 收到新 `plan` 后，todo 展示以最新 snapshot 为准，而不是旧值叠加

如果现有 UI 测试覆盖不足，至少补 view model 级测试，锁定：

- provider commands 合并到 registry
- `currentTodoItems` 优先读取最新 persisted ACP plan 投影

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ChatComposerTodoCardPresentationTests -only-testing:agentGuiTests/SlashCommandRegistryTests`

Expected: FAIL because `ChatView+InputArea` still只接 skill provider。

**Step 3: Write minimal implementation**

在输入区组装 registry 时加入 `ACPChatSlashCommandProvider`，数据源来自当前 session + 当前 provider 对应的 feature store。

保持现有行为：

- skill 仍可被选中并转为 directive chip
- ACP commands 显示 provider badge，如 `OpenCode`、`Copilot`
- 发送时不会附加 directive audit

todo 部分保持通过 `SessionTaskStateStore.todoItems(for:)` 取值，但确保 feature store 在收到新 plan 后即时覆盖旧状态。

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ChatComposerTodoCardPresentationTests -only-testing:agentGuiTests/SlashCommandRegistryTests`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/ChatView+InputArea.swift agentGui/Services/SessionTaskStateStore.swift agentGuiTests/ChatComposerTodoCardPresentationTests.swift agentGuiTests/SlashCommandRegistryTests.swift
git commit -m "feat: surface acp commands and plan todos in composer"
```

### Task 7: 加入 commands cache 恢复与 provider-specific fallback 行为回归测试

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionFeatureStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderFeatureAdapter.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalSessionFeatureStoreTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`

**Step 1: Write the failing test**

补两类恢复测试：

- app 重启或 provider 重建后，commands cache 仍可用于 slash 补全
- Copilot 无远端广告时返回空列表；只有后续收到远端广告后才暴露 commands

示例：

```swift
@Test func copilotDoesNotExposeCommandsWithoutRemoteAdvertisement() async throws {
    #expect(provider.remoteCommands(localSessionID: session.sessionId).isEmpty)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPExternalSessionFeatureStoreTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests`

Expected: FAIL because Copilot still bootstraps fallback commands instead of relying only on remote advertisement.

**Step 3: Write minimal implementation**

完善 feature store：

- 为 commands 建立 `localSessionID + providerID` 维度缓存
- 允许 provider adapter 根据 cached + remote 计算最终候选列表

完善 Copilot adapter：

- 移除文档种子 bootstrap
- 仅保留远端 `available_commands_update` 驱动的 commands cache

完善 OpenCode adapter：

- 若有 remote，则直接使用 remote
- 若无 remote，则退回 cached

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPExternalSessionFeatureStoreTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalSessionFeatureStore.swift agentGui/Services/ACP/ACPExternalProviderFeatureAdapter.swift agentGuiTests/ACPExternalSessionFeatureStoreTests.swift agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift agentGuiTests/OpenCodeCLIExecutionProviderTests.swift
git commit -m "feat: add acp command cache recovery and provider fallback rules"
```

### Task 8: 跑整组 ACP 与 slash 回归测试，并做最终 review

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-23-acp-slash-commands-agent-plan-design.md`
  - 仅在实现与设计存在必要偏差时更新

**Step 1: Run the focused test suite**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/ACPModelTests \
  -only-testing:agentGuiTests/ACPExternalAgentEventNormalizerTests \
  -only-testing:agentGuiTests/ACPExternalSessionFeatureExtractorTests \
  -only-testing:agentGuiTests/ACPExternalSessionFeatureStoreTests \
  -only-testing:agentGuiTests/ACPPlanProjectorTests \
  -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests \
  -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests \
  -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests \
  -only-testing:agentGuiTests/SlashCommandRegistryTests \
  -only-testing:agentGuiTests/ChatComposerSlashStateTests \
  -only-testing:agentGuiTests/ChatInputCommandParserTests \
  -only-testing:agentGuiTests/ChatComposerTodoCardPresentationTests
```

Expected: PASS.

**Step 2: Run repository smoke if needed**

Run: `./scripts/run_quality_smoke.sh`

Expected: PASS or only unrelated known failures.

**Step 3: Request code review**

用 @requesting-code-review 检查：

- feature 流是否与 normalizer 成功解耦
- Copilot fallback 是否过度假设远端支持
- `plan` 替换语义是否在任何路径上被意外 merge
- slash command 选择后是否仍污染 directive 审计链路

**Step 4: Update design doc only if implementation diverged**

如果实现和设计有必要差异，只更新对应设计文档中的偏差说明，不要重写整篇文档。

**Step 5: Commit**

```bash
git add agentGui docs/plans/2026-03-23-acp-slash-commands-agent-plan-design.md agentGuiTests
git commit -m "feat: add acp slash command and agent plan support"
```

## 5. 额外注意事项

- `ExecutionPlan` 当前内部状态使用 `done`，而 ACP 原生是 `completed`；实现时只在 projector 做映射，不要反向污染 ACP 原始模型。
- `ChatInputDirective` 是本地执行语义，不要把 ACP commands 伪装成 directive；否则审计尾注和 payload draft 都会被错误污染。
- `ACPExternalSessionFeatureStore` 必须以 provider 维度隔离缓存，避免 Copilot 和 OpenCode 在同一 local session 上互相覆盖 commands 或 plan。
- `available_commands_update` 是完整列表替换，不是 append；任何 merge 只允许发生在 provider fallback 层，而不是协议语义层。

## 6. 完成标准

满足以下条件才算完成：

- OpenCode 通过 ACP 广播的 commands 能进入输入区 slash 补全
- OpenCode 通过 ACP 下发的 `plan` 能更新 session plan 与 todo UI
- Copilot 在没有远端广告时仍可提供保守的 slash 种子命令，但不会伪造原生 plan
- 现有文本、思考、工具、权限投影行为无回归
- 所有新增与修改测试通过

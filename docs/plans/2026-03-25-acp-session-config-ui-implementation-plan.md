# ACP Session Config UI Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让 external ACP 会话配置切换回归标准协议：建会话时选择并锁定执行器，会话内通过 `session/set_mode` 与 `session/set_config_option` 切换 mode、model、approvals，并从远端 `configOptions` / `modes` 动态驱动 UI。

**Architecture:** 这次实现分成四层。第一层是 runtime contract 收口，把 external ACP client 从 `setModel` 升级为通用的 session config API，并在 `session/new` / `session/load` 中捕获配置快照。第二层是 feature state 扩展，把 `configOptions` 与 `modes` 纳入 session 级缓存和投影。第三层是 provider 适配与会话偏好边界收缩，让 Copilot/OpenCode/Claude adapter 统一通过标准 config option 选择模型与 approvals。第四层是 UI 重构，把“会话内切执行器”改成“建会话时选执行器 + 会话内只展示动态配置项”。

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Testing, ACP runtime stack (`ACPExternalAgentRuntimeClient`, `ACPExternalExecutionProviderBase`, `ACPExternalSessionFeatureStore`)

---

## 0. Design Constraints

- 严格按 @test-driven-development 执行：先写失败测试，再做最小实现，再跑 focused tests。
- 不做 provider 间会话迁移；`Session.defaultExecutionProviderID` 一旦建会话确定，进入会话后不再提供切换入口。
- 不重写 Settings 页的全局 executor defaults 结构；本轮只修正 external ACP 会话运行态配置。
- external ACP 的模型列表、mode 列表、approvals 可选项都以远端 `configOptions` / `modes` 为真相源，客户端不再写死 provider-specific 列表。
- built-in agent 继续保留本地模型与审批模式逻辑，不强行并入 external ACP 动态配置链路。
- 对 OpenCode、GitHub Copilot、Claude Adapter 一律使用标准 ACP `session/set_config_option` / `session/set_mode` 作为主链，不再把 `model` 视为专有协议操作。
- 在没有远端广告某个配置项时，UI 必须隐藏对应控件，而不是伪造本地选项。
- 完成所有任务后，使用 @requesting-code-review 做最终 review，重点检查 provider 锁定、动态 config source 和协议方法替换是否彻底。

## 1. Target File Inventory

### Create

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/NewSessionExecutionProviderMenu.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ACPSessionConfigurationControls.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ACPSessionConfigurationPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPSessionConfigurationPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeAdapterCLIExecutionProviderTests.swift`

### Modify

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderContracts.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionFeatureExtractor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionFeatureStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPSchemaExtensions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionExecutionPreferences.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPExternalAgentDescriptor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Toolbar.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchConversationPane.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ConversationExecutionProviderID.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalAgentRuntimeClientTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalSessionFeatureExtractorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalSessionFeatureStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`

## 2. Verification Commands

### Focused runtime/config tests

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-acp-session-config \
  -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests \
  -only-testing:agentGuiTests/ACPExternalSessionFeatureExtractorTests \
  -only-testing:agentGuiTests/ACPExternalSessionFeatureStoreTests \
  -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests \
  -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests \
  -only-testing:agentGuiTests/ClaudeAdapterCLIExecutionProviderTests \
  -only-testing:agentGuiTests/ACPSessionConfigurationPresentationTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: 所有 ACP session config 与 presentation tests 通过。

### Existing ACP regression task

Run task: `Focused ACP Tests Fresh`

Expected: 现有 ACP focused tests 继续通过，没有引入 load/new/restore 回归。

### Smoke validation

Run task: `Quality Smoke`

Expected: 基础质量烟测通过；若有与本次改动无关的历史失败，只记录并单独说明。

## 3. Target Data Shapes

目标实现里不再把 model 当作独立专用操作，而是把会话内可调项统一收敛到 mode 与 config option。

```swift
struct ACPExternalSessionConfigurationSnapshot: Equatable, Sendable {
    var configOptions: [ACPSessionConfigOption]
    var modes: ACPSessionModeState?
}

@MainActor
protocol ACPExternalProviderRuntimeClient: AnyObject {
    func ensureSession(workingDirectory: String, remoteSessionID: String?) async throws -> ACPExternalAgentSessionHandshake
    func setSessionMode(_ modeID: String, sessionID: String) async throws
    func setSessionConfigOption(_ configID: String, value: String, sessionID: String) async throws -> [ACPSessionConfigOption]
    func prompt(text: String, sessionID: String) async throws -> ACPStopReason
    func cancel(sessionID: String) async throws
    func close() async
}
```

UI 层不直接解释 provider-specific 默认模型，而是先生成标准化展示模型：

```swift
struct ACPSessionConfigurationPresentation: Equatable {
    var providerID: ConversationExecutionProviderID
    var providerDisplayName: String
    var modeOptions: [ExecutionOptionItem]
    var selectedModeID: String?
    var modelConfig: ACPSessionConfigControl?
    var approvalsConfig: ACPSessionConfigControl?
}
```

## 4. Task Breakdown

### Task 1: 收口 runtime contract，补齐标准 session config API

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderContracts.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalAgentRuntimeClientTests.swift`

**Step 1: Write the failing test**

在 `ACPExternalAgentRuntimeClientTests.swift` 增加以下失败测试：

```swift
@Test func setSessionConfigOptionUsesStandardACPMethod() async throws
@Test func setSessionModeUsesStandardACPMethod() async throws
@Test func ensureSessionCapturesConfigSnapshotFromNewSession() async throws
@Test func loadSessionCapturesConfigSnapshotFromLoadResponse() async throws
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-task1 -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为当前 runtime 只有 `setModel(...)`，也不会把 `session/new` / `session/load` 的 `configOptions` / `modes` 带回握手结果。

**Step 3: Write minimal implementation**

- 把 `ACPExternalProviderRuntimeClient` / `ACPExternalProviderRuntimeTransportClient` 改成 `setSessionMode` 与 `setSessionConfigOption`。
- 在 `ACPExternalAgentRuntimeClient` 中删除 `setModel(...)`，新增：

```swift
func setSessionMode(_ modeID: String, sessionID: String) async throws {
    _ = try await managedRuntime.runtime.setSessionMode(
        ACPSetSessionModeRequest(meta: nil, modeID: modeID, sessionID: sessionID)
    )
}

func setSessionConfigOption(_ configID: String, value: String, sessionID: String) async throws -> [ACPSessionConfigOption] {
    let response = try await managedRuntime.runtime.setSessionConfigOption(
        ACPSetSessionConfigOptionRequest(meta: nil, configID: configID, sessionID: sessionID, value: value)
    )
    return response.configOptions
}
```

- 在 `createSession(...)` 与 `loadSessionIfPossible(...)` 路径中捕获 `configOptions` / `modes`，写入新的 session configuration snapshot。

**Step 4: Run test to verify it passes**

同上命令。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalProviderContracts.swift agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift agentGuiTests/ACPExternalAgentRuntimeClientTests.swift
git commit -m "refactor: adopt standard acp session config apis"
```

### Task 2: 扩展 feature extraction/store，缓存动态 configOptions 与 modes

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionFeatureExtractor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionFeatureStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPSchemaExtensions.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalSessionFeatureExtractorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalSessionFeatureStoreTests.swift`

**Step 1: Write the failing test**

补 tests 覆盖：

```swift
@Test func extractorBuildsConfigPresentationFromConfigOptionUpdate() throws
@Test func extractorBuildsConfigPresentationFromCurrentModeUpdate() throws
@Test func storePersistsLatestSessionConfigSnapshotPerSessionAndProvider() throws
@Test func storeMergesInitialHandshakeSnapshotAndLiveUpdates() throws
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-task2 -only-testing:agentGuiTests/ACPExternalSessionFeatureExtractorTests -only-testing:agentGuiTests/ACPExternalSessionFeatureStoreTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为当前 extractor 对 `currentModeUpdate` / `configOptionUpdate` 返回空事件，store 也没有 session config cache。

**Step 3: Write minimal implementation**

- 为 `ACPExternalSessionFeatureEvent` 新增 session config 事件，例如：

```swift
case replaceSessionConfiguration(ACPExternalSessionConfigurationSnapshot)
case updateCurrentMode(providerID: ConversationExecutionProviderID, remoteSessionID: String, currentModeID: String)
```

- 让 extractor 消费：
  - `session/new` / `session/load` 提供的初始 snapshot
  - `config_option_update`
  - `current_mode_update`
- 在 store 中新增 `(sessionID, providerID)` 维度的 session config cache，并提供读取 API。

**Step 4: Run test to verify it passes**

同上命令。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalSessionFeatureExtractor.swift agentGui/Services/ACP/ACPExternalSessionFeatureStore.swift agentGui/Services/ACP/ACPSchemaExtensions.swift agentGuiTests/ACPExternalSessionFeatureExtractorTests.swift agentGuiTests/ACPExternalSessionFeatureStoreTests.swift
git commit -m "feat: cache external acp session config state"
```

### Task 3: 统一 provider 适配层，移除 model-special-case 主链

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionExecutionPreferences.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPExternalAgentDescriptor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeAdapterCLIExecutionProviderTests.swift`

**Step 1: Write the failing test**

为三个 provider 增加或修改 tests，覆盖：

```swift
@Test func providerUsesAdvertisedModelConfigOptionInsteadOfSetModelExtension() async throws
@Test func providerSkipsModelPickerWhenRemoteDoesNotAdvertiseModelConfig() async throws
@Test func providerAppliesConfigOptionResponseToSessionState() async throws
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-task3 -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiTests/ClaudeAdapterCLIExecutionProviderTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 provider base 仍通过 `selectedModelOverride(...)` 驱动 `setModel(...)`，descriptor 也仍保留旧的 session model extension 假设。

**Step 3: Write minimal implementation**

- 在 `ACPExternalExecutionProviderBase` 中删除“发送前统一 setModel”的逻辑，改成按 presentation/config lookup 选择是否调用 `setSessionConfigOption(...)`。
- 缩小 `SessionExecutionPreferences` 对 external ACP 的职责，只保留“本地默认覆盖值”，不再作为选项列表来源。
- 在三个 provider 中提供“如何从远端 `configOptions` 识别 model / approvals 配置项”的最小 adapter。
- 从 `ACPExternalAgentDescriptor` 移除对 model override extension 的主链依赖。

**Step 4: Run test to verify it passes**

同上命令。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift agentGui/Models/SessionExecutionPreferences.swift agentGui/Models/ACPExternalAgentDescriptor.swift agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIExecutionProvider.swift agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift agentGuiTests/OpenCodeCLIExecutionProviderTests.swift agentGuiTests/ClaudeAdapterCLIExecutionProviderTests.swift
git commit -m "refactor: drive external acp providers from remote config options"
```

### Task 4: 新建会话改成执行器选择入口，并锁定会话内 provider

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/NewSessionExecutionProviderMenu.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Toolbar.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchConversationPane.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ConversationExecutionProviderID.swift`

**Step 1: Write the failing test**

如果已有 UI/unit 测试基础不足，先为新 helper 增加 presentation-level tests：

```swift
@Test func providerMenuBuildsAvailableProviderItems() throws
@Test func creatingSessionWithChosenProviderPersistsProviderID() throws
```

建议把这些测试写进新文件 `ACPSessionConfigurationPresentationTests.swift`，避免直接写 SwiftUI snapshot test。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-task4 -only-testing:agentGuiTests/ACPSessionConfigurationPresentationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为目前新建会话入口直接使用 `AppSettings.defaultExecutionProviderID`，没有独立 provider selection menu。

**Step 3: Write minimal implementation**

- 新建 `NewSessionExecutionProviderMenu.swift`，封装通用 provider 选择菜单。
- 把 `SessionListView`、`ChatView+Toolbar`、`WorkbenchConversationPane` 的 `+` 入口全部改为复用这个菜单。
- 让创建动作显式接收 providerID：

```swift
private func createNewSession(providerID: ConversationExecutionProviderID) {
    let newSession = Session()
    newSession.defaultExecutionProviderID = providerID.rawValue
    modelContext.insert(newSession)
    try? modelContext.save()
}
```

**Step 4: Run test to verify it passes**

同上命令。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/NewSessionExecutionProviderMenu.swift agentGui/Views/SessionListView.swift agentGui/Views/ChatView+Toolbar.swift agentGui/Views/Workbench/WorkbenchConversationPane.swift agentGui/Models/ConversationExecutionProviderID.swift agentGuiTests/ACPSessionConfigurationPresentationTests.swift
git commit -m "feat: choose execution provider when creating sessions"
```

### Task 5: 重构 Chat 输入区，改为只读 provider badge + 动态会话配置控件

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ACPSessionConfigurationPresentation.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ACPSessionConfigurationControls.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPSessionConfigurationPresentationTests.swift`

**Step 1: Write the failing test**

在 `ACPSessionConfigurationPresentationTests.swift` 中覆盖：

```swift
@Test func presentationBuildsModeModelAndApprovalsControlsFromRemoteSnapshot() throws
@Test func presentationHidesModelControlWhenConfigCategoryMissing() throws
@Test func chatActionsNoLongerExposeProviderSelectionBindingForExternalSessions() throws
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-task5 -only-testing:agentGuiTests/ACPSessionConfigurationPresentationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为当前输入区仍显示 `chat.executionProviderPicker`，且 model/approval 控件仍从本地静态选项构建。

**Step 3: Write minimal implementation**

- 新建 `ACPSessionConfigurationPresentation`，把 store snapshot 归一化为 UI 控件模型。
- 新建 `ACPSessionConfigurationControls.swift`，封装：
  - provider badge
  - mode picker
  - model picker
  - approvals picker
- 在 `ChatView+InputArea.swift` 中删除 external ACP 的 provider picker，改为：

```swift
if resolvedExecutionProviderID == .builtInAgent {
    builtInControls
} else {
    ACPSessionConfigurationControls(...)
}
```

- 在 `ChatView+Actions.swift` 中新增：
  - `setACPMode(...)`
  - `setACPConfigOption(...)`
  - 从 feature store 读取 session config snapshot 的 helper

**Step 4: Run test to verify it passes**

同上命令。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/ACPSessionConfigurationPresentation.swift agentGui/Views/ACPSessionConfigurationControls.swift agentGui/Views/ChatView+InputArea.swift agentGui/Views/ChatView+Actions.swift agentGuiTests/ACPSessionConfigurationPresentationTests.swift
git commit -m "feat: show dynamic acp session config controls in chat"
```

### Task 6: 运行回归、修正文档并做最终 review

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-25-acp-session-config-ui-design.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-25-acp-session-config-ui-implementation-plan.md`

**Step 1: Run focused tests**

运行本计划顶部的 focused runtime/config tests 命令。

Expected: PASS。

**Step 2: Run existing ACP regression task**

Run task: `Focused ACP Tests Fresh`

Expected: PASS。

**Step 3: Run smoke validation**

Run task: `Quality Smoke`

Expected: PASS，或仅暴露与本次改动无关的历史失败。

**Step 4: Update docs if implementation drifted**

如果最终实现与设计/计划命名略有偏差，回写文档中的文件名、测试命令和已知风险。

**Step 5: Request code review**

使用 @requesting-code-review，重点要求 reviewer 检查：

- external ACP 是否还存在 `setModel` 旧链路残留
- 会话内是否仍可切执行器
- dynamic config UI 是否完全来自远端 snapshot
- session/load replay 后 config state 是否会丢失

**Step 6: Commit**

```bash
git add docs/plans/2026-03-25-acp-session-config-ui-design.md docs/plans/2026-03-25-acp-session-config-ui-implementation-plan.md
git commit -m "docs: finalize acp session config ui rollout plan"
```

## 5. Risks To Watch During Execution

1. `ACPSessionConfigOption.category` 在不同 provider 上未必完全一致，Task 3 中的 provider adapter 可能需要最小 meta fallback，但不要退回标题字符串猜测。
2. `session/load` 恢复时可能先拿到空 snapshot、后拿到 live updates，Task 2 必须把“初始空值 + 后续增量更新”作为正常路径覆盖进 tests。
3. Chat 输入区若直接把动态控件逻辑写进 `ChatView+InputArea.swift`，文件会继续膨胀；优先抽成独立 presentation + subview。
4. 新建会话入口分散在三个视图里，Task 4 必须先抽公共 menu 组件，否则后续容易再次漂移。

## 6. Definition of Done

满足以下条件才算完成：

1. external ACP runtime 已不再暴露 `setModel(...)` 主链。
2. `session/set_mode` 与 `session/set_config_option` 已有 focused tests 且通过。
3. Copilot / OpenCode / Claude adapter 的会话内模型切换来自远端 config option，而不是本地写死列表。
4. Chat 输入区对 external ACP 不再显示 provider picker。
5. 三个新建会话入口都要求用户显式选择执行器。
6. `Focused ACP Tests Fresh` 通过。
7. 代码 review 未发现 provider 锁定或动态 config source 的残留回归。

## 7. Execution Handoff

Plan complete and saved to `docs/plans/2026-03-25-acp-session-config-ui-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
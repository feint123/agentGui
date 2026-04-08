# Dynamic ACP Provider Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the hard-coded external ACP providers with a dynamic profile-driven ACP provider system that validates executable plus initialize on save and uses those profiles across settings, sessions, runtime registry, and recovery.

**Architecture:** Introduce a stable execution-provider reference model and a SwiftData-backed ACP provider profile model first, then migrate persistence and session preference storage to those references, then replace fixed provider assembly with a dynamic registry builder plus one shared dynamic ACP execution provider, and finally swap the settings and chat entry points to consume the new catalog. Keep built-in Anthropic execution separate, and preserve the existing ACP transport/runtime/session projection core.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, xcodebuild, existing ACP runtime stack, `ConversationExecutionProvider`, `ACPExternalExecutionProviderBase`, `ACPClientRuntime`, `ACPExternalAgentRuntimeClient`.

---

## 1. 实施原则

- 全程按 @test-driven-development 执行：先写失败测试，再写最小实现，再跑通过，再提交。
- 这次重构的根是 provider identity，不要先碰 UI 表面；先建立统一引用模型，再替换调用方。
- 外部 ACP 只做数据驱动，不保留 `GitHubCopilotCLIExecutionProvider`、`OpenCodeCLIExecutionProvider`、`ClaudeAdapterCLIExecutionProvider` 作为长期架构的一部分。
- 内置执行器继续保留固定实现，不和外部 ACP profile 混合进同一个 runtime class。
- 不要一次性做完全部 UI；先把 persistence 和 registry 打通，再接设置页和 chat。
- schema 变更必须附带 migration tests 和 in-memory harness 更新。
- 全部任务完成后，使用 @requesting-code-review 做最终 review，重点检查 provider migration、runtime isolation、settings save-time validation 回归。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionProviderReference.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPProviderProfile.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPProviderValidationSnapshot.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Repositories/ACPProviderProfileRepository.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Repositories/ACPProviderMigrationService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPProviderValidationService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPProviderValidationTypes.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/DynamicACPExternalExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/DynamicACPProviderRegistryBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ACPProviderSettingsEditorViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/ACPProviderListSection.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/ACPProviderEditorView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionProviderReferenceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPProviderProfileRepositoryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPProviderMigrationServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPProviderValidationServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/DynamicACPProviderRegistryBuilderTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/DynamicACPExternalExecutionProviderTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SettingsExecutorsDynamicProviderTests.swift`

### 主要修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionExecutionPreferences.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionJob.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPExternalSessionBinding.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RemoteConversationBinding.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChangeProposal.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionProviderRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionPersistenceStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionBindingStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatExecutionProviderAvailabilityModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatComposerAvailabilityRefreshPolicy.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ACPSessionConfigurationPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsExecutorsView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/NewSessionExecutionProviderMenu.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Toolbar.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchConversationPane.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/InMemoryAppHarness.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/MultiSessionExecutionFixtures.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionRecoveryTests.swift`

### 后续删除文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPExternalAgentDescriptor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIExecutionProvider.swift`

## 3. Task 1: 建立统一 Provider 身份模型

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionProviderReference.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionJob.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPExternalSessionBinding.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RemoteConversationBinding.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChangeProposal.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionProviderReferenceTests.swift`

**Step 1: Write the failing test**

Create `ExecutionProviderReferenceTests.swift` covering:

- `.builtIn` 编码解码稳定。
- `.externalACP(profileID:)` 编码解码稳定。
- 旧 `built_in_agent`、`github_copilot_cli`、`opencode_cli`、`claude_adapter_cli` 能映射到兼容引用，供 migration 使用。
- provider reference 为空或未知时回退 `.builtIn`。

示例：

```swift
@Test
func externalACPReferenceRoundTrips() throws {
    let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let encoded = try JSONEncoder().encode(ExecutionProviderReference.externalACP(profileID: id))
    let decoded = try JSONDecoder().decode(ExecutionProviderReference.self, from: encoded)
    #expect(decoded == .externalACP(profileID: id))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/ExecutionProviderReferenceTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL with missing `ExecutionProviderReference` type or missing compatibility decoding helpers.

**Step 3: Write minimal implementation**

- Add `ExecutionProviderReference` plus legacy decoding helpers.
- Add computed properties to models that currently expose `providerIDRaw`, but do not remove old raw fields yet.
- Introduce temporary dual accessors such as `executionProviderReferenceJSON` or `providerReferenceJSON` while preserving old storage for migration.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS for `ExecutionProviderReferenceTests`.

**Step 5: Commit**

```bash
git add agentGui/Models/ExecutionProviderReference.swift agentGui/Models/AppSettings.swift agentGui/Models/Session.swift agentGui/Models/ExecutionJob.swift agentGui/Models/ACPExternalSessionBinding.swift agentGui/Models/RemoteConversationBinding.swift agentGui/Models/ChangeProposal.swift agentGuiTests/ExecutionProviderReferenceTests.swift
git commit -m "refactor: introduce execution provider reference"
```

## 4. Task 2: 引入动态 ACP Provider Profile 模型与仓储

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPProviderProfile.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPProviderValidationSnapshot.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Repositories/ACPProviderProfileRepository.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/InMemoryAppHarness.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPProviderProfileRepositoryTests.swift`

**Step 1: Write the failing test**

Create repository tests covering:

- profile create and fetch by `sortOrder`.
- disabled profile excluded from enabled list.
- arguments and discovered capability snapshots round-trip through JSON helpers.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPProviderProfileRepositoryTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL with missing model or repository types.

**Step 3: Write minimal implementation**

- Add `ACPProviderProfile` SwiftData model.
- Add `ACPProviderValidationSnapshot` and helper computed properties.
- Register `ACPProviderProfile` in `PersistenceSchema.sharedModelTypes` and in-memory test harnesses.
- Add repository APIs: `allProfiles()`, `enabledProfiles()`, `save(profileDraft:)`, `delete(profileID:)`, `nextSortOrder()`.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS for repository tests.

**Step 5: Commit**

```bash
git add agentGui/Models/ACPProviderProfile.swift agentGui/Models/ACPProviderValidationSnapshot.swift agentGui/Repositories/ACPProviderProfileRepository.swift agentGui/agentGuiApp.swift agentGuiTests/TestSupport/InMemoryAppHarness.swift agentGuiTests/ACPProviderProfileRepositoryTests.swift
git commit -m "feat: add acp provider profile persistence"
```

## 5. Task 3: 实现旧配置到动态 Profile 的迁移

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Repositories/ACPProviderMigrationService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionExecutionPreferences.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionJob.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPExternalSessionBinding.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RemoteConversationBinding.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChangeProposal.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPProviderMigrationServiceTests.swift`

**Step 1: Write the failing test**

Create migration tests covering:

- legacy Copilot/OpenCode/Claude config JSON each create one stable preset profile.
- `AppSettings.defaultExecutionProviderID` migrates to `defaultExecutionProviderReference`.
- `Session.defaultExecutionProviderID` migrates to provider reference.
- legacy session preferences migrate into `externalACP[profileID]`.
- rerunning migration is idempotent and does not duplicate profiles.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPProviderMigrationServiceTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL with missing migration service or missing new settings/session accessors.

**Step 3: Write minimal implementation**

- Add `ACPProviderMigrationService`.
- Add stable preset migration keys for legacy providers.
- Replace `SessionExecutionPreferences` with:

```swift
struct SessionExecutionPreferences: Codable, Equatable, Sendable {
    var builtIn: BuiltInSessionExecutionPreferences
    var externalACP: [UUID: ACPRemoteSessionPreferenceSnapshot]
}
```

- Add compatibility decode for old `SessionExecutionPreferences` JSON.
- Run migration during app bootstrap before registry creation.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS for migration tests.

**Step 5: Commit**

```bash
git add agentGui/Repositories/ACPProviderMigrationService.swift agentGui/Models/AppSettings.swift agentGui/Models/Session.swift agentGui/Models/SessionExecutionPreferences.swift agentGui/Models/ExecutionJob.swift agentGui/Models/ACPExternalSessionBinding.swift agentGui/Models/RemoteConversationBinding.swift agentGui/Models/ChangeProposal.swift agentGui/agentGuiApp.swift agentGuiTests/ACPProviderMigrationServiceTests.swift
git commit -m "feat: migrate legacy acp providers to dynamic profiles"
```

## 6. Task 4: 实现 Save-time Validation 与 Initialize 探测服务

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPProviderValidationTypes.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPProviderValidationService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPClientRuntime.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPManagedClientRuntime.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPProviderValidationServiceTests.swift`

**Step 1: Write the failing test**

Create tests for:

- executable path missing returns `.missingExecutable`.
- executable found but initialize timeout returns `.initializeFailed`.
- initialize success returns agent info, capabilities, auth methods, resolved path, verified time.
- temporary runtime is always closed after validation.

Prefer a tiny fake stdio ACP fixture instead of real provider CLIs.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPProviderValidationServiceTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL with missing validation service or result types.

**Step 3: Write minimal implementation**

- Add `ACPProviderValidationService.validate(displayName:executablePath:arguments:)`.
- Resolve executable using `which`-equivalent logic or absolute-path existence checks inside a testable helper.
- Launch a temporary ACP runtime.
- Send one `initialize` request with current client capabilities.
- Convert response into `ACPProviderValidationSnapshot`.
- Ensure runtime teardown with `defer`.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS for validation service tests.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPProviderValidationTypes.swift agentGui/Services/ACP/ACPProviderValidationService.swift agentGui/Services/ACP/ACPClientRuntime.swift agentGui/Services/ACP/ACPManagedClientRuntime.swift agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift agentGuiTests/ACPProviderValidationServiceTests.swift
git commit -m "feat: add acp provider validation service"
```

## 7. Task 5: 用动态 Registry Builder 替换固定 Provider 装配

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/DynamicACPExternalExecutionProvider.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/DynamicACPProviderRegistryBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionProviderRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionPersistenceStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionBindingStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/MultiSessionExecutionFixtures.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/DynamicACPProviderRegistryBuilderTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/DynamicACPExternalExecutionProviderTests.swift`

**Step 1: Write the failing test**

Create tests for:

- enabled profiles produce external providers in registry.
- disabled profiles do not.
- provider lookup by `ExecutionProviderReference.externalACP(profileID:)` works.
- runtime isolation key includes provider reference or profileID, so two dynamic providers do not share runtime or binding state.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/DynamicACPProviderRegistryBuilderTests -only-testing:agentGuiTests/DynamicACPExternalExecutionProviderTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL with missing dynamic provider or registry APIs.

**Step 3: Write minimal implementation**

- Replace fixed registry fields with a built-in provider plus external provider dictionary.
- Change provider lookup and compatibility driver APIs to accept `ExecutionProviderReference`.
- Implement `DynamicACPExternalExecutionProvider` using profile-backed launch configuration and the existing `ACPExternalExecutionProviderBase` flow.
- Move session binding store to use provider reference or stable external provider key, not enum case.
- Build registry from repository output inside `ClaudeService+Messaging`.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS for dynamic registry and provider tests.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/DynamicACPExternalExecutionProvider.swift agentGui/Services/ACP/DynamicACPProviderRegistryBuilder.swift agentGui/Services/ConversationExecutionProviderRegistry.swift agentGui/Services/Execution/ExecutionPersistenceStore.swift agentGui/Services/ACP/ACPExternalSessionBindingStore.swift agentGui/Services/ClaudeService/ClaudeService+Messaging.swift agentGuiTests/TestSupport/MultiSessionExecutionFixtures.swift agentGuiTests/DynamicACPProviderRegistryBuilderTests.swift agentGuiTests/DynamicACPExternalExecutionProviderTests.swift
git commit -m "refactor: build external acp providers dynamically"
```

## 8. Task 6: 替换设置页为动态 Provider 管理 UI

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ACPProviderSettingsEditorViewModel.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/ACPProviderListSection.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/ACPProviderEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsExecutorsView.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SettingsExecutorsDynamicProviderTests.swift`

**Step 1: Write the failing test**

Create tests for:

- save action validates executable and initialize before persisting enabled provider.
- validation failure keeps draft unsaved and exposes error message.
- successful save persists provider profile and discovered snapshot.
- default provider picker lists built-in plus enabled external profiles.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/SettingsExecutorsDynamicProviderTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL with missing dynamic settings state or editor view model.

**Step 3: Write minimal implementation**

- Replace the three static provider sections with a profile list and editor.
- Move validation and save orchestration into `ACPProviderSettingsEditorViewModel`.
- Replace three availability statuses in `SettingsStore` with dynamic profile states.
- Keep built-in approval-mode section separate.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS for settings dynamic provider tests.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/ACPProviderSettingsEditorViewModel.swift agentGui/Views/Settings/ACPProviderListSection.swift agentGui/Views/Settings/ACPProviderEditorView.swift agentGui/Views/Settings/SettingsStore.swift agentGui/Views/Settings/SettingsExecutorsView.swift agentGuiTests/SettingsExecutorsDynamicProviderTests.swift
git commit -m "feat: add dynamic acp provider settings ui"
```

## 9. Task 7: 替换会话选择、Chat Composer 与执行偏好入口

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatExecutionProviderAvailabilityModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatComposerAvailabilityRefreshPolicy.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ACPSessionConfigurationPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/NewSessionExecutionProviderMenu.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Toolbar.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchConversationPane.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionRecoveryTests.swift`

**Step 1: Write the failing test**

Extend or add tests covering:

- new session creation stores external profile reference instead of enum raw value.
- runtime coordinator still releases sibling external providers by runtime scope even when provider identity is profile-backed.
- recovery path can rehydrate queued or running jobs that reference dynamic providers.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests -only-testing:agentGuiTests/ConversationExecutionRecoveryTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL with mismatched provider identity usage or missing dynamic lookup APIs.

**Step 3: Write minimal implementation**

- Replace `resolvedExecutionProviderID` with `resolvedExecutionProviderReference` plus a resolved display snapshot.
- Drive composer badge, readiness text, refresh policy, slash command provider, and ACP session config UI from the resolved provider reference.
- Update new session menus and session clone logic to persist provider reference.
- Keep built-in code path explicit and external dynamic path generic.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS for runtime coordinator and recovery tests.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/ChatExecutionProviderAvailabilityModel.swift agentGui/ViewModels/ChatComposerAvailabilityRefreshPolicy.swift agentGui/ViewModels/ACPSessionConfigurationPresentation.swift agentGui/Views/NewSessionExecutionProviderMenu.swift agentGui/Views/ChatView+Actions.swift agentGui/Views/ChatView+InputArea.swift agentGui/Views/ChatView+Toolbar.swift agentGui/Views/SessionListView.swift agentGui/Views/Workbench/WorkbenchConversationPane.swift agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift agentGuiTests/ConversationExecutionRecoveryTests.swift
git commit -m "refactor: switch chat and session flows to dynamic providers"
```

## 10. Task 8: 删除固定外部 Provider 类型并做回归收尾

**Files:**
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPExternalAgentDescriptor.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/InMemoryAppHarness.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`

**Step 1: Write the failing test**

Adjust or add final regression tests covering:

- in-memory test harness boots without deleted provider classes.
- ACP external provider base tests can use the new dynamic provider fixture.
- app bootstrap creates registry from profile repository, not fixed providers.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL while tests still instantiate removed provider-specific classes or fixtures.

**Step 3: Write minimal implementation**

- Remove dead fixed-provider code.
- Update test fixtures to use `DynamicACPExternalExecutionProvider` or dedicated dynamic test doubles.
- Ensure schema and bootstrap remain clean with no references to old provider-specific configuration fields.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS for ACP base tests.

**Step 5: Commit**

```bash
git add -A
git commit -m "refactor: remove fixed external acp providers"
```

## 11. Final Verification

Run the focused regression suite:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/ExecutionProviderReferenceTests \
  -only-testing:agentGuiTests/ACPProviderProfileRepositoryTests \
  -only-testing:agentGuiTests/ACPProviderMigrationServiceTests \
  -only-testing:agentGuiTests/ACPProviderValidationServiceTests \
  -only-testing:agentGuiTests/DynamicACPProviderRegistryBuilderTests \
  -only-testing:agentGuiTests/DynamicACPExternalExecutionProviderTests \
  -only-testing:agentGuiTests/SettingsExecutorsDynamicProviderTests \
  -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests \
  -only-testing:agentGuiTests/ConversationExecutionRecoveryTests \
  -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: PASS for all selected tests.

Then run a broader smoke check:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

Expected: full scheme passes, or only known unrelated pre-existing failures remain.

## 12. Execution Notes

- Task 1 through Task 3 must land before any UI changes.
- Task 4 can be developed in parallel with parts of Task 2, but merge only after migration lands.
- Task 5 is the integration pivot; do not start Task 6 or Task 7 until dynamic registry lookup is green.
- Task 8 should be a true delete pass. If old fixed-provider files still exist after Task 7, the refactor is incomplete.

## 13. Open Review Checklist

- Does every provider identity path now flow through `ExecutionProviderReference` rather than `ConversationExecutionProviderID` for external ACP?
- Is save-time validation the only path that writes discovered `agentInfo` and `agentCapabilities`?
- Can an external provider be removed without corrupting old sessions or queued jobs?
- Are runtime isolation keys still provider-scoped after switching to dynamic profile IDs?
- Are built-in approval settings still independent from external ACP provider session config options?

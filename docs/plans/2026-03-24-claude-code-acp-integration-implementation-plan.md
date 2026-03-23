# Claude Code ACP Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Claude as a first-class external ACP-backed conversation executor in agentGui by integrating a Claude ACP adapter CLI into the existing shared external ACP provider architecture.

**Architecture:** Reuse the current external ACP stack instead of creating a new runtime. Add a Claude-specific provider ID, configuration, availability/authentication handling, launch factory, event normalization, and UI wiring on top of `ACPExternalExecutionProviderBase`, while keeping all protocol handling capability-aware and treating the adapter CLI as the real ACP endpoint.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, existing ACP runtime stack (`ACPClientRuntime`, `ACPExternalExecutionProviderBase`, `ACPExternalAgentRuntimeClient`, `ACPPermissionCenter`), Settings UI, shared execution-provider registry.

---

## 1. 实施原则

- 这次实现不是“直接接入 claude CLI”，而是“接入 Claude ACP adapter CLI”；代码、设置和错误文案都要体现这层关系。
- 严格按 @test-driven-development 执行：先加失败测试，再写最小实现，再验证通过，再提交。
- 不要重写 external ACP 共用层；优先复用 `ACPExternalExecutionProviderBase`、`ACPCLIAvailabilityService`、`ACPExternalAgentRuntimeClient`、`ACPExternalAgentEventNormalizer`。
- 所有 provider-specific 能力都要 capability-aware，尤其是 `session/load`、`session/set_model`、`session/list`、认证方法和命令广告。
- V1 只做本地 stdio adapter CLI 接入，不引入 SDK 内嵌、gateway auth 表单、session list/fork/close UI。
- 认证状态必须作为一等状态对待；“可执行文件存在但未认证”不能被降级成“不可用”。
- Claude provider 的主价值是认证、权限和结构化更新投影，不要假设 client `fs/*` / `terminal/*` 回调是主执行链。
- 完成全部任务后，使用 @requesting-code-review 做一次最终 review，重点检查认证流、session restore 和 UI 回归。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIAvailabilityService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIRuntimeFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeAdapterCLIAvailabilityServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeAdapterCLIRuntimeFactoryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeAdapterCLIExecutionProviderTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ConversationExecutionProviderID.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/GitHubCopilotCLIConfiguration.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPExternalAgentDescriptor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentEventNormalizer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionProviderRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatExecutionProviderAvailabilityModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsExecutorsView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionProviderRegistryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatExecutionProviderAvailabilityModelTests.swift`

### 参考文件

- `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-24-claude-code-acp-integration-architecture.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-22-external-acp-provider-abstraction-implementation-plan.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-20-opencode-acp-integration-implementation-plan.md`

## 3. 关键设计决策

### 3.1 Provider ID 命名要体现 adapter 层

V1 不建议把新 provider 命名成 `claudeCodeCLI`，因为真正的 ACP endpoint 是 adapter。建议枚举值为：

```swift
enum ConversationExecutionProviderID: String, Codable, CaseIterable, Sendable {
    case builtInAgent = "built_in_agent"
    case githubCopilotCLI = "github_copilot_cli"
    case openCodeCLI = "opencode_cli"
    case claudeAdapterCLI = "claude_adapter_cli"
}
```

显示层可以继续使用 “Claude”，但持久化 ID 与运行时日志应保留 adapter 语义。

### 3.2 配置先复用现有 `ACPCLIConfiguration`

当前仓库已经把 provider CLI 配置收敛到 `ACPCLIConfiguration`，所以 V1 不需要再引入新配置结构，只需补默认值和 `AppSettings` 槽位：

```swift
extension ACPCLIConfiguration {
    static let claudeAdapterDefault = ACPCLIConfiguration(
        executablePath: "claude-agent-acp",
        defaultModel: "",
        defaultApprovalMode: "default"
    )
}
```

### 3.3 认证是可用性的一部分

Claude adapter 公开实现广告 `authMethods`，并支持 terminal auth。因此 availability 不能只做“文件是否存在”的静态探测。

V1 约定：

1. `notInstalled`: 找不到 adapter executable。
2. `launchFailed`: 可执行文件存在但进程无法拉起或 initialize 崩溃。
3. `notAuthenticated`: initialize 成功，但 provider 要求认证或明确暴露 auth method 且当前会话无法继续。
4. `available`: 可以直接进入 session flow。

### 3.4 事件模型先复用共享 normalizer

V1 不要创建独立的 `ClaudeAdapterEventNormalizer`。优先复用 `ACPExternalAgentEventNormalizer`，只在共享层补足下面这几类 Claude adapter 更常见的更新：

1. `usage_update`
2. `available_commands_update`
3. `current_mode_update`
4. 由 adapter 投影出来的 tool call / tool call update

如果共享 normalizer 无法覆盖，再在 provider 内包一层极薄的补丁适配器。

## 4. 任务拆解

### Task 1: 新增 Claude provider 标识与配置持久化

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ConversationExecutionProviderID.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/GitHubCopilotCLIConfiguration.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPExternalAgentDescriptor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionProviderRegistryTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

struct ConversationExecutionProviderRegistryTests {
    @Test func claudeProviderMetadataDefaultsAreRegistered() {
        #expect(ConversationExecutionProviderID(rawValue: "claude_adapter_cli") == .claudeAdapterCLI)
        #expect(ACPCLIConfiguration.claudeAdapterDefault.executablePath == "claude-agent-acp")
        #expect(ACPExternalAgentDescriptor.claudeAdapter.providerID == .claudeAdapterCLI)

        let settings = AppSettings()
        #expect(settings.claudeAdapterCLIConfiguration.executablePath == "claude-agent-acp")
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ConversationExecutionProviderRegistryTests`
Expected: FAIL with missing `claudeAdapterCLI`, missing `claudeAdapterDefault`, or missing `claudeAdapterCLIConfiguration`.

**Step 3: Write minimal implementation**

```swift
extension ACPCLIConfiguration {
    static let claudeAdapterDefault = ACPCLIConfiguration(
        executablePath: "claude-agent-acp",
        defaultModel: "",
        defaultApprovalMode: "default"
    )
}

extension ACPExternalAgentDescriptor {
    static let claudeAdapter = ACPExternalAgentDescriptor(
        providerID: .claudeAdapterCLI,
        displayName: "Claude",
        defaultExecutablePath: ACPCLIConfiguration.claudeAdapterDefault.executablePath,
        defaultArguments: [],
        supportsSessionModelOverrideByDefault: true,
        supportsCustomAgentName: false,
        defaultEnvironment: [:],
        executionBehavior: ACPExternalProviderExecutionBehavior(
            requiresCapabilityNegotiationForModelOverride: true,
            supportsEnvironmentOverrides: false,
            supportsCustomAgentName: false
        )
    )
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ConversationExecutionProviderRegistryTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/ConversationExecutionProviderID.swift agentGui/Models/GitHubCopilotCLIConfiguration.swift agentGui/Models/ACPExternalAgentDescriptor.swift agentGui/Models/AppSettings.swift agentGuiTests/ConversationExecutionProviderRegistryTests.swift
git commit -m "feat: add claude adapter provider metadata"
```

### Task 2: 增加 Claude adapter 可用性检测与启动工厂

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIAvailabilityService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIRuntimeFactory.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatExecutionProviderAvailabilityModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeAdapterCLIAvailabilityServiceTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeAdapterCLIRuntimeFactoryTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatExecutionProviderAvailabilityModelTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

struct ClaudeAdapterCLIAvailabilityServiceTests {
    @Test func quickStatusMarksMissingExecutableAsNotInstalled() {
        let service = ClaudeAdapterCLIAvailabilityService()
        let status = service.quickStatus(configuration: .init(executablePath: "/missing/claude-agent-acp", defaultModel: "", defaultApprovalMode: "default"))
        #expect(status.kind == .notInstalled)
    }
}

struct ClaudeAdapterCLIRuntimeFactoryTests {
    @Test func runtimeFactoryUsesBareAdapterCommand() {
        let factory = ClaudeAdapterCLIRuntimeFactory()
        let launch = factory.makeLaunchConfiguration(executablePath: "claude-agent-acp", workingDirectory: "/tmp/project")

        #expect(launch.command == "claude-agent-acp")
        #expect(launch.arguments.isEmpty)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ClaudeAdapterCLIAvailabilityServiceTests -only-testing:agentGuiTests/ClaudeAdapterCLIRuntimeFactoryTests -only-testing:agentGuiTests/ChatExecutionProviderAvailabilityModelTests`
Expected: FAIL with missing availability service or runtime factory symbols.

**Step 3: Write minimal implementation**

```swift
typealias ClaudeAdapterCLIAvailabilityStatus = ACPCLIAvailabilityStatus

struct ClaudeAdapterCLIAvailabilityService {
    private let sharedService: ACPCLIAvailabilityService

    init(sharedService: ACPCLIAvailabilityService = ACPCLIAvailabilityService()) {
        self.sharedService = sharedService
    }

    func quickStatus(configuration: ACPCLIConfiguration) -> ClaudeAdapterCLIAvailabilityStatus {
        sharedService.quickStatus(configuration: configuration)
    }

    func checkStatus(configuration: ACPCLIConfiguration) async throws -> ClaudeAdapterCLIAvailabilityStatus {
        try await sharedService.checkStatus(configuration: configuration)
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ClaudeAdapterCLIAvailabilityServiceTests -only-testing:agentGuiTests/ClaudeAdapterCLIRuntimeFactoryTests -only-testing:agentGuiTests/ChatExecutionProviderAvailabilityModelTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIAvailabilityService.swift agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIRuntimeFactory.swift agentGui/ViewModels/ChatExecutionProviderAvailabilityModel.swift agentGui/Views/Settings/SettingsStore.swift agentGuiTests/ClaudeAdapterCLIAvailabilityServiceTests.swift agentGuiTests/ClaudeAdapterCLIRuntimeFactoryTests.swift agentGuiTests/ChatExecutionProviderAvailabilityModelTests.swift
git commit -m "feat: add claude adapter availability and launch factory"
```

### Task 3: 让 ACP 运行时显式支持 Claude adapter 的认证与方法广告

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPModels.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentEventNormalizer.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeAdapterCLIExecutionProviderTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

struct ClaudeAdapterCLIExecutionProviderTests {
    @Test func runtimeClientSurfacesAuthMethodsFromInitialize() async throws {
        let harness = try ClaudeAdapterProviderHarness.initializeOnly(authMethods: [
            ACPAuthMethod(id: "claude-login", name: "Log in with Claude", description: "Run login", type: "terminal", arguments: nil, meta: nil)
        ])

        let snapshot = try await harness.runtimeClient.initializeIfNeeded()

        #expect(snapshot.authMethods?.contains(where: { $0.id == "claude-login" }) == true)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ClaudeAdapterCLIExecutionProviderTests`
Expected: FAIL because runtime client does not expose auth methods or snapshot metadata needed by provider logic.

**Step 3: Write minimal implementation**

```swift
struct ACPExternalAgentCapabilitySnapshot: Equatable, Sendable {
    let loadSession: Bool
    let supportsSessionModelOverride: Bool
    let agentVersion: String?
    let authMethods: [ACPAuthMethod]?
}
```

Add auth methods from initialize response into the snapshot and ensure provider code can inspect them before session creation.

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ClaudeAdapterCLIExecutionProviderTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPModels.swift agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift agentGui/Services/ACP/ACPExternalAgentEventNormalizer.swift agentGuiTests/ClaudeAdapterCLIExecutionProviderTests.swift
git commit -m "refactor: surface claude adapter auth metadata in acp runtime"
```

### Task 4: 接入 Claude adapter execution provider 到 shared external ACP provider 层

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionProviderRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeAdapterCLIExecutionProviderTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionProviderRegistryTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

@MainActor
struct ClaudeAdapterCLIExecutionProviderTests {
    @Test func providerResolvesClaudeConfigurationFromSettings() async throws {
        let provider = ClaudeAdapterCLIExecutionProvider()
        let settings = AppSettings()
        settings.claudeAdapterCLIConfiguration = .claudeAdapterDefault

        let session = Session.fixture()
        let resolved = provider.debugResolveConfiguration(for: session, settings: settings)

        #expect(resolved.executablePath == "claude-agent-acp")
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ClaudeAdapterCLIExecutionProviderTests -only-testing:agentGuiTests/ConversationExecutionProviderRegistryTests`
Expected: FAIL with missing provider type or registry integration.

**Step 3: Write minimal implementation**

```swift
@MainActor
final class ClaudeAdapterCLIExecutionProvider: ACPExternalExecutionProviderBase<ACPCLIConfiguration> {
    private let availabilityService: ClaudeAdapterCLIAvailabilityService
    private let runtimeFactory: ClaudeAdapterCLIRuntimeFactory

    init(
        availabilityService: ClaudeAdapterCLIAvailabilityService = ClaudeAdapterCLIAvailabilityService(),
        runtimeFactory: ClaudeAdapterCLIRuntimeFactory = ClaudeAdapterCLIRuntimeFactory(),
        ...
    ) {
        self.availabilityService = availabilityService
        self.runtimeFactory = runtimeFactory
        super.init(providerID: .claudeAdapterCLI, ...)
    }
}
```

Wire it into the provider registry and dependency construction in `agentGuiApp.swift`.

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ClaudeAdapterCLIExecutionProviderTests -only-testing:agentGuiTests/ConversationExecutionProviderRegistryTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIExecutionProvider.swift agentGui/Services/ConversationExecutionProviderRegistry.swift agentGui/Services/ClaudeService/ClaudeService+Messaging.swift agentGui/agentGuiApp.swift agentGuiTests/ClaudeAdapterCLIExecutionProviderTests.swift agentGuiTests/ConversationExecutionProviderRegistryTests.swift
git commit -m "feat: register claude adapter execution provider"
```

### Task 5: 处理 notAuthenticated 状态与设置页引导

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsExecutorsView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatExecutionProviderAvailabilityModelTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

struct ChatExecutionProviderAvailabilityModelTests {
    @Test func claudeProviderRemainsSelectableWhenAuthenticationIsRequired() async throws {
        let options = ConversationExecutionProviderID.optionItems(
            copilotAvailabilityStatus: .available,
            openCodeAvailabilityStatus: .available,
            claudeAvailabilityStatus: .notAuthenticated
        )

        let item = try #require(options.first(where: { $0.id == ConversationExecutionProviderID.claudeAdapterCLI.rawValue }))
        #expect(item.isEnabled == true)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ChatExecutionProviderAvailabilityModelTests`
Expected: FAIL because the availability model has no Claude branch or treats `notAuthenticated` as disabled.

**Step 3: Write minimal implementation**

Update execution-option generation and settings/chat warnings so Claude remains selectable, but shows explicit setup guidance when status is `notAuthenticated`.

```swift
case .claudeAdapterCLI:
    isEnabled = claudeAvailabilityStatus.kind == .available || claudeAvailabilityStatus.kind == .notAuthenticated
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ChatExecutionProviderAvailabilityModelTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/Settings/SettingsStore.swift agentGui/Views/Settings/SettingsExecutorsView.swift agentGui/Views/ChatView+Actions.swift agentGuiTests/ChatExecutionProviderAvailabilityModelTests.swift
git commit -m "feat: add claude adapter authentication guidance"
```

### Task 6: 验证共享 external ACP 投影链能消费 Claude adapter 更新

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentEventNormalizer.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeAdapterCLIExecutionProviderTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

@MainActor
struct ClaudeAdapterCLIExecutionProviderTests {
    @Test func providerProjectsUsageAndSlashCommandsFromClaudeAdapterUpdates() async throws {
        let harness = try ClaudeAdapterProviderHarness.promptFlow(
            updates: [
                .availableCommands(["/compact", "/say-hello"]),
                .usageUpdate(used: 42, size: 200_000),
                .assistantChunk("hello")
            ]
        )

        try await harness.provider.send(harness.request(text: "hello"))

        #expect(harness.featureStore.remoteCommands == ["/compact", "/say-hello"])
        #expect(harness.latestAssistantMessage()?.textContent?.contains("hello") == true)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ClaudeAdapterCLIExecutionProviderTests`
Expected: FAIL because usage or available commands updates are not fully projected for Claude provider traffic.

**Step 3: Write minimal implementation**

Patch the shared normalizer so Claude adapter updates use the same projection path as OpenCode/Copilot.

```swift
switch update.sessionUpdate {
case .availableCommandsUpdate:
    return .feature(.availableCommands(...))
case .usageUpdate:
    return .feature(.usage(...))
default:
    ...
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ClaudeAdapterCLIExecutionProviderTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalAgentEventNormalizer.swift agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift agentGuiTests/ClaudeAdapterCLIExecutionProviderTests.swift
git commit -m "fix: project claude adapter updates through shared acp pipeline"
```

### Task 7: 运行回归测试并补最终文档引用

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-24-claude-code-acp-integration-architecture.md`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeAdapterCLIAvailabilityServiceTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeAdapterCLIRuntimeFactoryTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeAdapterCLIExecutionProviderTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionProviderRegistryTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatExecutionProviderAvailabilityModelTests.swift`

**Step 1: Write the failing test**

No new failing product test in this task. Instead, add one final integration-style assertion if coverage is still missing: provider registry returns Claude provider for sessions whose default execution provider is `claude_adapter_cli`.

```swift
@Test func registryResolvesClaudeProviderFromSessionPreference() {
    let session = Session.fixture()
    session.defaultExecutionProviderID = ConversationExecutionProviderID.claudeAdapterCLI.rawValue
    let settings = AppSettings()

    let provider = registry.provider(for: session, settings: settings)
    #expect(provider.id == .claudeAdapterCLI)
}
```

**Step 2: Run focused tests**

Run: `xcodebuild test -parallel-testing-enabled NO -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ClaudeAdapterCLIAvailabilityServiceTests -only-testing:agentGuiTests/ClaudeAdapterCLIRuntimeFactoryTests -only-testing:agentGuiTests/ClaudeAdapterCLIExecutionProviderTests -only-testing:agentGuiTests/ConversationExecutionProviderRegistryTests -only-testing:agentGuiTests/ChatExecutionProviderAvailabilityModelTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS.

**Step 3: Run broader ACP regression suite**

Run: `xcodebuild test -parallel-testing-enabled NO -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiTests/ACPExternalSessionFeatureStoreTests -only-testing:agentGuiTests/ACPExternalSessionFeatureExtractorTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS; no regressions in existing external ACP providers.

**Step 4: Update design doc status note**

Add a short “Implementation status / follow-ups” note to the technical design doc only if the final implementation uncovers a real deviation, such as auth method semantics differing from the public adapter repository.

**Step 5: Commit**

```bash
git add docs/technical-spec/2026-03-24-claude-code-acp-integration-architecture.md agentGuiTests/ClaudeAdapterCLIAvailabilityServiceTests.swift agentGuiTests/ClaudeAdapterCLIRuntimeFactoryTests.swift agentGuiTests/ClaudeAdapterCLIExecutionProviderTests.swift agentGuiTests/ConversationExecutionProviderRegistryTests.swift agentGuiTests/ChatExecutionProviderAvailabilityModelTests.swift
git commit -m "test: validate claude adapter acp integration"
```

## 5. 风险清单

### 风险 1：把 `notAuthenticated` 错误归类为 `notInstalled`

如果 availability service 只看 PATH，会让设置页误导用户。必须通过 initialize + auth metadata 明确区分。

### 风险 2：错误假设 adapter 会调用 client 文件或终端方法

Claude adapter 可能更多依赖其内部工具执行并只发 ACP 更新。不要用“没有收到 `fs/read_text_file`”来推断 provider 故障。

### 风险 3：在 V1 过早开放 `session/list` / `fork` / `close`

这些能力虽然 adapter 可能支持，但会拉高 UI 和状态存储复杂度。V1 先把 send / restore / auth / projection 跑稳。

### 风险 4：配置命名与品牌不清

设置页若只写 “Claude Code CLI”，会把真实故障点藏起来。V1 至少要在安装引导或状态文案里明确提到 ACP adapter。

## 6. 完成标准

满足以下条件即可认为本计划完成：

1. 设置页可以配置 Claude adapter executable，并显示其可用性状态。
2. `claude_adapter_cli` 能作为会话执行器被选择与持久化。
3. provider registry 可以返回 Claude execution provider。
4. Claude provider 可以完成 initialize、认证状态判定、session/new 或 session/load、session/prompt、session/cancel。
5. Claude adapter 的 `usage_update`、`available_commands_update`、消息增量和工具事件能通过共享 ACP 投影层进入现有 UI。
6. 现有 GitHub Copilot 与 OpenCode ACP 测试不回归。

## 7. 执行交接

Plan complete and saved to `docs/plans/2026-03-24-claude-code-acp-integration-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?

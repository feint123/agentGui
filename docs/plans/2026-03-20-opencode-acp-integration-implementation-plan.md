# OpenCode ACP Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Turn the existing GitHub Copilot-only ACP executor path into a generic external ACP integration layer and add OpenCode CLI as a first-class conversation executor.

**Architecture:** Keep the built-in Claude path unchanged, but stop encoding ACP assumptions inside GitHub Copilot-specific types. Extract shared ACP launch, capability negotiation, session binding, and event normalization pieces into provider-agnostic components, then reattach GitHub Copilot and add OpenCode with small provider-specific configuration and UI differences.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, existing ACP runtime (`ACPManagedClientRuntime`, `ACPClientRuntime`, `ACPLocalClientHandler`), existing chat execution provider routing and settings UI.

---

## 1. 实施原则

- 这份计划应在独立 worktree 中执行；先用 @brainstorming 准备实现上下文，再按本计划逐 task 落地。
- 全程按 @test-driven-development 执行：先写失败测试，再写最小实现，再跑通过，再提交。
- 不要复制第二份 Copilot provider；OpenCode 必须复用共享 ACP 外部执行器基础设施。
- OpenCode V1 只支持 `opencode acp` 子进程模式；不要把 HTTP Server、Question Tool、动态 Agent 列表带进首版主链。
- 所有非标准 ACP 能力都要 capability-aware：`session/load`、`session/set_model`、`session/set_mode` 只能在握手确认后启用。
- GitHub Copilot 现有行为不能回归，尤其是 PATH 解析、session/load、多轮 turn 复用、工具投影和权限桥。
- 完成全部任务后，使用 @requesting-code-review 做一次最终 review，再考虑合并。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/OpenCodeCLIConfiguration.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPExternalAgentDescriptor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPExternalSessionBinding.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPCLIAvailabilityService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionBindingStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentEventNormalizer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIRuntimeFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIAvailabilityService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalAgentRuntimeClientTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalSessionBindingStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalAgentEventNormalizerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIRuntimeFactoryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIAvailabilityServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ConversationExecutionProviderID.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/GitHubCopilotCLIConfiguration.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionExecutionPreferences.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionProviderRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPMethodCatalog.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIAvailabilityService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIRuntimeFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/CopilotSessionBridge.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/CopilotACPEventNormalizer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatExecutionProviderAvailabilityModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsExecutorsView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionProviderSelectionTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionProviderRegistryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionExecutionPreferencesTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatExecutionProviderAvailabilityModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIAvailabilityServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIRuntimeFactoryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CopilotSessionBridgeTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`

### 参考文档

- `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-20-opencode-acp-integration-architecture.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-20-github-copilot-cli-integration-implementation-plan.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-20-acp-composer-preferences-implementation-plan.md`

## 3. 关键设计决策

### 3.1 Provider ID 与显示层分离

执行器枚举要新增 `opencode_cli`，但 UI 和运行时差异要落在 descriptor，而不是在 `switch` 里散落硬编码：

```swift
enum ConversationExecutionProviderID: String, Codable, CaseIterable, Sendable {
    case builtInAgent = "built_in_agent"
    case githubCopilotCLI = "github_copilot_cli"
    case openCodeCLI = "opencode_cli"
}

struct ACPExternalAgentDescriptor: Sendable, Equatable {
    let providerID: ConversationExecutionProviderID
    let displayName: String
    let defaultExecutablePath: String
    let defaultArguments: [String]
    let supportsSessionModelOverrideByDefault: Bool
    let supportsCustomAgentName: Bool
    let defaultEnvironment: [String: String]
}
```

### 3.2 OpenCode 配置单独持久化，通用行为共享

V1 不急着把所有外部 ACP provider 配置压成一个大 JSON 字典。先给 OpenCode 增加独立配置和 session override，等第三个 ACP provider 落地时再统一。

```swift
struct OpenCodeCLIConfiguration: Codable, Equatable, Sendable {
    var executablePath: String
    var defaultModel: String
    var defaultApprovalMode: String
    var environment: [String: String]
    var useACPStdIO: Bool

    static let `default` = OpenCodeCLIConfiguration(
        executablePath: "opencode",
        defaultModel: "",
        defaultApprovalMode: "default",
        environment: [:],
        useACPStdIO: true
    )
}
```

### 3.3 capability-aware 是共享 ACP 层的真边界

通用外部 ACP runtime client 必须缓存 initialize 结果，并且只在握手允许时调用可选能力：

```swift
struct ACPExternalAgentCapabilitySnapshot: Equatable, Sendable {
    let loadSession: Bool
    let supportsSessionModelOverride: Bool
    let agentVersion: String?
}

if let remoteSessionID, capabilitySnapshot.loadSession {
    _ = try await managedRuntime.runtime.loadSession(
        ACPLoadSessionRequest(cwd: workingDirectory, sessionID: remoteSessionID)
    )
} else {
    let response = try await managedRuntime.runtime.newSession(
        ACPNewSessionRequest(cwd: workingDirectory)
    )
    remoteSessionID = response.sessionID
}
```

## 4. 任务拆解

### Task 1: 固化 OpenCode 执行器元数据与全局配置

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/OpenCodeCLIConfiguration.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPExternalAgentDescriptor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ConversationExecutionProviderID.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/GitHubCopilotCLIConfiguration.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionProviderSelectionTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

@MainActor
struct ConversationExecutionProviderSelectionTests {
    @Test func appSettingsPersistsOpenCodeDefaults() {
        let settings = AppSettings()

        #expect(ConversationExecutionProviderID(rawValue: "opencode_cli") == .openCodeCLI)
        #expect(settings.openCodeCLIConfiguration.executablePath == "opencode")
        #expect(settings.openCodeCLIConfiguration.useACPStdIO == true)
        #expect(ACPExternalAgentDescriptor.openCode.defaultArguments == ["acp"])
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ConversationExecutionProviderSelectionTests`
Expected: FAIL with missing `openCodeCLI`, missing `openCodeCLIConfiguration`, or missing descriptor symbols.

**Step 3: Write minimal implementation**

```swift
enum ConversationExecutionProviderID: String, Codable, CaseIterable, Sendable {
    case builtInAgent = "built_in_agent"
    case githubCopilotCLI = "github_copilot_cli"
    case openCodeCLI = "opencode_cli"
}

struct OpenCodeCLIConfiguration: Codable, Equatable, Sendable {
    var executablePath: String
    var defaultModel: String
    var defaultApprovalMode: String
    var environment: [String: String]
    var useACPStdIO: Bool
}

extension AppSettings {
    var openCodeCLIConfiguration: OpenCodeCLIConfiguration {
        get { /* decode JSON */ }
        set { /* encode JSON */ }
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ConversationExecutionProviderSelectionTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/OpenCodeCLIConfiguration.swift agentGui/Models/ACPExternalAgentDescriptor.swift agentGui/Models/ConversationExecutionProviderID.swift agentGui/Models/GitHubCopilotCLIConfiguration.swift agentGui/Models/AppSettings.swift agentGuiTests/ConversationExecutionProviderSelectionTests.swift
git commit -m "feat: add opencode executor metadata"
```

### Task 2: 泛化可用性检测与 session-level 执行偏好

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPCLIAvailabilityService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionExecutionPreferences.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatExecutionProviderAvailabilityModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIAvailabilityService.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionExecutionPreferencesTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatExecutionProviderAvailabilityModelTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIAvailabilityServiceTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

@MainActor
struct SessionExecutionPreferencesTests {
    @Test func openCodeConfigurationMergesSessionOverridesOverGlobalDefaults() {
        let session = Session.fixture()
        let settings = AppSettings.testFixture()
        settings.openCodeCLIConfiguration = OpenCodeCLIConfiguration(
            executablePath: "opencode",
            defaultModel: "openai/gpt-5",
            defaultApprovalMode: "default",
            environment: [:],
            useACPStdIO: true
        )
        session.executionPreferences = SessionExecutionPreferences(
            builtInModelID: nil,
            gitHubCopilotCLI: .init(),
            openCodeCLI: OpenCodeCLISessionPreferences(modelID: "anthropic/claude-sonnet-4-5", approvalMode: "never")
        )

        let resolved = SessionExecutionPreferencesResolver.openCodeCLIConfiguration(for: session, settings: settings)
        #expect(resolved.defaultModel == "anthropic/claude-sonnet-4-5")
        #expect(resolved.defaultApprovalMode == "never")
    }
}
```

```swift
@MainActor
struct ChatExecutionProviderAvailabilityModelTests {
    @Test func refreshCanTrackOpenCodeAndCopilotIndependently() async {
        var probes: [ConversationExecutionProviderID] = []
        let model = ChatExecutionProviderAvailabilityModel(
            probe: { providerID, _ in
                probes.append(providerID)
                return ACPCLIAvailabilityStatus(kind: .available, version: nil)
            }
        )

        await model.refreshStatus(for: .openCodeCLI, executablePath: "opencode")
        #expect(model.openCodeStatus.kind == .available)
        #expect(model.copilotStatus == .unknown)
        #expect(probes == [.openCodeCLI])
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/SessionExecutionPreferencesTests -only-testing:agentGuiTests/ChatExecutionProviderAvailabilityModelTests -only-testing:agentGuiTests/GitHubCopilotCLIAvailabilityServiceTests`
Expected: FAIL with missing `openCodeCLI` preference fields, missing generic availability service, or old single-provider availability model API.

**Step 3: Write minimal implementation**

```swift
struct OpenCodeCLISessionPreferences: Codable, Equatable, Sendable {
    var modelID: String?
    var approvalMode: String?
}

enum SessionExecutionPreferencesResolver {
    static func openCodeCLIConfiguration(for session: Session, settings: AppSettings) -> OpenCodeCLIConfiguration {
        settings.openCodeCLIConfiguration.applying(session.executionPreferences.openCodeCLI)
    }
}

struct ACPCLIAvailabilityStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case available
        case notInstalled
        case failed(String)
        case unknown
    }

    let kind: Kind
    let version: String?
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/SessionExecutionPreferencesTests -only-testing:agentGuiTests/ChatExecutionProviderAvailabilityModelTests -only-testing:agentGuiTests/GitHubCopilotCLIAvailabilityServiceTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPCLIAvailabilityService.swift agentGui/Models/SessionExecutionPreferences.swift agentGui/ViewModels/ChatExecutionProviderAvailabilityModel.swift agentGui/Views/Settings/SettingsStore.swift agentGui/Services/GitHubCopilot/GitHubCopilotCLIAvailabilityService.swift agentGuiTests/SessionExecutionPreferencesTests.swift agentGuiTests/ChatExecutionProviderAvailabilityModelTests.swift agentGuiTests/GitHubCopilotCLIAvailabilityServiceTests.swift
git commit -m "feat: generalize acp executor availability and preferences"
```

### Task 3: 抽出 capability-aware 的通用 ACP 外部 runtime client

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIRuntimeFactory.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPMethodCatalog.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIRuntimeFactory.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalAgentRuntimeClientTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIRuntimeFactoryTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIRuntimeFactoryTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

@MainActor
struct ACPExternalAgentRuntimeClientTests {
    @Test func ensureSessionFallsBackToNewSessionWhenLoadIsNotAdvertised() async throws {
        let workingDirectory = makeTemporaryDirectory()
        let client = try makeRuntimeClient(
            script: noLoadSessionRubyAgentScript,
            descriptor: .openCode
        )

        let handshake = try await client.ensureSession(
            workingDirectory: workingDirectory.path,
            remoteSessionID: "existing-remote"
        )

        #expect(handshake.remoteSessionID != "existing-remote")
        #expect(handshake.capabilities.loadSession == false)
    }
}
```

```swift
struct OpenCodeCLIRuntimeFactoryTests {
    @Test func runtimeFactoryLaunchesOpenCodeACPMode() throws {
        let factory = OpenCodeCLIRuntimeFactory()
        let launch = factory.makeLaunchConfiguration(executablePath: "/usr/local/bin/opencode", workingDirectory: "/tmp/project")

        #expect(launch.command == "/usr/local/bin/opencode")
        #expect(launch.arguments == ["acp"])
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests -only-testing:agentGuiTests/GitHubCopilotCLIRuntimeFactoryTests -only-testing:agentGuiTests/OpenCodeCLIRuntimeFactoryTests`
Expected: FAIL with missing generic runtime client or missing OpenCode launch configuration.

**Step 3: Write minimal implementation**

```swift
struct ACPExternalAgentLaunchConfiguration: Equatable, Sendable {
    let command: String
    let arguments: [String]
    let environmentOverrides: [String: String]
    let currentDirectoryURL: URL
}

struct ACPExternalAgentSessionHandshake: Equatable, Sendable {
    let remoteSessionID: String
    let capabilities: ACPExternalAgentCapabilitySnapshot
}

@MainActor
final class ACPExternalAgentRuntimeClient {
    func ensureSession(workingDirectory: String, remoteSessionID: String?) async throws -> ACPExternalAgentSessionHandshake {
        try await initializeIfNeeded()
        if let remoteSessionID, capabilitySnapshot.loadSession {
            _ = try await managedRuntime.runtime.loadSession(ACPLoadSessionRequest(cwd: workingDirectory, sessionID: remoteSessionID))
            return ACPExternalAgentSessionHandshake(remoteSessionID: remoteSessionID, capabilities: capabilitySnapshot)
        }

        let response = try await managedRuntime.runtime.newSession(ACPNewSessionRequest(cwd: workingDirectory))
        return ACPExternalAgentSessionHandshake(remoteSessionID: response.sessionID, capabilities: capabilitySnapshot)
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests -only-testing:agentGuiTests/GitHubCopilotCLIRuntimeFactoryTests -only-testing:agentGuiTests/OpenCodeCLIRuntimeFactoryTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift agentGui/Services/OpenCode/OpenCodeCLIRuntimeFactory.swift agentGui/Services/ACP/ACPMethodCatalog.swift agentGui/Services/GitHubCopilot/GitHubCopilotCLIRuntimeFactory.swift agentGuiTests/ACPExternalAgentRuntimeClientTests.swift agentGuiTests/GitHubCopilotCLIRuntimeFactoryTests.swift agentGuiTests/OpenCodeCLIRuntimeFactoryTests.swift
git commit -m "refactor: extract generic acp external runtime client"
```

### Task 4: 持久化外部 ACP session 绑定并泛化事件归一化

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPExternalSessionBinding.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionBindingStore.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentEventNormalizer.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/CopilotSessionBridge.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/CopilotACPEventNormalizer.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalSessionBindingStoreTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalAgentEventNormalizerTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CopilotSessionBridgeTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

@MainActor
struct ACPExternalSessionBindingStoreTests {
    @Test func storePersistsCapabilitiesByLocalSessionAndProvider() throws {
        let modelContext = try makeModelContext()
        let store = ACPExternalSessionBindingStore(modelContext: modelContext)

        let binding = try store.upsert(
            sessionID: "local-1",
            providerID: .openCodeCLI,
            remoteSessionID: "remote-1",
            agentVersion: "0.4.0",
            capabilities: .init(loadSession: false, supportsSessionModelOverride: false, agentVersion: "0.4.0"),
            selectedModel: nil,
            selectedAgentName: nil
        )

        #expect(binding.providerID == .openCodeCLI)
        #expect(binding.negotiatedCapabilities?.loadSession == false)
    }
}
```

```swift
struct ACPExternalAgentEventNormalizerTests {
    @Test func normalizerProjectsToolCallsAndPermissionsWithoutCopilotSpecificNames() {
        let normalizer = ACPExternalAgentEventNormalizer()
        let events = normalizer.normalize(update: .permission(samplePermissionRequest()))

        #expect(events == [.permissionRequested(id: "tool-1", kind: .bash, title: "run command", reason: "Need approval")])
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPExternalSessionBindingStoreTests -only-testing:agentGuiTests/ACPExternalAgentEventNormalizerTests -only-testing:agentGuiTests/CopilotSessionBridgeTests`
Expected: FAIL with missing persisted binding model/store or Copilot-only normalizer types.

**Step 3: Write minimal implementation**

```swift
@Model
final class ACPExternalSessionBinding {
    var localSessionID: String
    var providerIDRaw: String
    var remoteSessionID: String
    var agentVersion: String
    var negotiatedCapabilitiesJSON: String
    var lastSelectedModel: String
    var lastSelectedAgentName: String
    var lastHandshakeAt: Date?
}

enum ACPExternalAgentUpdate: Equatable, Sendable {
    case session(ACPSessionUpdate)
    case permission(ACPRequestPermissionRequest)
}

typealias CopilotACPUpdate = ACPExternalAgentUpdate
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPExternalSessionBindingStoreTests -only-testing:agentGuiTests/ACPExternalAgentEventNormalizerTests -only-testing:agentGuiTests/CopilotSessionBridgeTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/ACPExternalSessionBinding.swift agentGui/Services/ACP/ACPExternalSessionBindingStore.swift agentGui/Services/ACP/ACPExternalAgentEventNormalizer.swift agentGui/Models/Session.swift agentGui/agentGuiApp.swift agentGui/Services/GitHubCopilot/CopilotSessionBridge.swift agentGui/Services/GitHubCopilot/CopilotACPEventNormalizer.swift agentGuiTests/ACPExternalSessionBindingStoreTests.swift agentGuiTests/ACPExternalAgentEventNormalizerTests.swift agentGuiTests/CopilotSessionBridgeTests.swift
git commit -m "refactor: persist external acp session bindings"
```

### Task 5: 让 GitHub Copilot provider 复用共享 ACP 外部执行器层

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIAvailabilityService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionProviderRegistryTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

@MainActor
struct GitHubCopilotCLIExecutionProviderTests {
    @Test func providerSkipsSessionLoadWhenNegotiatedCapabilitiesDisableIt() async throws {
        let runtimeClient = RuntimeClientStub(
            handshake: ACPExternalAgentSessionHandshake(
                remoteSessionID: "remote-new",
                capabilities: .init(loadSession: false, supportsSessionModelOverride: true, agentVersion: "1.2.3")
            ),
            stopReason: .endTurn,
            updates: []
        )

        let provider = makeCopilotProvider(runtimeClient: runtimeClient)
        try await provider.send(makeRequest())

        #expect(runtimeClient.loadedSessionIDs.isEmpty)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests`
Expected: FAIL because the provider still assumes Copilot-only handshake/session bridge types or always tries the old load path.

**Step 3: Write minimal implementation**

```swift
@MainActor
final class GitHubCopilotCLIExecutionProvider: ConversationExecutionProvider {
    private let descriptor = ACPExternalAgentDescriptor.githubCopilot
    private let bindingStoreFactory: (ModelContext) -> ACPExternalSessionBindingStore
    private let normalizer = ACPExternalAgentEventNormalizer()

    func send(_ request: ConversationExecutionRequest) async throws {
        let bindingStore = bindingStoreFactory(request.modelContext)
        let existingBinding = try bindingStore.binding(for: request.session.sessionId, providerID: .githubCopilotCLI)
        let handshake = try await runtimeClient.ensureSession(
            workingDirectory: workingDirectory,
            remoteSessionID: existingBinding?.remoteSessionID
        )
        if handshake.capabilities.supportsSessionModelOverride, let model = selectedModelID(for: configuration) {
            try await runtimeClient.setModel(model, sessionID: handshake.remoteSessionID)
        }
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests`
Expected: PASS, including existing multi-turn reuse and approval-mode regression tests.

**Step 5: Commit**

```bash
git add agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift agentGui/Services/GitHubCopilot/GitHubCopilotCLIAvailabilityService.swift agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift agentGuiTests/ConversationExecutionProviderRegistryTests.swift
git commit -m "refactor: move copilot provider onto generic acp executor layer"
```

### Task 6: 新增 OpenCode provider 并接入发送路由

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIAvailabilityService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionProviderRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIAvailabilityServiceTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionProviderRegistryTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

@MainActor
struct OpenCodeCLIExecutionProviderTests {
    @Test func sendUsesOpenCodeACPAndDoesNotAssumeModelOverrideSupport() async throws {
        let runtimeClient = RuntimeClientStub(
            handshake: ACPExternalAgentSessionHandshake(
                remoteSessionID: "opencode-1",
                capabilities: .init(loadSession: false, supportsSessionModelOverride: false, agentVersion: "0.4.0")
            ),
            stopReason: .endTurn,
            updates: [.session(sampleAgentMessageChunk("done"))]
        )

        let provider = makeOpenCodeProvider(runtimeClient: runtimeClient)
        try await provider.send(makeRequest(text: "hello opencode"))

        #expect(runtimeClient.promptRequests.first?.0 == "hello opencode")
        #expect(runtimeClient.setModelRequests.isEmpty)
    }
}
```

```swift
@MainActor
struct ConversationExecutionProviderRegistryTests {
    @Test func registryResolvesOpenCodeProvider() {
        let registry = ConversationExecutionProviderRegistry(
            builtIn: ProviderSpy(id: .builtInAgent),
            copilot: ProviderSpy(id: .githubCopilotCLI),
            openCode: ProviderSpy(id: .openCodeCLI)
        )
        let session = Session.fixture()
        let settings = AppSettings.testFixture(apiKey: "test")
        session.defaultExecutionProviderID = ConversationExecutionProviderID.openCodeCLI.rawValue

        #expect(registry.provider(for: session, settings: settings).id == .openCodeCLI)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/OpenCodeCLIAvailabilityServiceTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiTests/ConversationExecutionProviderRegistryTests`
Expected: FAIL with missing OpenCode provider implementation or registry constructor mismatch.

**Step 3: Write minimal implementation**

```swift
@MainActor
final class OpenCodeCLIExecutionProvider: ConversationExecutionProvider {
    let id: ConversationExecutionProviderID = .openCodeCLI

    func send(_ request: ConversationExecutionRequest) async throws {
        let settings = AppSettings.getOrCreate(in: request.modelContext)
        let configuration = SessionExecutionPreferencesResolver.openCodeCLIConfiguration(for: request.session, settings: settings)
        let handshake = try await runtimeClient.ensureSession(
            workingDirectory: resolvedWorkingDirectory(session: request.session, settings: settings),
            remoteSessionID: persistedBinding?.remoteSessionID
        )
        if handshake.capabilities.supportsSessionModelOverride,
           let model = configuration.defaultModel.nonEmptyValue {
            try await runtimeClient.setModel(model, sessionID: handshake.remoteSessionID)
        }
        _ = try await runtimeClient.prompt(text: request.text, sessionID: handshake.remoteSessionID)
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/OpenCodeCLIAvailabilityServiceTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiTests/ConversationExecutionProviderRegistryTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/OpenCode/OpenCodeCLIAvailabilityService.swift agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift agentGui/Services/ConversationExecutionProviderRegistry.swift agentGui/Services/ClaudeService/ClaudeService+Messaging.swift agentGuiTests/OpenCodeCLIAvailabilityServiceTests.swift agentGuiTests/OpenCodeCLIExecutionProviderTests.swift agentGuiTests/ConversationExecutionProviderRegistryTests.swift
git commit -m "feat: add opencode acp execution provider"
```

### Task 7: 暴露 OpenCode 设置与聊天 UI，并做回归验证

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsExecutorsView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ConversationExecutionProviderID.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionProviderSelectionTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatExecutionProviderAvailabilityModelTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

@MainActor
struct ConversationExecutionProviderSelectionTests {
    @Test func providerOptionsDisableOpenCodeWhenUnavailable() {
        let options = ConversationExecutionProviderID.optionItems(
            availabilityByProvider: [
                .githubCopilotCLI: ACPCLIAvailabilityStatus(kind: .available, version: nil),
                .openCodeCLI: ACPCLIAvailabilityStatus(kind: .notInstalled, version: nil)
            ]
        )

        #expect(options.first(where: { $0.id == ConversationExecutionProviderID.openCodeCLI.rawValue })?.isEnabled == false)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ConversationExecutionProviderSelectionTests -only-testing:agentGuiTests/ChatExecutionProviderAvailabilityModelTests`
Expected: FAIL because the picker/settings UI and option generation still assume only Copilot is the external provider.

**Step 3: Write minimal implementation**

```swift
ExecutionOptionPicker(
    title: "",
    options: ConversationExecutionProviderID.optionItems(
        availabilityByProvider: [
            .githubCopilotCLI: copilotComposerAvailabilityStatus,
            .openCodeCLI: openCodeComposerAvailabilityStatus
        ]
    ),
    selection: executionProviderSelectionRawValueBinding,
    accessibilityIdentifier: "chat.executionProviderPicker"
)

switch resolvedExecutionProviderID {
case .builtInAgent:
    builtInControls
case .githubCopilotCLI:
    copilotControls
case .openCodeCLI:
    openCodeControls
}
```

**Step 4: Run tests and smoke checks**

Run: `xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -parallel-testing-enabled NO -only-testing:agentGuiTests/ConversationExecutionProviderSelectionTests -only-testing:agentGuiTests/ChatExecutionProviderAvailabilityModelTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests`
Expected: PASS.

Run: `./scripts/run_quality_smoke.sh`
Expected: exit 0 and focused smoke suite passes.

**Step 5: Commit**

```bash
git add agentGui/Views/Settings/SettingsExecutorsView.swift agentGui/Views/Settings/SettingsStore.swift agentGui/Views/ChatView+Actions.swift agentGui/Views/ChatView+InputArea.swift agentGui/Models/ConversationExecutionProviderID.swift agentGuiTests/ConversationExecutionProviderSelectionTests.swift agentGuiTests/ChatExecutionProviderAvailabilityModelTests.swift
git commit -m "feat: expose opencode executor in settings and composer"
```

## 5. 手工验证清单

1. 在设置页中同时看到 GitHub Copilot CLI 和 OpenCode 两张配置卡片，并能分别保存路径、默认模型、审批模式。
2. 当 `opencode` 不在 PATH 中时，聊天输入区执行器 picker 会禁用 OpenCode，并展示可读状态文案。
3. 选择 OpenCode 后发送第一条消息，能够启动 `opencode acp`、完成 initialize、session/new、session/prompt。
4. OpenCode 触发文件读写、终端、权限请求时，现有工具调用和权限卡片 UI 正常投影。
5. OpenCode 不支持 `session/load` 时，重启 runtime 后会自动降级成新 session，而不是直接报协议错误。
6. OpenCode 不支持 `session/set_model` 时，不会把模型 override 强行发送给 agent。
7. GitHub Copilot CLI 既有多轮复用、session/load、审批模式映射和工具状态收敛测试全部通过。

## 6. 风险提示

- 如果新增 `ACPExternalSessionBinding`，记得把它加入 `PersistenceSchema.sharedModelTypes`，并同步更新所有手写 `ModelContainer` 测试夹具；否则会出现编译通过但测试运行时崩溃。
- `ACPCLIAvailabilityService` 必须继续复用 `ShellEnvironmentResolver`，否则设置页探测和真实启动 PATH 行为会分叉。
- `ChatView` 被拆成多个扩展文件，共享状态不要误加 `private`，否则新的 OpenCode composer 状态会编译失败。
- OpenCode V1 不要额外开启 `OPENCODE_ENABLE_QUESTION_TOOL`；把 capability-aware 主链跑稳比抢实验能力更重要。

## 7. 完成定义

- OpenCode 可以作为第三个执行器被选择、配置和发送消息。
- 通用 ACP 外部执行器层不再以 `Copilot*` 命名承载共享逻辑。
- `session/load` 与 `session/set_model` 都通过握手能力控制，不再依赖 Copilot 假设。
- GitHub Copilot 现有 ACP 行为无回归，OpenCode 的核心 turn 流程可工作。
- 所有新增/修改测试通过，最后再做一次 @requesting-code-review。
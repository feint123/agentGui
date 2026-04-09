# GitHub Copilot CLI Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add GitHub Copilot CLI as a first-class ACP-backed conversation executor alongside the built-in agent, with session-level executor selection, settings, approval bridging, and chat UI projection.

**Architecture:** Keep the existing built-in Claude path working, but lift the app from a single-provider messaging flow to a small execution-provider layer. Reuse the current ACP runtime, local permission bridge, terminal runtime, session persistence, and execution projection pipeline, then add a focused Copilot CLI runtime factory, session bridge, event normalizer, and UI selector instead of building a second ad hoc agent stack.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, existing ACP runtime (`ACPManagedClientRuntime`, `ACPLocalClientHandler`), existing chat UI and execution projection surfaces.

---

## 1. 实施原则

- 先锁定会话执行器选择、配置持久化和发送路由的测试，再接 Copilot CLI runtime；不要先改 UI 再赌运行时能补上。
- 第一版只支持官方推荐的 ACP 模式：`copilot --acp --stdio`。不要把交互式终端抓屏作为 MVP 主路径。
- 优先复用现有 ACP 文件/终端/审批桥和消息投影能力；不要为 Copilot CLI 再造一套平行权限系统或终端系统。
- 会话层的核心语义是“执行器”而不是“模型”。Copilot CLI 不是另一个 model provider，不能硬塞进 `selectedModel` 语义里。
- 用最小持久化扩展承载执行器状态：全局默认值放 `AppSettings`，会话默认值放 `Session`，外部 session 绑定放单独 bridge/binding 模型。
- 测试按四层推进：纯模型与配置、runtime/ACP 桥、消息路由、UI 与投影。
- 每个任务都按 TDD 执行，并在通过后立即提交；不要攒一个大补丁最后一起验证。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ConversationExecutionProviderID.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/GitHubCopilotCLIConfiguration.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIAvailabilityService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIRuntimeFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/CopilotSessionBridge.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/CopilotACPEventNormalizer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionProviderRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatExecutionProviderPicker.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsExecutorsView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionProviderSelectionTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIAvailabilityServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIRuntimeFactoryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CopilotSessionBridgeTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CopilotACPEventNormalizerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionProviderRegistryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/ChatExecutionProviderPickerUITests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RemoteConversationBinding.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AuthorizedRuntimeSettingsFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPManagedClientRuntime.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPLocalClientHandler.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentExecutionProjection.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsWindowView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsNavigationItem.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteConversationRouter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AuthorizedRuntimeSettingsFactoryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPManagedClientRuntimeTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentExecutionProjectionTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChannelSettingsViewModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SettingsWindowUITests.swift`

### 参考文档

- `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-19-github-copilot-cli-integration-requirements.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-19-cognitive-subagent-fabric-phase-5-runtime-unification-plan.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-18-unified-tool-authorization-implementation-plan.md`

## 3. 关键设计决策

### 3.1 执行器 ID 的真源

第一版把执行器收敛成一个很小的枚举，不做插件市场：

```swift
enum ConversationExecutionProviderID: String, Codable, CaseIterable, Sendable {
    case builtInAgent = "built_in_agent"
    case githubCopilotCLI = "github_copilot_cli"

    var displayName: String {
        switch self {
        case .builtInAgent: return "内置 Agent"
        case .githubCopilotCLI: return "GitHub Copilot CLI"
        }
    }
}
```

`AppSettings` 存全局默认值，`Session` 存会话默认值。不要把 Copilot CLI 塞进 `selectedModel` 或任意 Claude-only 字段。

### 3.2 Copilot CLI 配置边界

第一版配置只保留本需求真正需要的字段：

```swift
struct GitHubCopilotCLIConfiguration: Codable, Equatable, Sendable {
    var executablePath: String
    var defaultModel: String
    var customAgentName: String
    var defaultApprovalMode: String
    var useACPStdIO: Bool
}
```

不要在 V1 加 prompt mode、插件商店、计划面板镜像、fleet、任意实验协议选项。

### 3.3 外部 session 绑定怎么存

Copilot session 不是本地 `Session.sessionId`，必须单独存映射。第一版要求 bridge 至少保存：

- 本地 `sessionID`
- `providerID`
- 外部 `remoteSessionID`
- 最近握手时间
- CLI 版本
- 最后一次模型/agent 选择

不要把这些字段散落到 `Session` 本体里。`Session` 只保留默认执行器和少量 UI 选择状态。

### 3.4 事件归一化的最小集合

Copilot ACP update 先归一化成已有投影体系能消费的事件，不试图 1:1 映射所有上游细节：

```swift
enum CopilotNormalizedEvent: Equatable {
    case assistantTextDelta(String)
    case toolCallStarted(id: String, title: String)
    case toolCallUpdated(id: String, status: String)
    case toolCallCompleted(id: String, summary: String?)
    case permissionRequested(kind: String, reason: String)
    case statusChanged(String)
    case failed(message: String)
    case completed
}
```

先把这些事件接进现有消息、tool call 和 execution projection。后续再扩展 task tree、subagent cards、rich approval forms。

### 3.5 发送链路的最小改造方式

不要让 `ChatView` 自己理解 Copilot runtime。UI 只负责选择 provider，真正路由放进 provider registry：

```swift
protocol ConversationExecutionProvider: Sendable {
    var id: ConversationExecutionProviderID { get }
    func send(request: ConversationExecutionRequest) async throws
    func cancel(sessionID: String) async
}
```

`ClaudeService+Messaging.swift` 负责把现有 built-in 逻辑收口成一个 provider，并把 Copilot provider 作为并列实现接进去。

## 4. 任务拆解

### Task 1: 固化执行器选择与持久化模型

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ConversationExecutionProviderID.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/GitHubCopilotCLIConfiguration.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionProviderSelectionTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

struct ConversationExecutionProviderSelectionTests {
    @Test func appSettingsDefaultsToBuiltInAgent() {
        let settings = AppSettings()
        #expect(settings.defaultExecutionProviderID == ConversationExecutionProviderID.builtInAgent.rawValue)
        #expect(settings.githubCopilotCLIConfiguration.useACPStdIO == true)
    }

    @Test func sessionCanOverrideGlobalExecutionProvider() {
        let session = Session.fixture()
        session.defaultExecutionProviderID = ConversationExecutionProviderID.githubCopilotCLI.rawValue
        #expect(session.executionProviderID == .githubCopilotCLI)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ConversationExecutionProviderSelectionTests`
Expected: FAIL with missing execution-provider types or missing persisted fields.

**Step 3: Write minimal implementation**

```swift
@Model
final class AppSettings {
    var defaultExecutionProviderID: String
    var githubCopilotCLIConfigurationJSON: String

    var githubCopilotCLIConfiguration: GitHubCopilotCLIConfiguration {
        get { /* decode JSON */ }
        set { /* encode JSON */ }
    }
}

@Model
final class Session {
    var defaultExecutionProviderID: String = ConversationExecutionProviderID.builtInAgent.rawValue

    var executionProviderID: ConversationExecutionProviderID {
        ConversationExecutionProviderID(rawValue: defaultExecutionProviderID) ?? .builtInAgent
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ConversationExecutionProviderSelectionTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/ConversationExecutionProviderID.swift agentGui/Models/GitHubCopilotCLIConfiguration.swift agentGui/Models/AppSettings.swift agentGui/Models/Session.swift agentGuiTests/ConversationExecutionProviderSelectionTests.swift
git commit -m "feat: persist conversation execution provider selection"
```

### Task 2: 增加 Copilot CLI 可用性检测与设置页

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIAvailabilityService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsExecutorsView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsWindowView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsNavigationItem.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsToolsView.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIAvailabilityServiceTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SettingsWindowUITests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

struct GitHubCopilotCLIAvailabilityServiceTests {
    @Test func unavailableWhenExecutableMissing() async throws {
        let service = GitHubCopilotCLIAvailabilityService(fileManager: .default)
        let status = try await service.checkStatus(configuration: .init(executablePath: "/missing/copilot"))
        #expect(status.kind == .notInstalled)
    }
}
```

```swift
func testSettingsShowsExecutorsNavigationItem() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.buttons["settings.navigation.executors"].exists)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/GitHubCopilotCLIAvailabilityServiceTests -only-testing:agentGuiUITests/SettingsWindowUITests`
Expected: FAIL because availability service and executors settings view do not exist.

**Step 3: Write minimal implementation**

```swift
struct GitHubCopilotCLIAvailabilityStatus: Equatable {
    enum Kind { case available, notInstalled, notAuthenticated, failed(String) }
    let kind: Kind
    let version: String?
}

struct SettingsExecutorsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Picker("默认执行器", selection: /* persisted binding */) { /* built-in / copilot */ }
            TextField("Copilot 可执行文件路径", text: /* persisted binding */)
            TextField("默认模型（可选）", text: /* persisted binding */)
            TextField("自定义 Agent 名称（可选）", text: /* persisted binding */)
            Text(/* availability status text */)
        }
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/GitHubCopilotCLIAvailabilityServiceTests -only-testing:agentGuiUITests/SettingsWindowUITests`
Expected: PASS. Settings window shows a dedicated executors section and availability state.

**Step 5: Commit**

```bash
git add agentGui/Services/GitHubCopilot/GitHubCopilotCLIAvailabilityService.swift agentGui/Views/Settings/SettingsExecutorsView.swift agentGui/Views/Settings/SettingsWindowView.swift agentGui/Views/Settings/SettingsNavigationItem.swift agentGui/Views/Settings/SettingsStore.swift agentGui/Views/Settings/SettingsToolsView.swift agentGuiTests/GitHubCopilotCLIAvailabilityServiceTests.swift agentGuiUITests/SettingsWindowUITests.swift
git commit -m "feat: add copilot cli settings and availability checks"
```

### Task 3: 复用 ACP 运行时并建立 Copilot session bridge

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIRuntimeFactory.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/CopilotSessionBridge.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RemoteConversationBinding.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPManagedClientRuntime.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPLocalClientHandler.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AuthorizedRuntimeSettingsFactory.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIRuntimeFactoryTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CopilotSessionBridgeTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPManagedClientRuntimeTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AuthorizedRuntimeSettingsFactoryTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

struct GitHubCopilotCLIRuntimeFactoryTests {
    @Test func runtimeFactoryLaunchesACPModeWithStdIO() throws {
        let factory = GitHubCopilotCLIRuntimeFactory()
        let launch = factory.makeLaunchConfiguration(
            executablePath: "/usr/local/bin/copilot",
            workingDirectory: "/tmp/project"
        )

        #expect(launch.command == "/usr/local/bin/copilot")
        #expect(launch.arguments == ["--acp", "--stdio"])
    }
}

struct CopilotSessionBridgeTests {
    @Test func bridgeReusesRemoteSessionForSameLocalSession() {
        let bridge = CopilotSessionBridge.Binding(
            sessionID: "local-1",
            providerID: .githubCopilotCLI,
            remoteSessionID: "copilot-1"
        )
        #expect(bridge.remoteSessionID == "copilot-1")
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/GitHubCopilotCLIRuntimeFactoryTests -only-testing:agentGuiTests/CopilotSessionBridgeTests -only-testing:agentGuiTests/ACPManagedClientRuntimeTests -only-testing:agentGuiTests/AuthorizedRuntimeSettingsFactoryTests`
Expected: FAIL with missing runtime factory / binding types and missing approval/runtime propagation.

**Step 3: Write minimal implementation**

```swift
struct GitHubCopilotCLILaunchConfiguration: Equatable {
    let command: String
    let arguments: [String]
    let currentDirectoryURL: URL
}

struct GitHubCopilotCLIRuntimeFactory {
    func makeLaunchConfiguration(executablePath: String, workingDirectory: String) -> GitHubCopilotCLILaunchConfiguration {
        GitHubCopilotCLILaunchConfiguration(
            command: executablePath,
            arguments: ["--acp", "--stdio"],
            currentDirectoryURL: URL(fileURLWithPath: workingDirectory)
        )
    }
}

struct CopilotSessionBridge {
    struct Binding: Codable, Equatable, Sendable {
        let sessionID: String
        let providerID: ConversationExecutionProviderID
        let remoteSessionID: String
        var cliVersion: String?
        var lastHandshakeAt: Date?
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/GitHubCopilotCLIRuntimeFactoryTests -only-testing:agentGuiTests/CopilotSessionBridgeTests -only-testing:agentGuiTests/ACPManagedClientRuntimeTests -only-testing:agentGuiTests/AuthorizedRuntimeSettingsFactoryTests`
Expected: PASS. Runtime launch is fixed to ACP stdio, bridge persists mappings, and authorized runtime settings still produce safe tool permissions.

**Step 5: Commit**

```bash
git add agentGui/Services/GitHubCopilot/GitHubCopilotCLIRuntimeFactory.swift agentGui/Services/GitHubCopilot/CopilotSessionBridge.swift agentGui/Models/RemoteConversationBinding.swift agentGui/Services/ACP/ACPManagedClientRuntime.swift agentGui/Services/ACP/ACPLocalClientHandler.swift agentGui/Services/AuthorizedRuntimeSettingsFactory.swift agentGuiTests/GitHubCopilotCLIRuntimeFactoryTests.swift agentGuiTests/CopilotSessionBridgeTests.swift agentGuiTests/ACPManagedClientRuntimeTests.swift agentGuiTests/AuthorizedRuntimeSettingsFactoryTests.swift
git commit -m "feat: add copilot cli acp runtime and session bridge"
```

### Task 4: 把 Copilot ACP update 归一化到本地消息与投影模型

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/CopilotACPEventNormalizer.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentExecutionProjection.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteConversationRouter.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CopilotACPEventNormalizerTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentExecutionProjectionTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

struct CopilotACPEventNormalizerTests {
    @Test func textDeltaMapsToAssistantDeltaEvent() throws {
        let event = try CopilotACPEventNormalizer().normalize(
            update: .textDelta("hello")
        )

        #expect(event == .assistantTextDelta("hello"))
    }

    @Test func permissionPromptMapsToPermissionRequest() throws {
        let event = try CopilotACPEventNormalizer().normalize(
            update: .permission(toolKind: "execute", reason: "needs shell")
        )

        #expect(event == .permissionRequested(kind: "execute", reason: "needs shell"))
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/CopilotACPEventNormalizerTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/AgentExecutionProjectionTests`
Expected: FAIL because ACP update normalization and Copilot execution provider do not exist yet.

**Step 3: Write minimal implementation**

```swift
struct CopilotACPEventNormalizer {
    func normalize(update: CopilotACPUpdate) throws -> CopilotNormalizedEvent {
        switch update {
        case .textDelta(let value):
            return .assistantTextDelta(value)
        case .permission(let toolKind, let reason):
            return .permissionRequested(kind: toolKind, reason: reason)
        case .toolStarted(let id, let title):
            return .toolCallStarted(id: id, title: title)
        case .completed:
            return .completed
        }
    }
}
```

```swift
actor GitHubCopilotCLIExecutionProvider: ConversationExecutionProvider {
    let id: ConversationExecutionProviderID = .githubCopilotCLI

    func send(request: ConversationExecutionRequest) async throws {
        // initialize -> newSession/reuse -> prompt -> stream normalized events into local message state
    }

    func cancel(sessionID: String) async {
        // send ACP cancel / close if active
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/CopilotACPEventNormalizerTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/AgentExecutionProjectionTests`
Expected: PASS. Copilot ACP events now drive the same message/tool projection surfaces used by the built-in agent.

**Step 5: Commit**

```bash
git add agentGui/Services/GitHubCopilot/CopilotACPEventNormalizer.swift agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift agentGui/ViewModels/AgentExecutionProjection.swift agentGui/Services/Channels/RemoteConversationRouter.swift agentGuiTests/CopilotACPEventNormalizerTests.swift agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift agentGuiTests/AgentExecutionProjectionTests.swift
git commit -m "feat: project copilot cli acp updates into local execution UI"
```

### Task 5: 引入 provider registry 并改造消息发送/取消路由

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionProviderRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionProviderRegistryTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import agentGui

struct ConversationExecutionProviderRegistryTests {
    @Test func registryResolvesSessionOverrideBeforeGlobalDefault() throws {
        let session = Session.fixture()
        session.defaultExecutionProviderID = ConversationExecutionProviderID.githubCopilotCLI.rawValue

        let registry = ConversationExecutionProviderRegistry(
            builtIn: StubProvider(id: .builtInAgent),
            copilot: StubProvider(id: .githubCopilotCLI)
        )

        #expect(registry.provider(for: session).id == .githubCopilotCLI)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ConversationExecutionProviderRegistryTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests`
Expected: FAIL with missing registry type or unchanged `sendMessage` routing.

**Step 3: Write minimal implementation**

```swift
struct ConversationExecutionRequest: Sendable {
    let session: Session
    let text: String
    let modelContext: ModelContext
}

struct ConversationExecutionProviderRegistry {
    let builtIn: any ConversationExecutionProvider
    let copilot: any ConversationExecutionProvider

    func provider(for session: Session) -> any ConversationExecutionProvider {
        switch session.executionProviderID {
        case .builtInAgent: return builtIn
        case .githubCopilotCLI: return copilot
        }
    }
}
```

```swift
try await providerRegistry.provider(for: session).send(
    request: ConversationExecutionRequest(session: session, text: auditedText, modelContext: modelContext)
)
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ConversationExecutionProviderRegistryTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests`
Expected: PASS. `sendMessage`, regenerate, edit-and-resend, and cancel all route through the resolved execution provider.

**Step 5: Commit**

```bash
git add agentGui/Services/ConversationExecutionProviderRegistry.swift agentGui/Services/ClaudeService/ClaudeService+Messaging.swift agentGui/Views/ChatView+Actions.swift agentGuiTests/ConversationExecutionProviderRegistryTests.swift agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift
git commit -m "feat: route chat messaging through execution provider registry"
```

### Task 6: 在聊天输入区加入执行器选择器并同步到会话

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatExecutionProviderPicker.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentExecutionProjection.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/ChatExecutionProviderPickerUITests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChannelSettingsViewModelTests.swift`

**Step 1: Write the failing test**

```swift
func testChatComposerShowsExecutionProviderPicker() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.buttons["chat.executionProviderPicker"].exists)
}

func testSelectingCopilotPersistsToNextSend() {
    let app = XCUIApplication()
    app.buttons["chat.executionProviderPicker"].click()
    app.menuItems["GitHub Copilot CLI"].click()
    XCTAssertEqual(app.staticTexts["chat.executionProviderLabel"].label, "执行器：GitHub Copilot CLI")
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiUITests/ChatExecutionProviderPickerUITests`
Expected: FAIL because no execution-provider picker exists in the composer.

**Step 3: Write minimal implementation**

```swift
struct ChatExecutionProviderPicker: View {
    @Binding var selection: ConversationExecutionProviderID
    let availability: GitHubCopilotCLIAvailabilityStatus

    var body: some View {
        Menu {
            Button("内置 Agent") { selection = .builtInAgent }
            Button("GitHub Copilot CLI") { selection = .githubCopilotCLI }
                .disabled(availability.kind != .available)
        } label: {
            Label("执行器：\(selection.displayName)", systemImage: "bolt.horizontal.circle")
        }
        .accessibilityIdentifier("chat.executionProviderPicker")
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiUITests/ChatExecutionProviderPickerUITests`
Expected: PASS. Composer shows the picker, unavailable Copilot states are disabled with visible reason text, and session default updates before send.

**Step 5: Commit**

```bash
git add agentGui/Views/ChatExecutionProviderPicker.swift agentGui/Views/ChatView+InputArea.swift agentGui/Views/ChatView+Actions.swift agentGui/ViewModels/AgentExecutionProjection.swift agentGuiUITests/ChatExecutionProviderPickerUITests.swift agentGuiTests/ChannelSettingsViewModelTests.swift
git commit -m "feat: add chat execution provider picker"
```

### Task 7: 端到端回归、文档同步与质量烟测

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-19-github-copilot-cli-integration-requirements.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/README.md`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SettingsWindowUITests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/ChatExecutionProviderPickerUITests.swift`

**Step 1: Write the failing test**

Add one end-to-end provider-routing test that proves the selected executor controls the send path, and one UI assertion that the disabled reason text appears when Copilot is unavailable.

```swift
@Test func sendUsesCopilotProviderWhenSessionDefaultIsCopilot() async throws {
    let session = Session.fixture()
    session.defaultExecutionProviderID = ConversationExecutionProviderID.githubCopilotCLI.rawValue
    let harness = try await MessagingHarness.make()

    try await harness.send("hello", session: session)

    #expect(harness.copilotProvider.sentTexts == ["hello"])
    #expect(harness.builtInProvider.sentTexts.isEmpty)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiUITests/SettingsWindowUITests -only-testing:agentGuiUITests/ChatExecutionProviderPickerUITests`
Expected: FAIL until all routing, availability text, and UI bindings are complete.

**Step 3: Write minimal implementation**

Update docs to explain:

```markdown
- 默认执行器保存在 `AppSettings.defaultExecutionProviderID`
- 会话级覆盖保存在 `Session.defaultExecutionProviderID`
- Copilot CLI 仅通过 `copilot --acp --stdio` 接入
- 未安装 / 未登录时，聊天输入区仍显示选项，但不可执行且展示原因
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiUITests/SettingsWindowUITests -only-testing:agentGuiUITests/ChatExecutionProviderPickerUITests`
Expected: PASS.

Run: `./scripts/run_quality_smoke.sh`
Expected: PASS, or only unrelated pre-existing failures. If it fails, capture the failing suite and stop before broad refactors.

**Step 5: Commit**

```bash
git add docs/technical-spec/2026-03-19-github-copilot-cli-integration-requirements.md README.md agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift agentGuiUITests/SettingsWindowUITests.swift agentGuiUITests/ChatExecutionProviderPickerUITests.swift
git commit -m "docs: finalize copilot cli executor rollout notes"
```

## 5. 实施顺序提醒

- 先做 Task 1 到 Task 3，再动聊天发送主链。
- Task 4 和 Task 5 必须连着做，中间不要把半成品 provider registry 合并进主分支。
- Task 6 只在 Task 5 跑通后开始，否则 UI 会先暴露一个不能工作的选择器。
- Task 7 只负责收口验证和文档同步，不要把新的架构想法塞进最后一步。

## 6. 测试矩阵

- 纯模型：`ConversationExecutionProviderSelectionTests`
- 配置与可用性：`GitHubCopilotCLIAvailabilityServiceTests`
- ACP runtime：`GitHubCopilotCLIRuntimeFactoryTests`、`ACPManagedClientRuntimeTests`
- 会话绑定：`CopilotSessionBridgeTests`
- 事件归一化：`CopilotACPEventNormalizerTests`
- 路由：`ConversationExecutionProviderRegistryTests`、`GitHubCopilotCLIExecutionProviderTests`
- 投影：`AgentExecutionProjectionTests`
- 设置 UI：`SettingsWindowUITests`
- 聊天 UI：`ChatExecutionProviderPickerUITests`

## 7. 明确不做

- 不做 interactive terminal screen scraping 版本的 Copilot 集成。
- 不做 prompt mode 作为主链路，只允许后续单独加健康检查或 fallback。
- 不做多 provider 插件框架；V1 只支持 built-in 和 GitHub Copilot CLI 两种执行器。
- 不做完整 Copilot 任务树、计划审批面板或 fleet UI 镜像。
- 不顺手重构整套 `ClaudeService` 或聊天消息模型，只抽出必要的 provider registry 和 request 类型。
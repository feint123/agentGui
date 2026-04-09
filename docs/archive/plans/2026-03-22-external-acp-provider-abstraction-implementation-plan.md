# External ACP Provider Abstraction Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reduce duplicated orchestration code between GitHub Copilot CLI and OpenCode CLI providers by extracting a shared external ACP execution layer while preserving provider-specific capability negotiation, launch configuration, and product settings.

**Architecture:** Keep ACP wire protocol, event normalization, update projection, permission routing, and session binding as shared infrastructure. Introduce a thin provider descriptor plus a shared external ACP provider base that owns send or cancel or reset or projection flow, and leave each provider responsible only for configuration resolution, launch arguments, capability quirks, and product-only options. Migrate OpenCode first because it already uses the generic runtime client, then fold Copilot onto the same runtime abstraction with the minimum compatibility shims required.

**Tech Stack:** Swift 6, SwiftData, Swift Testing, existing ACP runtime stack, external CLI providers, `ConversationExecutionProvider`, `ACPExternalAgentRuntimeClient`, and current provider test suites.

---

## 1. 实施原则

- 这次重构先做“行为保真”，不借机改 UI、权限策略或会话恢复产品语义。
- 共享层只抽真正重复且已稳定的流程，不把 provider 差异硬塞进抽象导致条件分支蔓延。
- 以 OpenCode 当前的通用 runtime 路径为目标形态，Copilot 尽量向它收敛，而不是反过来把共享层特化成 Copilot 风格。
- 所有抽象都要先有 characterization tests，先锁住现有行为，再迁移实现。
- YAGNI：第一版不要引入“无限泛化”的 provider DSL；只覆盖当前 Copilot 和 OpenCode 共有的外部 ACP 生命周期。
- 计划中的每个 task 都按 @test-driven-development 执行：先写失败测试，再写最小实现，再跑通过，再提交。
- 全部任务完成后，使用 @requesting-code-review 做最终 review，重点检查会话恢复、能力协商和权限流回归。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderContracts.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPExternalAgentDescriptor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/GitHubCopilotCLIConfiguration.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/OpenCodeCLIConfiguration.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionExecutionPreferences.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIRuntimeFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIRuntimeFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIRuntimeFactoryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIRuntimeFactoryTests.swift`

### 参考文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentEventNormalizer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalUpdateProjector.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPExternalSessionBinding.swift`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-20-github-copilot-cli-integration-implementation-plan.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-20-opencode-acp-integration-implementation-plan.md`

## 3. 可以继续抽象的代码边界

### 3.1 应抽到共享层的部分

下面这些逻辑在 Copilot 和 OpenCode Provider 中基本同构，应该搬进共享外部 ACP provider 基类：

- `send` 主流程中的通用骨架：配置校验后拿 binding、解析 working directory、准备 runtime、恢复或新建 session、建立 assistant message、消费 update、收尾 message。
- `cancel`、`resetSessionState`、`prepareForActivation`、`closeInactiveSessionRuntimes`、`deactivateAllSessionRuntimes`、`markCancelledIfNeeded` 这类生命周期管理。
- `makePermissionResolver`、`makeUpdateSink`、`consume`、`flushProjectedUpdates`、`applyPermissionResolution`、`apply(event:to:in:)` 这类事件投影与权限回填。
- transcript fallback prompt、assistant message 创建与 finalize or fail 逻辑。
- binding store 读写和 shared bridge 同步。

### 3.2 必须保留在 provider 侧的部分

- 启动命令与参数：`copilot --acp --stdio` 和 `opencode acp` 不能强行统一。
- provider 配置模型差异：Copilot 有 `customAgentName`，OpenCode 有 `environment`。
- capability 策略：OpenCode 的 `setModel` 明确依赖 initialize 能力协商；Copilot 当前路径则更强假设，需要兼容迁移。
- provider 专属 availability 展示文案和默认 executable。

### 3.3 第一版不要抽的部分

- 不要把 `GitHubCopilotCLIConfiguration` 和 `OpenCodeCLIConfiguration` 合成一个巨大配置结构。
- 不要把所有 provider 特性都塞进 `ACPExternalAgentDescriptor`，只增加当前执行流程真正需要的字段。
- 不要在第一版同时重写 Settings UI 或会话偏好 UI，只保留现有数据入口。

## 4. 目标抽象形态

共享层目标形态如下：

```swift
@MainActor
protocol ACPExternalProviderRuntimeClient: AnyObject {
    func ensureSession(workingDirectory: String, remoteSessionID: String?) async throws -> ACPExternalAgentSessionHandshake
    func setModel(_ modelID: String, sessionID: String) async throws
    func prompt(text: String, sessionID: String) async throws -> ACPStopReason
    func cancel(sessionID: String) async throws
    func close() async
}

struct ACPExternalProviderBehavior: Sendable {
    let providerID: ConversationExecutionProviderID
    let displayName: String
    let supportsCustomAgentName: Bool
    let supportsEnvironmentOverrides: Bool
    let requiresCapabilityNegotiationForModelOverride: Bool
}
```

再由共享基类持有通用 orchestration：

```swift
@MainActor
class ACPExternalExecutionProviderBase<Configuration, RuntimeClient: ACPExternalProviderRuntimeClient>: ConversationExecutionProvider {
    func send(_ request: ConversationExecutionRequest) async throws
    func cancel(session: Session, modelContext: ModelContext) async
    func resetSessionState(session: Session, modelContext: ModelContext) async
    func prepareForActivation(session: Session, isActiveProvider: Bool, modelContext: ModelContext) async
}
```

具体 provider 只需要提供：

- 如何从 `Session` 和 `AppSettings` 解析配置
- 如何构建 launch configuration
- 如何决定 selected model 是否允许发 `session/set_model`
- 如何把 provider 专属字段写入 binding

## 5. 任务拆解

### Task 1: 用 characterization tests 锁住当前两套 Provider 的公共行为

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`

**Step 1: Write the failing test**

补 3 组 characterization tests，覆盖：

- send 流程会在恢复阶段屏蔽 replay updates，只投影 live turn
- cancel 会收敛所有 in-progress tool calls 和 active assistant message
- 切换 session 时会关闭其他 external ACP runtime，并恢复正确 binding

示例测试骨架：

```swift
@Test func sharedExternalFlowDoesNotProjectRestoreReplayIntoLiveTurn() async throws {
    let harness = try ExternalACPProviderHarness.make()
    let provider = harness.makeProvider()

    try await provider.send(harness.request(text: "hello"))

    let assistant = try #require(harness.latestAssistantMessage())
    #expect(assistant.textContent == "live reply")
    #expect(!assistant.toolCalls.contains(where: { $0.toolCallId == "restore-tool" }))
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests`

Expected: FAIL with missing harness or unabstracted shared test target symbols.

**Step 3: Write minimal implementation**

先只抽测试 harness，不动生产代码，让两套 provider 共用同一组行为断言 helper。

```swift
struct ExternalACPProviderAssertionHelpers {
    static func expectCancelledMessageSettlesToolCalls(_ message: Message) {
        #expect(message.status == .cancelled)
        #expect(message.toolCalls.allSatisfy { $0.status != .inProgress })
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift agentGuiTests/OpenCodeCLIExecutionProviderTests.swift agentGuiTests/ACPExternalExecutionProviderBaseTests.swift
git commit -m "test: lock shared external acp provider behavior"
```

### Task 2: 定义共享的 external ACP provider contracts，而不是直接抽基类

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderContracts.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPExternalAgentDescriptor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`

**Step 1: Write the failing test**

补测试验证 descriptor 能表达：

- display name
- launch arguments
- provider 是否要求能力协商后再允许 model override
- provider 是否支持 custom agent name 或 environment overrides

示例：

```swift
@Test func externalAgentDescriptorCapturesProviderSpecificExecutionBehavior() {
    let descriptor = ACPExternalAgentDescriptor.openCode

    #expect(descriptor.defaultArguments == ["acp"])
    #expect(descriptor.supportsSessionModelOverrideByDefault == false)
    #expect(descriptor.supportsCustomAgentName == false)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests`

Expected: FAIL with missing provider behavior contract or descriptor fields.

**Step 3: Write minimal implementation**

新增共享 contract，但先不迁移 provider 主体：

```swift
struct ACPExternalProviderExecutionBehavior: Equatable, Sendable {
    let requiresCapabilityNegotiationForModelOverride: Bool
    let supportsEnvironmentOverrides: Bool
    let supportsCustomAgentName: Bool
}
```

把 `ACPExternalAgentRuntimeClient` 暴露为通用 runtime client 协议实现，避免 OpenCode 和未来 Copilot 各自维护一套近似接口。

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalProviderContracts.swift agentGui/Models/ACPExternalAgentDescriptor.swift agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift agentGuiTests/OpenCodeCLIExecutionProviderTests.swift agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift
git commit -m "refactor: introduce external acp provider contracts"
```

### Task 3: 抽出共享 orchestration 基类，先迁移 OpenCode

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/OpenCodeCLIConfiguration.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionExecutionPreferences.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`

**Step 1: Write the failing test**

为 OpenCode 增加迁移后回归测试，确认以下行为不变：

- capability 不支持时跳过 `session/set_model`
- binding 会持久化 negotiated capabilities
- session 切换时旧 runtime 被关闭

```swift
@Test func openCodeProviderStillSkipsModelOverrideWithoutNegotiatedCapability() async throws {
    let harness = try OpenCodeProviderHarness.make(supportsModelOverride: false)

    try await harness.provider.send(harness.request(text: "hello"))

    #expect(!harness.logText().contains("session/set_model"))
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests`

Expected: FAIL once the provider is pointed at the new base with missing overrides.

**Step 3: Write minimal implementation**

把下列逻辑搬入基类：

- runtime 缓存和 working directory 复用
- permission resolver 和 update sink
- projected event 应用
- assistant message resolve or finalize or fail
- binding 恢复与保存

OpenCode provider 只保留：

- `resolveConfiguration`
- `makeLaunchConfiguration`
- `selectedModelOverride(from:handshake:)`
- `persistProviderSpecificBindingFields`

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift agentGui/Models/OpenCodeCLIConfiguration.swift agentGui/Models/SessionExecutionPreferences.swift agentGuiTests/OpenCodeCLIExecutionProviderTests.swift
git commit -m "refactor: move opencode provider onto shared external acp base"
```

### Task 4: 让 Copilot 收敛到同一 runtime abstraction，再迁移到共享基类

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/GitHubCopilotCLIConfiguration.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`

**Step 1: Write the failing test**

补测试锁住 Copilot 独有约束：

- 同一 runtime 重复 `ensureSession` 时不重复 `session/load`
- 切换到不同 remote session 时抛 `sessionAlreadyAttached`
- `defaultModel` 只来自 Copilot 配置，不从 built-in model 回退

```swift
@Test func copilotProviderUsesOnlyCopilotDefaultModelAfterBaseMigration() async throws {
    let harness = try CopilotProviderHarness.make(
        copilotDefaultModel: "gpt-5.4",
        builtInSelectedModel: "claude-sonnet-4-6"
    )

    try await harness.provider.send(harness.request(text: "hello"))

    #expect(harness.sentModelOverride == "gpt-5.4")
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests`

Expected: FAIL while Copilot still uses its old specialized runtime path.

**Step 3: Write minimal implementation**

优先方案：删除 `ACPGitHubCopilotCLIRuntimeClient`，改为让 Copilot 使用 `ACPExternalAgentRuntimeClient`，只在 provider 行为或 descriptor 中保留必要差异。

如果迁移时发现 Copilot 仍需一个小兼容层，限制它只做：

- handshake shape 兼容
- fixed protocol version fallback
- provider-specific capability fallback

禁止继续保留整套重复的 runtime lifecycle 代码。

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift agentGui/Models/GitHubCopilotCLIConfiguration.swift agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift
git commit -m "refactor: migrate copilot provider onto shared external acp runtime"
```

### Task 5: 清理 provider 配置入口与工厂，确保抽象停在正确层级

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIRuntimeFactory.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIRuntimeFactory.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPExternalAgentDescriptor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIRuntimeFactoryTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIRuntimeFactoryTests.swift`

**Step 1: Write the failing test**

补测试确认工厂和 descriptor 各司其职：

- runtime factory 只负责命令、参数、cwd、environment
- descriptor 只负责产品能力与默认行为元数据
- provider 不再自行拼重复的 launch or behavior 逻辑

```swift
@Test func openCodeRuntimeFactoryOnlyBuildsProcessLaunchConfiguration() {
    let configuration = OpenCodeCLIRuntimeFactory().makeLaunchConfiguration(
        executablePath: "opencode",
        workingDirectory: "/tmp/project",
        environmentOverrides: ["A": "1"]
    )

    #expect(configuration.command == "opencode")
    #expect(configuration.arguments == ["acp"])
    #expect(configuration.environmentOverrides == ["A": "1"])
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/GitHubCopilotCLIRuntimeFactoryTests -only-testing:agentGuiTests/OpenCodeCLIRuntimeFactoryTests`

Expected: FAIL if factories still carry product policy or duplicated defaults.

**Step 3: Write minimal implementation**

清理后应形成以下层次：

- configuration model: 用户设置数据
- session preferences resolver: 会话级覆盖
- descriptor or behavior: provider 默认能力与策略
- runtime factory: 进程启动参数
- base provider: 通用执行流程
- concrete provider: 少量 provider-specific 决策

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/GitHubCopilotCLIRuntimeFactoryTests -only-testing:agentGuiTests/OpenCodeCLIRuntimeFactoryTests`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/GitHubCopilot/GitHubCopilotCLIRuntimeFactory.swift agentGui/Services/OpenCode/OpenCodeCLIRuntimeFactory.swift agentGui/Models/ACPExternalAgentDescriptor.swift agentGuiTests/GitHubCopilotCLIRuntimeFactoryTests.swift agentGuiTests/OpenCodeCLIRuntimeFactoryTests.swift
git commit -m "refactor: separate provider behavior from launch factories"
```

### Task 6: 跑回归测试并删除已经失去价值的重复代码

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`

**Step 1: Write the failing test**

补一组 cross-provider regression tests，验证两边仍共享这些外部 ACP 语义：

- restore 阶段 update 不进入 live turn
- permission resolution 会在 tool call 记录里回填结果
- turn 结束时所有悬挂 tool call 会被 settle

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests`

Expected: FAIL until duplicated dead code and stale paths are fully removed.

**Step 3: Write minimal implementation**

删除或内联这些已经被基类覆盖的重复实现：

- duplicated `consume` and `applyPermissionResolution`
- duplicated message finalize and fail helpers
- duplicated runtime cache lifecycle code
- duplicated prompt transcript fallback helper

保留 provider 独有逻辑时，优先通过 override hook 或 behavior closure 注入，而不是复制整段 `send`。

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift agentGuiTests/OpenCodeCLIExecutionProviderTests.swift
git commit -m "refactor: remove duplicated external acp provider flow"
```

## 6. 验证矩阵

每个任务完成后至少跑相关子集，全部完成后跑完整回归：

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests \
  -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests \
  -only-testing:agentGuiTests/GitHubCopilotCLIRuntimeFactoryTests \
  -only-testing:agentGuiTests/OpenCodeCLIRuntimeFactoryTests \
  -only-testing:agentGuiTests/ACPExternalUpdateProjectorTests \
  -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests \
  -only-testing:agentGuiTests/ACPExternalUpdateProjectorTests \
  -only-testing:agentGuiTests/ACPPermissionCenterTests
```

然后再跑一次仓库现成 smoke task：

```bash
./scripts/run_quality_smoke.sh
```

## 7. 风险与回滚点

- 最大风险不是协议层，而是把 provider-specific capability 误抽成共享默认值，导致 Copilot 或 OpenCode 在真实 CLI 下行为回归。
- 第二风险是把 session binding 写入时机改坏，导致多 session 切换后 remote session attach 失效。
- 第三风险是权限请求 tool call 的映射在抽象后丢失 providerID 维度，重新引入跨 provider 污染。
- 如果 Task 4 证明 Copilot 无法立即迁到 `ACPExternalAgentRuntimeClient`，允许保留一个极薄的 Copilot runtime adapter，但必须禁止继续保留整套复制版 provider orchestration。

## 8. 完成标准

- OpenCode 和 Copilot Provider 的 `send` 主流程不再各自维护一整套重复实现。
- 共享层负责外部 ACP 通用生命周期，provider 文件只剩配置解析、能力策略和极少量产品差异。
- Copilot 不再维护与 `ACPExternalAgentRuntimeClient` 平行演进的大块 runtime lifecycle 代码，或至少只剩一层受控 adapter。
- 现有 provider 测试全部通过，新增 characterization tests 能同时覆盖两套 provider 的共享语义。

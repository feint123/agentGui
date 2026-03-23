# ACP Runtime Session Scheduler Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the current mixed external ACP session management with a provider-supervised, session-activation runtime scheduler that isolates Copilot and OpenCode state, removes session-only cache pollution, and preserves restore or prompt or cancel behavior through a single activation model.

**Architecture:** Introduce a provider-level supervisor plus a `(providerID, localSessionID)` activation registry and a single-writer session runtime actor. Move restore routing, live turn projection, binding persistence, and runtime lifecycle transitions into that actor so provider entry points become thin facades and existing shared caches in `ACPExternalExecutionProviderBase` can be deleted instead of wrapped.

**Tech Stack:** Swift 6, SwiftData, Swift Testing, existing ACP transport/runtime stack, `ConversationExecutionProvider`, `ACPExternalAgentRuntimeClient`, current Copilot and OpenCode provider implementations, focused ACP test suites.

---

## 1. 实施原则

- 先锁行为，再换实现；所有核心替换都先写失败测试。
- 新调度层必须直接成为 live state 的唯一事实源，不允许旧字典缓存继续并行存在。
- 先抽 identity 和 lifecycle，再迁移 provider；不要先在 `ACPExternalExecutionProviderBase` 上继续补条件分支。
- restore replay 与 live turn 的分相路由必须在同一个 activation 内完成，不能再依赖外围辅助对象拼接。
- provider-specific 差异只允许留在 capability policy 和 runtime factory，不允许重新扩散到共享调度层。
- 每个 task 都按 @test-driven-development 执行：先写失败测试，再最小实现，再跑通过，再提交。
- 全部任务完成后，用 @requesting-code-review 做一次 review，重点检查跨 provider 切换、restore fallback、change review 回归和删除冗余代码是否彻底。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPProviderRuntimeSupervisor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPSessionRuntimeRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPSessionRuntimeActor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPSessionRuntimeStateMachine.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPSessionUpdateRouter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPProviderRuntimeSupervisorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPSessionRuntimeRegistryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPSessionRuntimeActorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPSessionRuntimeStateMachineTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPSessionUpdateRouterTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderContracts.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionBindingStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionTurnRouter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalUpdateProjector.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderFeatureAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/CopilotSessionBridge.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalAgentRuntimeClientTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExternalChangeReviewIntegrationTests.swift`

### 删除文件或删除主要职责

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/CopilotSessionBridge.swift` 中与 live session activation 重复的内存 binding 缓存职责
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift` 中的 session runtime maps、全局 teardown 分支和 session context 镜像缓存

### 参考文件

- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-23-acp-runtime-session-scheduler-design.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-22-external-acp-provider-abstraction-implementation-plan.md`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalSessionFeatureStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalSessionFeatureExtractorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalSessionBindingStoreTests.swift`

## 3. 分阶段实施顺序

1. 先锁住当前跨 provider 切换、restore replay、runtime 重建和 change review 的关键行为。
2. 再引入新的 identity、state machine、registry、supervisor 和 actor。
3. 之后先迁移 OpenCode，再迁移 Copilot。
4. 最后删除旧桥接缓存和 `ACPExternalExecutionProviderBase` 的 live state 管理职责。
5. 完成后用 focused tests 和 quality smoke 收口。

## 4. Task Breakdown

### Task 1: 锁定跨 provider 与 restore replay 的回归面

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExternalChangeReviewIntegrationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`

**Step 1: Write the failing test**

补 4 组 characterization tests，覆盖：

- Copilot 会话 A 与 OpenCode 会话 B 来回切换后，两边都还能重新 initialize。
- `session/load` replay 的历史 update 不会进入 live turn projection。
- initialize timeout 只会重建当前 session runtime，不会污染兄弟 session。
- change review 的工作目录切换不会导致恢复到错误 remote session。

示例测试骨架：

```swift
@Test func crossProviderSessionSwitchingKeepsEachProviderInitializable() async throws {
    let harness = try CrossProviderSchedulerHarness.make()

    try await harness.sendCopilot(text: "copilot-first")
    try await harness.sendOpenCode(text: "opencode-first")
    try await harness.sendCopilot(text: "copilot-second")
    try await harness.sendOpenCode(text: "opencode-second")

    #expect(harness.copilotInitializeCount == 2)
    #expect(harness.openCodeInitializeCount == 2)
    #expect(harness.recordedErrors.isEmpty)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-plan-1 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/ExternalChangeReviewIntegrationTests CODE_SIGNING_ALLOWED=NO`

Expected: FAIL with missing scheduler harness, current replay pollution, or current cross-provider initialization coupling.

**Step 3: Write minimal implementation**

先只补测试桩和 shared assertion helpers，不改生产代码。

```swift
enum CrossProviderSchedulerAssertions {
    static func expectNoRestoreReplayProjection(_ assistant: Message) {
        #expect(!(assistant.textContent ?? "").contains("restore replay"))
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-plan-1 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/ExternalChangeReviewIntegrationTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift agentGuiTests/OpenCodeCLIExecutionProviderTests.swift agentGuiTests/ExternalChangeReviewIntegrationTests.swift agentGuiTests/ACPExternalExecutionProviderBaseTests.swift
git commit -m "test: lock external acp scheduler regressions"
```

### Task 2: 定义新的 runtime identity 和 lifecycle contracts

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderContracts.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPSessionRuntimeStateMachineTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalAgentRuntimeClientTests.swift`

**Step 1: Write the failing test**

新增测试锁定新的 identity 和状态迁移：

- `SessionRuntimeKey` 由 `providerID + localSessionID` 构成且可哈希。
- `RuntimeActivationID` 每次重建 runtime 都会变化。
- state machine 只允许 `idle -> startingRuntime -> initializing -> restoring -> ready -> sendingTurn -> ready` 这一类合法迁移。

```swift
@Test func stateMachineRejectsPromptBeforeReady() {
    var machine = ACPSessionRuntimeStateMachine()
    #expect(throws: ACPSessionRuntimeStateMachine.Error.self) {
        try machine.transition(.beginPrompt)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-plan-2 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPSessionRuntimeStateMachineTests -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests CODE_SIGNING_ALLOWED=NO`

Expected: FAIL with missing `SessionRuntimeKey`, `RuntimeActivationID`, or `ACPSessionRuntimeStateMachine`.

**Step 3: Write minimal implementation**

在 contracts 文件中新增：

```swift
struct SessionRuntimeKey: Hashable, Sendable {
    let providerID: ConversationExecutionProviderID
    let localSessionID: String
}

struct RuntimeActivationID: Hashable, Sendable {
    let rawValue: UUID
}
```

再用最小状态机实现合法迁移集合。

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-plan-2 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPSessionRuntimeStateMachineTests -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalProviderContracts.swift agentGuiTests/ACPSessionRuntimeStateMachineTests.swift agentGuiTests/ACPExternalAgentRuntimeClientTests.swift
git commit -m "refactor: add acp runtime identity and state contracts"
```

### Task 3: 引入 provider supervisor 和 session registry

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPProviderRuntimeSupervisor.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPSessionRuntimeRegistry.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPProviderRuntimeSupervisorTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPSessionRuntimeRegistryTests.swift`

**Step 1: Write the failing test**

新增测试覆盖：

- 同一个 `SessionRuntimeKey` 总是拿到同一个 activation 引用。
- 不同 provider 的相同 local session ID 不会碰撞。
- provider 级关闭只会关闭自己的 activations。
- activation rebuild 只替换当前 key，不影响 registry 里的其他条目。

```swift
@Test func registrySeparatesSessionsByProviderAndLocalSession() async throws {
    let registry = ACPSessionRuntimeRegistry()

    let copilot = await registry.activation(for: .init(providerID: .githubCopilotCLI, localSessionID: "s1"))
    let openCode = await registry.activation(for: .init(providerID: .openCodeCLI, localSessionID: "s1"))

    #expect(copilot !== openCode)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-plan-3 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPProviderRuntimeSupervisorTests -only-testing:agentGuiTests/ACPSessionRuntimeRegistryTests CODE_SIGNING_ALLOWED=NO`

Expected: FAIL with missing supervisor or registry types.

**Step 3: Write minimal implementation**

实现一个最小 registry 和 supervisor：

```swift
actor ACPSessionRuntimeRegistry {
    private var activations: [SessionRuntimeKey: ACPSessionRuntimeActor] = [:]

    func activation(for key: SessionRuntimeKey, make: @autoclosure () -> ACPSessionRuntimeActor) -> ACPSessionRuntimeActor {
        if let existing = activations[key] { return existing }
        let created = make()
        activations[key] = created
        return created
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-plan-3 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPProviderRuntimeSupervisorTests -only-testing:agentGuiTests/ACPSessionRuntimeRegistryTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPProviderRuntimeSupervisor.swift agentGui/Services/ACP/ACPSessionRuntimeRegistry.swift agentGuiTests/ACPProviderRuntimeSupervisorTests.swift agentGuiTests/ACPSessionRuntimeRegistryTests.swift
git commit -m "refactor: add acp provider supervisor and registry"
```

### Task 4: 落地 session update router，统一 restore 和 live 路由

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPSessionUpdateRouter.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPSessionUpdateRouterTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionTurnRouter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalUpdateProjector.swift`

**Step 1: Write the failing test**

覆盖以下行为：

- restore 阶段更新可以更新内部 session feature 状态，但不能投影到 live assistant 文本。
- live 阶段增量必须只来自当前 activation。
- activation 关闭后，旧 activation 的迟到 update 必须被丢弃。

```swift
@Test func updateRouterDropsStaleActivationUpdates() {
    let router = ACPSessionUpdateRouter()
    let current = RuntimeActivationID(rawValue: UUID())
    let stale = RuntimeActivationID(rawValue: UUID())

    #expect(router.shouldProject(updateActivationID: stale, currentActivationID: current, phase: .sendingTurn) == false)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-plan-4 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPSessionUpdateRouterTests -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests CODE_SIGNING_ALLOWED=NO`

Expected: FAIL with missing activation-aware router.

**Step 3: Write minimal implementation**

新增 activation-aware 路由器，并让旧 `ACPExternalSessionTurnRouter` 变成薄包装或删除后兼容层。

```swift
struct ACPSessionUpdateRouter {
    func shouldProject(updateActivationID: RuntimeActivationID, currentActivationID: RuntimeActivationID, phase: ACPSessionRuntimePhase) -> Bool {
        guard updateActivationID == currentActivationID else { return false }
        return phase == .sendingTurn
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-plan-4 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPSessionUpdateRouterTests -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPSessionUpdateRouter.swift agentGui/Services/ACP/ACPExternalSessionTurnRouter.swift agentGui/Services/ACP/ACPExternalUpdateProjector.swift agentGuiTests/ACPSessionUpdateRouterTests.swift agentGuiTests/ACPExternalExecutionProviderBaseTests.swift
git commit -m "refactor: make acp update routing activation-aware"
```

### Task 5: 实现 session runtime actor，收拢 live state

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPSessionRuntimeActor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionBindingStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderFeatureAdapter.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPSessionRuntimeActorTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalSessionFeatureStoreTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalSessionFeatureExtractorTests.swift`

**Step 1: Write the failing test**

新增 actor 级测试验证：

- initialize 成功后 capability snapshot 归属于当前 activation。
- `session/load` 超时或失败会触发 runtime 重建并回退 `session/new`。
- actor 内部持有 remote binding、feature store、projector 和 active request，不再依赖外围镜像缓存。

```swift
@Test func actorFallsBackToNewSessionAfterLoadTimeout() async throws {
    let harness = try SessionRuntimeActorHarness.make(loadBehavior: .timeoutThenNew)
    let handshake = try await harness.actor.prepareSession()

    #expect(handshake.remoteSessionID == "remote-new")
    #expect(harness.runtimeRebuildCount == 1)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-plan-5 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPSessionRuntimeActorTests -only-testing:agentGuiTests/ACPExternalSessionFeatureStoreTests -only-testing:agentGuiTests/ACPExternalSessionFeatureExtractorTests CODE_SIGNING_ALLOWED=NO`

Expected: FAIL with missing actor and fallback lifecycle handling.

**Step 3: Write minimal implementation**

让 actor 先只承接：

- runtime client
- activation ID
- binding store 访问
- update router
- projector

不要在这一 task 里迁移 provider。

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-plan-5 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPSessionRuntimeActorTests -only-testing:agentGuiTests/ACPExternalSessionFeatureStoreTests -only-testing:agentGuiTests/ACPExternalSessionFeatureExtractorTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPSessionRuntimeActor.swift agentGui/Services/ACP/ACPExternalSessionBindingStore.swift agentGui/Services/ACP/ACPExternalProviderFeatureAdapter.swift agentGuiTests/ACPSessionRuntimeActorTests.swift agentGuiTests/ACPExternalSessionFeatureStoreTests.swift agentGuiTests/ACPExternalSessionFeatureExtractorTests.swift
git commit -m "refactor: add acp session runtime actor"
```

### Task 6: 收窄 ACPExternalAgentRuntimeClient 为 transport client

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderContracts.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalAgentRuntimeClientTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`

**Step 1: Write the failing test**

新增测试验证 runtime client 不再承担 session scheduler 的镜像状态职责：

- attach 语义只对单 activation 生效。
- `ensureSession` 的结果被 actor 接管后，client 本身不暴露跨 session 缓存。
- close 后再次使用必须通过新 activation 重建。

```swift
@Test func runtimeClientCannotBeReusedAfterActivationClose() async throws {
    let harness = try RuntimeClientHarness.make()
    await harness.client.close()

    await #expect(throws: ACPExternalAgentRuntimeError.self) {
        _ = try await harness.client.ensureSession(workingDirectory: harness.workingDirectory, remoteSessionID: nil)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-plan-6 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests CODE_SIGNING_ALLOWED=NO`

Expected: FAIL because current runtime client still mixes lifecycle cache with session attachment semantics.

**Step 3: Write minimal implementation**

保留 transport 层必要行为，但把 activation 生命周期显式化：

```swift
protocol ACPExternalProviderRuntimeClient: AnyObject {
    func initializeIfNeeded() async throws -> ACPExternalAgentCapabilitySnapshot
    func loadSessionIfPossible(_ remoteSessionID: String) async throws -> ACPExternalAgentSessionHandshake?
    func createSession() async throws -> ACPExternalAgentSessionHandshake
    func prompt(text: String, sessionID: String) async throws -> ACPStopReason
    func cancel(sessionID: String) async throws
    func close() async
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-plan-6 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift agentGui/Services/ACP/ACPExternalProviderContracts.swift agentGuiTests/ACPExternalAgentRuntimeClientTests.swift agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift
git commit -m "refactor: narrow external acp runtime client responsibilities"
```

### Task 7: 先迁移 OpenCode provider 到 supervisor 和 actor 路径

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`

**Step 1: Write the failing test**

扩展 OpenCode provider tests，锁定迁移后的新行为：

- provider facade 只委托给 supervisor。
- 同一个 OpenCode session 连续发送不会重复 load 已附着 remote session。
- 切换另一个 OpenCode session 时关闭旧 activation，但 durable binding 仍可恢复。

```swift
@Test func openCodeProviderDelegatesSessionLifecycleToSupervisor() async throws {
    let harness = try OpenCodeSupervisorHarness.make()
    try await harness.provider.send(harness.request(text: "hello"))

    #expect(harness.supervisorSendCount == 1)
    #expect(harness.baseRuntimeClientMapsTouched == false)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-plan-7 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests CODE_SIGNING_ALLOWED=NO`

Expected: FAIL because current provider still runs through `ACPExternalExecutionProviderBase` live maps.

**Step 3: Write minimal implementation**

把 OpenCode provider 改成 thin facade：

- 解析配置
- 选择 capability policy
- 调用 supervisor 获取 actor 并发送 request

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-plan-7 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift agentGuiTests/OpenCodeCLIExecutionProviderTests.swift
git commit -m "refactor: migrate opencode provider to runtime supervisor"
```

### Task 8: 迁移 Copilot provider 并清除 bridge 式 live cache

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/CopilotSessionBridge.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`

**Step 1: Write the failing test**

增加回归测试验证：

- Copilot 的 live binding 不再依赖 bridge 内存缓存。
- provider 重新实例化后只从 durable binding store 恢复。
- Copilot 与 OpenCode 同时存在时不会共享 session-only cache。

```swift
@Test func copilotProviderRestoresFromDurableBindingWithoutBridgeMirror() async throws {
    let harness = try CopilotDurableBindingHarness.make()
    try await harness.firstProvider.send(harness.request(text: "first"))

    let secondProvider = harness.makeFreshProvider()
    try await secondProvider.send(harness.request(text: "second"))

    #expect(harness.bridgeLiveCacheReads == 0)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-plan-8 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests CODE_SIGNING_ALLOWED=NO`

Expected: FAIL because current Copilot path still reads live bridge state.

**Step 3: Write minimal implementation**

把 bridge 留成 compatibility shell 或直接只保留持久化适配，不再承载 live session activation state。

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-plan-8 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift agentGui/Services/GitHubCopilot/CopilotSessionBridge.swift agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift agentGuiTests/ACPExternalExecutionProviderBaseTests.swift
git commit -m "refactor: migrate copilot provider off bridge session cache"
```

### Task 9: 删除 ACPExternalExecutionProviderBase 中的旧 live maps 和 teardown 分支

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`

**Step 1: Write the failing test**

新增针对旧职责删除后的验证：

- provider base 不再持有 `runtimeClients`、`runtimeWorkingDirectories`、`activeTurns`、`featureStores`、`remoteSessionIDs`、`sessionContexts`、`pendingUpdateTasks` 这些 live maps。
- provider 行为测试仍然全部通过。

```swift
@Test func providerBaseNoLongerOwnsSessionLiveState() {
    let mirror = Mirror(reflecting: ACPExternalExecutionProviderBaseProbe())
    let labels = Set(mirror.children.compactMap(\.label))

    #expect(!labels.contains("runtimeClients"))
    #expect(!labels.contains("remoteSessionIDs"))
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-plan-9 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests CODE_SIGNING_ALLOWED=NO`

Expected: FAIL because old maps still exist.

**Step 3: Write minimal implementation**

删除旧 maps、旧清理分支和 session context 镜像缓存，把剩余共用代码压缩成真正的 facade helper。

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-plan-9 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift agentGuiTests/ACPExternalExecutionProviderBaseTests.swift agentGuiTests/OpenCodeCLIExecutionProviderTests.swift agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift
git commit -m "refactor: delete legacy external acp session maps"
```

### Task 10: 跑 focused ACP 回归并清理文档

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-23-acp-runtime-session-scheduler-design.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-23-acp-runtime-session-scheduler-implementation-plan.md`

**Step 1: Write the failing test**

这一 task 不新增功能测试，只补一条 checklist，要求所有 focused ACP tests 与 quality smoke 至少完成一次成功运行并记录结果。

```markdown
- [ ] Focused ACP Tests Fresh passed
- [ ] OpenCode ACP Tests Fresh passed
- [ ] Quality Smoke passed or documented known unrelated failures
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-plan-10 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiTests/ACPExternalSessionFeatureStoreTests -only-testing:agentGuiTests/ACPExternalSessionFeatureExtractorTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS or only unrelated failures. If any ACP regression remains, treat as blocking.

**Step 3: Write minimal implementation**

运行并记录：

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-derived-task -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiTests/ACPExternalSessionFeatureStoreTests -only-testing:agentGuiTests/ACPExternalSessionFeatureExtractorTests CODE_SIGNING_ALLOWED=NO`

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-opencode-derived -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests CODE_SIGNING_ALLOWED=NO`

Run: `./scripts/run_quality_smoke.sh`

把结果回填到设计文档和本 implementation plan 的执行记录区。

**Step 4: Run test to verify it passes**

Expected: focused ACP tests PASS；如 `Quality Smoke` 有无关失败，文档中明确记录并附上原因。

**Step 5: Commit**

```bash
git add docs/plans/2026-03-23-acp-runtime-session-scheduler-design.md docs/plans/2026-03-23-acp-runtime-session-scheduler-implementation-plan.md
git commit -m "docs: record acp runtime scheduler rollout verification"
```

## 5. 验收标准

- Copilot session A 与 OpenCode session B 来回切换后，双方都能稳定 initialize 和发送。
- `session/load` replay 不再污染 live turn projection。
- initialize timeout、load timeout、runtime close 只影响当前 activation。
- provider live state 的唯一事实源变成 `ACPSessionRuntimeActor`，而不是 `ACPExternalExecutionProviderBase` 内部字典。
- durable binding 只通过 `ACPExternalSessionBindingStore` 恢复，bridge 不再承载 live cache。
- OpenCode、Copilot、change review、feature store、feature extractor 相关回归测试通过。

## 6. 执行提示

- 每完成一个 task 就跑对应最小测试集，不要等到最后一次性跑全量。
- 迁移 OpenCode 时不要顺手改 Copilot；保持单 provider 切面提交，便于回退。
- 删除旧字典前，先确保 registry 和 actor 已经接管等价职责，否则会出现半替换状态。
- 如果某个旧 helper 仍然依赖 provider base live map，就先把它降级为 actor 内部 helper，再删旧字段。

Plan complete and saved to `docs/plans/2026-03-23-acp-runtime-session-scheduler-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
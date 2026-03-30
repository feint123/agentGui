# ACP Session Actor Single-Writer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Introduce a per-`(provider, localSession)` ACP provider session actor so the live `send` path has one serialized write entry, and ordered turn mutations no longer execute directly inside `ACPExternalExecutionProviderBase`.

**Architecture:** Keep runtime bootstrap and remote-session preparation on top of the existing `ACPProviderRuntimeSupervisor` plus `ACPSessionRuntimeActor` stack. Add a lightweight `ACPProviderSessionActor` plus registry dedicated to the live-turn send path: after the provider base resolves configuration, availability, prepared runtime session, and initial mode/config selections, it hands a prepared turn context and a `MainActor` hook surface into the session actor. The session actor becomes the only owner of begin prompt, prompt completion, pending-update drain, projected flush, finalize, cancellation cleanup, and failure cleanup ordering for one local session.

**Tech Stack:** Swift 6, SwiftData, Swift Testing, existing ACP runtime stack (`ACPExternalExecutionProviderBase`, `ACPProviderRuntimeSupervisor`, `ACPSessionRuntimeActor`, `ACPExternalProviderSessionStateStore`, `ACPExternalSessionTurnRouter`, `ACPExternalUpdateProjector`), focused ACP test suites.

---

## 1. Implementation Rules

- 我正在使用 writing-plans skill 来编写这份 implementation plan。
- 这份计划只覆盖 Feature 8，不提前实现 Feature 9 的 bootstrap/config actor 化，也不把 Feature 10 的完整 update projector/turn router/session state store 迁移提前拉进来。
- 严格按 @test-driven-development 执行：每个 task 先写失败测试，再验证红灯，再写最小实现，再跑通过，再提交。
- `ACPExternalExecutionProviderBase.send` 在本轮结束后仍可负责配置解析、provider 可用性检查、`ensureRemoteSessionPrepared`、initial mode/config 应用与 prompt text 组装；但 live turn 的顺序敏感写操作必须下沉到 session actor。
- 不要新建第二套 runtime lifecycle 状态机。`ACPSessionRuntimeActor` 继续负责 runtime/session bootstrap；新的 `ACPProviderSessionActor` 只负责单 session 的 live send 顺序化。
- session actor 可以通过 `MainActor` hook/closure 调用现有投影与模型变更逻辑，但 hook surface 必须收敛成明确动作，不能把整个 provider base 暴露给 actor。
- 从 `@MainActor` 类里构造 actor 依赖时，先把需要的依赖捕获到局部常量，再传入 `@Sendable` 闭包；不要直接在异步工厂闭包里捕获 `self` 的主线程隔离属性。
- focused tests 必须显式断言 `begin prompt`、`flush projected updates`、`finalize assistant message` 由 session actor 驱动，而不是只断言最终 message 状态正确。
- 单个 local session 的并发 `send` 必须被同一个 session actor 串行化；不同 local session 不应互相阻塞。
- 任务完成后，用 @requesting-code-review 做一次 focused review，重点检查：single-writer 是否真的成立、provider base 的直接 live-turn 状态突变是否明显减少、取消和失败路径是否仍完整。

## 2. Current State Summary

- `ACPExternalExecutionProviderBase.send` 当前直接执行整条 live turn 流程：在同一个方法里做 `updateProjector.reset -> activeTurn 建立 -> turnRouter.beginLiveTurn -> runtimeClient.prompt -> drainPendingUpdates -> flushProjectedUpdates -> finalizeAssistantMessage -> activeTurn 清理 -> turnRouter.finishLiveTurn`。
- `ACPProviderRuntimeSupervisor` 与 `ACPSessionRuntimeActor` 已经解决 runtime/session bootstrap 复用与恢复问题，但没有承接 live turn 单写入口。
- `ACPExternalProviderSessionStateStore`、`ACPExternalSessionTurnRouter`、`ACPExternalUpdateProjector` 仍由 provider base 直接调度，所以 send 主路径上的可变状态边界散在 base 内部。
- `DynamicACPExternalExecutionProviderTests` 目前只验证 ACP flow 的结果，没有验证 begin/flush/finalize 的执行归属。
- 现有 `Feature 8 ACP Actorization Tests` 任务已经预留了 `ACPProviderSessionActorTests`，说明仓库方向已经接受“新增 session actor + focused tests”的落地方式。

## 3. Desired End State

完成后应满足以下条件：

1. 同一个 `(provider, localSession)` 的 live send 只通过一个 `ACPProviderSessionActor` 串行进入。
2. `ACPExternalExecutionProviderBase.send` 不再直接编排一次完整 turn 的 begin/flush/finalize 顺序；它只准备上下文并把执行委托给 session actor。
3. session actor 独占以下动作顺序：begin prompt、建立 active turn、调用 prompt、等待 pending updates drain、flush projected updates、finalize/fail/cancel cleanup、finish/reset live turn。
4. 取消与异常路径不会绕过 actor 直接修改 live turn 状态；至少 send 主路径上的 cleanup 顺序从 actor 统一出发。
5. focused tests 能记录并断言 actor 驱动的步骤序列，而不是继续依赖“最后 message 看起来对了”的弱断言。
6. 本轮不把 `updateSessionMode`、`updateSessionConfigOption`、`ensureRemoteSessionPrepared`、release/cancel lifecycle 总收敛到 actor；这些明确留给 Feature 9-11。

## 4. Target Files

### New production files

- `agentGui/Services/ACP/ACPProviderSessionActor.swift`
- `agentGui/Services/ACP/ACPProviderSessionActorRegistry.swift`

### Production files to modify

- `agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- `agentGui/Services/ACP/ACPExternalProviderSessionStateStore.swift`
- `agentGui/Services/ACP/ACPProviderRuntimeSupervisor.swift`

### New test files

- `agentGuiTests/ACPProviderSessionActorTests.swift`
- `agentGuiTests/TestSupport/ACPProviderSessionActorTestProbe.swift`

### Test files to modify

- `agentGuiTests/DynamicACPExternalExecutionProviderTests.swift`
- `agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`
- `agentGuiTests/TestSupport/MultiSessionExecutionFixtures.swift`

## 5. Task Breakdown

### Task 1: 锁定 Feature 8 的行为验收面

**Files:**
- Create: `agentGuiTests/ACPProviderSessionActorTests.swift`
- Create: `agentGuiTests/TestSupport/ACPProviderSessionActorTestProbe.swift`
- Modify: `agentGuiTests/DynamicACPExternalExecutionProviderTests.swift`
- Modify: `agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`

**Step 1: Write the failing tests**

新增 3 组 focused tests：

1. `ACPProviderSessionActorTests.sendSerializesConcurrentTurnsForSameSession()`
   - 构造一个带 gate 的假 runtime prompt。
   - 并发触发同一个 actor 的两次 `sendPreparedTurn`。
   - 断言第二次 send 在第一次 finalize 之前不会开始 `beginPrompt`。
2. `ACPProviderSessionActorTests.sendAllowsDifferentSessionsToProceedIndependently()`
   - 两个不同 local session 的 actor 各自发送。
   - 断言它们不会共享串行锁。
3. `DynamicACPExternalExecutionProviderTests.sendRoutesBeginFlushFinalizeThroughSessionActor()`
   - 给 provider 注入 test probe。
   - 断言步骤序列至少包含：`.beginPrompt`, `.promptStarted`, `.promptFinished`, `.flushProjectedUpdates`, `.finalizeAssistantMessage`, `.finishLiveTurn`。

建议测试骨架：

```swift
import Foundation
import Testing
@testable import agentGui

struct ACPProviderSessionActorTests {
    @Test
    func sendSerializesConcurrentTurnsForSameSession() async throws {
        let probe = ACPProviderSessionActorTestProbe()
        let gate = AsyncGate()
        let actor = ACPProviderSessionActor(
            localSessionID: "session-a",
            hooks: .fixture(probe: probe, promptGate: gate)
        )

        let first = Task {
            try await actor.sendPreparedTurn(.fixture(requestText: "first"))
        }
        await probe.waitUntilContains(.beginPrompt(requestText: "first"))

        let second = Task {
            try await actor.sendPreparedTurn(.fixture(requestText: "second"))
        }

        try await Task.sleep(for: .milliseconds(100))
        #expect(await probe.steps.contains(.beginPrompt(requestText: "second")) == false)

        await gate.release()
        _ = try await first.value
        _ = try await second.value

        #expect(await probe.steps.firstIndex(of: .finalizeAssistantMessage(requestText: "first"))
            < await probe.steps.firstIndex(of: .beginPrompt(requestText: "second")))
    }
}
```

`ACPExternalExecutionProviderBaseTests` 额外补一条 characterization test，锁定“provider base 在 send 完成后不再自己持有 turn sequencing 断言入口，而是通过 injected session actor probe 暴露顺序”。该测试不需要验证所有细节，只要锁住 public integration surface。

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -quiet -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature8-task1 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPProviderSessionActorTests -only-testing:agentGuiTests/DynamicACPExternalExecutionProviderTests -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because `ACPProviderSessionActor`, test probe, and actor-owned send trace do not exist yet.

**Step 3: Write minimal implementation scaffolding**

先只补 test support 与最小占位 API，不接入生产 send 主路径。建议先定义可断言的 trace step：

```swift
enum ACPProviderSessionActorStep: Sendable, Equatable {
    case beginPrompt(requestText: String)
    case promptStarted(remoteSessionID: String)
    case promptFinished(stopReason: ACPStopReason)
    case flushProjectedUpdates
    case finalizeAssistantMessage(requestText: String)
    case finishLiveTurn
    case cancelCleanup
    case failCleanup
}
```

测试 probe 只负责记录步骤，不负责真实变更。

**Step 4: Run tests to verify scaffolding compiles**

Run 同 Step 2。

Expected: 仍然 FAIL，但失败收敛到“actor 未实现行为”而不是“类型不存在/无法编译”。

**Step 5: Commit**

```bash
git add agentGuiTests/ACPProviderSessionActorTests.swift agentGuiTests/TestSupport/ACPProviderSessionActorTestProbe.swift agentGuiTests/DynamicACPExternalExecutionProviderTests.swift agentGuiTests/ACPExternalExecutionProviderBaseTests.swift
git commit -m "test: lock feature 8 session actor behavior"
```

### Task 2: 引入 provider session actor 与 registry

**Files:**
- Create: `agentGui/Services/ACP/ACPProviderSessionActor.swift`
- Create: `agentGui/Services/ACP/ACPProviderSessionActorRegistry.swift`
- Modify: `agentGuiTests/ACPProviderSessionActorTests.swift`

**Step 1: Write the failing tests**

继续补 actor 单测，锁定最小状态与执行入口：

1. 同一个 registry key 返回同一个 actor。
2. `sendPreparedTurn` 在成功路径上的步骤顺序固定。
3. prompt 抛 `CancellationError` 时记录 `.cancelCleanup`，且不会再记录 `.finalizeAssistantMessage`。
4. prompt 抛普通错误时记录 `.failCleanup`，且错误继续向上传播。

建议测试骨架：

```swift
@Test
func sendRunsSuccessPathInFixedOrder() async throws {
    let probe = ACPProviderSessionActorTestProbe()
    let actor = ACPProviderSessionActor(
        localSessionID: "session-a",
        hooks: .fixture(probe: probe, stopReason: .endTurn)
    )

    try await actor.sendPreparedTurn(.fixture(requestText: "hello"))

    #expect(await probe.steps == [
        .beginPrompt(requestText: "hello"),
        .promptStarted(remoteSessionID: "remote-a"),
        .promptFinished(stopReason: .endTurn),
        .flushProjectedUpdates,
        .finalizeAssistantMessage(requestText: "hello"),
        .finishLiveTurn
    ])
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -quiet -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature8-task2 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPProviderSessionActorTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because actor success/cancel/failure sequencing and registry reuse do not exist yet.

**Step 3: Write minimal implementation**

推荐把 actor 设计成“单 session 串行器 + hook surface”，不要直接把 provider base 传进去：

```swift
actor ACPProviderSessionActor {
    struct PreparedTurn: Sendable {
        let requestText: String
        let localSessionID: String
        let remoteSessionID: String
        let promptText: String
    }

    struct Hooks: Sendable {
        let beginPrompt: @Sendable (PreparedTurn) async throws -> Void
        let prompt: @Sendable (PreparedTurn) async throws -> ACPStopReason
        let drainPendingUpdates: @Sendable (String) async -> Void
        let flushProjectedUpdates: @Sendable (PreparedTurn) async -> Void
        let finalizeAssistantMessage: @Sendable (PreparedTurn, ACPStopReason) async -> Void
        let handleCancellation: @Sendable (PreparedTurn) async -> Void
        let handleFailure: @Sendable (PreparedTurn, Error) async -> Void
        let finishLiveTurn: @Sendable (PreparedTurn) async -> Void
    }

    func sendPreparedTurn(_ turn: PreparedTurn) async throws {
        try await hooks.beginPrompt(turn)
        do {
            let stopReason = try await hooks.prompt(turn)
            await hooks.drainPendingUpdates(turn.localSessionID)
            await hooks.flushProjectedUpdates(turn)
            await hooks.finalizeAssistantMessage(turn, stopReason)
            await hooks.finishLiveTurn(turn)
        } catch is CancellationError {
            await hooks.handleCancellation(turn)
            throw CancellationError()
        } catch {
            await hooks.handleFailure(turn, error)
            throw error
        }
    }
}
```

`ACPProviderSessionActorRegistry` 保持最小化：只按 local session ID 返回 actor，不承担 runtime lifecycle。

**Step 4: Run tests to verify they pass**

Run 同 Step 2。

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPProviderSessionActor.swift agentGui/Services/ACP/ACPProviderSessionActorRegistry.swift agentGuiTests/ACPProviderSessionActorTests.swift
git commit -m "feat: add acp provider session actor"
```

### Task 3: 将 provider base 的 send 主路径委托给 session actor

**Files:**
- Modify: `agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- Modify: `agentGui/Services/ACP/ACPExternalProviderSessionStateStore.swift`
- Modify: `agentGuiTests/DynamicACPExternalExecutionProviderTests.swift`
- Modify: `agentGuiTests/TestSupport/MultiSessionExecutionFixtures.swift`

**Step 1: Write the failing integration tests**

补两条 integration tests：

1. `DynamicACPExternalExecutionProviderTests.sendRoutesLiveTurnThroughSingleSessionActor()`
   - 对同一个 session 连续发送两次。
   - 断言第二次 send 复用了同一个 provider session actor。
   - 断言步骤 trace 从 actor 发出，而不是 base 直调。
2. `DynamicACPExternalExecutionProviderTests.sendPreservesExistingACPFlowOutputsAfterActorization()`
   - 保留原有 prompt/config/remote commands 断言。
   - 额外断言 actor 化没有改变结果面。

建议把 test harness 做成显式注入：

```swift
let provider = DynamicACPExternalExecutionProvider(
    profile: profile,
    terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
    permissionCenter: ACPPermissionCenter(),
    sessionActorProbe: probe,
    runtimeClientFactory: { _, _, _, _, updateSink in
        DynamicACPTestRuntimeClient(
            handshake: .fixture(remoteSessionID: "remote-send"),
            updateSink: updateSink
        )
    }
)
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -quiet -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature8-task3 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/DynamicACPExternalExecutionProviderTests -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because `ACPExternalExecutionProviderBase.send` still performs live-turn mutations directly.

**Step 3: Write minimal implementation**

将 `send` 主路径切成两段：

1. base 侧准备阶段：
   - 解析 settings/configuration。
   - availability 检查。
   - `ensureRemoteSessionPrepared(...)`。
   - initial mode/config 应用。
   - `persistBinding(...)`。
   - 组装 `PreparedTurn`。
2. actor 侧执行阶段：
   - `beginPrompt` hook 内负责 `updateProjector.reset`、`activeTurn` 建立、`turnRouter.beginLiveTurn`。
   - `prompt` hook 调用 `runtimeClient.prompt(...)`。
   - 成功后 actor 依次 drain、flush、finalize、finish。
   - 失败/取消后 actor 依次执行 reset/flush/fail 或 cancel cleanup。

建议在 base 中新增一个“只暴露动作”的 hook 构造器：

```swift
private func makeSessionActorHooks(
    assistantMessage: Message,
    session: Session,
    modelContext: ModelContext,
    runtimeClient: any ACPExternalProviderRuntimeTransportClient
) -> ACPProviderSessionActor.Hooks {
    let updateProjector = self.updateProjector
    let turnRouter = self.turnRouter
    let sessionStateStore = self.sessionStateStore
    let provider = self

    return ACPProviderSessionActor.Hooks(
        beginPrompt: { preparedTurn in
            await MainActor.run {
                updateProjector.reset(sessionID: preparedTurn.localSessionID)
                let sessionState = sessionStateStore.state(for: preparedTurn.localSessionID)
                sessionState.resetProjectedMutations()
                sessionState.activeTurn = ACPExternalProviderActiveTurnState(
                    assistantMessage: assistantMessage,
                    modelContext: modelContext
                )
                turnRouter.beginLiveTurn(sessionID: preparedTurn.localSessionID)
            }
        },
        prompt: { preparedTurn in
            try await runtimeClient.prompt(text: preparedTurn.promptText, sessionID: preparedTurn.remoteSessionID)
        },
        ...
    )
}
```

关键点：

- hook 必须只暴露动作，不暴露 `self` 全对象。
- 从 `@MainActor` 类型构造 hook 时，先把依赖复制到局部常量，避免主线程隔离属性被 `@Sendable` 闭包直接捕获。
- `send` 末尾不再直接调用 `turnRouter.beginLiveTurn`、`flushProjectedUpdates`、`finalizeAssistantMessage`、`turnRouter.finishLiveTurn`。

**Step 4: Run tests to verify they pass**

Run 同 Step 2。

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift agentGui/Services/ACP/ACPExternalProviderSessionStateStore.swift agentGuiTests/DynamicACPExternalExecutionProviderTests.swift agentGuiTests/TestSupport/MultiSessionExecutionFixtures.swift
git commit -m "refactor: route acp send through provider session actor"
```

### Task 4: 清理 base 的直接 live-turn 编排职责并收口 focused suites

**Files:**
- Modify: `agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- Modify: `agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`
- Modify: `agentGuiTests/DynamicACPExternalExecutionProviderTests.swift`

**Step 1: Write the failing cleanup/regression tests**

补回归测试，锁定以下边界：

1. `send` 成功后，provider base 不再在方法体中直接清理 `activeTurn = nil`；该动作由 actor 的 finalize/finish hooks 完成。
2. `send` 抛错时，flush 与 fail cleanup 的顺序固定，且不会遗漏 `updateProjector.reset`。
3. `CancellationError` 路径会统一走 actor 的 cancel cleanup，且 assistant message 状态仍为 `.cancelled`。

建议测试骨架：

```swift
@Test
func cancellationPathFlushesThenMarksCancelledFromActor() async throws {
    let probe = ACPProviderSessionActorTestProbe()
    let provider = makeCancellationHarness(probe: probe)

    await #expect(throws: CancellationError.self) {
        try await provider.send(...)
    }

    #expect(await probe.contains(.flushProjectedUpdates))
    #expect(await probe.contains(.cancelCleanup))
    #expect(await probe.index(of: .flushProjectedUpdates) < await probe.index(of: .cancelCleanup))
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -quiet -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature8-task4 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPProviderSessionActorTests -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/DynamicACPExternalExecutionProviderTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL if any cleanup path still bypasses the actor-owned hook sequence.

**Step 3: Write minimal implementation**

对 `ACPExternalExecutionProviderBase` 做收口：

- 把 send 主路径直接使用的 `markCancelledIfNeeded`、`failAssistantMessage`、`flushProjectedUpdates`、`finalizeAssistantMessage`、`turnRouter.reset/begin/finish` 调用收敛到 actor hook 内。
- 保留这些 helper 本身，但把可见语义改成“被 actor 调用的动作”，不要再让 `send` 直接拼装完整 turn lifecycle。
- 若 `ACPExternalProviderSessionStateStore` 需要支持 actor registry 生命周期，可在 store 中补最小元数据，但不要开始迁移 feature store 或 binding store。

本 task 完成后，`ACPExternalExecutionProviderBase.send` 的结构应该接近：

```swift
func send(_ request: ConversationExecutionRequest) async throws {
    let prepared = try await prepareLiveTurn(request)
    let actor = await sessionActor(for: prepared.localSessionID)
    try await actor.sendPreparedTurn(prepared.turn)
}
```

如果 `send` 仍然保留完整 try/catch 并直接做 flush/finalize/cancel/fail，那么说明 Feature 8 没有真正完成。

**Step 4: Run focused regression suites**

优先运行已有集中任务：

```bash
xcodebuild test -quiet -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature8-acp-derived -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPProviderSessionActorTests -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/DynamicACPExternalExecutionProviderTests -only-testing:agentGuiTests/ACPIsolationTests -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests CODE_SIGNING_ALLOWED=NO
```

然后补跑 provider-focused suite，确保没有把既有 ACP 隔离与验证路径打坏：

```bash
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-provider-feature8 -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/DynamicACPExternalExecutionProviderTests -only-testing:agentGuiTests/ACPProviderValidationServiceTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift agentGuiTests/ACPExternalExecutionProviderBaseTests.swift agentGuiTests/DynamicACPExternalExecutionProviderTests.swift
git commit -m "refactor: reduce provider base live turn mutation ownership"
```

## 6. Risks and Guardrails

- 风险 1：如果把 `ensureRemoteSessionPrepared` 也一起搬进 actor，会和 Feature 9 的 bootstrap/config actor 化混线。规避方式：本轮 actor 只接收 prepared runtime session 与 turn context，不吞 bootstrap 责任。
- 风险 2：如果 actor 直接持有 `Message`、`Session`、`ModelContext` 并在非 `MainActor` 上突变，容易引入隔离问题。规避方式：所有模型写入继续通过 `MainActor` hook 完成。
- 风险 3：如果 session actor registry 退化成 provider base 里的普通字典，再加上 `@MainActor` send，会形成伪串行而不是真正 actor 单写入口。规避方式：显式引入 actor registry，focused tests 用并发 send 证明串行化。
- 风险 4：如果测试只断言 prompt 结果，不记录步骤序列，那么 provider base 仍可偷偷保留 begin/flush/finalize 直调。规避方式：把 step probe 当成 Feature 8 的正式验收工具，而不是临时调试代码。
- 风险 5：如果 hook 闭包直接捕获 `self.updateProjector`、`self.turnRouter`、`self.sessionStateStore` 等 `@MainActor` 属性，Swift 6 下很容易再次出现隔离捕获报错。规避方式：构造 hook 前先做局部常量提取。

## 7. Handoff Notes

- Feature 8 完成后，下一份计划应直接承接 Feature 9：把 `ensureRemoteSessionPrepared`、`updateSessionMode`、`updateSessionConfigOption` 统一并入 session actor，而不是重新在 provider base 上补分支。
- 如果在 Feature 8 过程中发现 cancel/release/warmup retry 的脏状态复位问题，不要顺手扩到完整生命周期状态机；先记录为 Feature 11 输入。
- 只有当 `send` 主路径已经缩成“prepare -> actor.sendPreparedTurn”这种薄 facade 结构时，才算真正满足本轮目标。

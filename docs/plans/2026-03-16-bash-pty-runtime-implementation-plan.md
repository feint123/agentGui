# Bash PTY Runtime Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the existing bash runtime with a PTY-only managed terminal task system that removes the old `BashSession` compatibility path and gives the app a single task-based execution model for attached and detached shell work.

**Architecture:** Introduce a new PTY runtime stack under `Services/Terminal` that owns process creation, transcript capture, task routing, lifecycle observation, and structured completion results. Rewire bash tool dispatch, task persistence, and UI presentation to consume the new terminal task contracts directly, then delete the old `BashSession` / legacy request normalization flow.

**Tech Stack:** Swift 6, SwiftData, Swift Testing, Foundation, Darwin PTY APIs, existing `ClaudeService`, `ToolCall`, `AgentLoopToolExecutionCoordinatorBuilder`, `ToolCallBubbleView`, `ToolCallDetailContentView`.

---

## 0. 实施约束

- 严格按 `@test-driven-development` 执行，先锁定 PTY runtime 契约，再接真实实现。
- 不保留旧 `background` / `interactive` / `interrupt` 兼容字段；计划中的任何 schema 改动都以新 PTY 协议为准。
- 不做双轨运行时，不允许“新旧 bash runtime 共存”。
- 新 runtime 必须以 `task_id` 为唯一控制主键，不允许隐式当前任务。
- 旧 `BashSession`、旧 `BashTaskEventReducer`、旧前台观察逻辑最终都要删除，不做保守保留。
- UI 与持久化要同步迁移，不允许 runtime 已替换但 `ToolCall` / UI 继续消费旧状态语义。

## 1. 当前代码落点

当前 bash 运行时相关代码主要分布在以下文件：

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashSession.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashTaskRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashTaskEventReducer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashPromptAnalyzer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashCommandClassifier.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+BashTool.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+BashSession.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolCallRecord.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TerminalTaskModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ToolCallRowPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashCommandClassifierTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashPromptAnalyzerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashTaskEventReducerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolSchemaTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolCallPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift`

已确认现状：

- `TerminalTaskModels.swift` 仍以 `foreground/background/interactive` 和 `runningForeground/runningBackground/waitingForPrompt` 为核心状态。
- `ClaudeService+BashTool.swift` 仍承担旧字段兼容归一化和单 `BashSession` 调度。
- `ACPClientService.swift` 仍按 `sessionId -> BashSession` 缓存 runtime。
- `ToolCall`、`ToolCallBubbleView`、`ToolCallDetailContentView` 已依赖旧 terminal metadata 和旧状态文本。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/PtyProcessController.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalTaskRuntime.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalTranscriptStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/BashToolOperationRouter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalRuntimeRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TerminalExecutionOutcome.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/PtyProcessControllerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalTaskRuntimeTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalTranscriptStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolOperationRouterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolExecutionResultTerminalTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TerminalTaskModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+BashTool.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolCallRecord.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ToolCallRowPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolSchemaTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolCallPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift`

### 删除文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashSession.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+BashSession.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashTaskEventReducer.swift`

### 视情况删除或收缩文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashCommandClassifier.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashPromptAnalyzer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashTaskRegistry.swift`

## 3. 关键架构决策

### 3.1 runtime 与 tool router 分层

`TerminalTaskRuntime` 只负责真实任务生命周期，不直接理解 tool schema；`BashToolOperationRouter` 负责把 `MessageResponse.Content.Input` 转成 runtime 调用。这样可以先稳定 runtime，再稳定工具接入。

### 3.2 每个任务都是一次性 PTY 会话

不再维护“按 session 复用一个 shell”的对象池。一次 `start` 创建一个 PTY 任务，后续所有控制都基于这个任务对象进行。

### 3.3 attached / detached 只是等待策略，不是 transport 差异

attached 和 detached 都使用同一个 PTY 控制器与 transcript 存储。差别只在调用何时返回，而不是创建不同类型的任务。

### 3.4 UI 只消费新 terminal metadata

`ToolCall` 的 terminal 字段要升级为能表达新 execution mode、completion reason、PID、transcript path、last output snippet。UI 不再推导旧 `runningForeground` / `waitingForPrompt` 文案。

### 3.5 先保留 prompt analyzer，后决定是否收缩

`BashPromptAnalyzer` 不是 runtime 底座，它只是输出解释器。第一阶段允许继续复用，但必须运行在新 transcript / output 之上，而不是继续依赖 `BashSession` 观察模型。

## 4. 任务拆解

### Task 1: 重写 terminal 模型为 PTY 语义

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TerminalExecutionOutcome.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TerminalTaskModels.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolExecutionResultTerminalTests.swift`

**Step 1: Write the failing test**

新增测试锁定以下契约：

- `TerminalExecutionMode` 只支持 `attached` / `detached`
- `TerminalTaskStatus` 只支持 `launching` / `running` / `waitingForInput` / `completed` / `failed` / `interrupted` / `timedOut` / `terminated`
- `TerminalExecutionOutcome` 能表达 `exitCode`、`terminationSignal`、`completionReason`、`transcriptPath`

```swift
@Test func terminalTaskStatusUsesPtyLifecycleStates() {
    #expect(TerminalTaskStatus(rawValue: "running") == .running)
    #expect(TerminalTaskStatus(rawValue: "runningForeground") == nil)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ToolExecutionResultTerminalTests
```

Expected: FAIL，因为现有 terminal 模型仍是旧状态集。

**Step 3: Write minimal implementation**

最小实现：

- 在 `TerminalTaskModels.swift` 删除旧 execution mode / status 定义
- 新增 `TerminalCompletionReason` 和 `TerminalExecutionOutcome`
- 调整 `TerminalTaskSnapshot` 字段以支持 `pid`、`processGroupID`、`transcriptPath`

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/TerminalTaskModels.swift agentGui/Models/TerminalExecutionOutcome.swift agentGuiTests/ToolExecutionResultTerminalTests.swift
git commit -m "refactor: redefine terminal task models for pty runtime"
```

### Task 2: 先做 transcript store，锁定输出持久化契约

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalTranscriptStore.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalTranscriptStoreTests.swift`

**Step 1: Write the failing test**

锁定以下行为：

- 创建任务 transcript 后可 append 输出
- 可读取最近 `N` 行输出
- 可返回 transcript 文件路径
- 结束任务后 transcript 仍可查询

```swift
@Test func transcriptStoreReturnsLatestLines() throws {
    let store = TerminalTranscriptStore(baseDirectory: FileManager.default.temporaryDirectory)
    let taskId = "task-1"

    try store.createTranscript(taskId: taskId)
    try store.append("one\ntwo\nthree\n", to: taskId)

    let tail = try store.readTail(taskId: taskId, lineCount: 2)
    #expect(tail == "two\nthree")
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/TerminalTranscriptStoreTests
```

Expected: FAIL because the store does not exist.

**Step 3: Write minimal implementation**

- 基于 `FileManager` 创建每任务 transcript 文件
- 提供 `createTranscript`、`append`、`readTail`、`transcriptURL`
- 先做串行安全实现，不做复杂 offset cursor

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Terminal/TerminalTranscriptStore.swift agentGuiTests/TerminalTranscriptStoreTests.swift
git commit -m "feat: add terminal transcript store"
```

### Task 3: 建立最小 PTY 控制器

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/PtyProcessController.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/PtyProcessControllerTests.swift`

**Step 1: Write the failing test**

锁定以下行为：

- 能启动 `zsh -lc 'echo hello'`
- 能读到 PTY 输出
- 能拿到 PID
- 能等到进程退出并产出 `exitCode`

```swift
@Test func ptyControllerCapturesOutputAndExitCode() async throws {
    let controller = try PtyProcessController(
        command: "echo hello",
        shell: "/bin/zsh",
        workingDirectory: nil,
        environment: ProcessInfo.processInfo.environment
    )

    let result = try await controller.runUntilExit()
    #expect(result.exitCode == 0)
    #expect(result.output.contains("hello"))
    #expect(result.pid > 0)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/PtyProcessControllerTests
```

Expected: FAIL because the PTY controller does not exist.

**Step 3: Write minimal implementation**

- 用 Darwin PTY API 创建 master/slave
- `fork` + `exec` 启动 `/bin/zsh -lc <command>`
- 读取 master fd 输出到内存
- 在退出后返回最小结果对象

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Terminal/PtyProcessController.swift agentGuiTests/PtyProcessControllerTests.swift
git commit -m "feat: add pty process controller"
```

### Task 4: 增加 PTY 控制器输入与信号能力

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/PtyProcessController.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/PtyProcessControllerTests.swift`

**Step 1: Write the failing test**

补充以下测试：

- `read name; echo hi $name` 可通过 `sendInput("Ada\n")` 完成
- 长任务可通过 `interrupt()` 收到 `SIGINT`
- `terminate(force: false)` 能结束 detached 任务

```swift
@Test func ptyControllerAcceptsInput() async throws {
    let controller = try PtyProcessController(command: "read name; echo hi $name")
    try await controller.start()
    try await controller.sendInput("Ada\n")

    let result = try await controller.waitForExit()
    #expect(result.output.contains("hi Ada"))
}
```

**Step 2: Run test to verify it fails**

Run the same `PtyProcessControllerTests` command.

Expected: FAIL because input and signal APIs are not implemented.

**Step 3: Write minimal implementation**

- 给控制器增加 `start()`、`sendInput(_:)`、`interrupt()`、`terminate(force:)`、`waitForExit()`
- 用进程组发送信号，避免只打到 shell 父进程

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Terminal/PtyProcessController.swift agentGuiTests/PtyProcessControllerTests.swift
git commit -m "feat: add pty input and signal control"
```

### Task 5: 组装 terminal task runtime

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalTaskRuntime.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalRuntimeRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashTaskRegistry.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalTaskRuntimeTests.swift`

**Step 1: Write the failing test**

锁定以下行为：

- `startAttached` 会创建任务快照并在退出后生成 outcome
- `startDetached` 会返回运行中任务，随后可查状态
- `sendInput(taskId:)` 只允许目标任务存在且未结束
- `status(taskId:)` / `readOutput(taskId:)` / `cleanup(taskId:)` 都基于 `task_id`

```swift
@Test func runtimeRoutesControlByTaskId() async throws {
    let runtime = TerminalTaskRuntime.makeForTests()
    let task = try await runtime.startDetached(command: "python -m http.server", taskId: "srv")

    let status = try await runtime.status(taskId: task.id)
    #expect(status.id == "srv")

    await #expect(throws: TerminalRuntimeError.taskNotFound) {
        _ = try await runtime.status(taskId: "missing")
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/TerminalTaskRuntimeTests
```

Expected: FAIL because the runtime does not exist.

**Step 3: Write minimal implementation**

- runtime 组合 `PtyProcessController` + `TerminalTranscriptStore` + registry
- 提供 `start`, `sendInput`, `interrupt`, `terminate`, `status`, `readOutput`, `cleanup`
- 通过 actor 管理 `taskId -> controller` 的运行态映射

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Terminal/TerminalTaskRuntime.swift agentGui/Services/Terminal/TerminalRuntimeRegistry.swift agentGui/Services/BashTaskRegistry.swift agentGuiTests/TerminalTaskRuntimeTests.swift
git commit -m "feat: add managed terminal task runtime"
```

### Task 6: 重写 bash tool schema 与 router

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/BashToolOperationRouter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+BashTool.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolSchemaTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolOperationRouterTests.swift`

**Step 1: Write the failing test**

锁定以下行为：

- `start` 必须要求 `task_id` 和 `command`
- 旧 `background` / `interactive` / `interrupt` 字段不再被接受
- `operation` 只允许 `start` / `send_input` / `interrupt` / `terminate` / `status` / `read_output` / `cleanup`

```swift
@Test func legacyBashFlagsAreRejected() throws {
    let input = MessageResponse.Content.Input([
        "command": .string("echo hello"),
        "background": .bool(true)
    ])

    #expect(throws: BashToolRequestError.self) {
        _ = try BashToolOperationRouter().parse(input: input)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/BashToolSchemaTests \
  -only-testing:agentGuiTests/BashToolOperationRouterTests
```

Expected: FAIL because the old request normalization still accepts legacy fields.

**Step 3: Write minimal implementation**

- 用新 router 解析请求
- 删除旧兼容归一化逻辑
- 把 `ClaudeService+BashTool.swift` 收敛成 `parse -> runtime call -> map result`

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Terminal/BashToolOperationRouter.swift agentGui/Services/ClaudeService+BashTool.swift agentGuiTests/BashToolSchemaTests.swift agentGuiTests/BashToolOperationRouterTests.swift
git commit -m "refactor: route bash tool through pty operations"
```

### Task 7: 切换 tool dispatch 与 tool call metadata

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolCallRecord.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolExecutionResultTerminalTests.swift`

**Step 1: Write the failing test**

锁定以下行为：

- terminal result success/failure 由 `TerminalExecutionOutcome` 判定
- `ToolCall` 能记录 `terminalTaskId`、`terminalTaskStatus`、`terminalExecutionMode`、`terminalPromptSummary`、`terminalTranscriptPath`
- 非零退出码不再被误判为 success

```swift
@Test func terminalOutcomeMapsNonZeroExitToFailure() {
    let outcome = TerminalExecutionOutcome(
        taskId: "task-1",
        exitCode: 2,
        terminationSignal: nil,
        completionReason: .exitedNonZero,
        startedAt: Date(),
        endedAt: Date(),
        transcriptPath: "/tmp/task-1.log",
        finalOutputSnippet: "boom"
    )

    let result = ToolExecutionResult.fromTerminalOutcome(outcome)
    #expect(result.toolCallStatus == .failed)
}
```

**Step 2: Run test to verify it fails**

Run the same `ToolExecutionResultTerminalTests` command.

Expected: FAIL because terminal result mapping is still text-based.

**Step 3: Write minimal implementation**

- 新增 `ToolExecutionResult.fromTerminalOutcome(_:)`
- `ToolCall` 扩展新的 transcript / completion metadata 字段
- `ClaudeService+ToolDispatch.swift` 使用新 runtime 而不是 `getBashSession`

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+ToolDispatch.swift agentGui/Services/ClaudeService+ToolCallRecord.swift agentGui/Models/ToolCall.swift agentGuiTests/ToolExecutionResultTerminalTests.swift
git commit -m "refactor: map bash tool results from terminal outcomes"
```

### Task 8: 重写 agent loop 观察链路

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift`

**Step 1: Write the failing test**

锁定以下行为：

- 不再创建或缓存 `BashSession`
- agent loop 在 bash tool 调用期间观察的是 terminal runtime snapshot
- 结束态由 runtime 提供，不再使用 `BashTaskEventReducer`

```swift
@Test func agentLoopUsesTerminalRuntimeInsteadOfBashSession() async throws {
    let builder = makeCoordinatorBuilderForTests()
    let dependencies = builder.build().dependenciesForTests

    #expect(dependencies.normalizeBashRequest != nil)
    #expect(dependencies.startForegroundBashObservation != nil)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopToolExecutionCoordinatorTests
```

Expected: FAIL because the builder still depends on `BashSession` observation.

**Step 3: Write minimal implementation**

- 用 `TerminalTaskRuntime` 暴露的 snapshot / output 读取替代旧观察逻辑
- `ACPClientService` 改为缓存 runtime 或 runtime registry，而不是 `bashSessions`
- 删除 `BashTaskEventReducer` 的调用点

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift agentGui/Services/ACPClientService.swift agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift
git commit -m "refactor: observe bash tools through terminal runtime"
```

### Task 9: 更新 tool call UI 展示

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ToolCallRowPresentation.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolCallPresentationTests.swift`

**Step 1: Write the failing test**

锁定以下行为：

- execution mode 显示 `attached` / `detached`
- 终态 badge 显示 `completed` / `failed` / `timedOut` / `terminated`
- detail view 可展示 transcript 路径和 completion reason

```swift
@Test func bashToolPresentationShowsDetachedMode() {
    let toolCall = ToolCall(toolCallId: "1", kind: .bash)
    toolCall.terminalExecutionMode = "detached"
    toolCall.terminalTaskStatus = "running"

    let presentation = ToolCallRowPresentation(toolCall: toolCall)
    #expect(presentation.badgeText?.contains("detached") == true)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/BashToolCallPresentationTests
```

Expected: FAIL because the UI still maps old execution modes and statuses.

**Step 3: Write minimal implementation**

- 替换旧 mode/status 文案映射
- detail view 增加 transcript / completion reason 字段
- 删除依赖旧 prompt 状态的条件分支

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/ToolCallBubbleView.swift agentGui/Views/ToolCallDetailContentView.swift agentGui/ViewModels/ToolCallRowPresentation.swift agentGuiTests/BashToolCallPresentationTests.swift
git commit -m "refactor: update bash tool ui for pty tasks"
```

### Task 10: 删除旧 runtime 并做集成回归

**Files:**
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashSession.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+BashSession.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashTaskEventReducer.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashCommandClassifier.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashPromptAnalyzer.swift`

**Step 1: Write the failing test**

补充集成级场景：

- `echo hello` attached 成功
- `read name; echo hi $name` 多轮输入成功
- `python -m http.server` detached 可查状态并终止
- `false` 返回 failed

```swift
@Test func detachedServerCanBeStoppedByTaskId() async throws {
    let runtime = TerminalTaskRuntime.makeForTests()
    _ = try await runtime.startDetached(command: "python -m http.server 8123", taskId: "srv")

    try await runtime.terminate(taskId: "srv", force: false)
    let status = try await runtime.status(taskId: "srv")
    #expect(status.status.isTerminal)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/PtyProcessControllerTests \
  -only-testing:agentGuiTests/TerminalTaskRuntimeTests \
  -only-testing:agentGuiTests/BashToolSchemaTests \
  -only-testing:agentGuiTests/BashToolCallPresentationTests \
  -only-testing:agentGuiTests/AgentLoopToolExecutionCoordinatorTests
```

Expected: FAIL until all old runtime references are removed.

**Step 3: Write minimal implementation**

- 删除旧 runtime 文件与残余引用
- 收缩 classifier / analyzer 到仍有价值的输出解释职责
- 清理项目引用，确保不再编译旧 `BashSession`

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add -A
git commit -m "refactor: remove legacy bash runtime"
```

### Task 11: 运行仓库级冒烟验证

**Files:**
- Modify if needed based on failures found in prior tasks

**Step 1: Run focused terminal test suites**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/PtyProcessControllerTests \
  -only-testing:agentGuiTests/TerminalTaskRuntimeTests \
  -only-testing:agentGuiTests/TerminalTranscriptStoreTests \
  -only-testing:agentGuiTests/BashToolOperationRouterTests \
  -only-testing:agentGuiTests/ToolExecutionResultTerminalTests
```

Expected: PASS.

**Step 2: Run affected integration suites**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopToolExecutionCoordinatorTests \
  -only-testing:agentGuiTests/BashToolSchemaTests \
  -only-testing:agentGuiTests/BashToolCallPresentationTests
```

Expected: PASS.

**Step 3: Run smoke task**

Run: VS Code task `Quality Smoke`

Expected: PASS. If it fails, capture whether failure is terminal-runtime-related or pre-existing.

**Step 4: Commit final stabilization**

```bash
git add -A
git commit -m "test: validate pty bash runtime rewrite"
```

## 5. 实施后检查清单

- `bash` 工具 schema 只接受新 PTY 协议字段。
- 代码库中不再存在 `BashSession` 的构造和缓存调用。
- `ToolExecutionResult` 不再依赖 `Error:` 前缀判断 bash success/failure。
- `ToolCall` 和 UI 能展示新 mode/status/completion reason/transcript 路径。
- detached 任务可按 `task_id` 查询、读输出、终止、清理。
- 仓库级 smoke 至少跑过一次，并记录结果。

## 6. 风险提示

- Darwin PTY API 容易引入资源泄漏，`master fd`、`slave fd`、`waitpid` 和任务取消清理必须在第一轮实现就写完整测试。
- detached 任务如果只终止 shell 而不终止进程组，会留下孤儿子进程；信号发送必须面向 `processGroupID`。
- UI 依赖旧状态文本较多，若不在同一阶段迁移，工具气泡会显示空 badge 或错误摘要。
- 现有 `Quality Smoke` 最近一次在上下文中为失败状态，计划执行时要区分新回归和历史失败。

## 7. 建议执行顺序

严格按 Task 1 到 Task 11 顺序执行，不要并行展开：

1. 先锁数据模型。
2. 再锁输出存储。
3. 再锁 PTY controller。
4. 然后拼 runtime。
5. 最后接 bash tool、agent loop、UI 和删除旧实现。

原因很简单：没有稳定的 PTY 底座，后面的 router、UI 和测试都会反复返工。
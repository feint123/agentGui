# Agent Loop Execution Guard Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Prevent the main agent loop from reporting task completion when the user asked to execute commands or run verification but the model never invoked any execution-capable tool.

**Architecture:** Add a small execution-requirement layer that classifies whether the current user turn requires real execution, track whether the loop produced execution evidence, and block or redirect a plain `end_turn` when that evidence is missing. Keep the first iteration narrowly scoped to the main agent path and existing tools (`bash`, `run_subagent` with `executor`, and `start_workflow`) so the fix is measurable and low-risk.

**Tech Stack:** Swift 6, Swift Testing, SwiftAnthropic, SwiftData, existing `ClaudeService` agentic loop and tool-call persistence.

---

## 1. 实施原则

- 先补回归测试，再做最小实现；不要先改提示词赌模型行为。
- 第一版只解决“执行命令/构建/测试”这类明确执行型请求，不顺手扩展到搜索、编辑、记忆写入等其他任务类型。
- 以“有执行证据才能完成”为准，而不是继续依赖模型自述或 `verify_completion` 文本。
- 尽量复用现有 `ToolCall`、`run_subagent`、`start_workflow` 和 `Bash` 轨迹，不引入新的持久化模型。
- UI 上的 `.completed` 与“真实完成”语义先最小修正；不要在本计划里重构整套消息状态机。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionRequirement.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionRequirementTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopExecutionGuardTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ExecutionPlan.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolCallRecord.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopPhase.swift`

## 3. 关键设计决策

### 3.1 什么叫“执行证据”

V1 只把下列行为算作 execution evidence：

- 直接调用 `bash`
- 调用 `run_subagent` 且 `agent_name == "executor"`
- 调用 `start_workflow`，且 workflow 最终完成返回成功结果

下列行为 **不算** execution evidence：

- 纯文本总结
- `verify_completion` 自报
- `create_execution_plan`
- `update_todo_list`
- `read_skill`、文本编辑、web 搜索

### 3.2 什么叫“要求执行”

V1 用轻量规则分类，仅覆盖本 bug 相关意图：

- 用户要求“执行命令 / run command / 执行 bash / 在终端运行 / build / test / compile / xcodebuild / swift test / npm test / pytest”等
- 用户明确要求“帮我跑一下”“执行一下”“验证一下构建/测试”

下列情况暂不触发强制执行：

- 单纯问“怎么运行”
- 分析原因、解释代码、生成计划
- 仅修改代码但未要求实际跑命令

### 3.3 Guard 的行为

当一个 turn 被分类为 `requiresExecution == true`，且本次 loop 在 `end_turn` 前没有任何 execution evidence 时：

- 不接受这次 `end_turn` 作为成功完成
- 注入一条纠正型 user message，明确要求模型必须调用 `bash` / `executor` / `start_workflow`
- 将 loop 重新切回 `.executing`
- 最多触发 1 次 guard retry，避免死循环

若第二次仍然 `end_turn` 且没有证据：

- 标记 loop 失败或“未完成”，并把原因写入 message 文本，不能再展示成正常完成

### 3.4 `verify_completion` 的角色

`verify_completion` 在 V1 继续保留，但不再被视为完成真实性来源。它只能总结已经发生过的验证，不能代替实际执行。

建议最小强化：当当前 session 尚无 execution evidence，而 `verified` 数组声称“build succeeded”/“tests passed”时，返回带 warning 的记录文本，提醒调用方验证声明无执行证据支撑。

## 4. 任务拆解

### Task 1: 固化“工具未执行却 end_turn”的回归测试

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopExecutionGuardTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopPhase.swift`

**Step 1: 写失败测试，重现当前 bug**

在新测试文件中构建一个最小 fake `AnthropicService`，让第一轮直接返回：

- assistant 文本：例如 “已执行完成”
- `stop_reason = "end_turn"`
- 无 `tool_use`

然后给 loop 一个明确要求执行命令的用户消息，例如：

```swift
MessageParameter.Message(
    role: .user,
    content: .text("请执行 xcodebuild test 并告诉我结果")
)
```

断言当前修复后的行为应为：

- 不把这轮视为成功完成
- loop 会注入一次纠正消息并继续，或者最终写出明确失败说明
- 绝不能静默当作完成

测试骨架：

```swift
@MainActor
struct AgentLoopExecutionGuardTests {

    @Test func endTurnWithoutExecutionEvidenceDoesNotCompleteExecutionTask() async throws {
        let service = FakeAnthropicService(script: [
            .endTurnText("已执行完成"),
            .endTurnText("还是不调用工具")
        ])

        let harness = try TestLoopHarness.make()
        let result = try await harness.run(
            userText: "请执行 xcodebuild test 并告诉我结果",
            service: service
        )

        #expect(result.finalText.contains("未执行"))
        #expect(result.executedToolNames.isEmpty)
        #expect(result.messageStatus != .completed)
    }
}
```

**Step 2: 跑 focused test，确认现状失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopExecutionGuardTests
```

Expected: FAIL，因为当前实现会接受 `end_turn` 并结束。

**Step 3: 为测试补最小 harness**

如果直接 fake `AnthropicService` 成本过高，就在测试文件内增加一个超小测试桩与 helper：

- `FakeAnthropicService`
- `TestLoopHarness.make()`
- 只支持本测试需要的 `streamMessage`、`countTokens` 和最少结构

不要把这个测试 helper 先抽成生产代码；除非两个以上测试文件需要复用。

**Step 4: 再跑 focused test**

Run 同 Step 2。

Expected: 仍 FAIL，但已经进入可实现状态，而不是编译不过。

**Step 5: Commit**

```bash
git add agentGuiTests/AgentLoopExecutionGuardTests.swift
git commit -m "test: capture agent loop execution guard regression"
```

### Task 2: 新增执行需求分类器

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionRequirement.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionRequirementTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`

**Step 1: 写失败测试，固定分类边界**

新增测试覆盖：

- “请执行 xcodebuild test” => `requiresExecution == true`
- “帮我运行 npm test 看报错” => `requiresExecution == true`
- “告诉我怎么运行 xcodebuild test” => `requiresExecution == false`
- “分析一下为什么测试失败” => `requiresExecution == false`
- “帮我修改代码，不用运行测试” => `requiresExecution == false`

测试示例：

```swift
@Test func classifierRecognizesExplicitCommandExecutionRequests() {
    #expect(ExecutionRequirement.classify("请执行 xcodebuild test").requiresExecution)
    #expect(ExecutionRequirement.classify("帮我运行 npm test 看报错").requiresExecution)
    #expect(!ExecutionRequirement.classify("告诉我怎么运行 xcodebuild test").requiresExecution)
}
```

**Step 2: 跑 focused test，确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ExecutionRequirementTests
```

Expected: FAIL，因为分类器还不存在。

**Step 3: 写最小实现**

在 `ExecutionRequirement.swift` 中实现：

```swift
struct ExecutionRequirement: Equatable {
    let requiresExecution: Bool
    let reason: String?

    static func classify(_ text: String) -> ExecutionRequirement {
        let normalized = text.lowercased()
        let executionPhrases = ["执行", "运行", "run", "build", "test", "xcodebuild", "swift test", "pytest", "npm test"]
        let advisoryPhrases = ["怎么", "how", "如何", "告诉我怎么", "不用运行"]

        let wantsExecution = executionPhrases.contains { normalized.contains($0) }
        let onlyAskingHow = advisoryPhrases.contains { normalized.contains($0) }

        return ExecutionRequirement(
            requiresExecution: wantsExecution && !onlyAskingHow,
            reason: wantsExecution && !onlyAskingHow ? "explicit_execution_request" : nil
        )
    }
}
```

不要过度 NLP 化。第一版规则化足够，后续再演进。

**Step 4: 在发送主请求前把 requirement 传入 loop**

在 `ACPClientService.swift` 中找到主 `runAgenticLoop(...)` 调用，基于最新用户消息文本计算 `ExecutionRequirement`，并作为新参数传入 `ClaudeService+AgenticLoop.swift`。

**Step 5: 跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 6: Commit**

```bash
git add agentGui/Models/ExecutionRequirement.swift agentGuiTests/ExecutionRequirementTests.swift agentGui/Services/ACPClientService.swift
git commit -m "feat: classify turns that require real execution"
```

### Task 3: 在 core loop 中跟踪执行证据并阻断假完成

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopPhase.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolCallRecord.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopExecutionGuardTests.swift`

**Step 1: 写或扩展失败测试，覆盖三类 evidence**

新增或补充以下测试：

- 调用 `bash` 后允许 `end_turn`
- 调用 `run_subagent(executor)` 后允许 `end_turn`
- 调用 `start_workflow` 后允许 `end_turn`
- 只调用 `verify_completion` 不允许 `end_turn`

示例：

```swift
@Test func bashToolUseSatisfiesExecutionGuard() async throws {
    let service = FakeAnthropicService(script: [
        .toolUse(name: "bash", inputJSON: ["command": "xcodebuild test"]),
        .endTurnText("测试已运行，以下是结果")
    ])

    let harness = try TestLoopHarness.make()
    let result = try await harness.run(
        userText: "请执行 xcodebuild test 并告诉我结果",
        service: service
    )

    #expect(result.executedToolNames.contains("bash"))
    #expect(result.messageStatus == .completed)
}
```

**Step 2: 跑 focused tests，确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopExecutionGuardTests
```

Expected: FAIL。

**Step 3: 在 loop 中增加运行时状态**

在 `ClaudeService+AgenticLoop.swift` 中新增最小运行时字段，例如：

```swift
var executionEvidence: Set<String> = []
var executionGuardRetryCount = 0
```

当 pending tool 执行成功进入分发时：

- `pending.name == "bash"` -> 记 evidence
- `pending.name == "run_subagent" && agent_name == "executor"` -> 记 evidence
- `pending.name == "start_workflow" && result.isError == false` -> 记 evidence

这里记录“调用发生过”即可，不要求命令一定 exit 0；失败的执行同样是执行证据。

**Step 4: 在 `end_turn` 进入 `.finalizing` 前插入 guard**

新增类似逻辑：

```swift
if executionRequirement.requiresExecution && executionEvidence.isEmpty {
    if executionGuardRetryCount == 0 {
        messages.append(.init(role: .user, content: .text(
            "You must actually execute the requested command using bash, the executor subagent, or start_workflow. Do not claim completion without a tool call."
        )))
        executionGuardRetryCount += 1
        loopCtx.phase = .executing
        continue
    } else {
        loopCtx.phase = .failed
        loopCtx.terminationReason = "Execution required but no execution-capable tool was used before end_turn"
    }
}
```

不要把这段藏进 reflection；这是一个同步 contract guard，不是质量反思。

**Step 5: 调整最终消息状态语义**

确保因 execution guard 失败而退出时：

- 不会被外层视作正常完成
- 文本里有明确说明，如 “任务需要执行命令，但模型未调用执行工具”

必要时在 `ACPClientService.swift` 外层 catch/状态设置里增加分支，而不是一律 `.completed`。

**Step 6: 跑 tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopExecutionGuardTests -only-testing:agentGuiTests/ExecutionRequirementTests
```

Expected: PASS。

**Step 7: Commit**

```bash
git add agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Models/AgentLoopPhase.swift agentGui/Services/ClaudeService+ToolCallRecord.swift agentGui/Services/ACPClientService.swift agentGuiTests/AgentLoopExecutionGuardTests.swift
git commit -m "fix: block agent loop completion without execution evidence"
```

### Task 4: 强化 `verify_completion`，避免自报结果误导 UI

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ExecutionPlan.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopExecutionGuardTests.swift`

**Step 1: 写失败测试，覆盖“无执行证据却宣称已验证”**

新增测试：

- session 内没有任何 execution evidence
- 调用 `verify_completion`，`verified = ["xcodebuild test passed"]`
- 返回值应包含 warning 或 note，表明这只是声明，没有执行证据

示例：

```swift
@Test func verifyCompletionWarnsWhenExecutionClaimsHaveNoEvidence() throws {
    let service = ClaudeService()
    let output = service.executeVerifyCompletion(
        input: makeVerifyInput(
            verified: ["xcodebuild test passed"],
            notVerified: []
        ),
        sessionId: "session-1"
    )

    #expect(output.contains("no execution evidence") || output.contains("无执行证据"))
}
```

**Step 2: 跑 focused test，确认失败**

Run 同上一个 focused suite。

**Step 3: 写最小实现**

为 `ClaudeService` 增加一个运行时 session 级 evidence 存储，或从已有 `ToolCall` 轨迹读取。如果成本较低，优先采用内存态：

- 每次 `bash` / `executor` / `start_workflow` 调用成功进入分派时，记录到 `sessionExecutionEvidence[sessionId]`
- `executeVerifyCompletion` 读取该标记

当 evidence 为空，且 `verified` 中包含 `build succeeded` / `tests passed` / `command ran successfully` 等短语时，输出 warning。

不要在这里拒绝调用；V1 只做显式警示。

**Step 4: 跑 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopExecutionGuardTests
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+ExecutionPlan.swift agentGuiTests/AgentLoopExecutionGuardTests.swift
git commit -m "fix: warn when verification claims lack execution evidence"
```

### Task 5: 回归验证与人工验收

**Files:**
- Modify if needed: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-11-agent-loop-execution-guard-implementation.md`

**Step 1: 跑相关测试集合**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopExecutionGuardTests \
  -only-testing:agentGuiTests/ExecutionRequirementTests \
  -only-testing:agentGuiTests/BashToolSchemaTests \
  -only-testing:agentGuiTests/BashToolCallPresentationTests
```

Expected: PASS。

**Step 2: 做一次手工 smoke test**

在 app 中用下面两类提示词各验证一次：

- 应触发 guard：`请执行 xcodebuild test 并告诉我结果`
- 不应触发 guard：`告诉我怎么运行 xcodebuild test`

观察点：

- 第一类请求如果模型第一次口头声称完成，系统会追打一轮强制工具提示
- 第二类请求仍可直接文本回答，不会被误伤
- 只有实际发生 `bash` / `executor` / `start_workflow` 后，消息才会走正常完成路径

**Step 3: 记录剩余风险**

在计划末尾补一段实施备注：

- V1 分类器为规则法，可能漏掉少量同义表达
- `start_workflow` 只按成功返回记 evidence，没有深挖 workflow 内部具体执行轨迹
- 还没有把“已完成”与“已验证完成”拆成独立 UI 状态

**Step 4: Commit**

```bash
git add docs/plans/2026-03-11-agent-loop-execution-guard-implementation.md
git commit -m "docs: add execution guard implementation plan"
```

## 5. 完成定义

满足以下条件才算完成：

- 明确执行型请求在没有工具调用证据时不能再静默完成
- 规则分类不会误伤“解释怎么做”类问题
- `bash` / `executor` / `start_workflow` 至少一种路径可满足 guard
- `verify_completion` 不再被误读为真实性来源
- 新增回归测试稳定通过

## 6. 非目标

- 不在本计划里重构所有 `Message.status` 枚举与 UI 文案
- 不在本计划里引入通用自然语言 intent 引擎
- 不在本计划里让每一种工具都接入 evidence guard
- 不在本计划里修复子代理内部所有可能的“口头完成”问题，除非它们会逃逸到主代理完成态

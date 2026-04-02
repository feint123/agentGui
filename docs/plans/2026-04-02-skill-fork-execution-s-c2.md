# S-C2: SkillInvocationTool Fork Mode Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 当 skill 的 `executionContext == .fork` 时，`skill_invoke` 工具不再将 prompt 展开到当前对话，而是在独立子代理 session 中执行，并将子代理的最终文本输出作为工具结果返回给主 agent。

**Architecture:** 在 `ClaudeService+ToolDispatch.swift` 的 `skill_invoke` 分支中增加 fork 路由判断：先用 `SkillService` 查找 skill，若 `executionContext == .fork` 则调用新增的 `ClaudeService+SkillFork.swift` 扩展（复用现有 `runSubagentLoop` 架构）；否则走现有 inline 路径。fork 执行时依据 `skill.allowedTools` 构造受限工具集，`skill.model` 和 `skill.effort` 覆盖模型。

**Tech Stack:** Swift 6, SwiftUI, SwiftAnthropic，现有 `runSubagentLoop` / `AgentLoopRunRequest` / `AgentLoopRuntime` / `WorkflowRoleDefinition` / `ToolGrant` / `DefaultToolsetResolver`

**依赖前置条件（已完成）:**
- S-A1: `Skill.executionContext: SkillExecutionContext`（`.fork` case）已在 `Skill.swift` 中存在 ✅
- S-C1: `SkillInvocationProcessor`（inline 路径）已在 `ClaudeService+ToolDispatch.swift` 中存在 ✅
- `runSubagentLoop` / `runCoreAgentLoop` 已在 `ClaudeService+Subagent.swift` 中存在 ✅

---

## 参考：Claude Code 对标

| Claude Code | agentGui 对应 |
|---|---|
| `executeForkedSkill()` (SkillTool.ts) | `ClaudeService+SkillFork.swift` → `executeForkedSkillInvoke()` |
| `prepareForkedCommandContext()` (forkedAgent.ts) | `buildForkedSkillRequest()` 内联实现 |
| `createSubagentContext()` | `runSubagentLoop()` 已有等价实现 |
| `command.allowedTools → alwaysAllowRules` | `skill.allowedTools → ToolGrant` 列表 |
| `runAgent()` | `runCoreAgentLoop()` |
| `extractResultText()` | `result.text` 直接取自 `runCoreAgentLoop` |

Claude Code 特定于 ANT 内部的逻辑（遥测、`logEvent`、`feature()`、`wasDiscovered`）**不迁移**。

---

## 关键文件

| 路径 | 变更类型 |
|---|---|
| `agentGui/Services/ClaudeService/ClaudeService+SkillFork.swift` | **新建** — fork 执行核心逻辑 |
| `agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift` | **修改** — `skill_invoke` 分支增加 fork 路由 |
| `agentGuiTests/SkillForkExecutionTests.swift` | **新建** — fork 执行单元测试 |

不修改：
- `Skill.swift` — `executionContext` 字段已存在
- `SkillInvocationProcessor.swift` — inline 路径保持不变
- `ClaudeService+Subagent.swift` — `runSubagentLoop` 保持不变，被复用

---

## Task 1: 新建 `SkillForkExecutionTests.swift` 并写失败测试

**目的：** TDD 驱动——先写测试，编译失败，再实现。

**文件：** 新建 `agentGuiTests/SkillForkExecutionTests.swift`

**Step 1: 写出测试骨架（此时编译失败是预期的）**

```swift
// agentGuiTests/SkillForkExecutionTests.swift
import XCTest
import SwiftAnthropic
@testable import agentGui

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Stub subagent loop runner
// ─────────────────────────────────────────────────────────────────────────────

/// 测试用 stub：不执行真实 API，直接返回预设文本和轮次。
final class StubSkillSubagentRunner: SkillSubagentRunning, @unchecked Sendable {
    var capturedTask: String?
    var capturedAllowedTools: [String]?
    var capturedModelId: String?
    var returnText: String = "stub result"

    func runSkillSubagent(
        task: String,
        allowedTools: [String],
        modelId: String
    ) async throws -> String {
        capturedTask = task
        capturedAllowedTools = allowedTools
        capturedModelId = modelId
        return returnText
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SkillForkExecutor unit tests
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class SkillForkExecutionTests: XCTestCase {

    // 辅助方法：构造带 fork context 的 skill
    private func makeForkSkill(
        directoryName: String = "code-review",
        allowedTools: [String] = [],
        model: String? = nil
    ) -> Skill {
        Skill.fixture(
            directoryName: directoryName,
            name: directoryName,
            executionContext: .fork,
            allowedTools: allowedTools,
            model: model
        )
    }

    // ── 1. 基础 fork 路径：传入 task 正确，返回子代理文本
    func test_fork_basic_returnsSubagentResult() async throws {
        let stub = StubSkillSubagentRunner()
        stub.returnText = "Review complete: 3 issues found"
        let executor = SkillForkExecutor(runner: stub, defaultModelId: "claude-opus-4-5")

        let skill = makeForkSkill()
        let result = try await executor.execute(
            skill: skill,
            processedContent: "Please review the code.",
            parentModelId: "claude-opus-4-5"
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("Review complete"))
        XCTAssertEqual(stub.capturedTask, "Please review the code.")
    }

    // ── 2. allowedTools 传递给 runner
    func test_fork_withAllowedTools_passesThemToRunner() async throws {
        let stub = StubSkillSubagentRunner()
        let executor = SkillForkExecutor(runner: stub, defaultModelId: "claude-haiku-4-5")

        let skill = makeForkSkill(allowedTools: ["bash", "str_replace_based_edit_tool"])
        _ = try await executor.execute(
            skill: skill,
            processedContent: "Run tests.",
            parentModelId: "claude-haiku-4-5"
        )

        XCTAssertEqual(stub.capturedAllowedTools, ["bash", "str_replace_based_edit_tool"])
    }

    // ── 3. skill.model 覆盖父 agent 模型
    func test_fork_modelOverride_usesSkillModel() async throws {
        let stub = StubSkillSubagentRunner()
        let executor = SkillForkExecutor(runner: stub, defaultModelId: "claude-opus-4-5")

        let skill = makeForkSkill(model: "claude-haiku-4-5")
        _ = try await executor.execute(
            skill: skill,
            processedContent: "Do something.",
            parentModelId: "claude-opus-4-5"
        )

        XCTAssertEqual(stub.capturedModelId, "claude-haiku-4-5")
    }

    // ── 4. 无 model override 时继承父 agent 模型
    func test_fork_noModelOverride_inheritsParentModel() async throws {
        let stub = StubSkillSubagentRunner()
        let executor = SkillForkExecutor(runner: stub, defaultModelId: "claude-opus-4-5")

        let skill = makeForkSkill()   // model = nil
        _ = try await executor.execute(
            skill: skill,
            processedContent: "Do something.",
            parentModelId: "claude-sonnet-4-5"
        )

        XCTAssertEqual(stub.capturedModelId, "claude-sonnet-4-5")
    }

    // ── 5. runner 抛出错误时，返回 isError=true 的 ToolExecutionResult
    func test_fork_runnerThrows_returnsErrorResult() async throws {
        struct RunnerError: Error {}
        final class ThrowingRunner: SkillSubagentRunning, @unchecked Sendable {
            func runSkillSubagent(task: String, allowedTools: [String], modelId: String) async throws -> String {
                throw RunnerError()
            }
        }
        let executor = SkillForkExecutor(runner: ThrowingRunner(), defaultModelId: "claude-opus-4-5")
        let skill = makeForkSkill()
        let result = try await executor.execute(
            skill: skill,
            processedContent: "Fail.",
            parentModelId: "claude-opus-4-5"
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("code-review"))
    }
}
```

**Step 2: 确认编译失败（`SkillForkExecutor`、`SkillSubagentRunning` 未定义）**

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | \
  grep -E "error:|SkillForkExecutor|SkillSubagentRunning" | head -20
```

预期：出现 `error: cannot find type 'SkillForkExecutor'`

**Step 3: Commit**

```bash
git add agentGuiTests/SkillForkExecutionTests.swift
git commit -m "test(S-C2): add failing SkillForkExecutor tests"
```

---

## Task 2: 新建 `ClaudeService+SkillFork.swift`

**目的：** 实现 `SkillSubagentRunning` 协议和 `SkillForkExecutor`，通过 Task 1 的测试。

**文件：** 新建 `agentGui/Services/ClaudeService/ClaudeService+SkillFork.swift`

**Step 1: 创建文件**

```swift
//
//  ClaudeService+SkillFork.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

// MARK: - SkillSubagentRunning Protocol

/// Fork skill 执行的子代理调用接口。
/// 抽象层让 SkillForkExecutor 在测试中可与 ClaudeService 解耦。
protocol SkillSubagentRunning: Sendable {
    /// 在独立子代理中执行 task，返回子代理的最终文本输出。
    /// - Parameters:
    ///   - task: 经过变量替换后的 skill prompt 全文（作为子代理的初始 user message）。
    ///   - allowedTools: 子代理可用的工具 ID 列表；空数组表示不限制。
    ///   - modelId: 子代理使用的模型 ID（已按 skill.model > parentModel 优先级解析）。
    func runSkillSubagent(
        task: String,
        allowedTools: [String],
        modelId: String
    ) async throws -> String
}

// MARK: - SkillForkExecutor

/// 封装 fork skill 的执行流程：内容传入 → 工具集构建 → 模型解析 → 子代理运行 → 结果封装。
///
/// 对应 Claude Code `executeForkedSkill()` (SkillTool.ts) 的 agentGui 移植。
/// 注意：不迁移遥测（logEvent）和 ANT-only 实验特性。
struct SkillForkExecutor {
    let runner: any SkillSubagentRunning
    let defaultModelId: String

    /// 执行 fork skill。
    /// - Parameters:
    ///   - skill: 已查找到的 Skill，`executionContext` 必须为 `.fork`。
    ///   - processedContent: 经过 SkillArgumentSubstitution 处理后的 skill 内容。
    ///   - parentModelId: 调用方（主 agent）当前模型 ID，当 skill 未指定 model 时继承。
    /// - Returns: 封装有子代理输出文本的 `ToolExecutionResult`；失败时 `isError = true`。
    func execute(
        skill: Skill,
        processedContent: String,
        parentModelId: String
    ) async throws -> ToolExecutionResult {
        // 解析实际使用的模型：skill.model > parentModelId
        let resolvedModelId = skill.model ?? parentModelId

        do {
            let resultText = try await runner.runSkillSubagent(
                task: processedContent,
                allowedTools: skill.allowedTools,
                modelId: resolvedModelId
            )
            let header = "[Skill fork result: \(skill.directoryName)]\n"
            return ToolExecutionResult(header + resultText)
        } catch {
            return .failure("Error executing forked skill '\(skill.directoryName)': \(error.localizedDescription)")
        }
    }
}

// MARK: - ClaudeService as SkillSubagentRunning

extension ClaudeService: SkillSubagentRunning {

    /// ClaudeService 的 SkillSubagentRunning 实现：构造子代理所需的完整参数，
    /// 复用 `runSubagentLoop` 路径（已有 subagent 执行基础设施）。
    ///
    /// - 工具集：若 `allowedTools` 非空，只开放列表内的工具；否则开放与主代理相同的工具集。
    /// - 该方法在 `ClaudeService+ToolDispatch.swift` 执行 skill_invoke 时通过 `currentRunContext`
    ///   获取 service/modelId/settings/sessionId/modelContext。
    func runSkillSubagent(
        task: String,
        allowedTools: [String],
        modelId: String
    ) async throws -> String {
        guard let ctx = currentSkillForkContext else {
            throw SkillForkError.missingRunContext
        }

        let toolGrants = buildToolGrants(
            from: allowedTools,
            context: .subagent
        )

        let definition = WorkflowRoleDefinition(
            name: "skill-fork",
            description: "Fork execution agent for skill invocation",
            systemPrompt: "",
            toolGrants: toolGrants,
            maxTurnsPerActivation: 20
        )

        // 创建一个占位的 ToolCall 记录（fork skill 无对应 SwiftData ToolCall）
        let dummyToolCall = ToolCall(
            id: UUID().uuidString,
            name: "skill_invoke",
            input: [:],
            sessionId: ctx.sessionId
        )

        let agentMsg = try await runSubagentLoop(
            task: task,
            definition: definition,
            toolCallRecord: dummyToolCall,
            service: ctx.service,
            modelId: modelId,
            overrideModelId: nil,
            settings: ctx.settings,
            sessionId: ctx.sessionId,
            modelContext: ctx.modelContext
        )

        return agentMsg.textContent ?? "(fork skill produced no output)"
    }

    /// 构造工具授权列表。
    /// - 若 allowedTools 为空：返回空数组（子代理将使用 WorkflowRoleDefinition 默认工具集）。
    /// - 若 allowedTools 非空：每个 toolID 构造一条 ToolGrant。
    private func buildToolGrants(
        from allowedTools: [String],
        context: ToolContext
    ) -> [ToolGrant] {
        guard !allowedTools.isEmpty else { return [] }
        return allowedTools.map { toolID in
            ToolGrant(
                toolID: toolID,
                accessMode: .unrestricted,
                allowedContexts: [context]
            )
        }
    }
}

// MARK: - SkillForkContext

/// ClaudeService 在 tool dispatch 执行期间存储的上下文，
/// 供 `runSkillSubagent` 获取当前运行环境参数。
struct SkillForkContext: Sendable {
    let service: any AnthropicService
    let modelId: String
    let settings: AppSettings
    let sessionId: String
    let modelContext: ModelContext
}

// MARK: - Errors

enum SkillForkError: Error, LocalizedError {
    case missingRunContext

    var errorDescription: String? {
        switch self {
        case .missingRunContext:
            return "SkillFork: ClaudeService 缺少运行上下文。skill_invoke 必须在 agent loop 内调用。"
        }
    }
}
```

**Step 2: 在 `ClaudeService` 中添加 `currentSkillForkContext` 存储属性**

修改文件：`agentGui/Services/ClaudeService/ClaudeService.swift`（或主 ClaudeService 文件）

在 `ClaudeService` class 内添加：

```swift
// MARK: - Skill Fork Context (为 SkillSubagentRunning 协议存储当前执行上下文)
/// 由 ClaudeService+ToolDispatch.swift 在 executeTool 调用前后设置/清除。
var currentSkillForkContext: SkillForkContext?
```

**Step 3: 在 `AgentMessage` 扩展中添加 `textContent` 辅助属性（若不存在）**

检查：

```bash
grep -rn "textContent\|var text:" /Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentMessage.swift | head -10
```

若不存在 `textContent`，在 `AgentMessage` extension 中添加：

```swift
/// 从 AgentMessage 提取纯文本内容（用于 fork skill 结果格式化）。
var textContent: String? {
    switch self {
    case .text(let t, _, _): return t
    case .detecting(let t, _, _): return t
    default: return nil
    }
}
```

根据实际 `AgentMessage` 的 case 定义调整。

**Step 4: 运行编译验证**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | \
  grep -E "error:|warning:" | grep -v "deprecated" | head -30
```

预期：0 errors

**Step 5: 运行 Task 1 的测试（应当通过）**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-sc2-task1 \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/SkillForkExecutionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`** TEST SUCCEEDED **`，5 个测试全部通过

**Step 6: Commit**

```bash
git add agentGui/Services/ClaudeService/ClaudeService+SkillFork.swift
git commit -m "feat(S-C2): add SkillForkExecutor and SkillSubagentRunning protocol"
```

---

## Task 3: 修改 `ClaudeService+ToolDispatch.swift`，接入 fork 路由

**目的：** 在现有 `skill_invoke` 分支中，先查找 skill，若是 fork context 则调用 `SkillForkExecutor`；否则走现有 inline 路径。

**文件：** `agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift`

### 3.1 理解现有代码

现有 `skill_invoke` 分支（`executeToolOnce` 中，约 line 148 和 248 处各出现一次）：

```swift
case "skill_invoke":
    guard let skillName = input["skill"]?.stringValue else {
        return .missingParameter("skill")
    }
    let skillArgs = input["args"]?.stringValue
    let processor = SkillInvocationProcessor(
        provider: skillService ?? NullSkillContentProvider(),
        sessionId: sessionId
    )
    let outcome = await processor.invoke(skillName: skillName, args: skillArgs)
    return ToolExecutionResult(fromSkillInvocationOutcome: outcome)
```

### 3.2 修改策略

在调用 `SkillInvocationProcessor` 之前，先用 `skillService` 查找 skill，若 `executionContext == .fork` 则走 fork 路径。两处相同的分支都需要修改。

**Step 1: 确认两处 `skill_invoke` 的上下文参数可用性**

```bash
grep -n "case \"skill_invoke\"" \
  agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift
```

记录行号，确认两处分支中 `service`、`modelId`、`settings`、`sessionId`、`modelContext` 全部可用。

**Step 2: 在 `ClaudeService+ToolDispatch.swift` 中添加辅助方法 `executeSkillInvokeForked`**

在文件底部（`// MARK: - Effective Working Directory` 之前）添加私有方法：

```swift
// MARK: - Skill Invoke Fork Helper

/// `skill_invoke` 的 fork 执行路径。
/// 在 SkillForkContext 注入后调用 SkillForkExecutor。
@MainActor
private func executeSkillInvokeForked(
    skill: Skill,
    args: String?,
    service: any AnthropicService,
    modelId: String,
    settings: AppSettings,
    sessionId: String,
    modelContext: ModelContext
) async -> ToolExecutionResult {
    // 1. 读取并替换内容（复用 SkillInvocationProcessor 的内容加载逻辑）
    guard let rawContent = await skillService?.readSkillContent(name: skill.directoryName) else {
        return .failure("Error: skill '\(skill.directoryName)' content could not be loaded for fork execution.")
    }
    let processedContent = SkillArgumentSubstitution.substitute(
        content: rawContent,
        args: args,
        skillDirectory: skill.path,
        sessionId: sessionId
    )

    // 2. 注入 fork context，供 SkillSubagentRunning 协议实现（self）使用
    currentSkillForkContext = SkillForkContext(
        service: service,
        modelId: modelId,
        settings: settings,
        sessionId: sessionId,
        modelContext: modelContext
    )
    defer { currentSkillForkContext = nil }

    // 3. 执行 fork
    let executor = SkillForkExecutor(runner: self, defaultModelId: modelId)
    do {
        return try await executor.execute(
            skill: skill,
            processedContent: processedContent,
            parentModelId: modelId
        )
    } catch {
        return .failure("Fork skill '\(skill.directoryName)' failed: \(error.localizedDescription)")
    }
}
```

**Step 3: 修改两处 `case "skill_invoke":` 分支**

将现有的分支替换为（两处完全相同的修改模式）：

```swift
case "skill_invoke":
    guard let skillName = input["skill"]?.stringValue else {
        return .missingParameter("skill")
    }
    let skillArgs = input["args"]?.stringValue

    // Fork 路由：若 skill 声明了 fork context，走子代理执行路径
    if let skill = await skillService?.availableSkills.first(where: {
        $0.name == skillName || $0.directoryName == skillName
    }), skill.executionContext == .fork {
        return await executeSkillInvokeForked(
            skill: skill,
            args: skillArgs,
            service: service,
            modelId: modelId,
            settings: settings,
            sessionId: sessionId,
            modelContext: modelContext
        )
    }

    // Inline 路径（原有逻辑不变）
    let processor = SkillInvocationProcessor(
        provider: skillService ?? NullSkillContentProvider(),
        sessionId: sessionId
    )
    let outcome = await processor.invoke(skillName: skillName, args: skillArgs)
    return ToolExecutionResult(fromSkillInvocationOutcome: outcome)
```

> **注意：** 查找到两处 `case "skill_invoke":` 后，分别替换。两处的参数名可能略有不同（一处传 `service`，另一处可能用 `acpService` 或其他变量名）——以实际代码为准。

**Step 4: 编译验证**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | \
  grep "error:" | head -20
```

预期：0 errors

**Step 5: 完整测试（包括 inline 不受影响）**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-sc2-task3 \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/SkillForkExecutionTests \
  -only-testing:agentGuiTests/SkillInvocationProcessorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：两个测试组全部通过

**Step 6: Commit**

```bash
git add agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift
git commit -m "feat(S-C2): route fork skills to subagent loop in skill_invoke dispatch"
```

---

## Task 4: 补充 fork 路由集成测试

**目的：** 验证 `ToolExecutionResult(fromSkillInvocationOutcome:)` 对 fork 路径不适用（fork 直接返回 `ToolExecutionResult`），以及 `ClaudeService+ToolDispatch` 的 fork 分支路由逻辑。

**文件：** 扩展 `agentGuiTests/SkillForkExecutionTests.swift`

**Step 1: 补充 fork 结果格式测试**

在 `SkillForkExecutionTests` 末尾追加：

```swift
// ── 6. fork result header 格式正确
func test_fork_resultHeader_containsSkillName() async throws {
    let stub = StubSkillSubagentRunner()
    stub.returnText = "All tests passed."
    let executor = SkillForkExecutor(runner: stub, defaultModelId: "claude-opus-4-5")

    let skill = makeForkSkill(directoryName: "run-tests")
    let result = try await executor.execute(
        skill: skill,
        processedContent: "Run the test suite.",
        parentModelId: "claude-opus-4-5"
    )

    XCTAssertTrue(result.text.hasPrefix("[Skill fork result: run-tests]"),
                  "Expected header prefix, got: \(result.text.prefix(50))")
}

// ── 7. allowedTools 为空时，runner 收到空数组（不限制）
func test_fork_noAllowedTools_passesEmptyArray() async throws {
    let stub = StubSkillSubagentRunner()
    let executor = SkillForkExecutor(runner: stub, defaultModelId: "claude-opus-4-5")

    let skill = makeForkSkill(allowedTools: [])
    _ = try await executor.execute(
        skill: skill,
        processedContent: "Do work.",
        parentModelId: "claude-opus-4-5"
    )

    XCTAssertEqual(stub.capturedAllowedTools, [])
}
```

**Step 2: 运行所有 SkillForkExecutionTests**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-sc2-task4 \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/SkillForkExecutionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：7 个测试全部通过

**Step 3: 运行现有 Skill 相关测试（回归检查）**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-sc2-regression \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/SkillInvocationProcessorTests \
  -only-testing:agentGuiTests/SkillArgumentSubstitutionTests \
  -only-testing:agentGuiTests/SkillCatalogPromptRendererTests \
  -only-testing:agentGuiTests/SkillManifestTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：所有现有 skill 测试通过，无回归

**Step 4: Commit**

```bash
git add agentGuiTests/SkillForkExecutionTests.swift
git commit -m "test(S-C2): add fork result format and edge case tests"
```

---

## Task 5: 处理 AgentMessage.textContent（若需要）

**目的：** 确保 `runSubagentLoop` 返回的 `AgentMessage` 可以提取纯文本内容。

**Step 1: 检查 `AgentMessage` 现有结构**

```bash
grep -n "case text\|case detecting\|var textContent\|func text" \
  agentGui/Models/AgentMessage.swift | head -20
```

**Step 2: 若 `textContent` 属性不存在，在 AgentMessage extension 中添加**

在 `agentGui/Models/AgentMessage.swift` 或新建 `AgentMessage+TextExtraction.swift`：

```swift
extension AgentMessage {
    /// 提取消息的纯文本内容。用于 fork skill 结果格式化。
    var textContent: String? {
        // 根据实际 AgentMessage enum case 定义调整
        // 常见模式示例：
        switch self {
        case .text(let content, _, _):
            return content
        case .detecting(let content, _, _):
            return content
        default:
            return nil
        }
    }
}
```

> **实施时**：以 `AgentMessage.swift` 实际 case 定义为准，不要猜测参数顺序。

**Step 3: 编译验证**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | \
  grep "error:" | head -10
```

预期：0 errors

**Step 4: Commit（仅当实际修改了文件）**

```bash
git add agentGui/Models/AgentMessage.swift   # 或新建的文件
git commit -m "feat(S-C2): add AgentMessage.textContent extraction helper"
```

---

## Task 6: 最终烟雾测试

**目的：** 确认 fork 路径不影响主代理 loop 稳定性，现有测试全部通过。

**Step 1: 运行所有 skill 测试**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-sc2-final \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/SkillForkExecutionTests \
  -only-testing:agentGuiTests/SkillInvocationProcessorTests \
  -only-testing:agentGuiTests/SkillArgumentSubstitutionTests \
  -only-testing:agentGuiTests/SkillCatalogPromptRendererTests \
  -only-testing:agentGuiTests/SkillManifestTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：`** TEST SUCCEEDED **`

**Step 2: Final commit（如有未提交的变更）**

```bash
git add -A
git status
# 确认只有预期文件，然后：
git commit -m "feat(S-C2): complete fork skill execution - SkillInvocationTool fork mode"
```

---

## 验收标准对照（来自 Design Doc S-C2）

| 验收标准 | 实现位置 | 验证方式 |
|---|---|---|
| `context: fork` 的 skill 以子代理运行，不在主 agent 消息列表展开 | `ClaudeService+ToolDispatch.swift` fork 分支 → `runSubagentLoop` | `test_fork_basic_returnsSubagentResult` |
| 子代理结果作为工具结果返回主 agent | `SkillForkExecutor.execute()` → `ToolExecutionResult` | `test_fork_resultHeader_containsSkillName` |
| fork 执行失败时，主 agent 收到错误工具结果，不 crash | `SkillForkExecutor.execute()` catch → `.failure(...)` | `test_fork_runnerThrows_returnsErrorResult` |
| `allowedTools` 传递到子代理（工具集受限） | `buildToolGrants()` → `WorkflowRoleDefinition.toolGrants` | `test_fork_withAllowedTools_passesThemToRunner` |
| `model:` 覆盖子代理模型 | `skill.model ?? parentModelId` | `test_fork_modelOverride_usesSkillModel` |
| inline skill 路径不受影响（回归） | inline 分支保持不变 | `SkillInvocationProcessorTests` 全部通过 |

---

## 已知限制（超出本 Feature 范围）

- **effort 覆盖**（S-C5）：`skill.effort` 字段存在但本期不传入 `WorkflowRoleDefinition`；需在 S-C5 中补充。现有 `EffortLevel` enum 和 `WorkflowRoleDefinition.effort` 字段已就绪，只需在 fork 构造时传入。
- **子代理 UI 投影**：fork skill 的子代理轮次不投影到主 session 的 chat 时间线（`streamProjectionTarget: .none`）——与 Claude Code 的 progress callback 行为一致，子代理内部细节不污染主 agent 视图。
- **toolInterceptor 为 nil**：fork 子代理不注入 tool interceptor，与现有 `runSubagentLoop` 中 `toolInterceptor: nil` 的行为一致。

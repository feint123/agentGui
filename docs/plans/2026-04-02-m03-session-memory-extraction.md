# M-03 会话末记忆自动提取服务 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在每个 agentic run（一次用户消息 → agent 完整响应）成功结束后，后台自动启动一个提取 subagent，分析本轮对话内容并将值得保留的内容写入 `RMSInsightStore`，不阻塞主线程。

**Architecture:** 新增 `MemoryExtractionHook`（订阅 `willFinishRun` stage），触发时 fire-and-forget 一个 detached Task，Task 通过 `MemoryExtractionCoordinator` actor 做 per-session 并发保护，然后调用 `ClaudeService.runCoreAgentLoop` 启动受限工具集（仅 `memory_write` + 只读工具）的提取 subagent。提取 subagent 的 user prompt 由 `MemoryExtractionPromptBuilder` 生成，内含现有 insights 摘要（防止重复写入）和四类型语义指导。

**Tech Stack:** Swift 6 / Swift Concurrency / SwiftAnthropic / SwiftData / `AgentLoopHook` 协议 / `ClaudeService.runCoreAgentLoop`

---

## 前置知识

- **Hook 注册路径**：`AgentLoopBuiltInHookFactory.makeHooks()` → `AgentLoopHookDispatcher` → `AgentLoopHookEmitter`
- **触发 stage**：`willFinishRun` 仅在 `completedSuccessfully == true`（即 `phase == .finalizing`，`stopReason == "end_turn"`）时发射
- **并发保护原则**：主 agent runs 不能等提取完成；提取 subagent 不能再触发新的提取（通过 `toolExecutionContext != .mainAgent` 守卫）
- **写入工具**：`memory_write` 工具已存在（`ClaudeService+ToolDispatch.swift` `executeGovernedMemoryWrite`），提取 subagent 直接调用
- **现有 insights**：`RMSInsightStore().load(scopes:)` 读取现有记忆，注入 prompt 防止重复
- **Semantic types**：`MemorySemanticType` 枚举已存在（`.user` / `.feedback` / `.project` / `.reference`），提取 prompt 应指导 agent 标注 `semanticType`

---

## Task 1：`MemoryExtractionCoordinator` Actor

> per-session 提取并发保护 + 空档期判断

**Files:**
- Create: `agentGui/Services/MemoryExtractionCoordinator.swift`
- Test: `agentGuiTests/MemoryExtractionCoordinatorTests.swift`

### Step 1: 编写失败测试

```swift
// agentGuiTests/MemoryExtractionCoordinatorTests.swift
import XCTest
@testable import agentGui

@MainActor
final class MemoryExtractionCoordinatorTests: XCTestCase {

    func test_shouldExtract_returnsTrueWhenIdle() async {
        let coordinator = MemoryExtractionCoordinator()
        let result = await coordinator.shouldExtract()
        XCTAssertTrue(result)
    }

    func test_shouldExtract_returnsFalseWhenExtractionInProgress() async {
        let coordinator = MemoryExtractionCoordinator()
        await coordinator.beginExtraction()
        let result = await coordinator.shouldExtract()
        XCTAssertFalse(result)
    }

    func test_beginExtraction_isIdempotentUnderConcurrency() async {
        let coordinator = MemoryExtractionCoordinator()
        var granted = 0
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask { await coordinator.beginExtraction() }
            }
            for await ok in group {
                if ok { granted += 1 }
            }
        }
        XCTAssertEqual(granted, 1, "Only one concurrent extraction should be granted")
    }

    func test_finishExtraction_resetsToIdle() async {
        let coordinator = MemoryExtractionCoordinator()
        await coordinator.beginExtraction()
        await coordinator.finishExtraction()
        let result = await coordinator.shouldExtract()
        XCTAssertTrue(result)
    }
}
```

### Step 2: 运行测试确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m03-task1 \
  -only-testing:agentGuiTests/MemoryExtractionCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译失败（类型不存在）

### Step 3: 编写最小实现

```swift
// agentGui/Services/MemoryExtractionCoordinator.swift
import Foundation

/// per-session 提取并发守卫。
/// 保证同一时刻一个 session 最多运行一次 extraction subagent。
actor MemoryExtractionCoordinator {
    private var isExtracting = false

    /// 查询当前是否可以启动新的提取。不修改状态。
    func shouldExtract() -> Bool {
        !isExtracting
    }

    /// 尝试占用提取槽位。若已被占用，返回 false；否则标记并返回 true。
    @discardableResult
    func beginExtraction() -> Bool {
        guard !isExtracting else { return false }
        isExtracting = true
        return true
    }

    /// 释放提取槽位。
    func finishExtraction() {
        isExtracting = false
    }
}
```

### Step 4: 运行测试确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m03-task1 \
  -only-testing:agentGuiTests/MemoryExtractionCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：`** TEST SUCCEEDED **`

### Step 5: Commit

```bash
git add agentGui/Services/MemoryExtractionCoordinator.swift \
        agentGuiTests/MemoryExtractionCoordinatorTests.swift
git commit -m "feat(M-03): add MemoryExtractionCoordinator actor for per-session guard"
```

---

## Task 2：`MemoryExtractionPromptBuilder`

> 生成提取 subagent 的 user prompt，含现有 insights 摘要和语义类型指导

**Files:**
- Create: `agentGui/Services/MemoryExtractionPromptBuilder.swift`
- Test: `agentGuiTests/MemoryExtractionPromptBuilderTests.swift`

### Step 1: 编写失败测试

```swift
// agentGuiTests/MemoryExtractionPromptBuilderTests.swift
import XCTest
@testable import agentGui

final class MemoryExtractionPromptBuilderTests: XCTestCase {

    func test_build_containsMessageCountHint() {
        let prompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: 12,
            existingInsights: []
        )
        XCTAssertTrue(prompt.contains("12"), "Prompt should reference the message count")
    }

    func test_build_containsMemoryWriteToolName() {
        let prompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: 4,
            existingInsights: []
        )
        XCTAssertTrue(prompt.contains("memory_write"), "Prompt must mention the write tool")
    }

    func test_build_containsAllFourSemanticTypes() {
        let prompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: 4,
            existingInsights: []
        )
        for typeName in ["user", "feedback", "project", "reference"] {
            XCTAssertTrue(prompt.contains(typeName), "Prompt must describe semantic type: \(typeName)")
        }
    }

    func test_build_containsWhatNotToSaveSection() {
        let prompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: 4,
            existingInsights: []
        )
        XCTAssertTrue(
            prompt.lowercased().contains("not") && prompt.lowercased().contains("save"),
            "Prompt must include what-not-to-save guidance"
        )
    }

    func test_build_withExistingInsights_includesTheirSummaries() {
        let insight = RMSInsight.constraint(
            id: "c1",
            summary: "Always inspect before editing",
            appliesWhen: "coding",
            changesDecision: "inspect first"
        )
        let prompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: 4,
            existingInsights: [insight]
        )
        XCTAssertTrue(prompt.contains("Always inspect before editing"))
    }

    func test_build_withNoExistingInsights_hasNoExistingSection() {
        let prompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: 4,
            existingInsights: []
        )
        XCTAssertFalse(prompt.contains("Existing memories"))
    }
}
```

### Step 2: 运行测试确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m03-task2 \
  -only-testing:agentGuiTests/MemoryExtractionPromptBuilderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：编译失败

### Step 3: 编写最小实现

```swift
// agentGui/Services/MemoryExtractionPromptBuilder.swift
import Foundation

/// 生成 memory extraction subagent 的 user prompt（nonisolated）。
///
/// 对齐 Claude Code `buildExtractAutoOnlyPrompt`：
/// - 包含四类型语义指导（user / feedback / project / reference）
/// - 包含 "What NOT to save" 章节
/// - 注入现有 insights 摘要防重复
/// - 指定工具权限（memory_write + 只读）
enum MemoryExtractionPromptBuilder {

    static func build(
        newMessageCount: Int,
        existingInsights: [RMSInsight]
    ) -> String {
        var lines: [String] = []

        // 角色说明
        lines += [
            "You are now acting as the memory extraction subagent.",
            "Analyze the most recent ~\(newMessageCount) messages above and use them to update the persistent memory system.",
            "",
            "Available tools: memory_write (to persist insights), and read-only tools (read_file, bash for ls/cat/stat only).",
            "Do NOT call bash rm or any write-capable shell command. Do NOT call other agents.",
            "You have a limited turn budget — complete extraction in at most 3 turns.",
            "",
            "You MUST only use content from the last ~\(newMessageCount) messages. Do not investigate or verify content further.",
        ]

        // 现有 insights 摘要（防重复写入）
        if !existingInsights.isEmpty {
            lines += [
                "",
                "## Existing memories",
                "",
                "Before writing, check this list to avoid duplicates. Update an existing entry rather than creating a new one if the content is similar.",
                "",
            ]
            for insight in existingInsights {
                lines.append("- [\(insight.id)] \(insight.summary)")
            }
        }

        // 语义类型指导（四类型）
        lines += [
            "",
            "## Types of memory",
            "",
            "There are four types of memory. Use the `semantic_type` field of memory_write to classify each insight:",
            "",
            "<types>",
            "",
            "<type>",
            "  <name>user</name>",
            "  <description>User's role, preferences, goals, and background. Helps tailor future responses.</description>",
            "  <when_to_save>When you learn details about who the user is or how they prefer to work.</when_to_save>",
            "  <how_to_use>Adjust tone, depth, and priorities based on user profile.</how_to_use>",
            "  <examples>User is a senior Swift engineer. User prefers concise responses. User works on macOS-only projects.</examples>",
            "</type>",
            "",
            "<type>",
            "  <name>feedback</name>",
            "  <description>Corrections the user gave or behaviors they explicitly confirmed or rejected.</description>",
            "  <when_to_save>When the user corrects a mistake, confirms an approach, or gives explicit behavioral guidance.</when_to_save>",
            "  <how_to_use>Avoid repeating corrected behaviors; reinforce confirmed approaches.</how_to_use>",
            "  <examples>User said 'don't add comments to unchanged code'. User confirmed TDD-first approach is preferred.</examples>",
            "</type>",
            "",
            "<type>",
            "  <name>project</name>",
            "  <description>Project-specific context: goals, architectural decisions, key deadlines, incidents.</description>",
            "  <when_to_save>When you learn project goals, technical constraints, or significant decisions.</when_to_save>",
            "  <how_to_use>Frame suggestions in terms of project constraints and direction.</how_to_use>",
            "  <examples>This project targets macOS 15+. The SwiftData migration path was decided to use Codable JSON side-car files.</examples>",
            "</type>",
            "",
            "<type>",
            "  <name>reference</name>",
            "  <description>Pointers to external systems, documentation, or resources relevant to future work.</description>",
            "  <when_to_save>When you discover important external information sources, API endpoints, or documentation links.</when_to_save>",
            "  <how_to_use>Surface the reference when the user asks about the same topic.</how_to_use>",
            "  <examples>Anthropic streaming docs: https://docs.anthropic.com/streaming. Xcode test target config: agentGui.xcodeproj scheme 'agentGui'.</examples>",
            "</type>",
            "",
            "</types>",
        ]

        // What NOT to save
        lines += [
            "",
            "## What NOT to save",
            "",
            "Do NOT save anything that can be retrieved from the codebase at any time:",
            "- Code patterns, variable names, or file structure",
            "- Git history or commit messages",
            "- Content already in CLAUDE.md or README",
            "- Transient task progress (use todo list for that)",
            "- Hallucinated or unverified facts",
            "- Any sensitive data (API keys, credentials)",
        ]

        // 保存说明
        lines += [
            "",
            "## How to save",
            "",
            "Call memory_write with:",
            "- `content`: the insight text",
            "- `title`: concise topic label (used as the insight ID base)",
            "- `scope`: 'user' for personal, 'project' for project-scoped",
            "- `semantic_type`: one of user|feedback|project|reference",
            "",
            "If nothing new is worth saving, respond with a short explanation and stop. Do not write trivial or low-value memories.",
        ]

        return lines.joined(separator: "\n")
    }
}
```

### Step 4: 运行测试确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m03-task2 \
  -only-testing:agentGuiTests/MemoryExtractionPromptBuilderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 5: Commit

```bash
git add agentGui/Services/MemoryExtractionPromptBuilder.swift \
        agentGuiTests/MemoryExtractionPromptBuilderTests.swift
git commit -m "feat(M-03): add MemoryExtractionPromptBuilder"
```

---

## Task 3：`MemoryExtractionHook` 结构体

> Hook 协议实现：检查守卫条件，fire-and-forget detached Task

**Files:**
- Create: `agentGui/Services/AgentLoopHooks/MemoryExtractionHook.swift`
- Test: `agentGuiTests/MemoryExtractionHookTests.swift`

### Step 1: 了解现有 Hook 接口

先阅读：
- `agentGui/Models/AgentLoopHookModels.swift`（`AgentLoopHook` 协议定义）
- `agentGui/Services/AgentLoopHooks/MemoryBootstrapHook.swift`（参考实现）

关键协议方法：
```swift
protocol AgentLoopHook: Sendable {
    var id: String { get }
    var order: Int { get }
    var kind: AgentLoopHookKind { get }
    var isRequired: Bool { get }
    func supports(_ stage: AgentLoopHookStage) -> Bool
    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult
}
```

### Step 2: 编写失败测试

```swift
// agentGuiTests/MemoryExtractionHookTests.swift
import XCTest
@testable import agentGui

@MainActor
final class MemoryExtractionHookTests: XCTestCase {

    func test_supports_willFinishRun() {
        var callbackInvoked = false
        let hook = MemoryExtractionHook { _ in callbackInvoked = true }
        XCTAssertTrue(hook.supports(.willFinishRun))
    }

    func test_supports_doesNotSupportOtherStages() {
        let hook = MemoryExtractionHook { _ in }
        let otherStages: [AgentLoopHookStage] = [
            .prepareRun, .didStartRun, .willStartRound,
            .didFinishRun, .willExecuteTool, .didExecuteTool
        ]
        for stage in otherStages {
            XCTAssertFalse(hook.supports(stage), "Should not support \(stage)")
        }
    }

    func test_perform_returnsImmediatelyWithContinue() async throws {
        let expectation = XCTestExpectation(description: "callback eventually called")
        expectation.assertForOverFulfill = true
        let hook = MemoryExtractionHook { _ in expectation.fulfill() }

        let context = makeTestContext(toolExecutionContext: .mainAgent)
        let result = try await hook.perform(stage: .willFinishRun, context: context)

        XCTAssertEqual(result, .continue)
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func test_perform_skipsExtractionForSubagent() async throws {
        var callbackInvoked = false
        let hook = MemoryExtractionHook { _ in callbackInvoked = true }
        let context = makeTestContext(toolExecutionContext: .subagent)

        let result = try await hook.perform(stage: .willFinishRun, context: context)

        XCTAssertEqual(result, .continue)
        // 给足够时间让可能的异步任务运行
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(callbackInvoked, "Subagent run must not trigger extraction")
    }

    // MARK: - Helpers

    private func makeTestContext(
        toolExecutionContext: ToolContext
    ) -> AgentLoopHookContext {
        var ctx = AgentLoopHookContext(
            runID: "test-run",
            sessionID: "test-session",
            workflowID: nil,
            executionContext: toolExecutionContext,
            modelId: "claude-sonnet-4-5",
            roundIndex: 2,
            phase: "finalizing"
        )
        ctx.messagesSnapshot = []
        ctx.metadata = [:]
        return ctx
    }
}
```

### Step 3: 运行测试确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m03-task3 \
  -only-testing:agentGuiTests/MemoryExtractionHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 4: 编写最小实现

```swift
// agentGui/Services/AgentLoopHooks/MemoryExtractionHook.swift
import Foundation

/// 在 `willFinishRun`（主 agent 完整结束）时，fire-and-forget 启动记忆提取 subagent。
///
/// 设计约束：
/// - `.subagent` 执行上下文不触发（防递归）
/// - `perform` 立即返回 `.continue`，不阻塞主 loop
/// - 实际提取通过注入的 `callback` 闭包执行（由 AgentLoopHookDependencyFactory 构建）
struct MemoryExtractionHook: AgentLoopHook {
    let id = "memory-extraction"
    let order = 90
    let kind: AgentLoopHookKind = .observer
    let isRequired = false

    /// Injected callback: runs the extraction subagent async. Captures coordinator + service.
    let callback: @Sendable (AgentLoopHookContext) async -> Void

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .willFinishRun
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        guard stage == .willFinishRun else { return .continue }

        // 只对主 agent run 触发
        guard context.executionContext == .mainAgent else { return .continue }

        // Fire-and-forget：不等待提取完成，立即放行 main loop
        let capturedContext = context
        let capturedCallback = callback
        Task.detached(priority: .background) {
            await capturedCallback(capturedContext)
        }

        return .continue
    }
}
```

### Step 5: 运行测试确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m03-task3 \
  -only-testing:agentGuiTests/MemoryExtractionHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 6: Commit

```bash
git add agentGui/Services/AgentLoopHooks/MemoryExtractionHook.swift \
        agentGuiTests/MemoryExtractionHookTests.swift
git commit -m "feat(M-03): add MemoryExtractionHook (observer, willFinishRun)"
```

---

## Task 4：Extraction Callback 实现

> 在 `AgentLoopHookDependencyFactory` 中构建实际的提取回调逻辑

**Files:**
- Modify: `agentGui/Services/AgentLoopHookDependencyFactory.swift`
- Modify: `agentGui/Services/AgentLoopBuiltInHookFactory.swift`
- Test: `agentGuiTests/MemoryExtractionCallbackTests.swift`

### Step 1: 阅读现有 DependencyFactory

仔细阅读 `agentGui/Services/AgentLoopHookDependencyFactory.swift` 全文，重点注意：
- `struct AgentLoopHookDependencyFactory` 有 `claudeService`, `request`, `runtime` 成员
- `func build(state:) -> Dependencies`：构建 `Dependencies` 结构体
- `Dependencies` 中如何添加 `extractMemoriesCallback` 字段

仔细阅读 `agentGui/Services/AgentLoopBuiltInHookFactory.swift` 全文，重点注意：
- `class State` 的字段列表
- `struct Dependencies` 的字段列表
- `makeHooks(dependencies:state:)` 中如何注册 hooks

### Step 2: 编写失败测试

```swift
// agentGuiTests/MemoryExtractionCallbackTests.swift
import XCTest
@testable import agentGui
import SwiftAnthropic

/// 验证 AgentLoopBuiltInHookFactory 将 MemoryExtractionHook 注册进 hook 列表。
@MainActor
final class MemoryExtractionCallbackTests: XCTestCase {

    func test_makeHooks_includesMemoryExtractionHook() {
        let state = AgentLoopBuiltInHookFactory.State()
        let deps = AgentLoopBuiltInHookFactory.Dependencies(
            businessLogSink: nil,
            memoryBootstrapLoader: { _ in nil },
            createToolCallRecord: { _, _ in fatalError() },
            updateToolCallRecord: { _, _ in },
            extractMemoriesCallback: { _ in }   // 新字段
        )
        let hooks = AgentLoopBuiltInHookFactory().makeHooks(dependencies: deps, state: state)
        let hasExtractionHook = hooks.contains { $0.id == "memory-extraction" }
        XCTAssertTrue(hasExtractionHook, "makeHooks should include MemoryExtractionHook")
    }
}
```

### Step 3: 运行测试确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m03-task4 \
  -only-testing:agentGuiTests/MemoryExtractionCallbackTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 4: 修改 `AgentLoopBuiltInHookFactory.swift`

在 `struct Dependencies` 末尾添加新字段，在 `makeHooks` 末尾添加 hook 注册：

```swift
// agentGui/Services/AgentLoopBuiltInHookFactory.swift

struct Dependencies {
    let businessLogSink: BusinessLogSink?
    let memoryBootstrapLoader: (State) async throws -> AgentLoopMessagePatch?
    let createToolCallRecord: (AgentLoopHookContext, State) async throws -> ToolCall
    let updateToolCallRecord: (AgentLoopHookContext, State) async throws -> Void
    // M-03: 新增提取回调
    let extractMemoriesCallback: @Sendable (AgentLoopHookContext) async -> Void
}

func makeHooks(
    dependencies: Dependencies,
    state: State
) -> [any AgentLoopHook] {
    [
        StreamProjectionHook(),
        RemoteChannelProjectionHook(),
        MemoryBootstrapHook { _ in
            try await dependencies.memoryBootstrapLoader(state)
        },
        ToolAuditHook(
            sink: dependencies.businessLogSink,
            createRecord: { context in
                try await dependencies.createToolCallRecord(context, state)
            },
            updateRecord: { context in
                try await dependencies.updateToolCallRecord(context, state)
            }
        ),
        FailureClassificationHook(),
        BusinessObservabilityHook(sink: dependencies.businessLogSink),
        // M-03: 会话末记忆自动提取
        MemoryExtractionHook(callback: dependencies.extractMemoriesCallback),
    ]
}
```

### Step 5: 修改 `AgentLoopHookDependencyFactory.swift`

在 `build(state:)` 方法中补充 `extractMemoriesCallback`：

```swift
// agentGui/Services/AgentLoopHookDependencyFactory.swift

func build(state: AgentLoopBuiltInHookFactory.State) -> AgentLoopBuiltInHookFactory.Dependencies {
    AgentLoopBuiltInHookFactory.Dependencies(
        businessLogSink: claudeService.businessLogSink,
        memoryBootstrapLoader: { hookState in
            try await loadMemoryBootstrap(state: hookState)
        },
        createToolCallRecord: { context, hookState in
            try await createToolCallRecord(context: context, state: hookState)
        },
        updateToolCallRecord: { context, hookState in
            try await updateToolCallRecord(context: context, state: hookState)
        },
        // M-03
        extractMemoriesCallback: buildExtractionCallback()
    )
}

/// 构建 memory extraction 的执行闭包。
/// 闭包捕获 coordinator（@MainActor 隔离），在 detached Task 中通过 actor isolated 调用安全执行。
private func buildExtractionCallback() -> @Sendable (AgentLoopHookContext) async -> Void {
    let coordinator = MemoryExtractionCoordinator()
    let service = claudeService
    let settings = runtime.settings
    let sessionId = runtime.sessionId
    let modelContext = runtime.modelContext

    return { @Sendable context in
        // 守卫：已在运行中则跳过
        guard await coordinator.beginExtraction() else { return }
        defer { Task { await coordinator.finishExtraction() } }

        do {
            try await runMemoryExtraction(
                context: context,
                claudeService: service,
                settings: settings,
                sessionId: sessionId,
                modelContext: modelContext
            )
        } catch {
            // 提取失败不影响主 loop，仅打印调试日志
            #if DEBUG
            print("[MemoryExtraction] error: \(error)")
            #endif
        }
    }
}

/// 实际运行 extraction subagent 的私有方法。
/// 从 RMSInsightStore 读取现有 insights → 构建 prompt → 调用 runCoreAgentLoop
private func runMemoryExtraction(
    context: AgentLoopHookContext,
    claudeService: ClaudeService,
    settings: AppSettings,
    sessionId: String,
    modelContext: ModelContext
) async throws {
    // 1. 读取现有 insights（防重复写入）
    let existingInsights = (try? RMSInsightStore().load(scope: .user)) ?? []

    // 2. 计算本轮新消息数（context.messagesSnapshot 是本次 run 的完整消息列表）
    let messageCount = context.messagesSnapshot.count

    guard messageCount > 0 else { return }

    // 3. 构建提取 prompt
    let extractionPrompt = MemoryExtractionPromptBuilder.build(
        newMessageCount: messageCount,
        existingInsights: existingInsights
    )

    // 4. 构建受限工具集（仅 memory_write + read_file + bash）
    let restrictedTools = claudeService.buildExtractionTools(settings: settings)

    // 5. 启动 extraction subagent（最多 5 轮）
    var loopMessages: [MessageParameter.Message] = context.messagesSnapshot
    loopMessages.append(.init(role: .user, content: .text(extractionPrompt)))

    let extractionSystem = claudeService.makeEphemeralSystemPrompt(nil)

    _ = try await claudeService.runCoreAgentLoop(
        messages: &loopMessages,
        service: claudeService.defaultService,
        modelId: settings.selectedModel,
        tools: restrictedTools,
        system: extractionSystem,
        settings: settings,
        sessionId: sessionId,
        modelContext: modelContext,
        maxRounds: 5,
        makeRound: { AgentRound(roundIndex: $0) },
        parentMessage: nil,
        streamProjectionTarget: .none,
        toolExecutionContext: .backgroundTask
    )
}
```

> **注意**：`buildExtractionTools` 和 `defaultService` 是需要在 `ClaudeService` 上新增的辅助方法（见 Task 5）。

### Step 6: 运行测试确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m03-task4 \
  -only-testing:agentGuiTests/MemoryExtractionCallbackTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

### Step 7: Commit

```bash
git add agentGui/Services/AgentLoopBuiltInHookFactory.swift \
        agentGui/Services/AgentLoopHookDependencyFactory.swift \
        agentGuiTests/MemoryExtractionCallbackTests.swift
git commit -m "feat(M-03): wire MemoryExtractionHook into built-in hook factory"
```

---

## Task 5: `ClaudeService` Extraction 辅助方法

> 为 extraction subagent 提供受限工具集构建和 defaultService 访问

**Files:**
- Create: `agentGui/Services/ClaudeService/ClaudeService+MemoryExtraction.swift`
- Test: `agentGuiTests/ClaudeServiceMemoryExtractionToolsTests.swift`

### Step 1: 了解现有 ToolBuilder

阅读 `agentGui/Services/ClaudeService/ClaudeService+ToolBuilder.swift`，重点关注：
- `buildTools(settings:)` 方法的工具列表构建模式
- `memory_write` 工具的 schema 定义（约第 240 行）
- 工具名常量的使用约定

### Step 2: 编写失败测试

```swift
// agentGuiTests/ClaudeServiceMemoryExtractionToolsTests.swift
import XCTest
@testable import agentGui

@MainActor  
final class ClaudeServiceMemoryExtractionToolsTests: XCTestCase {

    func test_buildExtractionTools_containsMemoryWrite() throws {
        let service = ClaudeService.shared
        let settings = AppSettings.preview

        let tools = service.buildExtractionTools(settings: settings)

        let names = tools.compactMap { tool -> String? in
            if case .tool(let def) = tool { return def.name }
            return nil
        }
        XCTAssertTrue(names.contains("memory_write"), "Extraction tools must include memory_write")
    }

    func test_buildExtractionTools_doesNotContainSubagentTool() throws {
        let service = ClaudeService.shared
        let settings = AppSettings.preview

        let tools = service.buildExtractionTools(settings: settings)

        let names = tools.compactMap { tool -> String? in
            if case .tool(let def) = tool { return def.name }
            return nil
        }
        XCTAssertFalse(names.contains("run_subagent"), "Extraction tools must not include run_subagent")
        XCTAssertFalse(names.contains("bash"), "Extraction tools should not include bash in default extraction set")
    }
}
```

> **注意**：如果 `AppSettings.preview` 不存在，使用 `AppSettings()` 或调整为已有的测试 fixture。

### Step 3: 运行测试确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m03-task5 \
  -only-testing:agentGuiTests/ClaudeServiceMemoryExtractionToolsTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 4: 编写最小实现

```swift
// agentGui/Services/ClaudeService/ClaudeService+MemoryExtraction.swift
import Foundation
import SwiftAnthropic

extension ClaudeService {

    /// 供 Task 4 的 `runMemoryExtraction` 访问主 AnthropicService。
    var defaultService: any AnthropicService {
        anthropicService
    }

    /// 构建 memory extraction subagent 的受限工具集。
    ///
    /// 只包含：
    /// - `memory_write`（写入 RMSInsights）
    /// - `read_file`（可选读取文件内容，减少幻觉）
    ///
    /// 不包含：bash、run_subagent、web_search、lsp_* 等重型工具，
    /// 确保提取 subagent 不会发起副作用或创建递归 loop。
    func buildExtractionTools(settings: AppSettings) -> [MessageParameter.Tool] {
        // 从完整工具集里筛选允许的工具名
        let allowed: Set<String> = ["memory_write", "read_file"]
        return buildTools(settings: settings).filter { tool in
            guard case .tool(let def) = tool else { return false }
            return allowed.contains(def.name)
        }
    }
}
```

> **注意**：`buildTools(settings:)` 和 `anthropicService` 是 `ClaudeService` 已有成员。若 `anthropicService` 访问级别为 `private`，在 Task 4 测试通过后检查是否需要改为 `internal`，或在 extension 内用已有的 `API_KEY`-based service 初始化替代。

### Step 5: 运行测试确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m03-task5 \
  -only-testing:agentGuiTests/ClaudeServiceMemoryExtractionToolsTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 6: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+MemoryExtraction.swift \
        agentGuiTests/ClaudeServiceMemoryExtractionToolsTests.swift
git commit -m "feat(M-03): add ClaudeService extraction tools helper"
```

---

## Task 6: 全量编译验证 + Smoke Test

> 确保所有修改在完整编译下无错误，并运行所有 M-03 相关测试

### Step 1: 运行全部 M-03 测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m03-all \
  -only-testing:agentGuiTests/MemoryExtractionCoordinatorTests \
  -only-testing:agentGuiTests/MemoryExtractionPromptBuilderTests \
  -only-testing:agentGuiTests/MemoryExtractionHookTests \
  -only-testing:agentGuiTests/MemoryExtractionCallbackTests \
  -only-testing:agentGuiTests/ClaudeServiceMemoryExtractionToolsTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`** TEST SUCCEEDED **`（所有 5 个测试套件通过）

### Step 2: 运行回归测试

确保没有破坏现有 bootstrap 相关逻辑：

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m03-regression \
  -only-testing:agentGuiTests/ClaudeServiceMemoryGuidanceInjectionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 3: Final Commit

```bash
git add -A
git commit -m "feat(M-03): session-end memory auto-extraction service complete

- MemoryExtractionCoordinator: per-session actor guard
- MemoryExtractionPromptBuilder: 4-type semantic prompt generation
- MemoryExtractionHook: willFinishRun observer, fire-and-forget
- AgentLoopBuiltInHookFactory: extractMemoriesCallback dependency wired
- AgentLoopHookDependencyFactory: extraction callback construction
- ClaudeService+MemoryExtraction: restricted tool set for extraction subagent

Extraction skips subagent runs (toolExecutionContext != .mainAgent),
prevents concurrent extraction via MemoryExtractionCoordinator.beginExtraction(),
and uses memory_write to persist RMSInsights with semanticType annotation."
```

---

## 架构决策记录

| 决策 | 选择 | 原因 |
|------|------|------|
| Hook stage | `willFinishRun` | 只在 `phase == .finalizing`（`end_turn`，无 tool_use）时触发，对齐 Claude Code `handleStopHooks` |
| 并发模型 | `actor MemoryExtractionCoordinator` | Swift 6 actor 隔离，per-session guard，比 `@MainActor Bool` flag 更清晰 |
| Fire-and-forget | `Task.detached(priority: .background)` | 不阻塞 main loop UI；提取失败不影响用户体验 |
| 递归防护 | `toolExecutionContext != .mainAgent` | extraction subagent 以 `.backgroundTask` 运行，不触发 `willFinishRun` 提取 |
| 工具集限制 | 仅 `memory_write` + `read_file` | 防止提取 subagent 发起 bash/web/subagent 等副作用；与 Claude Code `createAutoMemCanUseTool` 对齐 |
| Prompt 消息来源 | `context.messagesSnapshot` | 包含本次 run 的全部 API 消息（含 tool rounds），是最完整的本轮上下文 |
| 写入存储 | `memory_write` 工具 → `RMSInsightStore` | 复用已有 `executeGovernedMemoryWrite` 逻辑；自动分配 ID + scope + semanticType |

## 已知局限（后续 Feature 可改进）

- **无跨 run 游标**：每次 extraction 处理当前 run 的全部消息，不维护 UUID 游标。多次相同 run 若触发多次（理论上不会），可能写入重复 insights。
- **无 MEMORY.md 索引更新**：M-02 实现后才会有索引文件。M-03 写入的 insights 仍通过 `RMSInsightStore` 访问，非 MEMORY.md 路径。
- **无团队 scope**：extraction 仅写入 `.user` 或 `.project` scope，M-09 前不涉及 `team`。
- **subagent 模型固定**：使用 `settings.selectedModel`，未来可优化为用 haiku 降低成本。

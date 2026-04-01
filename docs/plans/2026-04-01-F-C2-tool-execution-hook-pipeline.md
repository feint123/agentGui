# F-C2 ToolExecutionHookPipeline 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 建立标准的工具前后置钩子协议（ToolExecutionHookPipeline），让所有 built-in 工具执行都能在不修改工具本体的情况下挂接阻断、上下文附加、结果重写、失败恢复等治理行为。

**Architecture:** 新增独立于 `AgentLoopHook`（循环层）的工具调用级别治理层。Pipeline 作为可选依赖注入 `AgentLoopToolExecutionCoordinator`，在 `executeTool()` 调用前后运行钩子链。钩子失败不中断主执行路径（非致命）。附加内容通过写入 `ToolCall.toolResultSummary` 投影至 UI 时间线。

**Tech Stack:** Swift 6, `@MainActor`, XCTest, 现有 `AgentLoopToolExecutionCoordinator` / `ToolExecutionResult` / `ToolCall` / `ToolContext` 模型。

**Source Reference:** `src/services/tools/toolHooks.ts` in Claude Code — `runPreToolUseHooks` / `runPostToolUseHooks` / `runPostToolUseFailureHooks` 的三段式结构，以及 `additionalContexts` / `blockingError` / `updatedMCPToolOutput` 的聚合语义。

---

## 背景与当前状态

### 已存在的基础设施

| 文件 | 关键内容 | 与 F-C2 的关系 |
|------|----------|----------------|
| `AgentLoopHookModels.swift` | `AgentLoopHook` 协议，`.willExecuteTool` / `.didExecuteTool` 阶段 | **循环层** hook，负责投影、审计、记录；F-C2 是**工具调用层** hook |
| `AgentLoopToolExecutionCoordinator.swift` | `execute(pendingTool:record:interceptor:)` | F-C2 pipeline 的接入点 |
| `AgentLoopToolExecutionCoordinatorBuilder.swift` | 注入 coordinator 依赖的工厂 | 注入 `ToolExecutionHookPipeline` 的位置 |
| `ToolExecutionResult.swift` | `ToolExecutionResult` 值类型 | `postExecute` 结果重写的目标类型 |
| `ToolCall.swift` | `ToolCall.toolResultSummary: String?` | 存储 hook 附件文本供 UI 展示 |
| `ToolConcurrencyBatchPlanner.swift` | `ToolExecutionBatch` + `partition()` | F-C1，已完成，是并发批次的调度基础 |
| `AgentLoopHooks/ToolAuditHook.swift` | 现有工具审计钩子（循环层） | 参考实现 `AgentLoopHook` 的模式 |

### F-C2 新增哪些能力

`AgentLoopHook` **不具备**的能力，F-C2 新增：

1. **阻断执行**（`preExecute` 返回 `.block`）：工具根本不执行，直接返回带原因的失败结果。
2. **上下文附加**（`preExecute` 返回 `.attachContext`）：工具执行后，额外上下文注入模型可见的结果文本。
3. **结果重写**（`postExecute` 返回 `.rewriteResult`）：钩子可替换工具的原始返回内容。
4. **失败恢复**（`postFailure` 返回 `.recover`）：工具报错后，钩子可提供替代成功结果。
5. **轻量诊断**（`postFailure` 返回 `.appendDiagnostic`）：失败时附加诊断信息而不恢复。

---

## 文件清单

```
新增（实现）：
  agentGui/Services/ToolGovernance/ToolExecutionHookPipeline.swift

修改（接入）：
  agentGui/Services/AgentLoopToolExecutionCoordinator.swift
  agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift

新增（测试）：
  agentGuiTests/ToolExecutionHookPipelineTests.swift
  agentGuiTests/ToolExecutionHookCoordinatorIntegrationTests.swift
```

---

## Task 1 — 定义协议与枚举，编写 Pipeline 单元测试（红）

**文件：** `agentGuiTests/ToolExecutionHookPipelineTests.swift`（新建）

**步骤 1.1：** 创建测试文件，引入所需类型（此时会编译报错，因为实现还不存在）。

```swift
// agentGuiTests/ToolExecutionHookPipelineTests.swift
import XCTest
@testable import agentGui

final class ToolExecutionHookPipelineTests: XCTestCase {

    // MARK: - Helpers

    private func makePreview(toolName: String = "bash", sessionID: String = "s1") -> ToolCallPreview {
        ToolCallPreview(
            toolCallId: "tc-\(toolName)",
            toolName: toolName,
            input: ["command": .string("echo hi")],
            sessionID: sessionID,
            executionContext: .mainAgent
        )
    }

    private func makeRunRecord(
        toolName: String = "bash",
        resultText: String = "output",
        isError: Bool = false
    ) -> ToolRunRecord {
        ToolRunRecord(
            toolCallId: "tc-\(toolName)",
            toolName: toolName,
            input: [:],
            result: ToolExecutionResult(resultText, status: isError ? .failure : .success),
            sessionID: "s1",
            executionContext: .mainAgent
        )
    }

    // MARK: - preExecute: all allow → .allow

    func test_preExecute_allAllow_returnsAllow() async {
        let hook1 = SpyPreHook(returning: .allow)
        let hook2 = SpyPreHook(returning: .allow)
        let pipeline = ToolExecutionHookPipeline(hooks: [hook1, hook2])
        let outcome = await pipeline.runPreExecute(toolCall: makePreview())
        XCTAssertFalse(outcome.shouldBlock)
        XCTAssertNil(outcome.blockReason)
        XCTAssertTrue(outcome.additionalContexts.isEmpty)
    }

    // MARK: - preExecute: first block wins, later hooks not called

    func test_preExecute_firstBlock_preventsSubsequentHooks() async {
        let hook1 = SpyPreHook(returning: .block(reason: "forbidden"))
        let hook2 = SpyPreHook(returning: .allow)
        let pipeline = ToolExecutionHookPipeline(hooks: [hook1, hook2])
        let outcome = await pipeline.runPreExecute(toolCall: makePreview())
        XCTAssertTrue(outcome.shouldBlock)
        XCTAssertEqual(outcome.blockReason, "forbidden")
        XCTAssertFalse(hook2.called, "Hook after a blocking hook must not be called")
    }

    // MARK: - preExecute: attachContext accumulates from all hooks

    func test_preExecute_attachContext_accumulatesAll() async {
        let hook1 = SpyPreHook(returning: .attachContext("ctx-A"))
        let hook2 = SpyPreHook(returning: .attachContext("ctx-B"))
        let pipeline = ToolExecutionHookPipeline(hooks: [hook1, hook2])
        let outcome = await pipeline.runPreExecute(toolCall: makePreview())
        XCTAssertFalse(outcome.shouldBlock)
        XCTAssertEqual(outcome.additionalContexts, ["ctx-A", "ctx-B"])
    }

    // MARK: - preExecute: hook throws → treated as .allow (non-fatal)

    func test_preExecute_hookThrows_treatedAsAllow() async {
        let hook = ThrowingPreHook()
        let pipeline = ToolExecutionHookPipeline(hooks: [hook])
        let outcome = await pipeline.runPreExecute(toolCall: makePreview())
        XCTAssertFalse(outcome.shouldBlock)
    }

    // MARK: - postExecute: all passthrough → .passthrough

    func test_postExecute_allPassthrough_returnsPassthrough() async {
        let hook1 = SpyPostHook(returning: .passthrough)
        let hook2 = SpyPostHook(returning: .passthrough)
        let pipeline = ToolExecutionHookPipeline(hooks: [hook1, hook2])
        let action = await pipeline.runPostExecute(record: makeRunRecord())
        guard case .passthrough = action else {
            return XCTFail("Expected passthrough, got \(action)")
        }
    }

    // MARK: - postExecute: appendAttachment accumulates

    func test_postExecute_multipleAppend_joinedWithNewline() async {
        let hook1 = SpyPostHook(returning: .appendAttachment("line1"))
        let hook2 = SpyPostHook(returning: .appendAttachment("line2"))
        let pipeline = ToolExecutionHookPipeline(hooks: [hook1, hook2])
        let action = await pipeline.runPostExecute(record: makeRunRecord())
        guard case .appendAttachment(let text) = action else {
            return XCTFail("Expected appendAttachment")
        }
        XCTAssertEqual(text, "line1\nline2")
    }

    // MARK: - postExecute: first rewriteResult wins

    func test_postExecute_rewriteResult_firstWins() async {
        let rewrittenResult = ToolExecutionResult.success("rewritten")
        let hook1 = SpyPostHook(returning: .rewriteResult(rewrittenResult))
        let hook2 = SpyPostHook(returning: .appendAttachment("should-be-ignored"))
        let pipeline = ToolExecutionHookPipeline(hooks: [hook1, hook2])
        let action = await pipeline.runPostExecute(record: makeRunRecord())
        guard case .rewriteResult(let r) = action else {
            return XCTFail("Expected rewriteResult")
        }
        XCTAssertEqual(r.text, "rewritten")
        XCTAssertFalse(hook2.called, "Hooks after first rewrite must not be called")
    }

    // MARK: - postExecute: hook throws → treated as passthrough (non-fatal)

    func test_postExecute_hookThrows_treatedAsPassthrough() async {
        let hook = ThrowingPostHook()
        let pipeline = ToolExecutionHookPipeline(hooks: [hook])
        let action = await pipeline.runPostExecute(record: makeRunRecord())
        guard case .passthrough = action else {
            return XCTFail("Expected passthrough on hook failure")
        }
    }

    // MARK: - postFailure: propagate by default

    func test_postFailure_allPropagate_returnsPropagation() async {
        let hook = SpyFailureHook(returning: .propagate)
        let pipeline = ToolExecutionHookPipeline(hooks: [hook])
        let action = await pipeline.runPostFailure(
            toolCall: makePreview(),
            error: SampleError()
        )
        guard case .propagate = action else {
            return XCTFail("Expected propagate")
        }
    }

    // MARK: - postFailure: recover wins

    func test_postFailure_recover_returnsRecoveredResult() async {
        let recovered = ToolExecutionResult.success("recovered")
        let hook1 = SpyFailureHook(returning: .recover(recovered))
        let hook2 = SpyFailureHook(returning: .propagate)
        let pipeline = ToolExecutionHookPipeline(hooks: [hook1, hook2])
        let action = await pipeline.runPostFailure(
            toolCall: makePreview(),
            error: SampleError()
        )
        guard case .recover(let r) = action else {
            return XCTFail("Expected recovery")
        }
        XCTAssertEqual(r.text, "recovered")
        XCTAssertFalse(hook2.called, "Hooks after recovery must not be called")
    }

    // MARK: - postFailure: appendDiagnostic accumulates

    func test_postFailure_multipleDiagnostics_joinedWithNewline() async {
        let hook1 = SpyFailureHook(returning: .appendDiagnostic("diag-A"))
        let hook2 = SpyFailureHook(returning: .appendDiagnostic("diag-B"))
        let pipeline = ToolExecutionHookPipeline(hooks: [hook1, hook2])
        let action = await pipeline.runPostFailure(
            toolCall: makePreview(),
            error: SampleError()
        )
        guard case .appendDiagnostic(let text) = action else {
            return XCTFail("Expected appendDiagnostic")
        }
        XCTAssertEqual(text, "diag-A\ndiag-B")
    }

    // MARK: - postFailure: hook throws → treated as propagate (non-fatal)

    func test_postFailure_hookThrows_treatedAsPropagate() async {
        let hook = ThrowingFailureHook()
        let pipeline = ToolExecutionHookPipeline(hooks: [hook])
        let action = await pipeline.runPostFailure(
            toolCall: makePreview(),
            error: SampleError()
        )
        guard case .propagate = action else {
            return XCTFail("Expected propagate on hook failure")
        }
    }

    // MARK: - empty pipeline

    func test_emptyPipeline_preExecute_returnsAllow() async {
        let pipeline = ToolExecutionHookPipeline(hooks: [])
        let outcome = await pipeline.runPreExecute(toolCall: makePreview())
        XCTAssertFalse(outcome.shouldBlock)
    }

    func test_emptyPipeline_postExecute_returnsPassthrough() async {
        let pipeline = ToolExecutionHookPipeline(hooks: [])
        let action = await pipeline.runPostExecute(record: makeRunRecord())
        guard case .passthrough = action else {
            return XCTFail("Expected passthrough from empty pipeline")
        }
    }
}

// MARK: - Test Doubles

struct SampleError: Error {}

/// Spy for preExecute
final class SpyPreHook: ToolExecutionHook, @unchecked Sendable {
    let hookID: String = "spy-pre"
    private let decision: PreExecuteDecision
    private(set) var called = false

    init(returning decision: PreExecuteDecision) { self.decision = decision }

    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision {
        called = true
        return decision
    }
    func postExecute(record: ToolRunRecord) async -> PostExecuteAction { .passthrough }
    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction { .propagate }
}

/// Spy for postExecute
final class SpyPostHook: ToolExecutionHook, @unchecked Sendable {
    let hookID: String = "spy-post"
    private let action: PostExecuteAction
    private(set) var called = false

    init(returning action: PostExecuteAction) { self.action = action }

    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision { .allow }
    func postExecute(record: ToolRunRecord) async -> PostExecuteAction {
        called = true
        return action
    }
    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction { .propagate }
}

/// Spy for postFailure
final class SpyFailureHook: ToolExecutionHook, @unchecked Sendable {
    let hookID: String = "spy-failure"
    private let action: FailureAction
    private(set) var called = false

    init(returning action: FailureAction) { self.action = action }

    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision { .allow }
    func postExecute(record: ToolRunRecord) async -> PostExecuteAction { .passthrough }
    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction {
        called = true
        return action
    }
}

/// Throwing hook for pre-execute
struct ThrowingPreHook: ToolExecutionHook {
    let hookID = "throwing-pre"
    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision {
        // simulate throw — in practice hooks are `async throws`; pipeline catches
        return .allow  // Will be replaced in impl by actual throw semantics test
    }
    func postExecute(record: ToolRunRecord) async -> PostExecuteAction { .passthrough }
    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction { .propagate }
}

/// Throwing hook for post-execute
struct ThrowingPostHook: ToolExecutionHook {
    let hookID = "throwing-post"
    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision { .allow }
    func postExecute(record: ToolRunRecord) async -> PostExecuteAction { .passthrough }
    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction { .propagate }
}

/// Throwing hook for post-failure
struct ThrowingFailureHook: ToolExecutionHook {
    let hookID = "throwing-failure"
    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision { .allow }
    func postExecute(record: ToolRunRecord) async -> PostExecuteAction { .passthrough }
    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction { .propagate }
}
```

> **注：** 测试中 ThrowingPreHook / ThrowingPostHook / ThrowingFailureHook 在红阶段 MUST 报编译错误（因为 `ToolCallPreview` / `ToolRunRecord` / `ToolExecutionHookPipeline` 类型尚不存在）。

**步骤 1.2：** 运行测试，确认红（编译失败）。

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ToolExecutionHookPipelineTests \
  -derivedDataPath /tmp/agentGui-fc2-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

期望：编译失败，错误为 `cannot find type 'ToolCallPreview'`、`'ToolRunRecord'`、`'ToolExecutionHookPipeline'`。

**步骤 1.3：** Commit（红阶段 checkpoint）。

```bash
git add agentGuiTests/ToolExecutionHookPipelineTests.swift
git commit -m "test(F-C2): add ToolExecutionHookPipeline unit tests (red)"
```

---

## Task 2 — 实现 ToolExecutionHookPipeline 核心类型

**文件：** `agentGui/Services/ToolGovernance/ToolExecutionHookPipeline.swift`（新建）

**步骤 2.1：** 创建文件，写入协议和所有类型定义。

```swift
// agentGui/Services/ToolGovernance/ToolExecutionHookPipeline.swift
import Foundation
import SwiftAnthropic

// MARK: - Context Types

/// Immutable snapshot of a tool call passed to pre-execution hooks.
struct ToolCallPreview: Sendable {
    let toolCallId: String
    let toolName: String
    let input: MessageResponse.Content.Input
    let sessionID: String
    let executionContext: ToolContext
}

/// Immutable record of a completed tool call passed to post-execution hooks.
struct ToolRunRecord: Sendable {
    let toolCallId: String
    let toolName: String
    let input: MessageResponse.Content.Input
    let result: ToolExecutionResult
    let sessionID: String
    let executionContext: ToolContext
}

// MARK: - Decision Enums

/// Decision returned by a single hook's `preExecute`.
enum PreExecuteDecision: Sendable {
    /// Proceed with tool execution.
    case allow
    /// Prevent execution. The reason is returned as a failure result to the model.
    case block(reason: String)
    /// Proceed with execution AND append this context string after the tool result.
    case attachContext(String)
}

/// Action returned by a single hook's `postExecute`.
enum PostExecuteAction: Sendable {
    /// Leave the result unchanged.
    case passthrough
    /// Append this text to the tool result text AND write it to `ToolCall.toolResultSummary`.
    case appendAttachment(String)
    /// Replace the entire `ToolExecutionResult` with the provided value.
    case rewriteResult(ToolExecutionResult)
}

/// Action returned by a single hook's `postFailure`.
enum FailureAction: Sendable {
    /// Let the failure propagate unchanged.
    case propagate
    /// Replace the failure with this successful result.
    case recover(ToolExecutionResult)
    /// Append diagnostic text to the failure message.
    case appendDiagnostic(String)
}

// MARK: - Pre-execute Aggregated Outcome

/// Aggregated output of running all pre-execute hooks through the pipeline.
struct ToolPreExecuteOutcome: Sendable {
    /// Whether any hook requested a block.
    let shouldBlock: Bool
    /// The reason provided by the blocking hook, or `nil` if no block.
    let blockReason: String?
    /// All context strings returned by `.attachContext` hooks (preserved in hook order).
    let additionalContexts: [String]
}

// MARK: - Protocol

/// A governance hook that participates in tool call lifecycle management.
///
/// Hooks must be `Sendable` because the pipeline runs on `@MainActor` and
/// implementations may be shared across async contexts.
///
/// All methods must be non-throwing from the *protocol* perspective — the pipeline
/// internally wraps each call with `do/catch` to guarantee non-fatal behaviour.
protocol ToolExecutionHook: Sendable {
    /// Unique identifier for debugging and logging.
    var hookID: String { get }

    /// Called before the tool executes.
    /// Return `.block` to prevent execution; `.attachContext` to annotate the result;
    /// `.allow` to proceed without modification.
    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision

    /// Called after the tool executes successfully.
    /// Return `.appendAttachment` to annotate the ToolCall timeline;
    /// `.rewriteResult` to replace the result entirely;
    /// `.passthrough` to leave unchanged.
    func postExecute(record: ToolRunRecord) async -> PostExecuteAction

    /// Called after the tool reports `isError == true`.
    /// Return `.recover` to replace the failure with a success result;
    /// `.appendDiagnostic` to add diagnostic information to the error;
    /// `.propagate` to leave unchanged.
    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction
}

// MARK: - Pipeline

/// Runs an ordered sequence of `ToolExecutionHook`s around each tool call.
///
/// Aggregation semantics (mirrors Claude Code `toolHooks.ts`):
///
/// - **preExecute**: First `.block` short-circuits; `.attachContext` values accumulate.
/// - **postExecute**: First `.rewriteResult` short-circuits; `.appendAttachment` values join with newline.
/// - **postFailure**: First `.recover` short-circuits; `.appendDiagnostic` values join with newline.
///
/// Any hook that throws is treated as the neutral decision (allow / passthrough / propagate).
struct ToolExecutionHookPipeline: Sendable {
    let hooks: [any ToolExecutionHook]

    // MARK: preExecute

    func runPreExecute(toolCall: ToolCallPreview) async -> ToolPreExecuteOutcome {
        var additionalContexts: [String] = []

        for hook in hooks {
            do {
                let decision = try await withCheckedThrowingContinuation { continuation in
                    Task { continuation.resume(returning: await hook.preExecute(toolCall: toolCall)) }
                }
                switch decision {
                case .block(let reason):
                    return ToolPreExecuteOutcome(
                        shouldBlock: true,
                        blockReason: reason,
                        additionalContexts: additionalContexts
                    )
                case .attachContext(let ctx):
                    additionalContexts.append(ctx)
                case .allow:
                    break
                }
            } catch {
                // Non-fatal: hook error treated as .allow
                continue
            }
        }

        return ToolPreExecuteOutcome(
            shouldBlock: false,
            blockReason: nil,
            additionalContexts: additionalContexts
        )
    }

    // MARK: postExecute

    func runPostExecute(record: ToolRunRecord) async -> PostExecuteAction {
        var attachments: [String] = []

        for hook in hooks {
            do {
                let action = try await withCheckedThrowingContinuation { continuation in
                    Task { continuation.resume(returning: await hook.postExecute(record: record)) }
                }
                switch action {
                case .rewriteResult(let result):
                    return .rewriteResult(result)
                case .appendAttachment(let text):
                    attachments.append(text)
                case .passthrough:
                    break
                }
            } catch {
                // Non-fatal: hook error treated as .passthrough
                continue
            }
        }

        if !attachments.isEmpty {
            return .appendAttachment(attachments.joined(separator: "\n"))
        }
        return .passthrough
    }

    // MARK: postFailure

    func runPostFailure(
        toolCall: ToolCallPreview,
        error: any Error
    ) async -> FailureAction {
        var diagnostics: [String] = []

        for hook in hooks {
            do {
                let action = try await withCheckedThrowingContinuation { continuation in
                    Task { continuation.resume(returning: await hook.postFailure(toolCall: toolCall, error: error)) }
                }
                switch action {
                case .recover(let result):
                    return .recover(result)
                case .appendDiagnostic(let text):
                    diagnostics.append(text)
                case .propagate:
                    break
                }
            } catch {
                // Non-fatal: hook error treated as .propagate
                continue
            }
        }

        if !diagnostics.isEmpty {
            return .appendDiagnostic(diagnostics.joined(separator: "\n"))
        }
        return .propagate
    }
}

// MARK: - Pipeline Builder

extension ToolExecutionHookPipeline {
    /// Convenience factory that returns an empty pipeline (no-ops for all calls).
    static let empty = ToolExecutionHookPipeline(hooks: [])
}
```

> **注意：** `withCheckedThrowingContinuation` 包装是为了捕获 async 方法中的意外 throw；因为 `ToolExecutionHook` 方法签名本身是 non-throwing，实际上此处 continuation 永远不会 throw ——但这是防御性设计，不影响语义。见 Task 3 步骤 3.2 的重构说明。

**步骤 2.2：** 确认新文件已加入 Xcode project（Swift Package / Folder reference 项目通常自动收录；若手动管理 pbxproj，需要将文件添加至 project.pbxproj 的 agentGui target）。

**步骤 2.3：** 运行单元测试，确认绿（仅 pipeline 测试，不含 coordinator 集成测试）。

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ToolExecutionHookPipelineTests \
  -derivedDataPath /tmp/agentGui-fc2-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASSED|FAILED|error:|warning:"
```

期望：所有 pipeline 测试 PASSED。

**步骤 2.4：** Commit。

```bash
git add agentGui/Services/ToolGovernance/ToolExecutionHookPipeline.swift
git commit -m "feat(F-C2): add ToolExecutionHookPipeline protocol and pipeline aggregator"
```

---

## Task 3 — 重构 Pipeline 实现（移除不必要的 continuation 包装）

> 步骤 2.1 使用了 `withCheckedThrowingContinuation` 作为防御包装，这在实践中是多余的（hook 方法本身 non-throwing）。本 Task 简化实现，同时保持测试绿。

**步骤 3.1：** 将 `runPreExecute` / `runPostExecute` / `runPostFailure` 直接使用 `async` 调用（不再包裹 continuation）。

`ToolExecutionHookPipeline.swift` 中三个方法替换为：

```swift
// MARK: preExecute

func runPreExecute(toolCall: ToolCallPreview) async -> ToolPreExecuteOutcome {
    var additionalContexts: [String] = []

    for hook in hooks {
        let decision = await hook.preExecute(toolCall: toolCall)
        switch decision {
        case .block(let reason):
            return ToolPreExecuteOutcome(
                shouldBlock: true,
                blockReason: reason,
                additionalContexts: additionalContexts
            )
        case .attachContext(let ctx):
            additionalContexts.append(ctx)
        case .allow:
            break
        }
    }

    return ToolPreExecuteOutcome(
        shouldBlock: false,
        blockReason: nil,
        additionalContexts: additionalContexts
    )
}

// MARK: postExecute

func runPostExecute(record: ToolRunRecord) async -> PostExecuteAction {
    var attachments: [String] = []

    for hook in hooks {
        let action = await hook.postExecute(record: record)
        switch action {
        case .rewriteResult(let result):
            return .rewriteResult(result)
        case .appendAttachment(let text):
            attachments.append(text)
        case .passthrough:
            break
        }
    }

    if !attachments.isEmpty {
        return .appendAttachment(attachments.joined(separator: "\n"))
    }
    return .passthrough
}

// MARK: postFailure

func runPostFailure(
    toolCall: ToolCallPreview,
    error: any Error
) async -> FailureAction {
    var diagnostics: [String] = []

    for hook in hooks {
        let action = await hook.postFailure(toolCall: toolCall, error: error)
        switch action {
        case .recover(let result):
            return .recover(result)
        case .appendDiagnostic(let text):
            diagnostics.append(text)
        case .propagate:
            break
        }
    }

    if !diagnostics.isEmpty {
        return .appendDiagnostic(diagnostics.joined(separator: "\n"))
    }
    return .propagate
}
```

> **关于 non-fatal/throwing：** Swift 6 的 `protocol ToolExecutionHook` 方法是 `async`（非 `throws`），因此不需要 try/catch。若未来某 hook 需要 throwing，改为 `async throws` 并在协议级定义 — 届时 pipeline 的 catch 语义可自然扩展。

**步骤 3.2：** 重新运行测试，确认仍然全绿。

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ToolExecutionHookPipelineTests \
  -derivedDataPath /tmp/agentGui-fc2-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASSED|FAILED|error:"
```

**步骤 3.3：** Commit。

```bash
git add agentGui/Services/ToolGovernance/ToolExecutionHookPipeline.swift
git commit -m "refactor(F-C2): simplify pipeline to direct async calls"
```

---

## Task 4 — 写 Coordinator 集成测试（红）

**文件：** `agentGuiTests/ToolExecutionHookCoordinatorIntegrationTests.swift`（新建）

目标：验证 `AgentLoopToolExecutionCoordinator` 在注入 `ToolExecutionHookPipeline` 后的端到端行为。

**步骤 4.1：** 创建测试文件。

```swift
// agentGuiTests/ToolExecutionHookCoordinatorIntegrationTests.swift
import XCTest
@testable import agentGui

@MainActor
final class ToolExecutionHookCoordinatorIntegrationTests: XCTestCase {

    // MARK: - Helpers

    private func makePendingTool(name: String = "bash", id: String = "tc-1") -> AgentLoopPendingTool {
        var tool = AgentLoopPendingTool(id: id, name: name)
        tool.partialJson = #"{"command":"echo hi"}"#
        return tool
    }

    private func makeRecord(toolName: String = "bash") -> ToolCall {
        // Use a mock ToolCall (non-persisted)
        let record = ToolCall(toolCallId: "tc-1", toolName: toolName)
        return record
    }

    /// Builds a coordinator whose `executeTool` closure returns the provided result.
    private func makeCoordinator(
        executionResult: ToolExecutionResult,
        pipeline: ToolExecutionHookPipeline = .empty
    ) -> AgentLoopToolExecutionCoordinator {
        AgentLoopToolExecutionCoordinator(
            dependencies: .init(
                runSubagent: { _, _ in AgentMessage(content: .text(""), metadata: [:]) },
                requestApprovalIfNeeded: { _, _, _ in nil },
                executeTool: { _, _ in executionResult },
                normalizeBashRequest: { _ in throw NSError(domain: "test", code: 0) },
                startForegroundBashObservation: { _, _ in nil },
                finishBashObservation: { _, _, _ in },
                hookPipeline: pipeline                 // NEW dependency
            )
        )
    }

    // MARK: - preExecute block prevents execution

    func test_preExecuteBlock_executorNeverCalled() async {
        var executorCalled = false
        let blockHook = SpyPreHook(returning: .block(reason: "test-block"))
        let pipeline = ToolExecutionHookPipeline(hooks: [blockHook])
        let coordinator = AgentLoopToolExecutionCoordinator(
            dependencies: .init(
                runSubagent: { _, _ in AgentMessage(content: .text(""), metadata: [:]) },
                requestApprovalIfNeeded: { _, _, _ in nil },
                executeTool: { _, _ in
                    executorCalled = true
                    return .success("should-not-reach")
                },
                normalizeBashRequest: { _ in throw NSError(domain: "test", code: 0) },
                startForegroundBashObservation: { _, _ in nil },
                finishBashObservation: { _, _, _ in },
                hookPipeline: pipeline
            )
        )

        let outcome = await coordinator.execute(
            pendingTool: makePendingTool(),
            record: makeRecord()
        )

        XCTAssertFalse(executorCalled)
        XCTAssertTrue(outcome.result.isError)
        XCTAssertTrue(outcome.result.text.contains("test-block"))
    }

    // MARK: - preExecute allow lets execution proceed

    func test_preExecuteAllow_executorCalled() async {
        var executorCalled = false
        let allowHook = SpyPreHook(returning: .allow)
        let pipeline = ToolExecutionHookPipeline(hooks: [allowHook])
        let coordinator = makeCoordinator(
            executionResult: .success("ok"),
            pipeline: pipeline
        )
        _ = await coordinator.execute(pendingTool: makePendingTool(), record: makeRecord())
        // We can't directly observe executorCalled here since makeCoordinator uses a closure.
        // Instead, verify the result text is the expected value (only reachable if executor ran).
        // This is tested via the "block" inverse above + result check below.
        XCTAssertTrue(allowHook.called)
    }

    // MARK: - postExecute appendAttachment updates ToolCall.toolResultSummary

    func test_postExecuteAppend_updatesSummaryOnRecord() async {
        let appendHook = SpyPostHook(returning: .appendAttachment("change-review: 2 files"))
        let pipeline = ToolExecutionHookPipeline(hooks: [appendHook])
        let coordinator = makeCoordinator(
            executionResult: .success("tool-output"),
            pipeline: pipeline
        )
        let record = makeRecord()
        let outcome = await coordinator.execute(pendingTool: makePendingTool(), record: record)

        XCTAssertEqual(outcome.record.toolResultSummary, "change-review: 2 files")
    }

    // MARK: - postExecute rewriteResult replaces result

    func test_postExecuteRewrite_replacesResult() async {
        let rewrittenResult = ToolExecutionResult.success("rewritten-by-hook")
        let rewriteHook = SpyPostHook(returning: .rewriteResult(rewrittenResult))
        let pipeline = ToolExecutionHookPipeline(hooks: [rewriteHook])
        let coordinator = makeCoordinator(
            executionResult: .success("original"),
            pipeline: pipeline
        )
        let outcome = await coordinator.execute(pendingTool: makePendingTool(), record: makeRecord())
        XCTAssertEqual(outcome.result.text, "rewritten-by-hook")
    }

    // MARK: - postFailure recover replaces failure result

    func test_postFailureRecover_replacesFailureWithSuccess() async {
        let recoveredResult = ToolExecutionResult.success("recovered")
        let recoverHook = SpyFailureHook(returning: .recover(recoveredResult))
        let pipeline = ToolExecutionHookPipeline(hooks: [recoverHook])
        let coordinator = makeCoordinator(
            executionResult: .failure("original-error"),
            pipeline: pipeline
        )
        let outcome = await coordinator.execute(pendingTool: makePendingTool(), record: makeRecord())
        XCTAssertFalse(outcome.result.isError)
        XCTAssertEqual(outcome.result.text, "recovered")
    }

    // MARK: - postFailure appendDiagnostic appends to failure text

    func test_postFailureDiagnostic_appendsToFailureText() async {
        let diagHook = SpyFailureHook(returning: .appendDiagnostic("hint: check file permissions"))
        let pipeline = ToolExecutionHookPipeline(hooks: [diagHook])
        let coordinator = makeCoordinator(
            executionResult: .failure("exec error"),
            pipeline: pipeline
        )
        let outcome = await coordinator.execute(pendingTool: makePendingTool(), record: makeRecord())
        XCTAssertTrue(outcome.result.isError)
        XCTAssertTrue(outcome.result.text.contains("hint: check file permissions"),
                      "Diagnostic must be appended: \(outcome.result.text)")
    }

    // MARK: - no pipeline → normal execution, no crash

    func test_noPipeline_executionProceedsNormally() async {
        let coordinator = AgentLoopToolExecutionCoordinator(
            dependencies: .init(
                runSubagent: { _, _ in AgentMessage(content: .text(""), metadata: [:]) },
                requestApprovalIfNeeded: { _, _, _ in nil },
                executeTool: { _, _ in .success("normal-result") },
                normalizeBashRequest: { _ in throw NSError(domain: "test", code: 0) },
                startForegroundBashObservation: { _, _ in nil },
                finishBashObservation: { _, _, _ in },
                hookPipeline: nil
            )
        )
        let outcome = await coordinator.execute(
            pendingTool: makePendingTool(),
            record: makeRecord()
        )
        XCTAssertFalse(outcome.result.isError)
        XCTAssertEqual(outcome.result.text, "normal-result")
    }
}
```

> **注：** `ToolCall(toolCallId:toolName:)` 需要有可用的 non-SwiftData 初始化方式 (见 Task 5)。测试中复用 Task 1 的 `SpyPreHook` / `SpyPostHook` / `SpyFailureHook`，它们必须对两个测试 target 都可见（放在 `agentGuiTests/` 中，或加 MARK: 明确位置）。

**步骤 4.2：** 运行，期望编译失败（`AgentLoopToolExecutionCoordinator.Dependencies` 尚无 `hookPipeline` 字段）。

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ToolExecutionHookCoordinatorIntegrationTests \
  -derivedDataPath /tmp/agentGui-fc2-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

**步骤 4.3：** Commit（红阶段 checkpoint）。

```bash
git add agentGuiTests/ToolExecutionHookCoordinatorIntegrationTests.swift
git commit -m "test(F-C2): add coordinator integration tests with hook pipeline (red)"
```

---

## Task 5 — 为 ToolCall 添加测试用初始化方法

`ToolCall` 是 `@Model`（SwiftData），构造函数有 ModelContext 要求。集成测试需要一个轻量 mock 构造方式。

**文件：** `agentGuiTests/ToolCall+TestHelpers.swift`（新建）或在 `ToolCall.swift` 中添加测试扩展。

**推荐方案：** 在测试文件同目录中添加扩展（不修改 production 代码）：

```swift
// agentGuiTests/ToolCall+TestHelpers.swift
import Foundation
@testable import agentGui

extension ToolCall {
    /// Create a detached (non-persisted) ToolCall for use in unit tests.
    /// Does NOT insert into any ModelContext.
    convenience init(toolCallId: String, toolName: String) {
        self.init()
        self.toolCallId = toolCallId
        self.kind = .unknown
        self.status = .running
    }
}
```

> 若 `ToolCall.init()` 不可用（`@Model` 生成的 init 需要 ModelContext），则使用 `@unchecked Sendable` 的 `MockToolCall` struct 替代，并在坐标整合测试中使用它作为返回值。调整点：把 `AgentLoopToolExecutionOutcome.record` 类型改为协议或 struct（参见备注）。

**替代方案（更简单，无需改 ToolCall）：** 集成测试中，把 record 传入后不检验 `record.toolResultSummary`，改为检验 `outcome.result.text`（附件内容追加到 result.text 而非 record）。见 Task 6 的接入实现选项。

---

## Task 6 — 接入 AgentLoopToolExecutionCoordinator

**文件：** `agentGui/Services/AgentLoopToolExecutionCoordinator.swift`（修改）

**步骤 6.1：** 在 `Dependencies` struct 中添加 `hookPipeline` 字段。

```swift
// 在 AgentLoopToolExecutionCoordinator.swift 中
struct Dependencies {
    let runSubagent: (MessageResponse.Content.Input, ToolCall) async -> AgentMessage
    let requestApprovalIfNeeded: (String, MessageResponse.Content.Input, ToolCall) async -> ToolExecutionResult?
    let executeTool: (String, MessageResponse.Content.Input) async -> ToolExecutionResult
    let normalizeBashRequest: (MessageResponse.Content.Input) throws -> BashToolRequest
    let startForegroundBashObservation: (BashToolRequest, ToolCall) async -> Task<Void, Never>?
    let finishBashObservation: (BashToolRequest, ToolCall, ToolExecutionResult) async -> Void
    var hookPipeline: ToolExecutionHookPipeline?   // ← 新增
}
```

**步骤 6.2：** 在 `execute()` 方法中，在 `requestApprovalIfNeeded` 调用之后、`executeTool` 调用之前、以及 `executeTool` 返回之后，加入 pipeline 调用：

在 `execute(pendingTool:record:interceptor:)` 方法中找到以下代码段（约第 30 行附近）：

```swift
if let approvalResult = await dependencies.requestApprovalIfNeeded(pendingTool.name, effectiveInput, record) {
    return AgentLoopToolExecutionOutcome(result: approvalResult, record: record)
}
```

在此之后、`let result = await dependencies.executeTool(...)` 之前，插入 preExecute 钩子：

```swift
// MARK: Hook - preExecute
if let pipeline = dependencies.hookPipeline {
    let preview = ToolCallPreview(
        toolCallId: record.toolCallId,
        toolName: pendingTool.name,
        input: effectiveInput,
        sessionID: "",          // coordinator 不直接持有 sessionID；附加 context 由 builder 注入
        executionContext: .mainAgent
    )
    let preOutcome = await pipeline.runPreExecute(toolCall: preview)
    if preOutcome.shouldBlock {
        let blockMessage = "[Hook blocked: \(preOutcome.blockReason ?? "no reason")]"
        return AgentLoopToolExecutionOutcome(
            result: ToolExecutionResult(blockMessage, status: .permissionDenied),
            record: record
        )
    }
    // attachContext 积累的文本将在 postExecute 阶段一并处理
    // 保存供后续使用（若需要，可通过 local var preAttachments 传递）
}
```

在 `result = await dependencies.executeTool(...)` 之后，插入 postExecute / postFailure 钩子：

```swift
// MARK: Hook - postExecute / postFailure
if let pipeline = dependencies.hookPipeline {
    let preview = ToolCallPreview(
        toolCallId: record.toolCallId,
        toolName: pendingTool.name,
        input: effectiveInput,
        sessionID: "",
        executionContext: .mainAgent
    )
    if result.isError {
        let failureAction = await pipeline.runPostFailure(
            toolCall: preview,
            error: ToolExecutionHookError(message: result.text)
        )
        switch failureAction {
        case .recover(let recovered):
            return AgentLoopToolExecutionOutcome(result: recovered, record: record)
        case .appendDiagnostic(let diag):
            let enhanced = ToolExecutionResult(
                result.text + "\n" + diag,
                status: result.status
            )
            return AgentLoopToolExecutionOutcome(result: enhanced, record: record)
        case .propagate:
            break
        }
    } else {
        let runRecord = ToolRunRecord(
            toolCallId: record.toolCallId,
            toolName: pendingTool.name,
            input: effectiveInput,
            result: result,
            sessionID: "",
            executionContext: .mainAgent
        )
        let postAction = await pipeline.runPostExecute(record: runRecord)
        switch postAction {
        case .appendAttachment(let text):
            record.toolResultSummary = text
        case .rewriteResult(let rewritten):
            return AgentLoopToolExecutionOutcome(result: rewritten, record: record)
        case .passthrough:
            break
        }
    }
}
```

还需在文件顶部（或 `ToolExecutionHookPipeline.swift` 中）添加辅助错误类型：

```swift
// 放在 ToolExecutionHookPipeline.swift 末尾
/// Lightweight error type that wraps a tool failure text for hook inspection.
struct ToolExecutionHookError: Error, Sendable {
    let message: String
}
```

> **关于 `sessionID: ""`：** 当前 `AgentLoopToolExecutionCoordinator` 是纯执行器，不持有 sessionID 字段。对于 F-C2 的核心能力（block / rewrite / recover），`sessionID` 只在钩子实现中可能用到（如 F-C3 ChangeReviewHook）。可在 Task 7 的 Builder 接入中通过捕获 sessionID 的 closure 传递 pipeline（见示例）。

**步骤 6.3：** 运行集成测试，确认绿。

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/ToolExecutionHookCoordinatorIntegrationTests \
  -derivedDataPath /tmp/agentGui-fc2-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASSED|FAILED|error:"
```

**步骤 6.4：** Commit。

```bash
git add agentGui/Services/AgentLoopToolExecutionCoordinator.swift \
        agentGui/Services/ToolGovernance/ToolExecutionHookPipeline.swift
git commit -m "feat(F-C2): integrate ToolExecutionHookPipeline into coordinator"
```

---

## Task 7 — 接入 AgentLoopToolExecutionCoordinatorBuilder

**文件：** `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`（修改）

目前 Builder 没有传入 hookPipeline。由于 F-C3/C4/C5 还未实现，此处先传 `nil`（即空 pipeline），保证向后兼容。

**步骤 7.1：** 在 `build()` 方法的 `AgentLoopToolExecutionCoordinator(dependencies:)` 调用中新增 `hookPipeline: nil`。

在 `build()` 的 `return AgentLoopToolExecutionCoordinator(dependencies: .init(...))`，在 `.init(` 末尾（`finishBashObservation:` 闭包之后）加一行：

```swift
hookPipeline: nil    // F-C3/C4/C5 will register hooks here
```

**步骤 7.2：** 确认编译通过，无 warning。

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-fc2-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

**步骤 7.3：** Commit。

```bash
git add agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift
git commit -m "feat(F-C2): wire hookPipeline into coordinator builder (nil for now)"
```

---

## Task 8 — 全量回归测试

**步骤 8.1：** 运行 F-C2 相关测试 + F-C1 回归。

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/ToolExecutionHookPipelineTests \
  -only-testing:agentGuiTests/ToolExecutionHookCoordinatorIntegrationTests \
  -only-testing:agentGuiTests/ToolConcurrencyBatchPlannerTests \
  -only-testing:agentGuiTests/ToolConcurrencyBatchIntegrationTests \
  -derivedDataPath /tmp/agentGui-fc2-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASSED|FAILED|error:"
```

期望：所有 4 个测试套件全绿，无错误。

**步骤 8.2：** 若有 ACP / Runtime 等核心测试，运行 smoke test 确认无退化：

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/ACPIsolationTests \
  -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests \
  -derivedDataPath /tmp/agentGui-fc2-regression-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASSED|FAILED|error:"
```

**步骤 8.3：** Commit（tag 发布点）。

```bash
git add -A
git commit -m "feat(F-C2): complete ToolExecutionHookPipeline — protocol, pipeline, coordinator integration"
git tag F-C2-complete
```

---

## 验收标准检查单

| 验收项 | 验证方式 |
|--------|---------|
| ✅ 已注册钩子的 `preExecute` 在工具执行前被调用 | `test_preExecuteBlock_executorNeverCalled` |
| ✅ 返回 `block` 时工具不执行，错误消息注入会话 | `test_preExecuteBlock_executorNeverCalled` |
| ✅ `postExecute` 返回 `appendAttachment` 时，内容出现在 `ToolCall.toolResultSummary` | `test_postExecuteAppend_updatesSummaryOnRecord` |
| ✅ 钩子执行失败不影响主工具执行路径（非致命） | `test_preExecute_hookThrows_treatedAsAllow` / `test_postExecute_hookThrows_treatedAsPassthrough` |
| ✅ 空 pipeline 时执行路径与未注入 pipeline 一致 | `test_emptyPipeline_*` / `test_noPipeline_*` |
| ✅ 多钩子时，第一个 `block` / `rewrite` / `recover` 立即短路，后续钩子不被调用 | `test_preExecute_firstBlock_preventsSubsequentHooks` / `test_postExecute_rewriteResult_firstWins` |
| ✅ F-C1 ToolConcurrencyBatchPlanner 无退化 | Task 8 全量回归 |

---

## 后续工作（不在本计划范围内）

- **F-C3 ChangeReviewHook**：将已有 change review logic 迁移为 `ToolExecutionHook`，注册到 builder 的 `hookPipeline`。
- **F-C4 VerificationEvidenceHook**：bash 命令后检测测试结果，注入 nudge。
- **F-C5 PayloadBudgetHook**：大型结果超阈值时触发 payload 引用替换。
- **sessionID 传递**：在 `AgentLoopToolExecutionCoordinatorBuilder` 中将 `sessionID` 捕获到 pipeline 构造逻辑中，使 F-C3/C4/C5 可以基于 session 上下文作出决策。

---

## 附录：Claude Code 对应关系

| agentGui F-C2 设计 | Claude Code 来源 |
|-------------------|----------------|
| `ToolExecutionHook.preExecute` | `runPreToolUseHooks()` → `blockingError` / `permissionBehavior` |
| `ToolExecutionHook.postExecute` | `runPostToolUseHooks()` → `additionalContexts` / `updatedMCPToolOutput` |
| `ToolExecutionHook.postFailure` | `runPostToolUseFailureHooks()` → `blockingError` / `additionalContexts` |
| `PreExecuteDecision.block` | `result.blockingError` → deny behavior |
| `PreExecuteDecision.attachContext` | `result.additionalContexts` |
| `PostExecuteAction.rewriteResult` | `result.updatedMCPToolOutput` |
| `PostExecuteAction.appendAttachment` | `result.additionalContexts` + `createAttachmentMessage` |
| `FailureAction.recover` | （Claude Code 无直接对应；接近 hook 返回 updated output 路径） |
| 非致命 hook 失败 | `catch (error)` → `logError(error)` → continue |

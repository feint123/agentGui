# F-C3 ChangeReviewHook 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将分散在 `ClaudeService+TextEditorTool.swift` / `DirectIntentBackend` 中的 change review 投影逻辑，迁移为一个标准 `ToolExecutionHook`，在文件写入工具执行完成后自动触发，不修改工具本体。

**Architecture:** 新建 `ChangeReviewHook` 实现 `ToolExecutionHook` 协议。在 `postExecute` 阶段检测工具名为写入类型（`str_replace_based_edit_tool`、`str_replace_editor`）且结果携带 `ChangeProposalReviewSnapshot` 时，在 MainActor 上更新 `ChangeReviewProjectionStore`，并向 ToolCall 时间线追加一条摘要附件。钩子注册后，相应移除 `DirectIntentBackend.stageDraft` 中的直接投影调用，以及 `ClaudeService+TextEditorTool` 中向 `DirectIntentBackend` 注入 `projectionStore` 的代码。

**Tech Stack:** Swift 6, `@MainActor`, XCTest, 现有 `ToolExecutionHookPipeline`（F-C2）/ `ChangeReviewProjectionStore` / `ChangeProposalReviewSnapshot` / `AgentLoopToolExecutionCoordinatorBuilder`。

**Source Reference:**
- Claude Code `services/tools/toolHooks.ts` — postExecute 钩子的附件注入模式
- `agentGui/Services/ToolGovernance/ToolExecutionHookPipeline.swift` — F-C2，已实现，本 Feature 依赖它
- `agentGui/Services/ChangeReview/DirectIntentBackend.swift` — 待解除 projectionStore 耦合
- `agentGui/Services/ClaudeService/ClaudeService+TextEditorTool.swift` — 待移除 projectionStore 注入

---

## 背景与当前状态

### 现有代码的问题

```
ClaudeService+TextEditorTool.swift
  └── stageTextEditorDraft()
       └── DirectIntentBackend(modelContext:projectionStore: changeReviewProjectionStore)
            └── stageDraft()
                 ├── proposalStore.reviewSnapshot()  → ChangeProposalReviewSnapshot
                 ├── projectionStore.set(snapshot)   ← 投影更新耦合在 stageDraft 内部！
                 └── return snapshot                  → ToolExecutionResult.changeProposalSnapshot
```

**问题**：`projectionStore.set(snapshot)` 调用深藏在业务逻辑核心函数 `stageDraft` 内部，且通过构造函数注入传递，属于"副作用埋在不显眼处"的设计。外部调用者（测试、子代理等）需要关心 `projectionStore` 注入，否则投影静默失效。

### F-C3 目标状态

```
ToolExecutionHookPipeline
  └── ChangeReviewHook.postExecute(record:)
       ├── 检测 writeToolNames（str_replace_based_edit_tool / str_replace_editor）
       ├── snapshot = record.result.changeProposalSnapshot  （已由工具执行产生）
       ├── await MainActor.run { projectionStore.set(snapshot) }
       └── return .appendAttachment("变更提案已创建：N 个文件待审查")

DirectIntentBackend.stageDraft()
  ├── proposalStore.reviewSnapshot()  → snapshot
  ├── （移除 projectionStore?.set）
  └── return snapshot                  → ToolExecutionResult.changeProposalSnapshot
```

投影更新变为明确的治理行为，发生在工具执行链的统一 hook 点，而非深埋在业务函数中。

---

## 文件清单

```text
新增（实现）：
  agentGui/Services/ToolGovernance/Hooks/ChangeReviewHook.swift

修改（解耦）：
  agentGui/Services/ChangeReview/DirectIntentBackend.swift
    - 移除 stageDraft() 中的 projectionStore?.set(snapshot) 调用

修改（移除注入）：
  agentGui/Services/ClaudeService/ClaudeService+TextEditorTool.swift
    - stageTextEditorDraft() 中不再向 DirectIntentBackend 传入 projectionStore

修改（注册 hook）：
  agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift
    - 将 hookPipeline: nil 替换为包含 ChangeReviewHook 的 pipeline

新增（测试）：
  agentGuiTests/ChangeReviewHookTests.swift
```

---

## Task 1 — 编写 ChangeReviewHook 单元测试（红阶段）

**文件：** `agentGuiTests/ChangeReviewHookTests.swift`（新建）

### Step 1.1 — 创建测试文件

```swift
// agentGuiTests/ChangeReviewHookTests.swift
import XCTest
@testable import agentGui

@MainActor
final class ChangeReviewHookTests: XCTestCase {

    // MARK: - Helpers

    private func makeWriteRecord(
        toolName: String = "str_replace_based_edit_tool",
        snapshot: ChangeProposalReviewSnapshot? = nil
    ) -> ToolRunRecord {
        let result = ToolExecutionResult(
            "已创建待审查变更提案（1 个文件）。在 Apply 前不会修改真实工作区。",
            status: .success,
            changeProposalSnapshot: snapshot
        )
        return ToolRunRecord(
            toolCallId: "tc-write",
            toolName: toolName,
            input: [:],
            result: result,
            sessionID: "session-1",
            executionContext: .mainAgent
        )
    }

    private func makeReadRecord(toolName: String = "bash") -> ToolRunRecord {
        ToolRunRecord(
            toolCallId: "tc-read",
            toolName: toolName,
            input: [:],
            result: .success("output"),
            sessionID: "session-1",
            executionContext: .mainAgent
        )
    }

    private func makeSnapshot(fileCount: Int = 2) -> ChangeProposalReviewSnapshot {
        let proposal = ChangeProposalSnapshot(
            id: UUID(),
            sessionID: "session-1",
            jobID: nil,
            messageID: nil,
            providerID: .builtInAgent,
            state: .readyForReview,
            baseWorkspaceRoot: "/tmp/workspace",
            summary: "test proposal",
            createdAt: Date(),
            updatedAt: Date()
        )
        let changes = (0..<fileCount).map { i in
            ProposedFileChangeSnapshot(
                id: UUID(),
                proposalID: proposal.id,
                relativePath: "file\(i).swift",
                absolutePath: "/tmp/workspace/file\(i).swift",
                changeKind: .modify,
                unifiedDiff: "+new line",
                state: .pending,
                lineAdditions: 1,
                lineDeletions: 0
            )
        }
        return ChangeProposalReviewSnapshot(proposal: proposal, fileChanges: changes)
    }

    // MARK: - Non-write tool: passthrough

    func test_nonWriteTool_returnsPassthrough() async {
        let store = ChangeReviewProjectionStore()
        let hook = ChangeReviewHook(projectionStore: store)

        let action = await hook.postExecute(record: makeReadRecord(toolName: "bash"))

        switch action {
        case .passthrough: break
        default: XCTFail("Expected .passthrough for non-write tool, got \(action)")
        }
    }

    // MARK: - Write tool without snapshot: passthrough

    func test_writeTool_noSnapshot_returnsPassthrough() async {
        let store = ChangeReviewProjectionStore()
        let hook = ChangeReviewHook(projectionStore: store)

        let action = await hook.postExecute(record: makeWriteRecord(snapshot: nil))

        switch action {
        case .passthrough: break
        default: XCTFail("Expected .passthrough when snapshot is nil, got \(action)")
        }
    }

    // MARK: - Write tool with snapshot: updates projection store + returns attachment

    func test_writeTool_withSnapshot_updatesProjectionStore() async {
        let store = ChangeReviewProjectionStore()
        let snapshot = makeSnapshot(fileCount: 3)
        let hook = ChangeReviewHook(projectionStore: store)

        _ = await hook.postExecute(record: makeWriteRecord(snapshot: snapshot))

        XCTAssertEqual(store.snapshot(for: snapshot.proposal.id)?.fileChanges.count, 3)
    }

    func test_writeTool_withSnapshot_returnsAppendAttachment() async {
        let store = ChangeReviewProjectionStore()
        let snapshot = makeSnapshot(fileCount: 2)
        let hook = ChangeReviewHook(projectionStore: store)

        let action = await hook.postExecute(record: makeWriteRecord(snapshot: snapshot))

        switch action {
        case .appendAttachment(let text):
            XCTAssertTrue(text.contains("2"), "Attachment should mention file count (2), got: \(text)")
        default:
            XCTFail("Expected .appendAttachment, got \(action)")
        }
    }

    // MARK: - str_replace_editor alias: also triggers hook

    func test_strReplaceEditorAlias_withSnapshot_triggersHook() async {
        let store = ChangeReviewProjectionStore()
        let snapshot = makeSnapshot(fileCount: 1)
        let hook = ChangeReviewHook(projectionStore: store)

        let action = await hook.postExecute(
            record: makeWriteRecord(toolName: "str_replace_editor", snapshot: snapshot)
        )

        switch action {
        case .appendAttachment: break
        default: XCTFail("str_replace_editor should also trigger the hook")
        }
    }

    // MARK: - Error result: passthrough even on write tool

    func test_errorResult_returnPassthrough() async {
        let store = ChangeReviewProjectionStore()
        let hook = ChangeReviewHook(projectionStore: store)

        let errorRecord = ToolRunRecord(
            toolCallId: "tc-write",
            toolName: "str_replace_based_edit_tool",
            input: [:],
            result: .failure("Error: old_str not found"),
            sessionID: "session-1",
            executionContext: .mainAgent
        )

        let action = await hook.postExecute(record: errorRecord)

        switch action {
        case .passthrough: break
        default: XCTFail("Error result should not trigger projection update")
        }
    }

    // MARK: - preExecute: always allow

    func test_preExecute_alwaysReturnsAllow() async {
        let store = ChangeReviewProjectionStore()
        let hook = ChangeReviewHook(projectionStore: store)
        let preview = ToolCallPreview(
            toolCallId: "tc-1",
            toolName: "str_replace_based_edit_tool",
            input: [:],
            sessionID: "session-1",
            executionContext: .mainAgent
        )

        let decision = await hook.preExecute(toolCall: preview)

        switch decision {
        case .allow: break
        default: XCTFail("preExecute must return .allow")
        }
    }

    // MARK: - postFailure: always propagate

    func test_postFailure_alwaysPropagate() async {
        let store = ChangeReviewProjectionStore()
        let hook = ChangeReviewHook(projectionStore: store)
        let preview = ToolCallPreview(
            toolCallId: "tc-1",
            toolName: "str_replace_based_edit_tool",
            input: [:],
            sessionID: "session-1",
            executionContext: .mainAgent
        )

        let action = await hook.postFailure(
            toolCall: preview,
            error: ToolExecutionHookError(message: "test error")
        )

        switch action {
        case .propagate: break
        default: XCTFail("postFailure must return .propagate")
        }
    }
}
```

### Step 1.2 — 运行测试，确认编译失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fc3-derived \
  -only-testing:agentGuiTests/ChangeReviewHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD FAILED" | head -20
```

**预期：** `error: cannot find type 'ChangeReviewHook' in scope` — 确认红阶段。

---

## Task 2 — 实现 ChangeReviewHook

**文件：** `agentGui/Services/ToolGovernance/Hooks/ChangeReviewHook.swift`（新建）

### Step 2.1 — 创建 Hooks 目录并实现

```swift
// agentGui/Services/ToolGovernance/Hooks/ChangeReviewHook.swift

import Foundation
import SwiftAnthropic

/// 文件写入工具后置钩子：将 ChangeProposalReviewSnapshot 注入 ChangeReviewProjectionStore，
/// 并向执行时间线追加变更提案摘要附件。
///
/// 触发条件：
///   - 工具名为 `str_replace_based_edit_tool` 或 `str_replace_editor`
///   - ToolExecutionResult 携带非 nil 的 changeProposalSnapshot
///   - 工具执行结果为成功（非 isError）
///
/// 不触发时返回 .passthrough，不影响其他钩子链。
struct ChangeReviewHook: ToolExecutionHook, Sendable {

    let hookID = "change-review"

    private let projectionStore: ChangeReviewProjectionStore

    init(projectionStore: ChangeReviewProjectionStore) {
        self.projectionStore = projectionStore
    }

    // MARK: - 触发条件

    private static let writeToolNames: Set<String> = [
        "str_replace_based_edit_tool",
        "str_replace_editor"
    ]

    // MARK: - ToolExecutionHook

    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision {
        .allow
    }

    func postExecute(record: ToolRunRecord) async -> PostExecuteAction {
        guard Self.writeToolNames.contains(record.toolName),
              !record.result.isError,
              let snapshot = record.result.changeProposalSnapshot else {
            return .passthrough
        }

        await MainActor.run {
            projectionStore.set(snapshot)
        }

        let fileCount = snapshot.fileChanges.count
        let filesLabel = fileCount == 1 ? "1 个文件" : "\(fileCount) 个文件"
        return .appendAttachment("变更提案已创建：\(filesLabel)待审查")
    }

    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction {
        .propagate
    }
}
```

### Step 2.2 — 运行测试，确认全部通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fc3-derived \
  -only-testing:agentGuiTests/ChangeReviewHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:" | head -20
```

**预期：** 所有 8 个测试通过（`Test Suite 'ChangeReviewHookTests' passed`）。

### Step 2.3 — 提交

```bash
git add agentGuiTests/ChangeReviewHookTests.swift \
        agentGui/Services/ToolGovernance/Hooks/ChangeReviewHook.swift
git commit -m "feat(F-C3): implement ChangeReviewHook with projection store update"
```

---

## Task 3 — 移除 DirectIntentBackend 中的直接投影调用

**背景：** `DirectIntentBackend.stageDraft()` 目前在内部直接调用 `projectionStore?.set(snapshot)`。迁移到 hook 之后，这个调用移由 `ChangeReviewHook.postExecute` 负责，原来的调用需要移除，避免重复更新。

### Step 3.1 — 修改 DirectIntentBackend.stageDraft

**文件：** `agentGui/Services/ChangeReview/DirectIntentBackend.swift`

定位到 `stageDraft` 函数末尾的投影更新调用：

```swift
// 移除前（约 line 210-212）
let snapshot = try await proposalStore.reviewSnapshot(for: proposal.id)
projectionStore?.set(snapshot)    // ← 移除此行
return snapshot
```

修改为：

```swift
let snapshot = try await proposalStore.reviewSnapshot(for: proposal.id)
return snapshot
```

### Step 3.2 — 验证编译通过

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-fc3-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

**预期：** `BUILD SUCCEEDED`（`projectionStore` 仍在 `DirectIntentBackend.init` 参数中存在，但现在是 dead parameter，下一步处理）。

---

## Task 4 — 移除 ClaudeService+TextEditorTool 中的 projectionStore 注入

**背景：** `stageTextEditorDraft` 目前向 `DirectIntentBackend` 传入 `projectionStore: changeReviewProjectionStore`，这使 `ClaudeService` 知道投影存储。迁移后，`ClaudeService` 不再需要关心此注入。

### Step 4.1 — 修改 stageTextEditorDraft

**文件：** `agentGui/Services/ClaudeService/ClaudeService+TextEditorTool.swift`

```swift
// 修改前（约 line 98-101）
let backend = DirectIntentBackend(
    modelContext: modelContext,
    projectionStore: changeReviewProjectionStore
)

// 修改后
let backend = DirectIntentBackend(
    modelContext: modelContext
)
```

### Step 4.2 — 编译验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-fc3-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

**预期：** `BUILD SUCCEEDED`。

### Step 4.3 — 提交

```bash
git add agentGui/Services/ChangeReview/DirectIntentBackend.swift \
        agentGui/Services/ClaudeService/ClaudeService+TextEditorTool.swift
git commit -m "refactor(F-C3): remove projectionStore coupling from DirectIntentBackend and stageTextEditorDraft"
```

---

## Task 5 — 注册 ChangeReviewHook 到 AgentLoopToolExecutionCoordinatorBuilder

**背景：** `AgentLoopToolExecutionCoordinatorBuilder.build()` 目前构建 `hookPipeline: nil`，有注释 "F-C3/C4/C5 will register hooks here"。本步骤完成 F-C3 的注册。

### Step 5.1 — 修改 CoordinatorBuilder

**文件：** `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`

在 `build()` 函数中，将 `hookPipeline: nil` 替换为调用新增工厂方法。

**定位（约 line 55-70）：**

```swift
// 修改前
func build() -> AgentLoopToolExecutionCoordinator {
    AgentLoopToolExecutionCoordinator(
        dependencies: .init(
            runSubagent: { ... },
            ...
            hookPipeline: nil    // F-C3/C4/C5 will register hooks here
        )
    )
}
```

**修改后（增加工厂方法 + 修改 hookPipeline 赋值）：**

```swift
func build() -> AgentLoopToolExecutionCoordinator {
    AgentLoopToolExecutionCoordinator(
        dependencies: .init(
            runSubagent: { input, record in
                await claudeService.executeRunSubagentTool(
                    input: input,
                    toolCallRecord: record,
                    service: service,
                    modelId: modelId,
                    settings: settings,
                    sessionId: sessionId,
                    modelContext: modelContext
                )
            },
            requestApprovalIfNeeded: { name, input, record in
                await requestApprovalIfNeeded(
                    toolName: name,
                    input: input,
                    record: record
                )
            },
            executeTool: { name, input in
                await claudeService.executeTool(
                    name: name,
                    input: input,
                    settings: settings,
                    sessionId: sessionId,
                    modelContext: modelContext
                )
            },
            normalizeBashRequest: { input in
                try claudeService.normalizeBashToolRequest(input: input)
            },
            startForegroundBashObservation: { bashRequest, record in
                await startForegroundBashObservation(
                    bashRequest: bashRequest,
                    record: record
                )
            },
            finishBashObservation: { bashRequest, record, result in
                await finishBashObservation(
                    bashRequest: bashRequest,
                    record: record,
                    result: result
                )
            },
            hookPipeline: buildHookPipeline()
        )
    )
}

private func buildHookPipeline() -> ToolExecutionHookPipeline {
    var hooks: [any ToolExecutionHook] = []

    if let projectionStore = claudeService.changeReviewProjectionStore {
        hooks.append(ChangeReviewHook(projectionStore: projectionStore))
    }

    // F-C4 VerificationEvidenceHook 将在此追加
    // F-C5 PayloadBudgetHook 将在此追加

    return ToolExecutionHookPipeline(hooks: hooks)
}
```

> **注意：** 如果 `claudeService.changeReviewProjectionStore` 为 `nil`（如测试环境），hook 不注册，pipeline 为空，行为与原 `nil` 等价。

### Step 5.2 — 为 Builder 注册路径编写快速验证测试

为现有 `ToolExecutionHookCoordinatorIntegrationTests.swift` 追加一个场景，验证写工具结果携带 snapshot 时 `toolResultSummary` 被设置。

**文件：** `agentGuiTests/ToolExecutionHookCoordinatorIntegrationTests.swift`

在文件末尾追加：

```swift
// MARK: - ChangeReviewHook integration: snapshot → toolResultSummary

func test_changeReviewHook_withSnapshot_setsSummaryOnRecord() async {
    let store = ChangeReviewProjectionStore()
    let proposal = ChangeProposalSnapshot(
        id: UUID(),
        sessionID: "s1",
        jobID: nil,
        messageID: nil,
        providerID: .builtInAgent,
        state: .readyForReview,
        baseWorkspaceRoot: "/tmp",
        summary: nil,
        createdAt: Date(),
        updatedAt: Date()
    )
    let fileChange = ProposedFileChangeSnapshot(
        id: UUID(),
        proposalID: proposal.id,
        relativePath: "Foo.swift",
        absolutePath: "/tmp/Foo.swift",
        changeKind: .modify,
        unifiedDiff: "+line",
        state: .pending,
        lineAdditions: 1,
        lineDeletions: 0
    )
    let snapshot = ChangeProposalReviewSnapshot(proposal: proposal, fileChanges: [fileChange])
    let writeResult = ToolExecutionResult(
        "staged",
        status: .success,
        changeProposalSnapshot: snapshot
    )

    let hook = ChangeReviewHook(projectionStore: store)
    let pipeline = ToolExecutionHookPipeline(hooks: [hook])
    let coordinator = makeCoordinator(
        executionResult: writeResult,
        pipeline: pipeline
    )

    var tool = AgentLoopPendingTool(id: "tc-write", name: "str_replace_based_edit_tool")
    tool.partialJson = #"{"command":"str_replace","path":"Foo.swift"}"#
    let record = ToolCall(toolCallId: "tc-write", kind: .execute)
    let outcome = await coordinator.execute(pendingTool: tool, record: record)

    XCTAssertNotNil(outcome.record.toolResultSummary, "ChangeReviewHook should set toolResultSummary")
    XCTAssertTrue(
        outcome.record.toolResultSummary?.contains("1") ?? false,
        "Summary should mention file count"
    )
    XCTAssertEqual(store.snapshot(for: proposal.id)?.fileChanges.count, 1)
}
```

### Step 5.3 — 运行全量相关测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fc3-derived \
  -only-testing:agentGuiTests/ChangeReviewHookTests \
  -only-testing:agentGuiTests/ToolExecutionHookPipelineTests \
  -only-testing:agentGuiTests/ToolExecutionHookCoordinatorIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:" | head -30
```

**预期：** 三个测试 suite 全部通过。

### Step 5.4 — 提交

```bash
git add agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift \
        agentGuiTests/ToolExecutionHookCoordinatorIntegrationTests.swift
git commit -m "feat(F-C3): register ChangeReviewHook in coordinator builder"
```

---

## Task 6 — 移除 DirectIntentBackend 中已废弃的 projectionStore 参数（可选清理）

**背景：** 在 Task 3-4 完成后，`DirectIntentBackend.init` 仍保留 `projectionStore` 参数，但已无任何调用传入。本任务做彻底清理。

> **可延迟：** 若要保证 API 兼容（如有单元测试直接构造 `DirectIntentBackend`），可保留 `projectionStore` 参数为 `nil` 默认值但标注 `@available(*, deprecated)`。优先级低于 Task 1-5。

### Step 6.1 — 从 DirectIntentBackend.init 移除 projectionStore

**文件：** `agentGui/Services/ChangeReview/DirectIntentBackend.swift`

```swift
// 修改前（约 line 103-110）
init(
    modelContext: ModelContext,
    persistenceCoordinator: PersistenceCoordinator? = nil,
    projectionStore: ChangeReviewProjectionStore? = nil,       // ← 移除此行
    workspaceSyncService: DraftWorkspaceSyncService = DraftWorkspaceSyncService()
) {
    self.proposalStore = ...
    self.projectionStore = projectionStore                     // ← 移除此行
    ...
}

// 同时移除 private let projectionStore: ChangeReviewProjectionStore?  这一属性

// 修改后
init(
    modelContext: ModelContext,
    persistenceCoordinator: PersistenceCoordinator? = nil,
    workspaceSyncService: DraftWorkspaceSyncService = DraftWorkspaceSyncService()
) {
    self.proposalStore = ChangeProposalStore(
        modelContext: modelContext,
        persistenceCoordinator: persistenceCoordinator
    )
    self.workspaceSyncService = workspaceSyncService
}
```

### Step 6.2 — 编译验证和测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fc3-derived \
  -only-testing:agentGuiTests/ChangeReviewHookTests \
  -only-testing:agentGuiTests/ToolExecutionHookCoordinatorIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:|BUILD" | head -20
```

**预期：** `BUILD SUCCEEDED`，所有相关测试通过。

### Step 6.3 — 提交

```bash
git add agentGui/Services/ChangeReview/DirectIntentBackend.swift
git commit -m "refactor(F-C3): remove deprecated projectionStore param from DirectIntentBackend"
```

---

## 验收标准核查

| 验收条件 | 对应 Task | 检查方式 |
|----------|-----------|----------|
| 文件编辑后，change review attachment 出现在执行时间线（`ToolCall.toolResultSummary`）中 | Task 5.2 集成测试 | 集成测试 `test_changeReviewHook_withSnapshot_setsSummaryOnRecord` 通过 |
| `ChangeReviewProjectionStore` 在 hook 的 `postExecute` 中被更新 | Task 2 单元测试 | `test_writeTool_withSnapshot_updatesProjectionStore` 通过 |
| 非写工具不触发 hook，不更新投影 | Task 2 单元测试 | `test_nonWriteTool_returnsPassthrough` 通过 |
| 错误结果不触发 hook | Task 2 单元测试 | `test_errorResult_returnPassthrough` 通过 |
| `DirectIntentBackend.stageDraft` 不再直接调用 `projectionStore?.set()` | Task 3 | Code review 确认，编译通过 |
| `ClaudeService+TextEditorTool` 不再向 `DirectIntentBackend` 注入 `projectionStore` | Task 4 | Code review 确认，编译通过 |
| `AgentLoopToolExecutionCoordinatorBuilder` 构建非空 pipeline（含 ChangeReviewHook） | Task 5 | 集成测试覆盖 |

---

## 已知边界情况

1. **ACP / External provider 执行**：ACP provider 走独立的执行路径，不经过 `AgentLoopToolExecutionCoordinatorBuilder` 构建的 coordinator，因此 `ChangeReviewHook` 不会为 ACP provider 的文件操作触发。这是预期行为：ACP provider 有自己的变更捕获路径（`WorkspaceChangeCaptureService`）。

2. **子代理（run_subagent）**：子代理内部工具调用会触发 `AgentLoopToolExecutionCoordinator`，但当前 `ToolRunRecord.sessionID` 为空字符串（见 `AgentLoopToolExecutionCoordinator.swift` ~line 110）。`ChangeReviewHook` 不依赖 `record.sessionID`，因为 snapshot 本身已包含正确的 `sessionID`（在 `stageDraft` 中建立），所以投影更新不受影响。

3. **`projectionStore` 为 nil 时**：`buildHookPipeline()` 中条件检查 `claudeService.changeReviewProjectionStore != nil` 后才注册 hook。在单元测试中 `changeReviewProjectionStore` 通常为 nil，这时 pipeline 为空，行为与原代码一致。

---

## 依赖关系

| 依赖项 | 状态 | 说明 |
|--------|------|------|
| F-C2 `ToolExecutionHookPipeline` | ✅ 已完成 | `ChangeReviewHook` 实现 `ToolExecutionHook` 协议 |
| `ChangeReviewProjectionStore` | ✅ 已存在 | `@Observable @MainActor final class`，Sendable |
| `ChangeProposalReviewSnapshot` | ✅ 已存在 | `Sendable` struct，已在 `ToolExecutionResult` 中携带 |
| `AgentLoopToolExecutionCoordinatorBuilder` | ✅ 已有 `hookPipeline: nil` 占位符 | 本 Feature 填充 |

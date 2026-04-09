# Agent Change Review And Final Apply Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 agentGui 落地一套统一的 agent 文件变更审查与最终确认流水线，让 agent 改动先进入提案层或隔离工作区，在用户审查 diff 并明确确认后再 apply 到真实工作区。

**Architecture:** 新增独立的 Change Review 子系统，把工作区结果建模为 durable `ChangeProposal` 聚合，而不是继续堆叠在 `ToolCall` 上。内建工具调用走 intent-based staging，外部 Copilot/OpenCode provider 走隔离工作区执行，二者最终统一汇入 `ChangeProposalStore`、`ChangeReviewProjectionStore` 和唯一可写真实工作区的 `ApplyEngine`。

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, Foundation, AppKit, existing `ConversationExecutionOrchestrator`, existing `GitDiffView`, existing `ToolCall` / chat execution UI.

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 1. 实施原则

- 这份计划应在独立 worktree 中执行；先用 @brainstorming 固化上下文，再按本计划逐 task 落地。
- 全程按 @test-driven-development 执行：先写失败测试，再写最小实现，再跑通过，再提交。
- 第一阶段坚持“文件级提案审查”，不要一开始就引入 hunk 级交互编辑。
- `ApplyEngine` 必须成为唯一允许写真实工作区的模块；任何 provider 或 text editor 工具都不能绕过它直接成为最终写入源。
- 变更提案状态不能混入 `ExecutionJobState` 或 `MessageStatus`；执行态与工作区审查态必须保持解耦。
- 外部 provider 的隔离执行优先使用 macOS 可行的 APFS clone 路径，不先做复杂 cross-platform 抽象过度设计。
- 全部任务完成后，使用 @requesting-code-review 做最终 review，再考虑合并。

## 2. 参考文档

- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-21-agent-change-review-and-final-apply-design.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-21-conversation-execution-runtime-rearchitecture-design.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-21-conversation-execution-runtime-rearchitecture-implementation-plan.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/text editor tool.md`

## 3. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChangeProposal.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ProposedFileChange.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChangeReviewDecision.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/ChangeProposalStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/ChangeReviewProjectionStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/ChangeCaptureCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/LiveDiffService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/ApplyEngine.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/DraftRevertService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/ConflictResolver.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/WorkspaceIsolationBackend.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/APFSCloneBackend.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/DirectIntentBackend.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChangeProposalReviewView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChangeProposalStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChangeReviewProjectionStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/DirectIntentBackendTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ApplyEngineTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/APFSCloneBackendTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExternalChangeReviewIntegrationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/ChangeProposalReviewFlowUITests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/PersistenceCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/GitDiffView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+TextEditorTool.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+ToolCallRecord.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

## 4. 关键设计决策

### 4.1 `ChangeProposal` 是审查域的一等实体

不要把待审查变更继续塞到 `ToolCall.diffContent` 或 `MessageStatus` 里。`ToolCall` 继续表示动作记录，审查状态统一落到新聚合：

```swift
enum ChangeProposalState: String, Codable, Sendable {
    case collecting
    case readyForReview
    case partiallyApproved
    case applying
    case applied
    case discarded
    case conflicted
    case failed
}

enum ProposedFileChangeState: String, Codable, Sendable {
    case proposed
    case accepted
    case rejected
    case revertedBeforeApply
    case applied
    case conflict
    case failed
}
```

### 4.2 真实工作区只能由 `ApplyEngine` 写入

第一阶段必须把最终写盘路径从：

```swift
ClaudeService+TextEditorTool -> write file directly
```

切换为：

```swift
tool call -> change proposal -> review -> ApplyEngine.apply(...)
```

### 4.3 内建与外部 provider 只在“捕获方式”上不同

统一审查链路下只保留两种接入模式：

1. `DirectIntentBackend`：内建 patch / text editor 工具直接生成提案。
2. `APFSCloneBackend`：外部 Copilot/OpenCode 在隔离工作区运行，系统持续计算 diff 形成提案。

## 5. 任务拆解

### Task 1: 固化 durable proposal / file change / review decision 模型

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChangeProposal.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ProposedFileChange.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChangeReviewDecision.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChangeProposalStoreTests.swift`

**Step 1: Write the failing test**

新增模型级测试，锁定以下行为：

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct ChangeProposalStoreTests {
    @Test func proposalStartsCollectingAndTracksProviderSessionAndJob() throws {
        let proposal = ChangeProposal(
            sessionID: "session-1",
            jobID: UUID(),
            messageID: UUID(),
            providerID: .githubCopilotCLI,
            baseWorkspaceRoot: "/tmp/workspace"
        )

        #expect(proposal.state == .collecting)
        #expect(proposal.providerID == .githubCopilotCLI)
        #expect(proposal.sessionID == "session-1")
        #expect(proposal.updatedAt >= proposal.createdAt)
    }

    @Test func proposedFileChangeStartsProposedAndCarriesUnifiedDiff() throws {
        let change = ProposedFileChange(
            proposalID: UUID(),
            relativePath: "agentGui/Models/ToolCall.swift",
            absolutePath: "/tmp/workspace/agentGui/Models/ToolCall.swift",
            changeKind: .modify,
            unifiedDiff: "@@ -1 +1 @@\n-old\n+new"
        )

        #expect(change.state == .proposed)
        #expect(change.unifiedDiff.contains("@@"))
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/ChangeProposalStoreTests
```

Expected: FAIL with missing `ChangeProposal` / `ProposedFileChange` / state enums.

**Step 3: Write minimal implementation**

最小实现：

```swift
@Model
final class ChangeProposal {
    var id: UUID
    var sessionID: String
    var jobID: UUID?
    var messageID: UUID?
    var providerIDRaw: String
    var stateRaw: String
    var baseWorkspaceRoot: String
    var createdAt: Date
    var updatedAt: Date

    init(sessionID: String, jobID: UUID?, messageID: UUID?, providerID: ConversationExecutionProviderID, baseWorkspaceRoot: String) {
        self.id = UUID()
        self.sessionID = sessionID
        self.jobID = jobID
        self.messageID = messageID
        self.providerIDRaw = providerID.rawValue
        self.stateRaw = ChangeProposalState.collecting.rawValue
        self.baseWorkspaceRoot = baseWorkspaceRoot
        self.createdAt = Date()
        self.updatedAt = self.createdAt
    }
}
```

并在 `ToolCall` 上增加：

- `changeProposalID: UUID?`
- `changeProposalStateRaw: String?`

先只做字段，不做 UI。

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/ChangeProposal.swift agentGui/Models/ProposedFileChange.swift agentGui/Models/ChangeReviewDecision.swift agentGui/Models/ToolCall.swift agentGuiTests/ChangeProposalStoreTests.swift
git commit -m "feat: add durable change proposal models"
```

### Task 2: 建立 proposal store 与 projection store，形成独立审查域

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/ChangeProposalStore.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/ChangeReviewProjectionStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/PersistenceCoordinator.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChangeProposalStoreTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChangeReviewProjectionStoreTests.swift`

**Step 1: Write the failing test**

为 store 和 projection 写失败测试：

```swift
@MainActor
struct ChangeReviewProjectionStoreTests {
    @Test func reviewProjectionSummarizesPendingChangesForSession() async throws {
        let harness = try ChangeProposalHarness.make()
        let store = harness.makeProposalStore()
        let projectionStore = ChangeReviewProjectionStore()

        let proposal = try await store.createProposal(
            sessionID: "session-1",
            jobID: UUID(),
            messageID: UUID(),
            providerID: .builtInAgent,
            baseWorkspaceRoot: "/tmp/workspace"
        )
        try await store.upsertFileChange(
            proposalID: proposal.id,
            relativePath: "README.md",
            absolutePath: "/tmp/workspace/README.md",
            changeKind: .modify,
            unifiedDiff: "@@ -1 +1 @@\n-old\n+new"
        )

        let snapshot = try await store.reviewSnapshot(for: proposal.id)
        projectionStore.set(snapshot)

        let projection = projectionStore.projection(forSessionID: "session-1")
        #expect(projection.pendingProposalCount == 1)
        #expect(projection.pendingFileCount == 1)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/ChangeProposalStoreTests \
  -only-testing:agentGuiTests/ChangeReviewProjectionStoreTests
```

Expected: FAIL with missing store / projection types.

**Step 3: Write minimal implementation**

实现最小 API：

```swift
@MainActor
final class ChangeProposalStore {
    func createProposal(...) async throws -> ChangeProposal
    func upsertFileChange(...) async throws
    func reviewSnapshot(for proposalID: UUID) async throws -> ChangeProposalReviewSnapshot
    func proposals(for sessionID: String) throws -> [ChangeProposal]
}

@Observable
final class ChangeReviewProjectionStore {
    func set(_ snapshot: ChangeProposalReviewSnapshot)
    func projection(forSessionID sessionID: String) -> SessionChangeReviewProjection
}
```

`PersistenceCoordinator` 同步补齐新模型注册。

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ChangeReview/ChangeProposalStore.swift agentGui/Services/ChangeReview/ChangeReviewProjectionStore.swift agentGui/Services/PersistenceCoordinator.swift agentGuiTests/ChangeProposalStoreTests.swift agentGuiTests/ChangeReviewProjectionStoreTests.swift
git commit -m "feat: add change review persistence stores"
```

### Task 3: 搭建 review UI 骨架并复用 `GitDiffView`

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChangeProposalReviewView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/GitDiffView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/ChangeProposalReviewFlowUITests.swift`

**Step 1: Write the failing test**

新增 UI 测试，锁定最小可见流程：

```swift
@MainActor
struct ChangeProposalReviewFlowUITests {
    @Test func pendingProposalBadgeOpensReviewScreen() async throws {
        let app = try ChangeProposalReviewUITestApp.launchWithPendingProposal()

        try await app.find("chat.changeReviewBadge").tap()

        #expect(try await app.exists("changeReview.screen"))
        #expect(try await app.exists("changeReview.fileList"))
        #expect(try await app.exists("git.diff"))
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiUITests/ChangeProposalReviewFlowUITests
```

Expected: FAIL because review screen routing and badge do not exist.

**Step 3: Write minimal implementation**

实现：

1. `WorkspaceState` 新增 review 选择状态：

```swift
var selectedChangeProposalID: UUID?
var selectedChangeProposalFilePath: String?
```

2. `ChangeProposalReviewView` 提供：
   - 文件列表
   - 选中文件 unified diff
   - 复用 `GitDiffView` 渲染 diff 文本

3. `ChatView+InputArea` 增加 badge：
   - `chat.changeReviewBadge`

先不接 apply，只做到可进入 review 页面并切文件。

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/ChangeProposalReviewView.swift agentGui/Utilities/WorkspaceState.swift agentGui/Views/GitDiffView.swift agentGui/Views/ChatView.swift agentGui/Views/ChatView+InputArea.swift agentGuiUITests/ChangeProposalReviewFlowUITests.swift
git commit -m "feat: add change proposal review ui scaffold"
```

### Task 4: 将内建 text editor 工具迁移到 `DirectIntentBackend`

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/DirectIntentBackend.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/DirectIntentBackendTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+TextEditorTool.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+ToolCallRecord.swift`

**Step 1: Write the failing test**

锁定“生成提案但不直接写真实文件”的行为：

```swift
@MainActor
struct DirectIntentBackendTests {
    @Test func strReplaceCreatesProposalWithoutMutatingRealFile() async throws {
        let harness = try DirectIntentHarness.make(fileText: "hello")
        let backend = harness.makeBackend()

        let proposal = try await backend.captureStrReplace(
            path: harness.filePath,
            oldStr: "hello",
            newStr: "world",
            sessionID: "session-1"
        )

        #expect(try String(contentsOf: harness.fileURL) == "hello")
        #expect(proposal.fileChanges.count == 1)
        #expect(proposal.fileChanges[0].unifiedDiff.contains("+world"))
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/DirectIntentBackendTests
```

Expected: FAIL because text editor path still writes files directly.

**Step 3: Write minimal implementation**

实现最小迁移：

1. `DirectIntentBackend` 根据 tool input 读取原文件并生成 unified diff。
2. `ClaudeService+TextEditorTool` 中将以下命令切到提案捕获：
   - `str_replace`
   - `create`
   - `write`
   - `insert`
3. 保持 `view/read/open` 仍然直接读取。
4. `ClaudeService+ToolCallRecord` 在 edit 类工具调用上写入 `changeProposalID`。

先不要支持目录批量写入，只覆盖单文件路径。

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ChangeReview/DirectIntentBackend.swift agentGui/Services/ClaudeService/ClaudeService+TextEditorTool.swift agentGui/Services/ClaudeService/ClaudeService+ToolCallRecord.swift agentGuiTests/DirectIntentBackendTests.swift
git commit -m "feat: stage built-in file edits as proposals"
```

### Task 5: 实现 `ApplyEngine`、`DraftRevertService` 与最小冲突检测

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/ApplyEngine.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/DraftRevertService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/ConflictResolver.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ApplyEngineTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChangeProposalReviewView.swift`

**Step 1: Write the failing test**

锁定三件事：

1. `ApplyEngine` 把提案写回真实工作区。
2. `DraftRevertService` 可以在 apply 前撤销单文件提案。
3. base hash 不匹配时进入 `conflicted`。

```swift
@MainActor
struct ApplyEngineTests {
    @Test func applyWritesApprovedFilesToWorkspace() async throws {
        let harness = try ApplyEngineHarness.make(original: "hello")
        let proposal = try await harness.makeProposal(newText: "world")

        try await harness.applyEngine.apply(proposalID: proposal.id, approvedPaths: ["file.txt"])

        #expect(try String(contentsOf: harness.fileURL) == "world")
        #expect(try harness.store.proposal(id: proposal.id).state == .applied)
    }

    @Test func applyMarksProposalConflictedWhenBaseHashChanged() async throws {
        let harness = try ApplyEngineHarness.make(original: "hello")
        let proposal = try await harness.makeProposal(newText: "world")
        try "user edit".write(to: harness.fileURL, atomically: true, encoding: .utf8)

        await #expect(throws: ChangeReviewConflictError.self) {
            try await harness.applyEngine.apply(proposalID: proposal.id, approvedPaths: ["file.txt"])
        }
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/ApplyEngineTests
```

Expected: FAIL because apply / revert / conflict services do not exist.

**Step 3: Write minimal implementation**

实现：

```swift
@MainActor
final class ApplyEngine {
    func apply(proposalID: UUID, approvedPaths: [String]) async throws
}

struct ConflictResolver {
    func validateBaseHash(currentFileURL: URL, expectedHash: String?) throws
}

@MainActor
final class DraftRevertService {
    func revertFiles(proposalID: UUID, relativePaths: [String]) async throws
}
```

UI 上在 `ChangeProposalReviewView` 先接：

- `Apply All`
- `Apply Selected`
- `Discard File`
- `Discard Proposal`

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ChangeReview/ApplyEngine.swift agentGui/Services/ChangeReview/DraftRevertService.swift agentGui/Services/ChangeReview/ConflictResolver.swift agentGui/Views/ChangeProposalReviewView.swift agentGuiTests/ApplyEngineTests.swift
git commit -m "feat: add proposal apply and revert engine"
```

### Task 6: 引入 `APFSCloneBackend` 与 `LiveDiffService`，支持隔离工作区

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/WorkspaceIsolationBackend.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/APFSCloneBackend.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/LiveDiffService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/APFSCloneBackendTests.swift`

**Step 1: Write the failing test**

锁定 macOS 隔离路径的最小行为：

```swift
@MainActor
struct APFSCloneBackendTests {
    @Test func cloneBackendCreatesEditableIsolatedWorkspace() async throws {
        let harness = try IsolationHarness.make()
        let backend = APFSCloneBackend(fileManager: .default)

        let handle = try await backend.prepare(sessionID: "session-1", sourceRoot: harness.sourceRoot)

        let isolatedFile = handle.isolatedRoot.appending(path: "file.txt")
        try "isolated edit".write(to: isolatedFile, atomically: true, encoding: .utf8)

        #expect(try String(contentsOf: harness.sourceRoot.appending(path: "file.txt")) == "original")
        #expect(try String(contentsOf: isolatedFile) == "isolated edit")
    }

    @Test func liveDiffServiceBuildsUnifiedDiffAgainstBaseWorkspace() async throws {
        let harness = try IsolationHarness.make()
        let backend = APFSCloneBackend(fileManager: .default)
        let handle = try await backend.prepare(sessionID: "session-1", sourceRoot: harness.sourceRoot)
        let isolatedFile = handle.isolatedRoot.appending(path: "file.txt")
        try "edited".write(to: isolatedFile, atomically: true, encoding: .utf8)

        let diff = try await LiveDiffService().diff(for: handle)
        #expect(diff.contains("+edited"))
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/APFSCloneBackendTests
```

Expected: FAIL because isolation backend and live diff service do not exist.

**Step 3: Write minimal implementation**

实现最小后端：

1. `WorkspaceIsolationBackend` 协议。
2. `APFSCloneBackend.prepare(...)` 用 clone/copy 建立隔离目录。
3. `LiveDiffService.diff(for:)` 以 base root 和 isolated root 生成 unified diff。
4. 提供 `cleanup(handle:)`。

先不做 watcher 流式更新，只先做拉取式 diff 生成。

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ChangeReview/WorkspaceIsolationBackend.swift agentGui/Services/ChangeReview/APFSCloneBackend.swift agentGui/Services/ChangeReview/LiveDiffService.swift agentGuiTests/APFSCloneBackendTests.swift
git commit -m "feat: add isolated workspace backend"
```

### Task 7: 将 external provider 执行上下文切到隔离工作区

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExternalChangeReviewIntegrationTests.swift`

**Step 1: Write the failing test**

锁定外部 provider 运行时不直接碰真实工作区，而是通过 isolation handle：

```swift
@MainActor
struct ExternalChangeReviewIntegrationTests {
    @Test func copilotExecutionWritesOnlyInsideIsolatedWorkspaceBeforeApply() async throws {
        let harness = try ExternalChangeReviewHarness.make(providerID: .githubCopilotCLI)

        try await harness.runAgentThatEdits("README.md", newText: "isolated")

        #expect(try String(contentsOf: harness.realWorkspaceFile("README.md")) != "isolated")
        let proposal = try #require(harness.latestProposal())
        #expect(proposal.state == .readyForReview)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/ExternalChangeReviewIntegrationTests
```

Expected: FAIL because provider working directory is still real workspace.

**Step 3: Write minimal implementation**

实现迁移：

1. `ConversationExecutionOrchestrator` 在外部 provider job 启动时创建 isolation handle。
2. 向 driver / provider 执行上下文注入 isolated root。
3. provider 的 terminal runtime factory 使用 isolated root 作为 working directory。
4. job 结束后调用 `LiveDiffService` 产出最终提案并将状态切到 `readyForReview`。

第一阶段先做“结束后生成提案”，第二阶段再做运行中 live watcher。

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/Execution/ConversationExecutionOrchestrator.swift agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift agentGuiTests/ExternalChangeReviewIntegrationTests.swift
git commit -m "feat: route external providers through isolated workspaces"
```

### Task 8: 强化聊天区与 ToolCall 集成，补齐恢复与回归测试

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChangeProposalReviewView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChangeProposalStoreTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/ChangeProposalReviewFlowUITests.swift`

**Step 1: Write the failing test**

锁定最终集成行为：

1. ToolCall 泡泡显示提案摘要。
2. App 启动后能恢复 `readyForReview` proposal。
3. 用户从 ToolCall 直接跳 review。

```swift
@MainActor
struct ChangeProposalReviewFlowUITests {
    @Test func toolCallProposalLinkRestoresReviewAfterAppReload() async throws {
        let app = try ChangeProposalReviewUITestApp.launchWithPersistedProposal()

        #expect(try await app.exists("toolCall.proposalLink"))
        try await app.find("toolCall.proposalLink").tap()
        #expect(try await app.exists("changeReview.screen"))
        #expect(try await app.exists("changeReview.applyAll"))
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/ChangeProposalStoreTests \
  -only-testing:agentGuiUITests/ChangeProposalReviewFlowUITests
```

Expected: FAIL because tool bubble link and restore bootstrap are incomplete.

**Step 3: Write minimal implementation**

实现：

1. `agentGuiApp.swift` 启动时恢复 `readyForReview` / `conflicted` proposals 到 `ChangeReviewProjectionStore`。
2. `ToolCallBubbleView` 和 `ToolCallDetailContentView` 增加 proposal 跳转链接与摘要。
3. `ChangeProposalReviewView` 完成 applied / discarded 后清理 workspace selection。

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/ToolCallBubbleView.swift agentGui/Views/ToolCallDetailContentView.swift agentGui/agentGuiApp.swift agentGui/Views/ChangeProposalReviewView.swift agentGuiTests/ChangeProposalStoreTests.swift agentGuiUITests/ChangeProposalReviewFlowUITests.swift
git commit -m "feat: restore and surface pending change proposals"
```

## 6. 全量验证

在所有任务完成后，按以下顺序验证：

1. Focused unit / integration suites:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/ChangeProposalStoreTests \
  -only-testing:agentGuiTests/ChangeReviewProjectionStoreTests \
  -only-testing:agentGuiTests/DirectIntentBackendTests \
  -only-testing:agentGuiTests/ApplyEngineTests \
  -only-testing:agentGuiTests/APFSCloneBackendTests \
  -only-testing:agentGuiTests/ExternalChangeReviewIntegrationTests
```

Expected: PASS.

2. Focused UI suite:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiUITests/ChangeProposalReviewFlowUITests
```

Expected: PASS.

3. Repo smoke task:

```bash
./scripts/run_quality_smoke.sh
```

Expected: existing smoke checks pass without regression.

## 7. 交付边界

第一阶段交付完成的标志：

1. built-in 文件编辑不再直接写真实工作区，而是进入提案审查。
2. external Copilot/OpenCode provider 在隔离工作区运行，结束后生成待审查 proposal。
3. 用户能在 review 页面里查看 diff、应用全部、应用选中文件、丢弃文件、丢弃提案。
4. app 重启后可恢复待审查 proposal。

明确留到下一阶段的内容：

1. 运行中 live watcher 的高频流式 diff。
2. hunk 级 apply / reject。
3. post-apply 一键反向回滚。
4. 更复杂的三方合并与 rename / binary 文件特殊处理。

Plan complete and saved to `docs/plans/2026-03-21-agent-change-review-and-final-apply-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - 我按 task 逐个落地、每步 review、快速迭代

**2. Parallel Session (separate)** - 你开新 session，用 `executing-plans` 按这份计划批量执行

你选哪一种？
# Data Reliability And Recovery Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a durable data reliability layer for agentGui so session plans, Todo state, verification state, workflow runtime records, and core settings are saved consistently, recoverable after abnormal exit, diagnosable when corrupted, and exportable for backup and restore.

**Architecture:** Introduce a single persistence coordination layer in front of SwiftData writes, move session task state from in-memory dictionaries into SwiftData-backed models, and add a startup reliability bootstrap that performs recovery detection and integrity checks before the UI becomes interactive. Keep the first phase scoped to local persistence and local backup archives, with recovery and diagnostics surfaced through dedicated view models and lightweight SwiftUI panels instead of ad hoc alerts.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Observation, Foundation JSON/ZIP-style archive writing, Swift Testing, existing ClaudeService, WorkflowRuntime, WorkspaceState, and AppSettings/Session/WorkflowInstance models.

---

## 1. 实施原则

- 先补测试，再落持久化编排层，再接 UI；不要先在各处散改 `try? modelContext.save()`。
- 统一把“保存失败”视为业务事件，而不是纯日志事件；错误分类、上报、用户提示要走同一链路。
- `Session` 相关任务态必须有单一持久化来源，内存缓存只能作为读优化，不能再是事实来源。
- 恢复能力优先覆盖 P0：会话计划、Todo、验证结果、进行中的 workflow、进行中的 bash 任务、未完成消息生成。
- 完整性检查和备份恢复先做本地版本，不引入云同步、多端冲突或后台自动修复。
- 所有新增 SwiftData 测试都使用 in-memory `ModelContainer`；测试默认按 `@MainActor` 编写，避免隔离错误。

## 2. 当前代码落点

当前需求直接落在这些现有文件上，计划按这些入口组织改造：

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ExecutionPlan.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+TodoTool.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowRuntime.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionPlan.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

已确认的主要问题：

- `ClaudeService` 仍把 `sessionTodoLists`、`sessionVerifications` 保存在内存字典中。
- `WorkflowRuntime`、`ContentView`、`WorkspacePanelView`、`ACPClientService` 等处存在大量 `try? modelContext.save()`。
- `Session.planJson` 已持久化，但没有配套的保存失败策略、损坏诊断和恢复元数据。
- 应用启动时只初始化 `ModelContainer` 和运行时对象，没有恢复检测、完整性检查、迁移信息或备份入口。

## 3. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionTaskState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/PersistenceFailureRecord.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RecoverySnapshot.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/IntegrityIssue.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackupArchiveManifest.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/PersistenceCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/SessionTaskStateStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/RuntimeRecoveryService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/DataIntegrityChecker.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BackupArchiveService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ReliabilityCenterViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Reliability/ReliabilityCenterView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Reliability/RecoveryBannerView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/PersistenceCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionTaskStateStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RuntimeRecoveryServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/DataIntegrityCheckerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackupArchiveServiceTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ExecutionPlan.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+TodoTool.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowRuntime.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

## 4. 关键架构决策

### 4.1 统一保存入口

不要在视图、service、runtime 中继续直接调用 `modelContext.save()` 或 `try? modelContext.save()`。引入一个主线程隔离的 `PersistenceCoordinator`，职责只有四个：

- 执行保存并返回结构化结果
- 对错误做分类，例如权限、磁盘空间、验证失败、存储损坏、未知错误
- 写入 `PersistenceFailureRecord` 供诊断面板查看
- 通过可观察状态或回调把“本次变更未成功保存”通知给 UI

建议接口：

```swift
@MainActor
final class PersistenceCoordinator {
    enum SaveDomain: String {
        case settings
        case sessionMessages
        case toolCalls
        case workflow
        case sessionTaskState
        case backupRestore
    }

    func save(
        _ context: ModelContext,
        domain: SaveDomain,
        userMessage: String,
        metadata: [String: String] = [:]
    ) throws
}
```

### 4.2 会话任务态单一事实源

`Session.planJson` 可以保留，但 Todo、Verification、恢复状态不能继续散落在 `ClaudeService` 内存态。建议新增 `SessionTaskState` 模型，由 `sessionId` 关联到 `Session`，统一承载：

- `planJson`
- `todoJson`
- `verificationJson`
- `lastKnownPhase`
- `lastUpdatedAt`
- `interruptedRunSummaryJson`

实现上分两步：

- 第一阶段保留 `Session.planJson` 作为兼容字段，并把它镜像到 `SessionTaskState.planJson`
- 第二阶段把 UI 和服务统一切到 `SessionTaskStateStore`，让 `ClaudeService` 只维护短期缓存

### 4.3 异常中断恢复模型

恢复目标不是“自动继续执行一切”，而是“准确告诉用户上次停在什么位置，并给出可选择动作”。建议新增 `RecoverySnapshot`，覆盖三类来源：

- workflow 未完成
- bash 任务未正常结束
- 会话消息生成处于 streaming/awaiting-finalize 状态

恢复动作只做三种：

- 恢复查看
- 标记为中断
- 清理现场

### 4.4 启动期可靠性引导

在 `agentGuiApp` 中增加一个启动引导顺序：

1. 初始化 `ModelContainer`
2. 初始化 `PersistenceCoordinator`
3. 初始化 `RuntimeRecoveryService`
4. 执行轻量级 `DataIntegrityChecker`
5. 将恢复摘要与诊断摘要注入 `ReliabilityCenterViewModel`
6. 再创建 `WorkflowRuntime` 和主界面依赖

这样能保证 UI 读到的是“带有诊断上下文的状态”，而不是先进入主界面后才被动发现数据损坏。

## 5. 任务拆解

### Task 1: 建立统一保存协调层

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/PersistenceFailureRecord.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/PersistenceCoordinator.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/PersistenceCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`

**Step 1: 写失败测试，固定错误分类与记录契约**

新增测试覆盖：

- 保存成功时不写故障记录
- 保存失败时能映射为结构化错误分类
- 核心域 `sessionMessages`、`toolCalls`、`workflow` 触发更高等级告警
- UI 可消费最近一次保存失败摘要

测试示例：

```swift
import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct PersistenceCoordinatorTests {

    @Test func recordsStructuredFailureForCoreWorkflowSave() async throws {
        let harness = try PersistenceCoordinatorHarness.makeFailingSaveHarness()
        let coordinator = PersistenceCoordinator()

        await #expect(throws: PersistenceCoordinator.SaveError.self) {
            try coordinator.save(
                harness.context,
                domain: .workflow,
                userMessage: "未能保存工作流状态"
            )
        }

        #expect(harness.recordedFailures.count == 1)
        #expect(harness.recordedFailures.first?.domainRaw == "workflow")
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/PersistenceCoordinatorTests
```

Expected: FAIL，因为协调层与失败记录模型尚未实现。

**Step 3: 写最小实现**

实现内容：

- `PersistenceFailureRecord` 保存 domain、category、message、metadataJSON、createdAt
- `PersistenceCoordinator` 统一封装 `context.save()`
- `AppSettings.getOrCreate(in:)` 改为通过协调层保存或允许注入保存闭包
- `ContentView` 与 `WorkspacePanelView` 先接最小用户可见错误提示，不再吞掉保存失败

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/PersistenceFailureRecord.swift agentGui/Services/PersistenceCoordinator.swift agentGui/Models/AppSettings.swift agentGui/ContentView.swift agentGui/Views/WorkspacePanelView.swift agentGuiTests/PersistenceCoordinatorTests.swift
git commit -m "feat: add coordinated persistence error handling"
```

### Task 2: 持久化会话任务状态

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionTaskState.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/SessionTaskStateStore.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionTaskStateStoreTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ExecutionPlan.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+TodoTool.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`

**Step 1: 写失败测试，固定 Todo/Verification/Plan 的恢复语义**

新增测试覆盖：

- 创建 plan 后可从 `SessionTaskState` 读回
- 更新 TodoList 后重建 `ClaudeService` 仍能恢复
- 记录 verification 后 UI 读取的是持久化结果而不是内存字典
- 旧数据只有 `Session.planJson` 时仍能迁移装配为任务态

测试示例：

```swift
import Foundation
import SwiftAnthropic
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct SessionTaskStateStoreTests {

    @Test func todoAndVerificationReloadAfterServiceRecreation() async throws {
        let harness = try SessionTaskStateHarness.make()
        let session = harness.insertSession(id: "session-1")

        try harness.store.saveTodoItems([TodoItem(title: "Persist me")], for: session.sessionId)
        try harness.store.saveVerification(
            CompletionVerification(verified: ["build"], notVerified: []),
            for: session.sessionId
        )

        let reloaded = try #require(harness.store.taskState(for: session.sessionId))
        #expect(reloaded.todoItems.count == 1)
        #expect(reloaded.verification?.verified == ["build"])
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/SessionTaskStateStoreTests -only-testing:agentGuiTests/AgentLoopExecutionGuardTests
```

Expected: FAIL，因为 `SessionTaskState` 与 store 尚不存在，旧测试还依赖内存态。

**Step 3: 写最小实现**

实现内容：

- `SessionTaskState` 用 JSON 字段持久化 todo 和 verification，避免一开始引入过多关系模型
- `Session` 增加到 `SessionTaskState` 的一对一关系或通过 `sessionId` 可查询关联
- `SessionTaskStateStore` 提供读写 API 和从旧 `planJson` 回填逻辑
- `ClaudeService+ExecutionPlan`、`ClaudeService+TodoTool` 改为先写 store，再刷新内存缓存
- `WorkspacePanelView` 读取 store/派生状态，而不是直接读 `sessionTodoLists`

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/SessionTaskState.swift agentGui/Services/SessionTaskStateStore.swift agentGui/Models/Session.swift agentGui/Services/ACPClientService.swift agentGui/Services/ClaudeService+ExecutionPlan.swift agentGui/Services/ClaudeService+TodoTool.swift agentGui/Views/WorkspacePanelView.swift agentGuiTests/SessionTaskStateStoreTests.swift agentGuiTests/AgentLoopExecutionGuardTests.swift
git commit -m "feat: persist session task state"
```

### Task 3: 补齐 workflow 与运行时异常中断恢复

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RecoverySnapshot.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/RuntimeRecoveryService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RuntimeRecoveryServiceTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowRuntime.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

**Step 1: 写失败测试，固定恢复入口行为**

新增测试覆盖：

- 未完成 `WorkflowInstance` 在应用重启后会被识别为可恢复项
- 进行中的 bash task 可映射成恢复摘要
- 进行中的消息生成在下次启动时会标记为 interrupted，而不是永远停留在 running
- 用户选择“标记为中断”后会更新持久化状态

测试示例：

```swift
import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct RuntimeRecoveryServiceTests {

    @Test func findsInterruptedWorkflowInstancesAtStartup() async throws {
        let harness = try RuntimeRecoveryHarness.make()
        harness.insertWorkflow(status: .running, sessionId: "s1")

        let service = RuntimeRecoveryService()
        let summary = try service.loadRecoverySummary(from: harness.context)

        #expect(summary.items.count == 1)
        #expect(summary.items.first?.kind == .workflow)
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/RuntimeRecoveryServiceTests
```

Expected: FAIL，因为恢复快照模型与恢复服务还不存在。

**Step 3: 写最小实现**

实现内容：

- `RecoverySnapshot` 持久化恢复项摘要与用户处理结果
- `WorkflowRuntime` 在开始、暂停、失败、完成时统一更新恢复元数据
- `ACPClientService` 为消息生成和 bash 任务写入最后状态标记
- `agentGuiApp` 启动时加载恢复摘要
- `ChatView` 在会话命中恢复项时显示恢复横幅，提供“恢复查看”“标记为中断”“清理现场”操作

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/RecoverySnapshot.swift agentGui/Services/RuntimeRecoveryService.swift agentGui/Services/WorkflowRuntime.swift agentGui/Services/ACPClientService.swift agentGui/Views/ChatView.swift agentGui/agentGuiApp.swift agentGuiTests/RuntimeRecoveryServiceTests.swift
git commit -m "feat: add runtime recovery summaries"
```

### Task 4: 加入启动期完整性检查与诊断面板

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/IntegrityIssue.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/DataIntegrityChecker.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ReliabilityCenterViewModel.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Reliability/ReliabilityCenterView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/DataIntegrityCheckerTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`

**Step 1: 写失败测试，固定完整性检查规则**

新增测试覆盖：

- 孤立 `Message` 能被识别
- 没有有效 `sessionId` 的 `ToolCall` 能被识别
- 无法解析的 `planJson` 会以 issue 输出，而不是崩溃
- 非法 workflow 记录组合会被纳入诊断摘要

测试示例：

```swift
import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct DataIntegrityCheckerTests {

    @Test func flagsBrokenPlanJsonInsteadOfCrashing() async throws {
        let harness = try IntegrityHarness.make()
        harness.insertSession(id: "s1", planJson: "{not-json")

        let checker = DataIntegrityChecker()
        let report = try checker.runLightweightChecks(in: harness.context)

        #expect(report.issues.contains { $0.kind == .brokenPlanJSON })
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/DataIntegrityCheckerTests
```

Expected: FAIL，因为完整性检查器与诊断模型还不存在。

**Step 3: 写最小实现**

实现内容：

- `DataIntegrityChecker` 提供轻量扫描，不做破坏性修复
- `ReliabilityCenterViewModel` 聚合最近保存失败、恢复项、完整性 issue
- `ContentView` 增加入口打开 `ReliabilityCenterView`
- `agentGuiApp` 启动时执行轻量检查并缓存结果

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/IntegrityIssue.swift agentGui/Services/DataIntegrityChecker.swift agentGui/ViewModels/ReliabilityCenterViewModel.swift agentGui/Views/Reliability/ReliabilityCenterView.swift agentGui/agentGuiApp.swift agentGui/ContentView.swift agentGuiTests/DataIntegrityCheckerTests.swift
git commit -m "feat: add integrity diagnostics center"
```

### Task 5: 建立本地备份、导出与恢复路径

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackupArchiveManifest.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BackupArchiveService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackupArchiveServiceTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ReliabilityCenterViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Reliability/ReliabilityCenterView.swift`

**Step 1: 写失败测试，固定归档范围与恢复契约**

新增测试覆盖：

- 完整备份包含 `AppSettings`、`Session`、`Message`、`ToolCall`、`WorkflowInstance`、`SessionTaskState`
- 单会话导出只包含目标 session 及其关联对象
- 恢复时会校验 manifest 版本并拒绝不兼容包
- 恢复前先做 dry-run 校验，避免半写入状态

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct BackupArchiveServiceTests {

    @Test func exportsSingleSessionWithoutLeakingOtherSessions() async throws {
        let harness = try BackupArchiveHarness.make()
        harness.seedTwoSessions()

        let archiveURL = try harness.service.exportSession(id: "session-1", from: harness.context)
        let manifest = try harness.loadManifest(from: archiveURL)

        #expect(manifest.scope == .singleSession("session-1"))
        #expect(manifest.sessionIDs == ["session-1"])
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/BackupArchiveServiceTests
```

Expected: FAIL，因为备份服务与 manifest 模型尚不存在。

**Step 3: 写最小实现**

实现内容：

- `BackupArchiveService` 输出 manifest + JSON payload 目录或 zip 包
- 支持 `exportSession(id:)` 与 `exportAll()`
- `restore(from:)` 先校验版本与数据完整性，再写入新上下文
- `ReliabilityCenterView` 增加导出与恢复入口

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/BackupArchiveManifest.swift agentGui/Services/BackupArchiveService.swift agentGui/ViewModels/ReliabilityCenterViewModel.swift agentGui/Views/Reliability/ReliabilityCenterView.swift agentGuiTests/BackupArchiveServiceTests.swift
git commit -m "feat: add local backup and restore workflow"
```

### Task 6: 明确 schema version 与迁移文档

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/WorkflowInstance.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-data-reliability-and-recovery-requirements.md`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/PersistenceMigrationTests.swift`

**Step 1: 写失败测试，固定最小迁移兼容边界**

新增测试覆盖：

- 带旧字段的 `SessionTaskState` 载荷可被当前模型读取
- 缺省新字段时能使用默认值恢复
- 不兼容版本会产生用户可见错误，而不是静默跳过

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/PersistenceMigrationTests
```

Expected: FAIL，因为版本字段与迁移测试尚未实现。

**Step 3: 写最小实现**

实现内容：

- 在关键模型或归档 manifest 中加入 `schemaVersion`
- 在 `agentGuiApp` 的容器初始化附近集中声明当前持久化版本常量
- 在需求文档或邻接技术文档中补充迁移策略、回滚策略、允许废弃字段清单

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/AppSettings.swift agentGui/Models/Session.swift agentGui/Models/WorkflowInstance.swift agentGui/agentGuiApp.swift docs/spec/2026-03-10-data-reliability-and-recovery-requirements.md agentGuiTests/PersistenceMigrationTests.swift
git commit -m "docs: define persistence schema versioning rules"
```

## 6. 推荐执行顺序

按优先级执行，不要并行改动所有层：

1. Task 1，先收口保存入口，否则后续状态落盘仍不可信。
2. Task 2，把 Todo、Verification、Plan 切到持久化事实源。
3. Task 3，补 runtime 恢复摘要与会话入口。
4. Task 4，把启动完整性检查和诊断面板接起来。
5. Task 5，最后做导出、备份和恢复。
6. Task 6，在主链路稳定后再固化 schema version 与迁移文档。

## 7. 验证矩阵

每个阶段至少执行以下验证：

- Focused tests：只跑当前任务对应测试类
- Regression tests：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopExecutionGuardTests -only-testing:agentGuiTests/WorkflowBusinessObservabilityTests
```

- Full suite before merge：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test
```

- Manual checks：

```text
1. 创建 Todo、plan、verification，重启应用后确认侧栏和会话状态恢复。
2. 模拟保存失败，确认 UI 提示且不会误报保存成功。
3. 注入损坏 planJson，确认诊断面板出现 issue 且应用不崩溃。
4. 启动后命中未完成 workflow，确认会话出现恢复入口。
5. 导出单会话与全量快照，验证 restore dry-run 与实际恢复路径。
```

## 8. 风险与取舍

- SwiftData 模型扩展会带来容器兼容风险，所以先用 JSON 字段承载复杂任务态，减少关系爆炸。
- `PersistenceCoordinator` 初版只要求覆盖关键路径；不必一次性替换全部非关键设置写入，但必须先替换需求文档点名的核心数据。
- 恢复功能先做“恢复查看”，不做自动续跑 bash 和自动续流消息，避免隐式副作用。
- 备份恢复初版优先保证可验证、可回滚，不追求极致性能或增量归档。

Plan complete and saved to `docs/plans/2026-03-11-data-reliability-and-recovery-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

**Which approach?**
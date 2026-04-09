# NSBackgroundActivityScheduler Agent Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the first production path for user-created background agent tasks in agentGui, using `NSBackgroundActivityScheduler` for low-frequency wakeups, a controlled `AgentLoop` execution path, and session-native result delivery.

**Architecture:** Add a dedicated `Services/Background` layer that separates scheduler registration, policy mapping, eligibility checks, execution coordination, and observation persistence. Reuse the existing `Session` / `Message`, `AgentLoop`, `PersistenceCoordinator`, `BusinessMonitor`, and app bootstrap infrastructure so background execution becomes a new trigger source for the current runtime rather than a second orchestration engine.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, AppKit `NSBackgroundActivityScheduler`, Observation, Foundation, Swift Testing, existing `ClaudeService`, `AgentLoop`, `PersistenceCoordinator`, `RuntimeRecoveryService`, and `BusinessMonitor`.

---

## 0. 范围约束

- 严格按设计文档当前边界实施：只支持用户手动创建后台任务，不接 `WorkflowRuntime`、多代理编排、自动 replanning。
- 后台任务必须绑定已有 `Session`，结果默认回写到 `Session` / `Message`，不做独立黑盒日志中心。
- `NSBackgroundActivityScheduler` 只负责系统唤醒，不直接承载业务状态机；执行前必须经过业务层 eligibility 判定。
- 首期只支持 deferrable 工作，默认频率不低于 10 分钟；不承诺严格准点，不实现 cron 语义。
- 后台 Agent 默认走受限工具权限和更低预算，不能直接复用前台会话的全部执行能力。
- 所有新逻辑优先按 `@MainActor` 和 in-memory `ModelContainer` 测试，避免在计划执行期引入线程隔离噪音。

## 1. 实施原则

- 严格按 `@test-driven-development` 执行，先锁定数据模型、policy 映射、eligibility 分类、结果回写和 bootstrap 行为，再接真实 scheduler。
- 不把业务逻辑直接塞进 scheduler block；block 只负责把系统触发转交给 coordinator，并且保证 completion 一定被调用。
- 所有后台执行都要有可观测证据：trigger、skip、defer、start、complete、fail 都必须落库或落业务事件。
- 后台任务定义、运行记录、策略 JSON 都进入 SwiftData；in-memory 状态只作为 coordinator 的瞬时缓存，不作为事实来源。
- 先做最小可用闭环：任务定义、注册、触发、受限执行、回写、观测。`outcome-aware cadence`、trust tier 自动降级、完整管理页排序/过滤属于后续增强，但数据结构本期要预留。
- 每个任务都要有稳定 `taskKey` 和稳定 scheduler identifier，避免系统学习调度启发式时频繁失忆。

## 2. 当前代码落点

当前实现计划直接依赖这些现有文件和能力：

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Message.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionTaskState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopRunRequest.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentBusinessEvent.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryBackgroundJob.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopRunner.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHookEmitter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/PersistenceCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/RuntimeRecoveryService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/BusinessMonitor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsWindowView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsNavigationItem.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsGeneralView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

已确认的现状和约束：

- 代码库目前没有 `Services/Background` 目录，也没有任何后台任务管理模型或测试。
- `agentGuiApp` 已经承担 `ModelContainer`、`AppSettings` 加载、`RuntimeRecoveryService` 和主运行时注入，适合作为后台 coordinator 的 bootstrap 入口。
- `ClaudeService+AgenticLoop.swift` 已有通用 `runCoreAgentLoop` 路径，但 `AgentLoopRunRequest` 仍缺少后台来源、执行预算、结果投影等背景任务特定元数据。
- `RuntimeRecoveryService` 已有异常中断摘要与状态归一化模式，可复用其“异常运行记录在下次启动时统一处理”的思路。
- `BusinessMonitor` 和 `AgentBusinessEvent` 已经提供业务可观测性基础，不需要新造第二套事件系统。

## 3. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackgroundAgentTask.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackgroundAgentTaskRun.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackgroundTaskPolicy.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackgroundTaskExecutionPolicy.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackgroundTaskToolGrantPolicy.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundSystemScheduler.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundTaskRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundTaskPolicyEngine.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundTaskEligibilityEvaluator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundTaskExecutionCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundActivityCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundPromptComposer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundSessionResultWriter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundTaskObservationService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/Adapters/BackgroundAgentLoopAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/BackgroundTaskManagementViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsBackgroundAutomationView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Background/BackgroundTaskListView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Background/BackgroundTaskEditorSheet.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundAgentTaskModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundTaskPolicyEngineTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundTaskRegistryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundTaskEligibilityEvaluatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundPromptComposerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundSessionResultWriterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundAgentLoopAdapterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundTaskExecutionCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundActivityCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundTaskManagementViewModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/BackgroundTaskManagementUITests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopRunRequest.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentBusinessEvent.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/RuntimeRecoveryService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/BusinessMonitor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsWindowView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsNavigationItem.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsGeneralView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

## 4. 关键架构决策

### 4.1 先抽象系统 scheduler，再接真实 `NSBackgroundActivityScheduler`

不要让 `BackgroundActivityCoordinator` 直接 new AppKit 对象并在测试里碰真实系统调度。先定义一个最薄的 `BackgroundSystemScheduler` 协议与 factory：

- 负责暴露 `identifier`
- 负责设置 `interval` / `tolerance` / `qualityOfService` / `repeats`
- 负责注册 handler
- 负责 `invalidate()`
- 在测试里用 fake scheduler 验证注册、刷新、停用和 completion 调用

这样 Task 2 到 Task 5 的核心逻辑都可以在单元测试内跑完，避免计划执行过程被 AppKit 背景调度副作用拖慢。

### 4.2 任务定义与运行记录分离

`BackgroundAgentTask` 是用户可编辑模板，`BackgroundAgentTaskRun` 是一次触发样本。两者不要混在一个模型里，否则：

- 任务编辑和运行审计会互相污染
- skip / defer 无法成为一等观测样本
- 下次策略调整缺少历史依据

首期就要把 `status`、`decision`、`resultSummary`、`messageId` 等字段放到 run record，而不是塞回 task 本体。

### 4.3 后台执行走新的 adapter，不直接在 UI service 上打洞

不要让设置页或 scheduler block 直接调用 `ClaudeService.runAgenticLoop(...)`。统一通过：

- `BackgroundPromptComposer`
- `BackgroundAgentLoopAdapter`
- `BackgroundSessionResultWriter`
- `BackgroundTaskExecutionCoordinator`

这样后续如果要引入“仅摘要任务”“仅内存维护任务”“文件系统触发任务”，只需要换 adapter，而不必改 scheduler 层。

### 4.4 首期 UI 只做任务管理，不做复杂后台面板

产品需要用户手动创建任务，所以本期必须有：

- 后台总开关
- 任务列表
- 创建 / 编辑 sheet
- 启停任务
- 最近运行摘要

但不需要在本期引入复杂历史过滤、趋势图或多列分析面板。运行历史明细可以先通过最近记录摘要和 SwiftData 数据源支撑，后续再扩。

## 5. 任务拆解

### Task 1: 建立后台任务模型、策略值类型和设置字段

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackgroundAgentTask.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackgroundAgentTaskRun.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackgroundTaskPolicy.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackgroundTaskExecutionPolicy.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackgroundTaskToolGrantPolicy.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundAgentTaskModelTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

**Step 1: Write the failing tests**

新增测试覆盖：

- `BackgroundAgentTask` 默认字段完整，`taskKey` 生成后可稳定持久化
- `BackgroundTaskPolicy` / `BackgroundTaskExecutionPolicy` / `BackgroundTaskToolGrantPolicy` 可编码解码
- `BackgroundAgentTaskRun` 可表达 `triggered`、`running`、`completed`、`failed`、`deferred`、`skipped`
- `AppSettings` 默认提供后台总开关、默认 QoS、最大并发数、观测保留天数
- `agentGuiApp` 的 schema 已包含两个新 SwiftData 模型

测试示例：

```swift
import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct BackgroundAgentTaskModelTests {

    @Test func taskPoliciesRoundTripThroughJSON() throws {
        let policy = BackgroundTaskPolicy(
            baseIntervalSeconds: 21_600,
            toleranceSeconds: 3_600,
            repeats: true,
            qualityOfService: .utility
        )

        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(BackgroundTaskPolicy.self, from: data)

        #expect(decoded.baseIntervalSeconds == 21_600)
        #expect(decoded.qualityOfService == .utility)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/BackgroundAgentTaskModelTests
```

Expected: FAIL，因为后台任务模型与设置字段尚未存在。

**Step 3: Write minimal implementation**

最小实现内容：

- 新增两个 SwiftData 模型和三个 Codable 策略值类型
- 在 `AppSettings` 增加后台开关和默认策略字段
- 在 `agentGuiApp` 的 schema 中注册新模型
- 给模型补齐最小初始化器和 JSON 访问器，避免 UI 和服务层手写字符串拼装

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/BackgroundAgentTask.swift agentGui/Models/BackgroundAgentTaskRun.swift agentGui/Models/BackgroundTaskPolicy.swift agentGui/Models/BackgroundTaskExecutionPolicy.swift agentGui/Models/BackgroundTaskToolGrantPolicy.swift agentGui/Models/AppSettings.swift agentGui/agentGuiApp.swift agentGuiTests/BackgroundAgentTaskModelTests.swift
git commit -m "feat: add background task models and settings"
```

### Task 2: 引入 scheduler 抽象、policy engine 和任务 registry

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundSystemScheduler.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundTaskPolicyEngine.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundTaskRegistry.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundTaskPolicyEngineTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundTaskRegistryTests.swift`

**Step 1: Write the failing tests**

锁定以下行为：

- `BackgroundTaskPolicyEngine` 能把用户策略映射到系统 `interval` / `tolerance` / `qos` / `repeats`
- registry 为同一个 `taskKey` 生成稳定 identifier，例如 `com.agentgui.background.task.<taskKey>`
- registry 能根据启用状态、删除状态做增量注册和清理，而不是每次全量重建
- fake scheduler 在任务停用后收到 `invalidate()`

测试示例：

```swift
@Test func registryUsesStableSchedulerIdentifier() {
    let task = BackgroundAgentTask(taskKey: "repo-daily-summary", title: "日报", sessionId: "s-1", taskPrompt: "生成日报")

    #expect(BackgroundTaskRegistry.schedulerIdentifier(for: task) == "com.agentgui.background.task.repo-daily-summary")
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/BackgroundTaskPolicyEngineTests \
  -only-testing:agentGuiTests/BackgroundTaskRegistryTests
```

Expected: FAIL，因为 scheduler abstraction、policy engine 和 registry 尚未实现。

**Step 3: Write minimal implementation**

最小实现内容：

- 定义 `BackgroundSystemScheduler` 协议和 `NSBackgroundActivityScheduler` 适配器
- 实现 policy engine，把 trigger policy 映射为系统调度参数
- 实现 registry，从 `ModelContext` 拉取 enabled tasks，维护 scheduler map 和稳定 identifier
- 暂时只完成注册与失效，不接执行路径

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Background/BackgroundSystemScheduler.swift agentGui/Services/Background/BackgroundTaskPolicyEngine.swift agentGui/Services/Background/BackgroundTaskRegistry.swift agentGuiTests/BackgroundTaskPolicyEngineTests.swift agentGuiTests/BackgroundTaskRegistryTests.swift
git commit -m "feat: add background scheduler registry and policy engine"
```

### Task 3: 建立 eligibility evaluator 和 observation service

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundTaskEligibilityEvaluator.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundTaskObservationService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundTaskEligibilityEvaluatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentBusinessEvent.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/BusinessMonitor.swift`

**Step 1: Write the failing tests**

新增测试覆盖：

- disabled task 返回 `skip`
- 命中 cooldown、已有同 taskKey 运行中实例、scheduler `shouldDefer` 为 true 时返回 `defer`
- 工作区路径不存在时返回结构化 skip 原因
- observation service 能写入 `BackgroundAgentTaskRun` 初始记录并发出业务事件
- 新增事件类别 `backgroundTaskRegistered`、`backgroundTaskTriggered`、`backgroundTaskSkipped`、`backgroundTaskDeferred`、`backgroundTaskStarted`、`backgroundTaskCompleted`、`backgroundTaskFailed`

测试示例：

```swift
@Test func cooldownTaskIsDeferredInsteadOfExecuted() throws {
    let task = BackgroundAgentTask.fixture(cooldownUntil: Date().addingTimeInterval(600))
    let evaluator = BackgroundTaskEligibilityEvaluator()

    let result = evaluator.evaluate(task: task, now: Date(), environment: .fixture())

    #expect(result.decision == .defer)
    #expect(result.reason == "cooldownActive")
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/BackgroundTaskEligibilityEvaluatorTests
```

Expected: FAIL，因为 evaluator 和新的业务事件类型尚未存在。

**Step 3: Write minimal implementation**

最小实现内容：

- 定义 eligibility 输入环境和值结果
- 实现 `skip` / `defer` / `run` 三分类
- 实现 observation service，负责创建 run record、更新状态摘要和记录业务事件
- 扩展现有 business event 类型与 monitor 便于背景任务复用

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Background/BackgroundTaskEligibilityEvaluator.swift agentGui/Services/Background/BackgroundTaskObservationService.swift agentGui/Models/AgentBusinessEvent.swift agentGui/Utilities/BusinessMonitor.swift agentGuiTests/BackgroundTaskEligibilityEvaluatorTests.swift
git commit -m "feat: add background task eligibility and observation"
```

### Task 4: 实现 prompt composer、session result writer 和 AgentLoop adapter

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundPromptComposer.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundSessionResultWriter.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/Adapters/BackgroundAgentLoopAdapter.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundPromptComposerTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundSessionResultWriterTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundAgentLoopAdapterTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopRunRequest.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`

**Step 1: Write the failing tests**

锁定以下行为：

- prompt composer 会注入任务名、触发时间、工作区路径、后台执行约束，不直接裸跑用户 prompt
- session result writer 在目标 `Session` 中追加一条系统说明消息和一条 agent 结果消息
- 失败时写入精简失败摘要，不暴露内部堆栈
- background adapter 创建受限 `AgentLoopRunRequest`，强制更低 `maxRounds`、后台 `toolExecutionContext`、可选模型 override

测试示例：

```swift
@Test func composerInjectsBackgroundExecutionCapsule() {
    let composer = BackgroundPromptComposer()
    let rendered = composer.compose(
        task: .fixture(title: "巡检", taskPrompt: "检查仓库状态"),
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(rendered.contains("任务名称：巡检"))
    #expect(rendered.contains("禁止等待人工输入"))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/BackgroundPromptComposerTests \
  -only-testing:agentGuiTests/BackgroundSessionResultWriterTests \
  -only-testing:agentGuiTests/BackgroundAgentLoopAdapterTests
```

Expected: FAIL，因为 composer、writer、adapter 和后台 run request 扩展尚未实现。

**Step 3: Write minimal implementation**

最小实现内容：

- 给 `AgentLoopRunRequest` 增加后台来源元数据，例如 `runSource`、`runLabel`、`requestedBudgetSeconds`
- 在 `ClaudeService+AgenticLoop.swift` 中允许后台 adapter 复用 `runCoreAgentLoop`，但不把 UI message 构造责任混进去
- 实现 prompt capsule 渲染
- 实现 session-native 结果写回
- 实现 adapter，把后台任务转成一次受控的 agent loop 请求

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Background/BackgroundPromptComposer.swift agentGui/Services/Background/BackgroundSessionResultWriter.swift agentGui/Services/Background/Adapters/BackgroundAgentLoopAdapter.swift agentGui/Models/AgentLoopRunRequest.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGuiTests/BackgroundPromptComposerTests.swift agentGuiTests/BackgroundSessionResultWriterTests.swift agentGuiTests/BackgroundAgentLoopAdapterTests.swift
git commit -m "feat: add background prompt composition and agent loop adapter"
```

### Task 5: 接入 execution coordinator 和 app bootstrap coordinator

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundTaskExecutionCoordinator.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundActivityCoordinator.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundTaskExecutionCoordinatorTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundActivityCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/RuntimeRecoveryService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

**Step 1: Write the failing tests**

新增测试覆盖：

- app 启动时如果 `backgroundAgentEnabled == true`，coordinator 会 bootstrap 所有 enabled tasks
- scheduler 触发后先写入 `.triggered` run，再执行 eligibility，再决定 `.deferred` 或真正执行
- execution coordinator 能串起 observation、prompt composition、agent adapter、session writer 和 task 状态回写
- 执行完成后一定调用 completion handler
- 启动时能把异常卡在 `.running` 的历史 run 归一为 `.interrupted` 或恢复候选状态

测试示例：

```swift
@Test func coordinatorBootstrapsEnabledTasksOnAppLaunch() async throws {
    let harness = try BackgroundActivityCoordinatorHarness.make()
    let coordinator = harness.coordinator

    try await coordinator.bootstrap(modelContext: harness.modelContext)

    #expect(harness.schedulerFactory.createdIdentifiers == ["com.agentgui.background.task.repo-daily-summary"])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/BackgroundTaskExecutionCoordinatorTests \
  -only-testing:agentGuiTests/BackgroundActivityCoordinatorTests
```

Expected: FAIL，因为 coordinator 链路和 app bootstrap wiring 尚未存在。

**Step 3: Write minimal implementation**

最小实现内容：

- `BackgroundTaskExecutionCoordinator` 负责整合 evaluator、observation、adapter、writer、task/run 更新
- `BackgroundActivityCoordinator` 负责 bootstrap、re-register、handle trigger、invalidate removed tasks
- 在 `agentGuiApp` 中创建并注入后台 coordinator；应用启动时读取 `AppSettings` 并按开关决定是否 bootstrap
- 在 `RuntimeRecoveryService` 增加后台 run 归一化辅助入口，统一处理残留 `.running`

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Background/BackgroundTaskExecutionCoordinator.swift agentGui/Services/Background/BackgroundActivityCoordinator.swift agentGui/Services/RuntimeRecoveryService.swift agentGui/agentGuiApp.swift agentGuiTests/BackgroundTaskExecutionCoordinatorTests.swift agentGuiTests/BackgroundActivityCoordinatorTests.swift
git commit -m "feat: bootstrap background activity coordination"
```

### Task 6: 加入设置页和任务管理 UI，支持手动创建与启停

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/BackgroundTaskManagementViewModel.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsBackgroundAutomationView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Background/BackgroundTaskListView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Background/BackgroundTaskEditorSheet.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundTaskManagementViewModelTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/BackgroundTaskManagementUITests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsWindowView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsNavigationItem.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsGeneralView.swift`

**Step 1: Write the failing tests**

锁定以下行为：

- 用户可以创建绑定 `Session` 的后台任务
- 表单至少要求任务名称、目标会话、提示词正文、运行频率
- 任务列表可启停任务，并显示最近结果摘要与连续失败次数
- 后台总开关关闭时，创建入口和启停动作呈现禁用状态
- UI test 能覆盖创建任务、启停任务、查看失败状态和 cooldown 标记

测试示例：

```swift
@MainActor
@Test func saveTaskRejectsMissingPrompt() throws {
    let viewModel = BackgroundTaskManagementViewModel(modelContext: .inMemoryForTesting())

    viewModel.draftTitle = "日报"
    viewModel.draftSessionID = "session-1"
    viewModel.draftPrompt = ""

    #expect(throws: BackgroundTaskManagementViewModel.ValidationError.self) {
        try viewModel.saveDraft()
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/BackgroundTaskManagementViewModelTests
```

Expected: FAIL，因为管理 view model 和后台设置页尚未存在。

UI 测试在本任务末尾单独执行：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiUITests/BackgroundTaskManagementUITests
```

**Step 3: Write minimal implementation**

最小实现内容：

- 新增后台自动化设置页或设置分组
- 新增任务列表和编辑 sheet
- `BackgroundTaskManagementViewModel` 统一承载列表查询、创建/编辑、启停、立即刷新注册请求
- 保存任务后通知 `BackgroundActivityCoordinator` 执行 re-register，避免用户重启应用才能生效

**Step 4: Run tests to verify they pass**

先跑 view model tests，再跑 UI tests。预期都 PASS。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/BackgroundTaskManagementViewModel.swift agentGui/Views/Settings/SettingsBackgroundAutomationView.swift agentGui/Views/Background/BackgroundTaskListView.swift agentGui/Views/Background/BackgroundTaskEditorSheet.swift agentGui/Views/Settings/SettingsWindowView.swift agentGui/Views/Settings/SettingsNavigationItem.swift agentGui/Views/Settings/SettingsStore.swift agentGui/Views/Settings/SettingsGeneralView.swift agentGuiTests/BackgroundTaskManagementViewModelTests.swift agentGuiUITests/BackgroundTaskManagementUITests.swift
git commit -m "feat: add background task management ui"
```

### Task 7: 做集成收尾、质量验证和文档回填

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-16-nsbackgroundactivityscheduler-agent-design.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-16-nsbackgroundactivityscheduler-agent-implementation-plan.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundActivityCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundTaskExecutionCoordinatorTests.swift`

**Step 1: Write the failing integration assertions**

把最后一轮集成契约补齐：

- 手工创建任务后，coordinator 能生成稳定 scheduler 并在触发后回写 session
- `skip` / `defer` / `completed` / `failed` 都会写入 `BackgroundAgentTaskRun`
- 连续失败会更新 `consecutiveFailureCount` 与 `cooldownUntil`
- 删除任务后 scheduler 被失效并从 registry 清理

**Step 2: Run focused integration tests and smoke**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/BackgroundActivityCoordinatorTests \
  -only-testing:agentGuiTests/BackgroundTaskExecutionCoordinatorTests
```

然后运行仓库已有 smoke task：

```bash
./scripts/run_quality_smoke.sh
```

Expected: 所有与后台任务相关的单元测试通过；如果 smoke 暴露与本需求无关的历史问题，只记录到计划回填，不顺手修 unrelated failure。

**Step 3: Finish implementation gaps**

根据集成结果只补本功能直接相关缺口：

- completion handler 漏调用
- run 记录状态不一致
- scheduler refresh 漏失效旧实例
- session 回写顺序不稳定

**Step 4: Update docs**

更新设计文档中的“已落地偏差 / 当前实现状态”，并在本计划文档中标记已完成任务与偏差说明。

**Step 5: Commit**

```bash
git add docs/plans/2026-03-16-nsbackgroundactivityscheduler-agent-design.md docs/plans/2026-03-16-nsbackgroundactivityscheduler-agent-implementation-plan.md agentGuiTests/BackgroundActivityCoordinatorTests.swift agentGuiTests/BackgroundTaskExecutionCoordinatorTests.swift
git commit -m "docs: reconcile background scheduler implementation plan"
```

## 6. 测试矩阵

实现期间至少保持下面这组测试常绿：

- `agentGuiTests/BackgroundAgentTaskModelTests`
- `agentGuiTests/BackgroundTaskPolicyEngineTests`
- `agentGuiTests/BackgroundTaskRegistryTests`
- `agentGuiTests/BackgroundTaskEligibilityEvaluatorTests`
- `agentGuiTests/BackgroundPromptComposerTests`
- `agentGuiTests/BackgroundSessionResultWriterTests`
- `agentGuiTests/BackgroundAgentLoopAdapterTests`
- `agentGuiTests/BackgroundTaskExecutionCoordinatorTests`
- `agentGuiTests/BackgroundActivityCoordinatorTests`
- `agentGuiTests/BackgroundTaskManagementViewModelTests`

回归时额外跑：

- `agentGuiTests/AgentLoopBusinessObservabilityTests`
- `agentGuiTests/AgentLoopRunnerTests`
- `agentGuiTests/RuntimeRecoveryServiceTests`
- `agentGuiUITests/BackgroundTaskManagementUITests`
- `./scripts/run_quality_smoke.sh`

## 7. 风险与执行注意事项

- `NSBackgroundActivityScheduler` 只能在 macOS 真环境体现真实调度语义，所以所有策略判断必须能在 fake scheduler 下单测；不要把“等待系统真的触发一次”当验证手段。
- `PersistentIdentifier` 在 `BackgroundAgentTaskRun.messageId` 上的存储方式要先确认是否直接可序列化；如果 SwiftData 上不稳定，首期降级为 `String` 存 `Message.id.uuidString`，避免 schema 卡死。
- 后台执行如果直接复用前台 `ToolContext`，很容易绕过权限边界；adapter 中必须显式指定后台上下文。
- app 启动 bootstrap 不能阻塞主界面太久；任务注册可以同步完成，但异常 run 归一化和观测清理要保持轻量。
- UI 首期不要引入复杂查询组合或大量批量操作，避免把计划拖成“后台管理平台”而不是“后台任务最小闭环”。

## 8. 完成定义

满足以下条件才算本计划完成：

- 用户能在设置页创建、编辑、启停后台任务。
- 应用启动后能按 enabled tasks 注册稳定 scheduler。
- 系统触发后会先做 eligibility 判定，再决定 skip、defer 或执行。
- 执行结果会回写到目标 `Session`，并形成用户可见消息。
- 所有关键阶段都会写入 `BackgroundAgentTaskRun` 和业务观测事件。
- 相关单元测试、UI 测试和仓库 smoke 至少完成一轮通过或明确记录非本需求缺陷。

Plan complete and saved to `docs/plans/2026-03-16-nsbackgroundactivityscheduler-agent-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
# Testing And Release Quality Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a release-oriented quality system for agentGui that turns the current unit-test-heavy baseline into a layered test strategy with real UI automation, scenario coverage, performance baselines, release gates, and a bug-to-test regression loop.

**Architecture:** Keep the work incremental and test-first. Start by adding deterministic test fixtures, launch-time test injection, and accessibility identifiers so UI and scenario automation can run against stable in-memory data. Then layer on critical-path UI tests, service-level scenario tests, performance/stability baselines, and finally standardize release and regression workflows in checked-in docs so quality gates no longer live in tribal knowledge.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, XCTest UI Testing, Foundation, existing RuntimeRecoveryService, WorkflowRuntime, ClaudeService, AppSettings, Session, Message, ToolCall, Story Memory services.

---

## 1. 实施原则

- 先补测试支撑点，再写真正的 UI 自动化；不要直接在模板 UI Tests 上堆业务断言。
- 先覆盖关键路径，再扩展到性能和稳定性；P0 目标是让发布前最容易回归的链路自动报警。
- 所有新增测试默认使用 in-memory `ModelContainer`，测试入口尽量保持 `@MainActor`，避免 Swift 6 默认隔离带来的噪音。
- UI 自动化必须依赖稳定的 launch arguments、fixture 数据和 `accessibilityIdentifier`，不能依赖文案模糊匹配或人工目测。
- 发布检查必须沉淀为仓库内文档和可直接执行的命令，不接受只存在于聊天记录里的“约定”。
- 每个 P0/P1 回归问题最终都要落成测试资产或明确记录为什么暂不自动化。

## 2. 当前代码落点

本次需求主要围绕以下现有文件展开：

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MainSplitView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkflowTimelineView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowRuntime.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/RuntimeRecoveryService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RuntimeRecoveryServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkflowBusinessObservabilityTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/agentGuiUITests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/agentGuiUITestsLaunchTests.swift`

已确认的主要缺口：

- `agentGuiTests` 已有较多单元测试，但缺少按“关键用户目标”组织的场景测试。
- `agentGuiUITests` 仍然是 Xcode 默认模板，没有稳定的测试入口、fixture 或断言目标。
- 主界面目前没有系统化的 `accessibilityIdentifier`，UI 自动化查询成本高且脆弱。
- 应用启动虽然已经在测试环境切到 in-memory store，但缺少更细的 launch argument 注入点来驱动预设场景。
- 发布前检查矩阵、测试层级映射和回归沉淀流程尚未文档化。

## 3. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/PreviewData.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/QualityFixtureBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/InMemoryAppHarness.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/QualityFixtureBuilderTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ReleaseScenarioTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/PerformanceBaselineTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StabilityBaselineTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/UITestBase.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SessionManagementUITests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/ChatFlowUITests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/ToolCallUITests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/WorkflowRecoveryUITests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SettingsUITests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-11-testing-layer-matrix.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-11-release-checklist-matrix.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-11-regression-to-test-workflow.md`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MainSplitView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkflowTimelineView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Message.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/WorkflowInstance.swift`
- `/Volumes/T7/文稿/Projects/agentGui/docs/FEATURE_REQUIREMENTS.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-testing-and-release-quality-requirements.md`

## 4. 关键架构决策

### 4.1 测试入口统一走 launch options

不要把 UI 测试场景硬编码在各个视图的 `onAppear` 里。新增 `TestLaunchOptions`，在 `agentGuiApp` 启动时解析：

- 是否开启 UI 测试模式
- 初始选中的 tab
- 是否预置 API Key
- 是否注入示例消息、工具调用、工作流状态、恢复状态
- 是否在测试模式下关闭后台调度和不稳定副作用

这样 UI 测试只需要组合启动参数，就能覆盖设置、普通对话、工具调用、工作流、恢复等路径。

### 4.2 共享 fixture 与 PreviewData 使用同一套构造器

不要让 Preview、单元测试、场景测试、UI 测试各自维护一份演示数据。由 `QualityFixtureBuilder` 提供统一工厂，为 `Session`、`Message`、`ToolCall`、`WorkflowInstance`、Story Memory 相关记录生成稳定样本；`PreviewData` 复用这些样本，避免 UI 调整后 preview 和测试脱节。

### 4.3 UI 自动化查询全部基于 accessibility identifiers

为关键页面和关键交互统一命名：

- `tab.chat`、`tab.settings`、`tab.reliability`
- `sessionList.list`、`sessionList.createButton`
- `chat.messageList`、`chat.inputField`、`chat.sendButton`
- `toolDetail.panel`、`toolDetail.result`
- `workspace.selector`、`workspace.fileTree`
- `workflow.timeline`、`workflow.resumeButton`
- `settings.apiKeyField`、`settings.saveButton`

命名一旦落地，后续 UI 测试和辅助功能检查都沿用这套标识。

### 4.4 场景测试优先验证“用户目标完成”

`ReleaseScenarioTests` 不应只验证单个 service 方法输出，而应围绕规格中列出的 7 条关键路径组织：首次配置 API Key、普通对话、工具调用、Bash 任务、工作流执行、Story Memory 使用、会话恢复。每个场景至少断言：初始条件、关键动作、持久化结果、用户可见状态摘要。

### 4.5 性能基线先从可重复的轻量指标开始

首轮不要追求复杂 profiling 基础设施，先用可重复的基线测试覆盖：

- 长消息渲染
- Markdown 增量解析
- 长会话加载
- 文件树加载
- 工作流运行和恢复摘要构建

阈值先保守，目标是让明显回退能被自动发现。

## 5. 任务拆解

### Task 1: 搭建共享测试基建与可注入启动参数

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/PreviewData.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/QualityFixtureBuilder.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/InMemoryAppHarness.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/QualityFixtureBuilderTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Message.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/WorkflowInstance.swift`

**Step 1: 写失败测试，固定 fixture 和 launch contract**

新增测试覆盖：

- `QualityFixtureBuilder` 能生成可重复的会话、消息、工具调用、工作流和恢复场景样本
- `TestLaunchOptions` 能正确解析 launch arguments，并在非法值时回退到安全默认值
- `InMemoryAppHarness` 能在不触发真实网络和后台任务的前提下完成应用测试初始化

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct QualityFixtureBuilderTests {

    @Test func parsesLaunchOptionsForRecoveryScenario() throws {
        let options = TestLaunchOptions(arguments: [
            "-com.agentgui.test.mode", "true",
            "-com.agentgui.test.workflowState", "running",
            "-com.agentgui.test.recoveryMode", "true"
        ])

        #expect(options.isUITestMode)
        #expect(options.workflowState == .running)
        #expect(options.recoveryMode)
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/QualityFixtureBuilderTests
```

Expected: FAIL，因为测试基建和 launch option 解析尚未实现。

**Step 3: 写最小实现**

实现内容：

- `TestLaunchOptions` 解析测试启动参数
- `agentGuiApp` 在测试模式下注入可预测的 in-memory fixture，并禁用不稳定后台行为
- 为核心模型补齐测试/preview 共享 fixture 工厂
- `PreviewData` 复用同一套构造器，避免示例数据分叉

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Utilities/TestLaunchOptions.swift agentGui/Utilities/PreviewData.swift agentGui/agentGuiApp.swift agentGui/Models/AppSettings.swift agentGui/Models/Session.swift agentGui/Models/Message.swift agentGui/Models/ToolCall.swift agentGui/Models/WorkflowInstance.swift agentGuiTests/TestSupport/QualityFixtureBuilder.swift agentGuiTests/TestSupport/InMemoryAppHarness.swift agentGuiTests/QualityFixtureBuilderTests.swift
git commit -m "test: add shared quality test fixtures"
```

### Task 2: 为关键界面补齐自动化可见性标识

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MainSplitView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkflowTimelineView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/UITestBase.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SessionManagementUITests.swift`

**Step 1: 写失败 UI 测试，固定基础导航路径**

新增 `SessionManagementUITests`，覆盖：

- 应用可通过 launch arguments 启动到聊天页
- 会话列表、消息区、工作区树可被稳定查询
- 新建会话按钮点击后列表出现新的会话行

测试示例：

```swift
import XCTest

final class SessionManagementUITests: UITestBase {

    @MainActor
    func testCreateSessionShowsNewRow() throws {
        launchApp(arguments: ["-com.agentgui.test.mode", "true"])

        XCTAssertTrue(app.tables["sessionList.list"].exists)
        app.buttons["sessionList.createButton"].click()
        XCTAssertTrue(app.outlines.matching(identifier: "sessionList.item").firstMatch.exists)
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiUITests/SessionManagementUITests
```

Expected: FAIL，因为还没有 `UITestBase` 和关键标识。

**Step 3: 写最小实现**

实现内容：

- 新增 `UITestBase` 统一设置 launch arguments 和环境
- 为 Tab、三栏布局、会话列表、消息区、工作区树、新建按钮补齐 `accessibilityIdentifier`
- 如果会话列表当前缺少稳定“空态到首条会话”的交互入口，一并补齐最小可测交互

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/ContentView.swift agentGui/Views/MainSplitView.swift agentGui/Views/SessionListView.swift agentGui/Views/ChatView.swift agentGui/Views/WorkspacePanelView.swift agentGuiUITests/UITestBase.swift agentGuiUITests/SessionManagementUITests.swift
git commit -m "test: add ui automation identifiers for core navigation"
```

### Task 3: 落地首批 P0 UI 自动化回归用例

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/ChatFlowUITests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/ToolCallUITests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/WorkflowRecoveryUITests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SettingsUITests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkflowTimelineView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

**Step 1: 先写 5 条失败的关键路径 UI 用例**

新增用例覆盖：

- 首次配置 API Key 并保存
- 普通对话发送后消息区出现用户消息与代理消息
- 工具详情面板可展开并显示结果
- 工作流启动后时间线出现运行状态
- 启动恢复模式时出现恢复提示并可执行“标记中断”或“查看详情”

建议测试类分布：

- `SettingsUITests`: API Key、模型、代理设置
- `ChatFlowUITests`: 普通对话、长消息渲染
- `ToolCallUITests`: 工具详情与结果展示
- `WorkflowRecoveryUITests`: 工作流、恢复、可靠性页面入口

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiUITests/SettingsUITests \
  -only-testing:agentGuiUITests/ChatFlowUITests \
  -only-testing:agentGuiUITests/ToolCallUITests \
  -only-testing:agentGuiUITests/WorkflowRecoveryUITests
```

Expected: FAIL，因为预置场景和细粒度标识还不完整。

**Step 3: 写最小实现**

实现内容：

- `agentGuiApp` 根据 launch options 预装测试 session、消息、工具调用、工作流、恢复快照
- 设置页、工具详情、工作流时间线、恢复入口补齐精确标识
- 为 UI 测试补足必要但最小的可见反馈，避免只能依赖内部状态

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS，且 UI Tests 不再是模板工程。

**Step 5: Commit**

```bash
git add agentGui/agentGuiApp.swift agentGui/ContentView.swift agentGui/Views/ToolCallDetailContentView.swift agentGui/Views/WorkflowTimelineView.swift agentGuiUITests/ChatFlowUITests.swift agentGuiUITests/ToolCallUITests.swift agentGuiUITests/WorkflowRecoveryUITests.swift agentGuiUITests/SettingsUITests.swift
git commit -m "test: add critical release ui regression coverage"
```

### Task 4: 建立关键用户路径场景测试

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ReleaseScenarioTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/RuntimeRecoveryService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowRuntime.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`

**Step 1: 写失败的场景测试，覆盖 7 条关键用户路径**

场景建议至少包含：

- 首次配置 API Key 后，`ClaudeService` 获得可用连接设置
- 普通对话完成后，会话和消息持久化状态正确
- 工具调用完成后，`ToolCall` 与消息展示数据一致
- Bash 任务执行后，任务快照或事件摘要可恢复
- 工作流执行后，激活记录和状态摘要可观察
- Story Memory 写入后，检索输入能命中对应上下文
- 应用重启后，恢复服务能找回中断任务或待完成消息

测试示例：

```swift
import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ReleaseScenarioTests {

    @Test func sessionRecoveryScenarioFindsInterruptedWorkflowAndPendingMessage() async throws {
        let harness = try InMemoryAppHarness.makeRecoveryScenario()

        let summary = try harness.runtimeRecoveryService.loadRecoverySummary(from: harness.context)

        #expect(summary.items.count == 2)
        #expect(summary.items.contains { $0.sourceKind == .workflow })
        #expect(summary.items.contains { $0.sourceKind == .messageGeneration })
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ReleaseScenarioTests
```

Expected: FAIL，因为关键路径场景尚未用统一 harness 组织。

**Step 3: 写最小实现**

实现内容：

- 用 `InMemoryAppHarness` 封装关键业务依赖，减少每个场景测试自行拼装容器和服务
- 在 `RuntimeRecoveryService`、`WorkflowRuntime`、`MemoryRuntimeCoordinator` 暴露适合场景验证的摘要接口或轻量测试钩子
- 尽量复用现有单元测试中的 in-memory patterns，避免重复造轮子

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGuiTests/ReleaseScenarioTests.swift agentGui/Services/RuntimeRecoveryService.swift agentGui/Services/WorkflowRuntime.swift agentGui/Services/MemoryRuntimeCoordinator.swift agentGui/Models/AppSettings.swift
git commit -m "test: add release scenario coverage for critical user flows"
```

### Task 5: 建立性能与稳定性基线

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/PerformanceBaselineTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StabilityBaselineTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RuntimeRecoveryServiceTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkflowBusinessObservabilityTests.swift`

**Step 1: 写失败测试，固定首批基线指标与异常恢复期望**

性能基线至少包括：

- `MarkdownMessageIncrementalParser` 处理 10KB 混合 Markdown 的耗时
- 长会话加载 500 条消息的耗时
- 工作流时间线摘要构建耗时
- 文件树加载和刷新耗时

稳定性基线至少包括：

- API 失败时不会留下不一致的消息状态
- 工具失败时仍保留可诊断记录
- 保存失败时可靠性面板能显示摘要
- 重启恢复后可把中断项标记为已处理

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/PerformanceBaselineTests \
  -only-testing:agentGuiTests/StabilityBaselineTests
```

Expected: FAIL，因为基线测试文件和阈值尚未建立。

**Step 3: 写最小实现**

实现内容：

- 引入可重复的基线测试样本与阈值常量
- 复用现有恢复和工作流测试数据，避免用脆弱的随机输入做基线
- 将稳定性断言尽量落在现有 service 输出与持久化结果上，而不是 UI 文案

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS，后续可按真实机器结果再微调阈值。

**Step 5: Commit**

```bash
git add agentGuiTests/PerformanceBaselineTests.swift agentGuiTests/StabilityBaselineTests.swift agentGuiTests/RuntimeRecoveryServiceTests.swift agentGuiTests/WorkflowBusinessObservabilityTests.swift
git commit -m "test: add performance and stability baselines"
```

### Task 6: 固化测试层级映射、发布矩阵与回归闭环

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-11-testing-layer-matrix.md`
- Create: `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-11-release-checklist-matrix.md`
- Create: `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-11-regression-to-test-workflow.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/FEATURE_REQUIREMENTS.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-testing-and-release-quality-requirements.md`

**Step 1: 写文档骨架，先把门槛、责任和执行顺序写死**

文档内容至少包括：

- 五类测试的定义、覆盖对象、触发时机、最小通过门槛
- P0/P1 功能需求文档必须补充的测试层级映射模板
- 发布前必须执行的命令、顺序、通过标准、人工确认项
- 线上或手测发现回归后，如何把 bug 链接到新增测试与修复记录

**Step 2: 人工校对文档与现有代码结构一致**

Check:

```bash
rg -n "测试层级|发布前|回归" docs/technical-spec docs/FEATURE_REQUIREMENTS.md docs/spec/2026-03-10-testing-and-release-quality-requirements.md
```

Expected: 能看到统一术语、统一优先级和明确执行命令。

**Step 3: 写最小落地内容**

建议文档结构：

- `testing-layer-matrix.md`: 单元 / 集成 / 场景 / UI / 性能 的责任边界和示例
- `release-checklist-matrix.md`: 构建、单测、场景、UI、迁移、恢复、权限、导出路径检查
- `regression-to-test-workflow.md`: bug 编号、复现、测试补齐、修复、回归验证、关闭标准
- `FEATURE_REQUIREMENTS.md`: 为未来需求文档新增“测试层级映射”小节模板

**Step 4: 人工复核并补全遗漏项**

Check 同 Step 2。

Expected: 文档可直接被开发者用于发布前执行，不需要额外口头说明。

**Step 5: Commit**

```bash
git add docs/technical-spec/2026-03-11-testing-layer-matrix.md docs/technical-spec/2026-03-11-release-checklist-matrix.md docs/technical-spec/2026-03-11-regression-to-test-workflow.md docs/FEATURE_REQUIREMENTS.md docs/spec/2026-03-10-testing-and-release-quality-requirements.md
git commit -m "docs: define testing layers and release quality gates"
```

## 6. 发布前执行建议

在 Task 1 到 Task 6 完成后，建议至少执行以下命令作为首轮发布前验证：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test
```

如果全量测试过慢，先执行最关键的一组：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ReleaseScenarioTests \
  -only-testing:agentGuiTests/PerformanceBaselineTests \
  -only-testing:agentGuiTests/StabilityBaselineTests \
  -only-testing:agentGuiUITests/SessionManagementUITests \
  -only-testing:agentGuiUITests/ChatFlowUITests \
  -only-testing:agentGuiUITests/ToolCallUITests \
  -only-testing:agentGuiUITests/WorkflowRecoveryUITests \
  -only-testing:agentGuiUITests/SettingsUITests
```

## 7. 完成定义

以下条件全部满足，才算本计划完成：

- `agentGuiUITests` 不再是模板工程，至少有 5 条关键用户路径自动化用例。
- 关键用户路径具备统一的场景测试入口，并覆盖工作流、工具调用、恢复。
- 长消息渲染、Markdown 解析、长会话加载、文件树加载、工作流运行具备可重复的性能基线。
- 发布前检查矩阵和测试层级映射已在仓库内文档化。
- 新增 P0/P1 功能需求文档有明确的测试层级映射要求。
- 至少选取一个真实回归案例，按 bug -> test -> fix 的流程演练一次并记录。
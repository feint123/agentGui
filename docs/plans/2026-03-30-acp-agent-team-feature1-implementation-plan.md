# ACP Agent Team Feature 1 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 agentGui 落地 Feature 1 的 team session 壳层：把 `agentTeam` 作为一种 `SessionKind` 引入会话体系，使其能在 session 列表中显示、作为“新建对话”菜单中的一个选项被创建，并在 `WorkbenchShellView` 的主内容区内渲染独立于普通消息气泡的 team surface。

**Architecture:** 继续以 `Session` 作为 workbench 与 session list 的一级主对象，不再走“独立 team window”路径。Feature 1 的核心是新增 `SessionKind.agentTeam`，并让 `WorkbenchConversationPane` 根据选中的 session kind 在同一 workbench 内容位中切换 `ChatView` 与 `AgentTeamSessionView`；如需保存 team lifecycle 元数据，使用一个从属于 `Session(kind: .agentTeam)` 的轻量 team state model，而不是一个绕开 session 列表的顶级窗口实体。

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Observation, existing `Session` / `SessionKind` / `SessionCatalogViewModel` / `WorkbenchConversationPane` / `ChatView`, Swift Testing, XCTest UI tests.

**Depends On:** [docs/plans/2026-03-30-acp-agent-team-design.md](../plans/2026-03-30-acp-agent-team-design.md)

---

## 0. 执行约束

- 我正在使用 writing-plans skill 来编写这份 implementation plan。
- 这份计划只覆盖 Feature 1，不提前实现 Feature 2 的完整 Team Workbench shell、Feature 3 的 mission brief、或后续 claim/artifact/review 协议。
- `agentTeam` 必须是第一类 `SessionKind`，这样它才能自然进入 [agentGui/Views/SessionListView.swift](agentGui/Views/SessionListView.swift) 和现有 session 切换流。
- 不再为 Feature 1 设计独立窗口或新的顶级 scene；team surface 必须和普通 chat 一样，承载在 [agentGui/Views/Workbench/WorkbenchShellView.swift](agentGui/Views/Workbench/WorkbenchShellView.swift) 的主内容区内，具体分流落在 [agentGui/Views/Workbench/WorkbenchConversationPane.swift](agentGui/Views/Workbench/WorkbenchConversationPane.swift)。
- `agentTeam` 不能退化成“仍然用 `ChatView` 渲染、只是 title 改了”的伪实现；即使首版 UI 只是占位，也要用独立 view，不能把 team 过程投影回普通 `Message` 气泡主体。
- Team Mode 首版入口放在现有“新建对话”菜单内，优先复用 [agentGui/Views/NewSessionExecutionProviderMenu.swift](agentGui/Views/NewSessionExecutionProviderMenu.swift)，并同步覆盖 [agentGui/Views/SessionListView.swift](agentGui/Views/SessionListView.swift) 与 [agentGui/Views/Workbench/WorkbenchConversationPane.swift](agentGui/Views/Workbench/WorkbenchConversationPane.swift) 的空状态入口。
- 严格按 @test-driven-development 执行：每个任务先补失败测试，再写最小实现，再跑通过。
- 完成全部任务后，用 @requesting-code-review 做一次 focused review，重点检查：`SessionKind.agentTeam` 是否真的成为主入口、workbench 内容位是否完成分流、以及实现中是否还残留任何独立窗口思路。

## 1. 当前状态摘要

- 目前持久化的会话主实体只有 [agentGui/Models/Session.swift](agentGui/Models/Session.swift)，`SessionKind` 仅区分 `local` / `channel` / `backgroundTask`，没有 `agentTeam`。
- 当前 [agentGui/ViewModels/SessionCatalogViewModel.swift](agentGui/ViewModels/SessionCatalogViewModel.swift) 已按 `SessionKind.allCases` 重建 section，因此一旦新增 `SessionKind.agentTeam`，它理论上就能进入 session 列表，但前提是相应的展示标题、排序和交互策略被补齐。
- 当前主工作台 [agentGui/Views/Workbench/WorkbenchShellView.swift](agentGui/Views/Workbench/WorkbenchShellView.swift) 通过 [agentGui/Views/Workbench/WorkbenchConversationPane.swift](agentGui/Views/Workbench/WorkbenchConversationPane.swift) 固定渲染 [agentGui/Views/ChatView.swift](agentGui/Views/ChatView.swift)，还没有按 session kind 分流内容视图。
- 当前新建会话入口主要通过 [agentGui/Views/NewSessionExecutionProviderMenu.swift](agentGui/Views/NewSessionExecutionProviderMenu.swift) 复用在 [agentGui/Views/SessionListView.swift](agentGui/Views/SessionListView.swift)、[agentGui/Views/Workbench/WorkbenchConversationPane.swift](agentGui/Views/Workbench/WorkbenchConversationPane.swift) 和 chat toolbar 内。若 Team Mode 要作为“新增对话列表中的一个选项”，就不能再把入口绑死在 chat toolbar 动作里，而要提升到这层共享菜单。
- 当前 [agentGui/Services/Sessions/SessionInteractionPolicy.swift](agentGui/Services/Sessions/SessionInteractionPolicy.swift) 的可编辑、可删除、可重命名规则只考虑现有三种 session kind。新增 `agentTeam` 后必须明确其 sidebar 与 toolbar 行为，避免默认继承出错误权限。
- 当前 `agentGuiUITests` 目录为空，因此本 feature 需要首次新增基于 workbench 的 UI smoke test 文件，而不是依赖已存在的 team UI 测试。

## 2. Feature 1 目标态

完成后系统应满足以下条件：

1. 在“新建对话”菜单中选择 Team Mode 时，系统会创建一个新的 `Session(kind: .agentTeam)`，它和普通 chat session 一起出现在 session 列表中。
2. 普通 chat 与 `agentTeam` session 能并存，用户可以像切换普通对话一样在 sidebar 中切换它们。
3. 当选中 `agentTeam` session 时，`WorkbenchConversationPane` 不再渲染 `ChatView`，而是渲染独立的 `AgentTeamSessionView` 占位壳层。
4. `AgentTeamSessionView` 首版展示 team 标题、来源 chat、模式和生命周期状态，但不渲染普通消息列表和 composer。
5. 从“新建对话”菜单创建 `agentTeam` session 后，当前 workbench 直接切换到该 team session，而不是打开新窗口。

## 3. 目标文件清单

### 新增生产文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamMode.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamRunStatus.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamSessionState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamSessionFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamSessionView.swift`

### 新增测试文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionKindTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionStateTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionFactoryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchConversationPaneTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/AgentTeamSessionUITests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionKind.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/SessionCatalogViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Sessions/SessionInteractionPolicy.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/NewSessionExecutionProviderMenu.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchConversationPane.swift`

### 参考文件

- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-30-acp-agent-team-design.md`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionKind.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchConversationPane.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/NewSessionExecutionProviderMenu.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`

## 4. 验证命令

### Focused Feature 1 tests

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-agent-team-feature1 \
  -only-testing:agentGuiTests/SessionKindTests \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests \
  -only-testing:agentGuiTests/AgentTeamSessionFactoryTests \
  -only-testing:agentGuiTests/WorkbenchConversationPaneTests \
  -only-testing:agentGuiUITests/AgentTeamSessionUITests \
  CODE_SIGNING_ALLOWED=NO
```

Expected:

- `SessionKind.agentTeam`、team state、factory 和 workbench 分流 tests 全部通过。
- UI smoke 至少覆盖“从新建对话菜单创建 agentTeam session，并在同一 workbench 中切到 team surface”这条主路径。
- 不应出现任何依赖独立窗口或 scene value 的新增测试。

### Compile fallback when UI automation is noisy

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-agent-team-feature1-build \
  CODE_SIGNING_ALLOWED=NO
```

Expected: 新增 session kind、team state、team view 和 workbench 分流全部成功编译；若 UI test target 首次接入存在宿主噪音，先记录为测试基建问题，不要误判为 Feature 1 产品逻辑失败。

## 5. Task Breakdown

### Task 1: 为 Session 体系引入 agentTeam kind 与最小 team state

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionKind.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamMode.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamRunStatus.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamSessionState.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionKindTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionStateTests.swift`

**Step 1: Write the failing tests**

先锁住 session 层最小契约：

- `SessionKind` 新增 `.agentTeam`
- `.agentTeam` 有明确的 `displayName` 与 `defaultSourceTitle`
- `.agentTeam` 不会走 `ChatView` 的普通可发送会话语义
- `AgentTeamSessionState` 可以保存 team mode、lifecycle status、source session backlink
- `AgentTeamSessionState` 必须从属于一个 `Session(kind: .agentTeam)`，而不是单独漂浮成顶级 window data

测试草图：

```swift
import Testing
@testable import agentGui

struct SessionKindTests {
    @Test func agentTeamKindHasStablePresentation() {
        #expect(SessionKind.agentTeam.displayName == "Agent Team")
        #expect(SessionKind.allCases.contains(.agentTeam))
    }
}
```

```swift
import Testing
@testable import agentGui

@MainActor
struct AgentTeamSessionStateTests {
    @Test func teamStateBindsToAgentTeamSession() {
        let session = Session(title: "修复 ACP", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session, sourceSessionID: "chat-1", sourceSessionTitle: "修复 ACP")

        #expect(state.session === session)
        #expect(state.status == .created)
        #expect(state.mode == .executionDelivery)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-task1 \
  -only-testing:agentGuiTests/SessionKindTests \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 `.agentTeam` 和 team state model 尚不存在。

**Step 3: Write the minimal implementation**

实现要求：

- 在 `SessionKind` 中新增 `.agentTeam`
- 如果 `Session` 需要 team 辅助字段，只添加最少字段；更推荐让 source backlink 与生命周期状态落在 `AgentTeamSessionState`
- `AgentTeamSessionState` 使用 1:1 关系依附 `Session(kind: .agentTeam)`

实现草图：

```swift
enum SessionKind: String, Codable, CaseIterable, Sendable {
    case local
    case channel
    case backgroundTask
    case agentTeam
}

@Model
final class AgentTeamSessionState {
    @Relationship var session: Session?
    var sourceSessionID: String
    var sourceSessionTitle: String
    var modeRaw: String
    var statusRaw: String
}
```

注意：

- 不要在这个阶段把 team card / memo / artifact 数据塞进 `Session`
- 不要引入独立 window id 或 scene value

**Step 4: Run test to verify it passes**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/SessionKind.swift \
  agentGui/Models/Session.swift \
  agentGui/Models/AgentTeamMode.swift \
  agentGui/Models/AgentTeamRunStatus.swift \
  agentGui/Models/AgentTeamSessionState.swift \
  agentGuiTests/SessionKindTests.swift \
  agentGuiTests/AgentTeamSessionStateTests.swift
git commit -m "feat: add agent team session kind"
```

### Task 2: 让 session 列表和交互策略识别 agentTeam

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/SessionCatalogViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Sessions/SessionInteractionPolicy.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`

**Step 1: Write the failing tests**

先锁住 sidebar 相关行为：

- `SessionCatalogViewModel` 会把 `.agentTeam` 会话编进可见 section
- `.agentTeam` section 标题稳定
- `SessionInteractionPolicy` 对 `.agentTeam` 的 rename/delete/clear/send 规则明确，不依赖默认穿透

测试草图：

```swift
import Testing
@testable import agentGui

@MainActor
struct AgentTeamSessionCatalogTests {
    @Test func agentTeamSessionsAppearInCatalogSections() {
        let chat = Session.fixture(title: "普通对话", kind: .local)
        let team = Session.fixture(title: "团队壳层", kind: .agentTeam)
        let viewModel = SessionCatalogViewModel()

        viewModel.setSessions([chat, team])

        #expect(viewModel.visibleSections.contains(where: { $0.kind == .agentTeam }))
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-task2 \
  -only-testing:agentGuiTests/SessionKindTests \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 catalog 和 interaction policy 仍未理解 `.agentTeam`。

**Step 3: Write the minimal implementation**

实现要求：

- `SessionCatalogViewModel` 的 section 顺序明确包含 `.agentTeam`
- `SessionListView` 在现有列表里自然显示 team session，不新增单独导航
- `SessionInteractionPolicy` 明确 team session 是否允许 rename/delete；`canSend` 不应再驱动 team surface，因为选中 `.agentTeam` 后不会进入 `ChatView`

建议首版策略：

- `agentTeam` 允许删除
- `agentTeam` 允许重命名
- `agentTeam` 不提供 `clearMessages`

**Step 4: Run test to verify it passes**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/SessionCatalogViewModel.swift \
  agentGui/Services/Sessions/SessionInteractionPolicy.swift \
  agentGui/Views/SessionListView.swift
git commit -m "feat: show agent team sessions in catalog"
```

### Task 3: 在 WorkbenchConversationPane 内分流 ChatView 与 AgentTeamSessionView

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamSessionView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchConversationPane.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchConversationPaneTests.swift`

**Step 1: Write the failing tests**

锁住主内容区分流规则：

- 选中 `Session(kind: .local)` 时仍渲染 `ChatView`
- 选中 `Session(kind: .agentTeam)` 时改渲染 `AgentTeamSessionView`
- `AgentTeamSessionView` 具备稳定 accessibility identifiers，例如 `panel.agentTeam`, `agentTeam.placeholder`, `agentTeam.title`

测试草图：

```swift
import Testing
@testable import agentGui

@MainActor
struct WorkbenchConversationPaneTests {
    @Test func agentTeamSessionUsesDedicatedSurface() {
        let session = Session.fixture(title: "团队壳层", kind: .agentTeam)
        let pane = WorkbenchConversationPane()

        #expect(pane != nil)
        // 这里写 view inspection / presentation helper 断言，锁住 kind -> view 的映射
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-task3 \
  -only-testing:agentGuiTests/WorkbenchConversationPaneTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 `WorkbenchConversationPane` 还只会渲染 `ChatView`。

**Step 3: Write the minimal implementation**

`AgentTeamSessionView` 首版要求：

- 接收 `Session` 和可选 `AgentTeamSessionState`
- 显示 team title、source chat、mode、status
- 提供“Feature 1 壳层”级占位文案，不展示消息列表/composer

`WorkbenchConversationPane` 分流草图：

```swift
if let session = workspaceState.selectedSession {
    switch session.kind {
    case .agentTeam:
        AgentTeamSessionView(session: session)
            .accessibilityIdentifier("panel.agentTeam")
    default:
        ChatView(session: session, showsNavigationChrome: false)
            .accessibilityIdentifier("panel.chat")
    }
}
```

注意：

- 不要在 `AgentTeamSessionView` 内嵌 `ChatView`
- 不要把 team surface 写成 popover、sheet 或新窗口

**Step 4: Run test to verify it passes**

Run 同 Step 2，然后执行 compile fallback：

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-team-task3-build CODE_SIGNING_ALLOWED=NO
```

Expected: PASS，且 workbench 主内容位编译通过。

**Step 5: Commit**

```bash
git add agentGui/Views/Team/AgentTeamSessionView.swift \
  agentGui/Views/Workbench/WorkbenchConversationPane.swift \
  agentGuiTests/WorkbenchConversationPaneTests.swift
git commit -m "feat: route agent team sessions in workbench"
```

### Task 4: 从新建对话菜单创建并切换到 agentTeam session

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamSessionFactory.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/NewSessionExecutionProviderMenu.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchConversationPane.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionFactoryTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/AgentTeamSessionUITests.swift`

**Step 1: Write the failing tests**

锁住用户主链路：

1. “新建对话”菜单出现 Team Mode 选项
2. 选择后创建 `Session(kind: .agentTeam)`
3. 创建后 workbench 选中该 team session，而不是打开新窗口
4. 选中后主内容区显示 `AgentTeamSessionView`

工厂测试草图：

```swift
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct AgentTeamSessionFactoryTests {
    @Test func createFromChatBuildsAgentTeamSessionAndState() throws {
        let container = try TestModelContainer.make()
        let context = ModelContext(container)
        let source = Session(title: "当前聊天", kind: .local)
        context.insert(source)

        let result = try AgentTeamSessionFactory().create(from: source, modelContext: context)

        #expect(result.session.kind == .agentTeam)
        #expect(result.state.sourceSessionID == source.sessionId)
    }
}
```

UI 测试草图：

```swift
import XCTest

final class AgentTeamSessionUITests: XCTestCase {
    func testCreatingAgentTeamSessionSwitchesWorkbenchContent() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-com.agentgui.test.mode", "true", "-com.agentgui.test.preloadMessages", "true"]
        app.launch()

      app.buttons["sessionList.createButton"].click()
      app.menuItems["sessionList.create.agentTeam"].click()

        XCTAssertTrue(app.otherElements["panel.agentTeam"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["agentTeam.placeholder"].exists)
        XCTAssertTrue(app.outlines["sessionList.list"].exists)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-task4 \
  -only-testing:agentGuiTests/AgentTeamSessionFactoryTests \
  -only-testing:agentGuiUITests/AgentTeamSessionUITests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为“新建对话”菜单里还没有 Team Mode 选项，factory 也不存在。

**Step 3: Write the minimal implementation**

`AgentTeamSessionFactory` 负责：

- 创建 `Session(kind: .agentTeam)`
- 派生标题，例如 `"<source title> · Team"`
- 创建并持久化 `AgentTeamSessionState`

入口改造要求：

```swift
Menu {
  ForEach(resolvedOptions) { option in
    Button(option.title) {
      onSelect(option)
    }
  }
}
```

实现上有两个可接受方向，推荐第一种：

1. 把 [agentGui/Views/NewSessionExecutionProviderMenu.swift](agentGui/Views/NewSessionExecutionProviderMenu.swift) 泛化成“新建会话菜单”，同时支持普通 provider 选项和 `agentTeam` 选项。
2. 如果不想在本轮重命名组件，可以保留文件名，但内部输出类型必须从“仅 provider”扩展成可表达 `localChat(provider)` 与 `agentTeam` 的枚举。

实现草图：

```swift
enum NewSessionMenuAction: Equatable {
  case localChat(ExecutionProviderReference)
  case agentTeam(sourceSession: Session?)
}
```

`SessionListView` 与 `WorkbenchConversationPane` 的空状态都改成消费这个菜单动作：

- 选择 `localChat(provider)` 时保持现有创建逻辑
- 选择 `agentTeam(sourceSession: nil)` 时创建一个无来源 team session，或使用默认标题
- 如果用户是从某个已有 chat session 上下文里触发菜单，可传入 `sourceSession`

首版更稳妥的要求是：

- sidebar 的 `+` 菜单必须包含 `sessionList.create.agentTeam`
- `WorkbenchConversationPane` 空状态里的“新建对话”按钮也能创建 `agentTeam`
- 不再依赖 [agentGui/Views/ChatView+Toolbar.swift](agentGui/Views/ChatView+Toolbar.swift) 作为唯一入口

**Step 4: Run tests to verify they pass**

先跑 focused suite，再补一次 build：

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-task4-all \
  -only-testing:agentGuiTests/SessionKindTests \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests \
  -only-testing:agentGuiTests/AgentTeamSessionFactoryTests \
  -only-testing:agentGuiTests/WorkbenchConversationPaneTests \
  -only-testing:agentGuiUITests/AgentTeamSessionUITests CODE_SIGNING_ALLOWED=NO
```

Expected:

- 新建对话菜单中出现 Team Mode 选项且可点击
- 点击后 session 列表中出现新的 `agentTeam` session
- workbench 主内容区切换到 `AgentTeamSessionView`

**Step 5: Commit**

```bash
git add agentGui/Services/Team/AgentTeamSessionFactory.swift \
  agentGui/Views/NewSessionExecutionProviderMenu.swift \
  agentGui/Views/SessionListView.swift \
  agentGui/Views/Workbench/WorkbenchConversationPane.swift \
  agentGuiTests/AgentTeamSessionFactoryTests.swift \
  agentGuiUITests/AgentTeamSessionUITests.swift
git commit -m "feat: create agent team sessions from new session menu"
```

## 6. 收尾检查

全部任务完成后，再做以下检查：

1. 手动验证从一个已有 chat 连续创建两个 `agentTeam` session，确认它们会在 session 列表中并列显示，而不是覆盖同一条记录。
2. 手动验证切回原 chat session 后，`ChatView` 正常恢复，`agentTeam` session 不会污染普通消息列表。
3. 手动验证删除 `agentTeam` session 不会误删来源 chat。
4. 用 `@requesting-code-review` 做 focused review，确认没有任何独立 team window、scene value、或把 `ChatView` 直接复用成 team surface 的偷懒实现。

## 7. Deferred Until Feature 2+

以下内容故意不在 Feature 1 实现：

- Mission Header、Team Roster、Workstream Board、Inspector 的正式布局
- brief、task card、artifact、memo、review、merge gate
- source chat 与 team session 的复杂级联生命周期
- team run 完成后 publish 回 chat transcript
- 独立 team 导航子系统或独立窗口模式

Plan 成功的标准不是 team 已经“能协作”，而是 `agentTeam` 已经成为一个可创建、可列出、可切换、并在同一 workbench 中拥有独立承载面的 session kind。
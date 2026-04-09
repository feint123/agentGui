# ACP Agent Team Feature 2 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 agentGui 落地 Feature 2 的 Team Workbench UI shell：在现有 `Session(kind: .agentTeam)` surface 之上，建立独立的 Mission Header、Team Roster、Workstream Board 占位区和 Inspector 占位区，使 team session 不再表现为单张说明卡，而是成为一个具备明确结构层级的工作台。

**Architecture:** 继续复用 Feature 1 已经建立的 `Session(kind: .agentTeam)` 入口和 `WorkbenchConversationPane` 的 kind 分流，不新增顶级 scene，也不提前引入 Feature 3 的持久化 brief / task card / artifact 模型。Feature 2 只在 `AgentTeamSessionView` 内部完成 UI shell 升级：通过一个轻量 presentation helper 把当前 session/state 映射为可展示的 mission/roster/placeholder 文案，再由拆分后的 SwiftUI 子视图渲染四个稳定区域，并用 accessibility identifiers 与最小 UI test fixture 锁住结构。

**Tech Stack:** Swift 6、SwiftUI for macOS、SwiftData、Observation、现有 `Session` / `AgentTeamSessionState` / `WorkbenchConversationPane` / `WorkbenchSidebarPanelStyle`、Swift Testing、XCTest UI tests。

**Depends On:** [docs/plans/2026-03-30-acp-agent-team-design.md](../plans/2026-03-30-acp-agent-team-design.md), [docs/plans/2026-03-30-acp-agent-team-feature1-implementation-plan.md](../plans/2026-03-30-acp-agent-team-feature1-implementation-plan.md)

---

## 0. 执行约束

- 我正在使用 writing-plans skill 来编写这份 implementation plan。
- 这份计划只覆盖 Feature 2，不提前实现 Feature 3 的 mission brief 持久化、Feature 5 的 task card 状态机、Feature 6 的 typed artifact schema，或 Feature 10 的 review / merge gate。
- `AgentTeamSessionView` 仍然是 `WorkbenchConversationPane` 中 `.agentTeam` surface 的唯一入口，因此 Feature 2 必须在该 surface 内完成升级，而不是改成新的 window、popover 或 sidebar panel。
- 允许新增轻量 presentation helper 和纯 UI placeholder 数据，但不要为了 Mission Header 去修改 `Session` 或 `AgentTeamSessionState` 的持久化字段；真实 brief 数据留给 Feature 3。
- Team Workbench shell 的主结构必须清晰可见：Mission Header、Team Roster、Workstream Board、Inspector 四块区域都要具备稳定 accessibility identifiers，便于后续 UI 自动化与 Feature 5/6/10 增量接入。
- 不能把 Workstream Board 做回 message list 的视觉变体；即使首版只是占位卡片，也必须以“任务板”而不是“聊天气泡”组织主内容区。
- 优先复用 [agentGui/Views/Workbench/WorkbenchSidebarPanelStyle.swift](../../agentGui/Views/Workbench/WorkbenchSidebarPanelStyle.swift) 的卡片与间距风格，避免 Team surface 视觉体系与 Workbench 其它 panel 断裂。
- 遵循 @swiftui-expert-skill：保持状态所有权单一、`body` 纯净、子视图及时抽离，优先用 `ViewThatFits` / 拆分布局，不默认引入 `GeometryReader`。
- 严格按 @test-driven-development 执行：每个任务先补失败测试，再写最小实现，再回归验证。
- 完成全部任务后，用 @requesting-code-review 做一次 focused review，重点检查：Team shell 是否真正独立于 chat bubble、四个区域是否稳定可定位、以及测试 fixture 是否足够支撑后续 feature 继续叠加。

## 1. 当前状态摘要

- 当前 [agentGui/Views/Team/AgentTeamSessionView.swift](../../agentGui/Views/Team/AgentTeamSessionView.swift) 仍然只是一个单列 `VStack`：顶部标题、说明文案、再加一个展示来源/模式/状态的 `Grid`。这满足了 Feature 1 的“独立 surface”要求，但还没有形成真正的 workbench shell。
- 当前 [agentGui/Views/Workbench/WorkbenchConversationPane.swift](../../agentGui/Views/Workbench/WorkbenchConversationPane.swift) 已能根据 `Session.kind` 在 `ChatView` 与 `AgentTeamSessionView` 间分流，因此 Feature 2 不需要再改 surface 路由，只需要升级 team surface 本体。
- 当前 `AgentTeamSessionState` 只持有 `sourceSessionTitle`、`mode`、`status` 等壳层元数据；`AgentTeamMode` 目前只有 `.executionDelivery`，`AgentTeamRunStatus` 包含 `created` / `active` / `completed` / `failed`。这些字段足够支持首版 Mission Header 和 Roster 的占位展示，但不够表达真实 brief、task card 或 artifact，因此必须通过 presentation helper 补出 placeholder 文案，而不是直接扩表。
- 当前 [agentGui/Views/Workbench/WorkbenchSidebarPanelStyle.swift](../../agentGui/Views/Workbench/WorkbenchSidebarPanelStyle.swift) 已提供通用 card/header/scroll style，可直接复用于 roster、board、inspector 等 panel，减少额外视觉系统。
- 当前 [agentGui/Utilities/TestLaunchOptions.swift](../../agentGui/Utilities/TestLaunchOptions.swift) 和 [agentGui/agentGuiApp.swift](../../agentGui/agentGuiApp.swift) 已支持 UI test in-memory store、工作区路径、预置消息等 fixture，但还没有“直接种出一个 agentTeam session shell”这一专用 fixture 模式。
- 当前 `agentGuiUITests` 目标存在，但工作区中没有已落地文件，因此 Feature 2 需要顺手建立最小的 Team Workbench UI smoke test 文件，而不能依赖不存在的测试基类。

## 2. Feature 2 目标态

完成后系统应满足以下条件：

1. 选中任意 `Session(kind: .agentTeam)` 时，主内容区展示一个独立 Team Workbench shell，而不是单张说明卡或任何形式的 message bubble 列表。
2. 顶部 Mission Header 至少展示：目标摘要、来源上下文、当前模式、当前状态、预算占位、是否等待用户占位。
3. 左侧 Team Roster 区展示角色化 provider 面板占位，例如 conductor、worker、reviewer，并明确 readiness / current focus / blocker 占位字段。
4. 中央 Workstream Board 是主视觉焦点，显示按阶段组织的占位 task cards，而不是时间线式日志。
5. 右侧 Inspector 区展示被选中 work item 的 artifact / review / trace 占位说明，建立未来 Feature 6/10 的承载位置。
6. Team shell 在较窄 detail 宽度下仍可用：横向布局放不下时，至少能退化为纵向堆叠，而不是发生遮挡或裁切。
7. UI 自动化可以稳定断言 `panel.agentTeam`、Mission Header、Roster、Board、Inspector 的存在，并确认 `chat.inputArea` 没有出现在 team session 中。

## 3. Scope Guardrails

- 不新增 `AgentTeamMission`、`AgentTeamTaskCard`、`AgentTeamArtifact` 的 SwiftData 模型；这些属于后续 feature。
- 不把 provider registry 真正接入 Team Roster；首版 roster 只渲染由 presentation helper 生成的角色占位卡。
- 不实现真实拖拽、lane 切换、artifact 打开、review trace drill-down；Feature 2 只建立占位承载面和选中态外观。
- 不修改 `WorkbenchShellView` 的全局 split 架构；team shell 应在 detail 区自包含完成布局。
- 不顺手重构 `ChatView`、`SessionListView` 或 sidebar 导航结构，除非测试 fixture 必须让 UI smoke 能稳定选中 team session。

## 4. Relevant Existing Files

### 已有 Team 与 Session 入口

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamSessionState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamMode.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamRunStatus.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamSessionFactory.swift`

### 已有 Workbench 与 Team surface

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchConversationPane.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamSessionView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchSidebarPanelStyle.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchEmptyStateViews.swift`

### 已有测试与 UI fixture 支撑

- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchConversationPaneTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionStateTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

## 5. Target File Plan

### New Files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamMissionHeaderView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamWorkbenchPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/AgentTeamWorkbenchShellUITests.swift`

### Modified Files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamSessionView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchConversationPane.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchConversationPaneTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/README.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/quality/test-matrix-2026-03-11.md`

如果 `AgentTeamWorkbenchPanelViews.swift` 在实现中超过约 250 行，可继续拆成 `AgentTeamRosterPanelView.swift` 与 `AgentTeamInspectorPanelView.swift`；但在 Feature 2 阶段先以一个 panel file 集中占位视图即可，避免过度碎片化。

## 6. Implementation Order

先锁定展示契约，再实现 shell 布局，再补 UI smoke fixture，最后更新文档与回归入口。

---

### Task 1: 提炼 Team Workbench 的 presentation helper 与占位展示契约

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamWorkbenchPresentationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionStateTests.swift`

**Step 1: Write the failing tests**

先把 Feature 2 允许展示的“假数据边界”锁死，避免后续 UI 直接把持久化模型和字符串拼接写进 view body。测试需要覆盖：

- 有来源 chat 时，Mission Header 的 objective / source summary 会引用 `sourceSessionTitle`。
- `created` / `active` / `completed` / `failed` 会映射成用户可见的 header 状态文案，而不是裸枚举值。
- Roster 首版至少稳定产出三类角色占位：conductor、worker、reviewer。
- Workstream Board 首版稳定产出多个阶段列或阶段卡占位，如 `Briefing`、`Working`、`Reviewing`。

测试草图：

```swift
import Testing
@testable import agentGui

@MainActor
struct AgentTeamWorkbenchPresentationTests {
    @Test
    func presentationBuildsMissionHeaderFromState() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let state = AgentTeamSessionState(
            session: session,
            sourceSessionID: "chat-1",
            sourceSessionTitle: "修复 ACP",
            mode: .executionDelivery,
            status: .active
        )

        let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: state)

        #expect(presentation.header.title == "修复 ACP")
        #expect(presentation.header.statusText == "进行中")
        #expect(presentation.header.objectiveSummary.contains("修复 ACP"))
        #expect(presentation.roster.count == 3)
        #expect(presentation.boardColumns.count >= 3)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature2-task1 \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 `AgentTeamWorkbenchPresentation` 及其 header/roster/board placeholder 结构尚不存在。

**Step 3: Write the minimal implementation**

实现一个纯展示 helper，形态可参考：

```swift
struct AgentTeamWorkbenchPresentation: Equatable {
    struct Header: Equatable {
        let title: String
        let objectiveSummary: String
        let sourceSummary: String
        let modeText: String
        let statusText: String
        let budgetText: String
        let waitingText: String
        let acceptanceSummary: String
    }

    struct RosterItem: Identifiable, Equatable { ... }
    struct BoardColumn: Identifiable, Equatable { ... }
    struct InspectorSummary: Equatable { ... }

    let header: Header
    let roster: [RosterItem]
    let boardColumns: [BoardColumn]
    let inspector: InspectorSummary

    static func make(session: Session, state: AgentTeamSessionState?) -> Self { ... }
}
```

要求：

- 所有 placeholder 文案集中定义在 helper 内，`AgentTeamSessionView` 只消费 presentation，不自己拼字符串。
- `modeText` 与 `statusText` 输出中文用户可读文案。
- 不引入 SwiftData 或环境依赖，确保 helper 可被快速单测。
- `AgentTeamSessionStateTests` 可顺手补一个断言，锁住 `.active` / `.failed` 等状态切换仍会更新时间，避免后续 header 数据被旧状态污染。

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift agentGuiTests/AgentTeamWorkbenchPresentationTests.swift agentGuiTests/AgentTeamSessionStateTests.swift
git commit -m "feat: add agent team workbench presentation placeholders"
```

### Task 2: 把 AgentTeamSessionView 升级为真正的 Team Workbench shell

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamMissionHeaderView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamSessionView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchConversationPaneTests.swift`

**Step 1: Write the failing tests**

先锁住 shell 结构，而不是只锁一个总 panel id。测试至少需要新增以下稳定 identifier 常量：

- `agentTeam.missionHeader`
- `agentTeam.roster`
- `agentTeam.board`
- `agentTeam.inspector`

并锁住 `WorkbenchConversationPane` 的 team surface 继续指向 `AgentTeamSessionView`，不允许未来误回退到 chat 组件。测试草图：

```swift
import Testing
@testable import agentGui

@MainActor
struct WorkbenchConversationPaneTests {
    @Test
    func agentTeamSurfacePublishesWorkbenchShellAccessibilityIdentifiers() {
        #expect(AgentTeamSessionView.panelAccessibilityIdentifier == "panel.agentTeam")
        #expect(AgentTeamSessionView.missionHeaderAccessibilityIdentifier == "agentTeam.missionHeader")
        #expect(AgentTeamSessionView.rosterAccessibilityIdentifier == "agentTeam.roster")
        #expect(AgentTeamSessionView.boardAccessibilityIdentifier == "agentTeam.board")
        #expect(AgentTeamSessionView.inspectorAccessibilityIdentifier == "agentTeam.inspector")
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature2-task2 \
  -only-testing:agentGuiTests/WorkbenchConversationPaneTests \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为新的 shell identifiers 和分拆子视图还不存在。

**Step 3: Write the minimal implementation**

把 `AgentTeamSessionView` 从“单列说明卡”重构为以下结构：

```swift
struct AgentTeamSessionView: View {
    let session: Session
    let state: AgentTeamSessionState?

    private var presentation: AgentTeamWorkbenchPresentation {
        .make(session: session, state: state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AgentTeamMissionHeaderView(presentation: presentation.header)
                .accessibilityIdentifier(Self.missionHeaderAccessibilityIdentifier)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    AgentTeamRosterPanelView(items: presentation.roster)
                        .frame(width: 260)
                    AgentTeamBoardPanelView(columns: presentation.boardColumns)
                        .frame(maxWidth: .infinity)
                    AgentTeamInspectorPanelView(summary: presentation.inspector)
                        .frame(width: 320)
                }

                VStack(spacing: 16) {
                    AgentTeamRosterPanelView(items: presentation.roster)
                    AgentTeamBoardPanelView(columns: presentation.boardColumns)
                    AgentTeamInspectorPanelView(summary: presentation.inspector)
                }
            }
        }
    }
}
```

实现要求：

- `AgentTeamMissionHeaderView` 负责标题、目标摘要、来源摘要、状态/模式/budget/waiting chips，不直接知道 session/state。
- `AgentTeamWorkbenchPanelViews.swift` 承载 Roster / Board / Inspector 三个占位 panel，避免 `AgentTeamSessionView.body` 变成超长 `VStack`。
- 视觉上优先复用 `workbenchSidebarCardStyle()` 或 `WorkbenchSidebarSectionCard`，保持与 Workbench 其它 panel 的材料、圆角、间距一致。
- Board 区明确展示“按阶段列出的卡片占位”，不要使用任何 message row、bubble、composer 相关组件。
- `panel.agentTeam` 仍保留在根容器上，且根容器背景延续当前 detail surface 的 `textBackgroundColor` 语义。

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/Team/AgentTeamMissionHeaderView.swift agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift agentGui/Views/Team/AgentTeamSessionView.swift agentGuiTests/WorkbenchConversationPaneTests.swift
git commit -m "feat: build agent team workbench shell layout"
```

### Task 3: 为 Team Workbench shell 建立最小 UI test fixture 与 smoke 回归

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/AgentTeamWorkbenchShellUITests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

**Step 1: Write the failing tests**

新增一条最小但真实的 UI smoke 场景，覆盖 Feature 2 的验收主链路：

1. 以 UI test mode 启动应用。
2. 直接 seed 一个 `Session(kind: .agentTeam)`，并附带 `sourceSessionTitle`、`status = .active` 等基础 team fixture。
3. 启动后等待 `panel.agentTeam` 出现。
4. 断言 Mission Header、Roster、Board、Inspector 都存在。
5. 断言 `chat.inputArea` 不存在，证明 team surface 没有回退成聊天页。

UI 测试草图：

```swift
import XCTest

final class AgentTeamWorkbenchShellUITests: XCTestCase {
    func testAgentTeamWorkbenchShellShowsDedicatedRegions() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-com.agentgui.test.mode", "true",
            "-com.agentgui.test.agentTeamFixture", "shell",
            "-com.agentgui.test.sessionId", "ui-agent-team"
        ]

        app.launch()

        XCTAssertTrue(app.otherElements["panel.agentTeam"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.otherElements["agentTeam.missionHeader"].exists)
        XCTAssertTrue(app.otherElements["agentTeam.roster"].exists)
        XCTAssertTrue(app.otherElements["agentTeam.board"].exists)
        XCTAssertTrue(app.otherElements["agentTeam.inspector"].exists)
        XCTAssertFalse(app.otherElements["chat.inputArea"].exists)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature2-task3 \
  -only-testing:agentGuiUITests/AgentTeamWorkbenchShellUITests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 UI test 文件、team fixture launch arg 和对应 seed 逻辑都还不存在。

**Step 3: Write the minimal implementation**

fixture 设计建议：

```swift
struct TestLaunchOptions {
    let agentTeamFixtureMode: String?
}
```

在 `agentGuiApp.seedUITestDataIfNeeded(in:)` 中新增一个明确的 team fixture 分支：

- 当 `agentTeamFixtureMode == "shell"` 时，直接创建 `Session(sessionId: ..., title: "ACP Agent Team", kind: .agentTeam)`。
- 同时插入 `AgentTeamSessionState`，至少填充：`sourceSessionTitle`、`mode: .executionDelivery`、`status: .active`。
- 不要再给这个 session 灌入普通 message fixture。
- 让该 session 成为 in-memory store 中默认被选中的首个 session，确保 UI smoke 不依赖 sidebar 点击路径。

注意：

- 这一步只为自动化提供 team shell fixture，不要把 UI test 专用分支泄漏到生产路径。
- 如果 app 的 seeding helper 已封装 `ensureSession(...)`，优先新增一个 `ensureAgentTeamSession(...)` 辅助函数，而不是把 `ensureSession` 搞成多职责巨型函数。

**Step 4: Re-run the focused UI test**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Utilities/TestLaunchOptions.swift agentGui/agentGuiApp.swift agentGuiUITests/AgentTeamWorkbenchShellUITests.swift
git commit -m "test: add agent team workbench shell smoke coverage"
```

### Task 4: 更新文档与本地验证入口，避免 Feature 2 成为隐藏能力

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/README.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/quality/test-matrix-2026-03-11.md`

**Step 1: Write the failing documentation diff**

这里没有传统意义上的“失败测试”，但要先明确 Feature 2 完成后必须补哪两类文档信息：

- README 的本地回归命令里增加 Team Workbench focused test / UI smoke 的命令示例。
- 质量矩阵中增加 `AgentTeamWorkbenchShellUITests` 的覆盖说明，标注它验证的是独立 shell 结构而非 team 协作语义。

可以先写一个 checklist 作为 task 内的验收基线：

```text
- README 包含 focused unit + UI smoke 命令
- test matrix 提到 Mission Header / Roster / Board / Inspector 的 smoke coverage
```

**Step 2: Run verification commands before editing docs**

在补文档前先确认最终命令实际能跑通。建议至少执行：

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature2-final \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  -only-testing:agentGuiTests/WorkbenchConversationPaneTests \
  -only-testing:agentGuiUITests/AgentTeamWorkbenchShellUITests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

**Step 3: Write the minimal documentation updates**

README 建议加入一个 focused 命令块，例如：

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  -only-testing:agentGuiTests/WorkbenchConversationPaneTests \
  -only-testing:agentGuiUITests/AgentTeamWorkbenchShellUITests
```

质量矩阵建议补一句：

- `agentGuiUITests/AgentTeamWorkbenchShellUITests`
  - Verifies the Agent Team session renders a dedicated Mission Header, Roster, Board, and Inspector shell without the chat composer surface.

**Step 4: Re-run the final focused command**

Run the same command from Step 2.

Expected: PASS，并确认 README 中记录的命令与真实执行命令一致。

**Step 5: Commit**

```bash
git add README.md docs/quality/test-matrix-2026-03-11.md
git commit -m "docs: document agent team workbench shell coverage"
```

## 7. Final Verification Checklist

全部任务完成后，逐项核对：

1. `WorkbenchConversationPane` 仍然只通过 `.agentTeam` 分流到 `AgentTeamSessionView`，没有额外 surface 分叉。
2. `AgentTeamSessionView` 的 UI 主体已经是 Mission Header + Roster + Board + Inspector，而不是单卡说明页。
3. Team shell 在 UI 自动化里可通过稳定 identifiers 定位四个区域。
4. `chat.inputArea` 不会出现在 `Session(kind: .agentTeam)` 的 UI smoke 场景中。
5. 没有为 Feature 2 提前引入持久化 mission/task/artifact 模型。
6. README 和 test matrix 都记录了 focused 回归入口。

## 8. Suggested Execution Notes

- 如果 Task 2 的 shell 视图很快膨胀到多个卡片和行组件，优先继续拆 view file，而不是把一切塞回 `AgentTeamSessionView.swift`。
- 如果 UI smoke 因 macOS 自动化焦点问题不稳定，优先强化 launch seeding，避免把用例写成依赖菜单点击顺序的脆弱路径。
- 如果后续 Feature 3 很快接上，这里的 `AgentTeamWorkbenchPresentation` 应继续保留，转而从真实 mission/task/artifact 模型组装 view-facing data，而不是让 SwiftUI 直接读持久化模型。
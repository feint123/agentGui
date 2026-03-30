# ACP Agent Team Feature 3 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 agentGui 落地 Feature 3 的统一 mission brief 模型：把 Team Mode 启动时的 objective、constraints、acceptance criteria、mode、budget 和初始上下文摘要收敛成一份结构化 brief，并让 team session 的创建链路、Mission Header 展示链路和后续 provider 消费链路都从这一份 canonical brief 出发。

**Architecture:** 延续 Feature 1/2 已建立的 `Session(kind: .agentTeam)` + `AgentTeamSessionState` 壳层，不新增顶级 team run 实体，也不提前落地 Feature 4 的 claim、Feature 5 的 task cards 或 Feature 6 的 artifacts。Feature 3 采用“纯 Swift brief contract + SwiftData JSON 持久化 + 启动表单草稿模型”的增量方案：新增 `AgentTeamMissionBrief` / `AgentTeamBudget` 作为 runtime contract，把 brief JSON 挂在 `AgentTeamSessionState` 上，Team Mode 创建入口改为先收集 brief draft 再调用 `AgentTeamSessionFactory` 创建 session，Mission Header 和未来 team provider bootstrap 统一通过同一个 brief resolver 读取这份数据。

**Tech Stack:** Swift 6、SwiftUI for macOS、SwiftData、Observation、现有 `Session` / `AgentTeamSessionState` / `AgentTeamSessionFactory` / `NewSessionExecutionProviderMenu` / `AgentTeamWorkbenchPresentation` / ACP provider registry、Swift Testing、XCTest UI tests。

**Depends On:** [docs/plans/2026-03-30-acp-agent-team-design.md](../plans/2026-03-30-acp-agent-team-design.md), [docs/plans/2026-03-30-acp-agent-team-feature1-implementation-plan.md](../plans/2026-03-30-acp-agent-team-feature1-implementation-plan.md), [docs/plans/2026-03-30-acp-agent-team-feature2-implementation-plan.md](../plans/2026-03-30-acp-agent-team-feature2-implementation-plan.md)

---

## 0. 执行约束

- 我正在使用 writing-plans skill 来编写这份 implementation plan。
- 这份计划只覆盖 Feature 3，不提前实现 Feature 4 的 claim 协议、Feature 5 的 task card 状态机、Feature 6 的 typed artifact board 或 Feature 10 的 review / merge gate。
- 不新增独立 team window，也不绕开现有 `Session(kind: .agentTeam)` 入口；brief 必须挂在当前 team session 生命周期上。
- 不把复杂数组字段直接散落进 `Session` 顶层属性。这个仓库已经用 `Session.planJson`、`executionPreferencesJSON` 承载复杂结构，因此 brief 也应采用同类“typed runtime model + JSON persistence slot”的策略，避免过早把 SwiftData schema 扩成多层关系网。
- Team Mode 创建链路不能继续“点击菜单立刻建一个空 team shell”。Feature 3 完成后，所有正常创建路径都必须先形成一份 draft，再生成统一 brief，再建 team session。
- Mission Header 不能继续依赖 Feature 2 的占位文案；objective、constraints、acceptance、budget、context summary 都必须来自实际 brief。
- 所有 team-scoped 消费方都必须通过同一个 brief accessor / resolver 读数据，不能在 UI、factory、未来 provider bootstrap 里各自拼一套字段。
- 必须兼容已有 Feature 1/2 产生的无 brief 历史 `agentTeam` session 和 UI test fixture，不能因为 `briefJSON` 为空就让现有 Team Workbench 崩掉。缺少持久化 brief 时，应通过同一个 fallback resolver 给出可回显但明确受限的 legacy brief。
- 遵循 @swiftui-expert-skill：表单状态和提交逻辑放在独立 draft/view-model 中，`View` 只负责渲染和事件回调，不把一堆字符串规范化逻辑塞进 `body`。
- 严格按 @test-driven-development 执行：每个任务先写失败测试，再写最小实现，再回归验证。
- 完成全部任务后，用 @requesting-code-review 做一次 focused review，重点检查：brief 是否真的是单一真相源、team 创建路径是否不再绕过 brief、以及 Mission Header 是否已经彻底摆脱 Feature 2 占位字符串。

## 1. 当前状态摘要

- 当前 [agentGui/Services/Team/AgentTeamSessionFactory.swift](../../agentGui/Services/Team/AgentTeamSessionFactory.swift) 创建 `agentTeam` session 时，只会写入 `sourceSessionID`、`sourceSessionTitle`、`mode`、`status` 这类壳层元数据，没有任何 brief 结构。
- 当前 [agentGui/Models/AgentTeamSessionState.swift](../../agentGui/Models/AgentTeamSessionState.swift) 没有 `briefJSON` 或等价字段，因此 objective、constraints、acceptance、budget、context summary 没有持久化位置。
- 当前 [agentGui/Views/NewSessionExecutionProviderMenu.swift](../../agentGui/Views/NewSessionExecutionProviderMenu.swift) 的 `.agentTeam(source:)` action 只是一个立即执行的 menu action，没有启动表单、没有 draft，也没有提交校验。
- 当前 [agentGui/Views/SessionListView.swift](../../agentGui/Views/SessionListView.swift)、[agentGui/Views/Workbench/WorkbenchConversationPane.swift](../../agentGui/Views/Workbench/WorkbenchConversationPane.swift) 和 [agentGui/Views/ChatView+Toolbar.swift](../../agentGui/Views/ChatView+Toolbar.swift) 在收到 `.agentTeam` action 后都会直接调用 `AgentTeamSessionFactory`，因此 Team Mode 的三条主入口都绕过了 brief 收集。
- 当前 [agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift](../../agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift) 仍然把 Mission Header 文案硬编码为 placeholder，例如“预算：待配置”“验收：待 Feature 3 接入正式 mission brief 后细化”，这说明当前 header 并没有真正的数据源。
- 当前 [agentGui/Views/Team/AgentTeamMissionHeaderView.swift](../../agentGui/Views/Team/AgentTeamMissionHeaderView.swift) 只渲染 title、objective placeholder、source summary 和四个 chip，没有 constraints、acceptance criteria、initial context summary 的结构化承载位。
- 当前 `agentGuiApp` 的 UI test fixture 只会种出一个 feature-2 级别的 team shell，不会预置 brief 数据，因此 Feature 3 需要同步升级 test launch options。
- 当前还不存在任何 team provider 消费 brief 的统一入口。未来 conductor / worker / reviewer 如果各自读取 `Session` 和 `AgentTeamSessionState` 零碎字段，很容易重新形成多套“伪 brief”。Feature 3 必须先建立 canonical resolver，哪怕真正的多 provider 协作还在 Feature 4 之后。

## 2. Feature 3 目标态

完成后系统应满足以下条件：

1. 用户从任意 Team Mode 入口创建 team session 时，都会先进入一个 brief composer，而不是直接生成空壳 team session。
2. 提交 composer 后，系统会构建一份 `AgentTeamMissionBrief`，并把它持久化到 team session 关联的 `AgentTeamSessionState`。
3. `AgentTeamMissionBrief` 至少包含：objective、constraints、acceptanceCriteria、mode、budget、initialContextSummary；这些字段均有统一 typed contract。
4. Mission Header 直接渲染 brief 中的 objective、constraints、acceptance、budget、initial context summary，而不是继续展示 Feature 2 的 placeholder。
5. 所有 team-scoped 消费方通过同一个 `AgentTeamMissionBriefResolver` 或等价单一入口读取 brief；UI 展示、session factory 结果回填和未来 provider bootstrap 都不再重复造 brief。
6. 对于 Feature 1/2 已存在但没有持久化 brief 的 `agentTeam` session，系统能通过 canonical fallback brief 保持 UI 可用，并明确这是一份 legacy-derived brief，而不是静默崩溃或显示空白。
7. UI 自动化可以验证：点击 Team Mode 会先看到 brief composer，填写并提交后 team session 被创建，Mission Header 出现真实 brief 内容。

## 3. Scope Guardrails

- 不实现多 provider claim / assign / handoff 流程；Feature 3 只为这些后续 feature 提供统一 brief 输入和读取基座。
- 不新增 `AgentTeamTaskCard`、`AgentTeamArtifact`、`AgentTeamMemo` 的 SwiftData 模型。
- 不在这个 feature 里接入真实 token 计费系统；budget 先以 team 内部约束对象表示，例如 token/cost/provider 并发上限的文本或数值组合，但 contract 必须足够稳定，后续可直接演进。
- 不在这个 feature 里让 built-in chat session 也使用 mission brief；brief 只对 `SessionKind.agentTeam` 生效。
- 不顺手重构所有“新建会话”入口为一个总 coordinator，除非简化 Team Mode brief sheet 的复用是必须的。目标是把 Feature 3 增量接到现有三条入口上，而不是借机做大规模 session 创建架构重写。
- 不要求 Feature 3 立即把 brief 发送给真正的远端 ACP 会话；但必须建立一个明确的、可测试的 resolver / bootstrap contract，保证 Feature 4 开始时所有 provider 能从同一 brief 出发。

## 4. Relevant Existing Files

### 已有 Team Session 与创建链路

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamSessionState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamSessionFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/NewSessionExecutionProviderMenu.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchConversationPane.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Toolbar.swift`

### 已有 Team Workbench 展示层

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamSessionView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamMissionHeaderView.swift`

### 已有 ACP / provider 基础设施

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionProviderRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/DynamicACPExternalExecutionProvider.swift`

### 已有测试与 UI fixture 支撑

- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionFactoryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionStateTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamWorkbenchPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

## 5. Target File Plan

### New Files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamMissionBrief.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamMissionBriefResolver.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentTeamMissionBriefDraft.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamBriefComposerSheet.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamMissionBriefTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamMissionBriefResolverTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamMissionBriefDraftTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/AgentTeamBriefComposerUITests.swift`

### Modified Files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamSessionState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamSessionFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamMissionHeaderView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchConversationPane.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Toolbar.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/NewSessionExecutionProviderMenu.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionFactoryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionStateTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamWorkbenchPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/README.md`

如果 `AgentTeamBriefComposerSheet.swift` 超过约 250 行，可继续拆成 `AgentTeamBriefComposerSections.swift`，但 Feature 3 先把 draft state 与 form UI 放在一个文件里即可，避免过早碎片化。

## 6. Implementation Order

先建立 canonical brief contract，再改 session factory 和启动表单，再切换 Mission Header 到真实 brief，最后补 provider-facing resolver 和 UI fixture。

---

### Task 1: 建立 canonical mission brief contract 与持久化槽位

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamMissionBrief.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamSessionState.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamMissionBriefTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionStateTests.swift`

**Step 1: Write the failing tests**

先锁住 brief 自身的 typed contract 和 `AgentTeamSessionState` 上的 persistence slot，避免后续 UI 与 factory 各自造不同字段。测试需要覆盖：

- `AgentTeamMissionBrief` round-trip 编解码后仍保留 objective、constraints、acceptance、mode、budget、initialContextSummary。
- `AgentTeamSessionState` 新增 `briefJSON` 与 `missionBrief` 访问器后，可以安全写入和读取 brief。
- 更新 `missionBrief` 时会刷新 `updatedAt`，与现有 `mode` / `status` 行为保持一致。
- budget contract 至少有稳定的最小字段，例如 `maxActiveProviders`、`tokenBudgetText`、`costBudgetText`；后续 feature 可以扩展，但现在不能是匿名 `[String: String]`。

测试草图：

```swift
import Testing
@testable import agentGui

struct AgentTeamMissionBriefTests {
    @Test
    func briefRoundTripsThroughJSON() throws {
        let brief = AgentTeamMissionBrief(
            objective: "为 ACP team 制定修复方案",
            constraints: ["仅修改 Swift 文件", "保持 UI 稳定"],
            acceptanceCriteria: ["存在 focused tests", "Mission Header 可回显 brief"],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "medium"),
            initialContextSummary: "来源聊天包含 bug 复现与日志摘要。"
        )

        let data = try JSONEncoder().encode(brief)
        let decoded = try JSONDecoder().decode(AgentTeamMissionBrief.self, from: data)

        #expect(decoded == brief)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature3-task1 \
  -only-testing:agentGuiTests/AgentTeamMissionBriefTests \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 `AgentTeamMissionBrief`、`AgentTeamBudget` 与 `AgentTeamSessionState.missionBrief` 还不存在。

**Step 3: Write the minimal implementation**

建议 contract 形态：

```swift
struct AgentTeamMissionBrief: Codable, Equatable, Sendable {
    let objective: String
    let constraints: [String]
    let acceptanceCriteria: [String]
    let mode: AgentTeamMode
    let budget: AgentTeamBudget
    let initialContextSummary: String
}

struct AgentTeamBudget: Codable, Equatable, Sendable {
    let maxActiveProviders: Int
    let tokenBudgetText: String
    let costBudgetText: String
}
```

`AgentTeamSessionState` 增量方向：

- 新增 `briefJSON: String = ""`
- 新增计算属性 `missionBrief: AgentTeamMissionBrief?`
- 新增 `updateMissionBrief(_ brief: AgentTeamMissionBrief?)` 或等价 setter，用统一编码和 `updatedAt` 刷新逻辑处理

要求：

- `missionBrief` 的 JSON 编码失败不能静默吃掉并留下一份不一致状态；至少要回退为清空并在测试里可见。
- 不把 `constraints` / `acceptanceCriteria` 展平成多个单独字符串字段；后续 Feature 10 的 evidence mapping 需要保留数组形态。
- `AgentTeamMissionBrief` 本身保持纯 Swift type，不依赖 SwiftData，方便未来 provider runtime 直接复用。

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/AgentTeamMissionBrief.swift agentGui/Models/AgentTeamSessionState.swift agentGuiTests/AgentTeamMissionBriefTests.swift agentGuiTests/AgentTeamSessionStateTests.swift
git commit -m "feat: add canonical agent team mission brief contract"
```

### Task 2: 增加 brief draft 与 source-context 预填逻辑，并让 factory 必须消费 brief

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentTeamMissionBriefDraft.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamSessionFactory.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamMissionBriefDraftTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionFactoryTests.swift`

**Step 1: Write the failing tests**

锁住 team 启动的“draft -> brief -> persisted session”链路，而不是继续允许 factory 生成无 brief session。测试至少覆盖：

- 从已有 chat session 启动 Team Mode 时，draft 能预填 objective 或 context summary，并带上 source session title。
- draft 可以把多行输入规范化为 `[String] constraints` 和 `[String] acceptanceCriteria`。
- `AgentTeamSessionFactory` 接收 draft 或 `AgentTeamMissionBrief` 后，会把 brief 持久化到 `AgentTeamSessionState`。
- 创建结果中的 `state.mode` 应与 brief.mode 一致，不再由 state 自己默认为 `.executionDelivery` 后再脱节。
- standalone Team Mode 在没有 source session 时，也能构造一份有效 brief，而不是回到空壳 session。

测试草图：

```swift
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct AgentTeamSessionFactoryTests {
    @Test
    func createPersistsMissionBriefIntoState() throws {
        let container = try TestModelContainer.make()
        let context = ModelContext(container)
        let source = Session(title: "修复 ACP", kind: .local)
        context.insert(source)

        let draft = AgentTeamMissionBriefDraft.prefilled(from: source)
            .withObjective("为 ACP team 生成修复计划")
            .withConstraintsText("仅修改 Swift 文件\n保持 focused tests")
            .withAcceptanceCriteriaText("Mission Header 回显 brief\nteam session 持久化 brief")

        let result = try AgentTeamSessionFactory().create(from: source, draft: draft, modelContext: context)

        #expect(result.state.missionBrief?.objective == "为 ACP team 生成修复计划")
        #expect(result.state.mode == .executionDelivery)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature3-task2 \
  -only-testing:agentGuiTests/AgentTeamMissionBriefDraftTests \
  -only-testing:agentGuiTests/AgentTeamSessionFactoryTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 draft 模型和 factory 的 brief 输入路径尚不存在。

**Step 3: Write the minimal implementation**

建议 draft 形态：

```swift
struct AgentTeamMissionBriefDraft: Equatable, Sendable {
    var objective: String
    var constraintsText: String
    var acceptanceCriteriaText: String
    var mode: AgentTeamMode
    var maxActiveProviders: Int
    var tokenBudgetText: String
    var costBudgetText: String
    var initialContextSummary: String
    var sourceSessionTitle: String

    func buildBrief() -> AgentTeamMissionBrief { ... }
    static func prefilled(from source: Session?) -> Self { ... }
}
```

实现要求：

- `prefilled(from:)` 对 source session 的默认策略保持克制：objective 可以为空或为简短引导，但 `initialContextSummary` 应尽量从 `source.title`、最后消息预览、当前 provider 等已有信息生成一段可编辑摘要。
- `buildBrief()` 要做行级规范化：去掉空行、trim 空白、保持顺序，不自动去重到丢失语义。
- `AgentTeamSessionFactory` 新增接收 draft / brief 的重载；旧的 `create(from:)` 可保留给测试和 legacy fixture，但内部必须转成一份明确的 fallback brief，而不是继续创建无 brief session。
- `state.mode` 以 `brief.mode` 为真相源；不要同时维护两套模式默认值而不做同步。

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/AgentTeamMissionBriefDraft.swift agentGui/Services/Team/AgentTeamSessionFactory.swift agentGuiTests/AgentTeamMissionBriefDraftTests.swift agentGuiTests/AgentTeamSessionFactoryTests.swift
git commit -m "feat: require mission brief for agent team session creation"
```

### Task 3: 把 Team Mode 入口改成 brief composer，而不是立即建 session

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamBriefComposerSheet.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchConversationPane.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Toolbar.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/NewSessionExecutionProviderMenu.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/AgentTeamBriefComposerUITests.swift`

**Step 1: Write the failing tests**

锁住 Team Mode 的新启动行为，而不是只覆盖 factory。至少需要覆盖：

1. 点击 Team Mode 菜单项后，先弹出 brief composer，而不是马上创建 session。
2. composer 会预填来源聊天摘要或 source session title。
3. 填写 objective / constraints / acceptance 后点击创建，才真正生成 `Session(kind: .agentTeam)`。
4. 创建完成后当前 workbench 切换到新 team session，并展示 Mission Header 中的 objective。

UI 测试草图：

```swift
import XCTest

final class AgentTeamBriefComposerUITests: XCTestCase {
    func testTeamModeOpensBriefComposerBeforeCreatingSession() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-com.agentgui.test.mode", "true",
            "-com.agentgui.test.preloadMessages", "true",
            "-com.agentgui.test.sessionId", "ui-brief-source"
        ]
        app.launch()

        app.buttons["sessionList.createButton"].click()
        app.menuItems["sessionList.create.agentTeam"].click()

        XCTAssertTrue(app.otherElements["agentTeam.briefComposer"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields["agentTeam.brief.objective"].exists)
        XCTAssertTrue(app.textViews["agentTeam.brief.constraints"].exists)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature3-task3 \
  -only-testing:agentGuiUITests/AgentTeamBriefComposerUITests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为当前 `.agentTeam` 仍然直接创建 session，没有 composer sheet。

**Step 3: Write the minimal implementation**

实现建议：

- 新增 `AgentTeamBriefComposerSheet`，接收 `sourceSession` 或 `SourceContext`、一个可变 `AgentTeamMissionBriefDraft`、`onCancel`、`onSubmit`。
- 在 [agentGui/Views/SessionListView.swift](../../agentGui/Views/SessionListView.swift)、[agentGui/Views/Workbench/WorkbenchConversationPane.swift](../../agentGui/Views/Workbench/WorkbenchConversationPane.swift) 和 [agentGui/Views/ChatView+Toolbar.swift](../../agentGui/Views/ChatView+Toolbar.swift) 中，为 `.agentTeam(source:)` action 增加 `@State` 驱动的 pending draft / sheet presentation。
- 普通 `.localChat` action 保持立即创建，不要影响现有 provider 入口。
- `NewSessionExecutionProviderMenu` 本身可继续只产出 `.agentTeam(source:)` action；Feature 3 的关键是 host view 在收到该 action 后改为“打开 composer”。

form 最小字段建议：

- `objective` 单行或多行必填
- `constraintsText` 多行
- `acceptanceCriteriaText` 多行
- `mode` picker
- `maxActiveProviders` stepper 或 menu
- `tokenBudgetText` / `costBudgetText` 文本输入
- `initialContextSummary` 多行

要求：

- 只有点击“创建 Team”才真正调用 `AgentTeamSessionFactory`。
- 表单关闭时不生成空 team session。
- 访问性 id 稳定，例如 `agentTeam.briefComposer`、`agentTeam.brief.objective`、`agentTeam.brief.constraints`、`agentTeam.brief.acceptance`、`agentTeam.brief.submit`。

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Team/AgentTeamBriefComposerSheet.swift agentGui/Views/SessionListView.swift agentGui/Views/Workbench/WorkbenchConversationPane.swift agentGui/Views/ChatView+Toolbar.swift agentGui/Views/NewSessionExecutionProviderMenu.swift agentGuiUITests/AgentTeamBriefComposerUITests.swift
git commit -m "feat: collect mission brief before creating team sessions"
```

### Task 4: 用真实 brief 驱动 Mission Header，并淘汰 Feature 2 placeholder

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamMissionHeaderView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamSessionView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamWorkbenchPresentationTests.swift`

**Step 1: Write the failing tests**

锁住 Feature 3 的核心用户可见结果：Mission Header 真正显示 brief，而不是“待 Feature 3 接入”的文案。测试至少覆盖：

- 当 session 上存在 `missionBrief` 时，header 的 objective、constraints、acceptance、budget、context summary 都直接来自 brief。
- 当 session 上没有 `missionBrief` 时，presentation 通过 fallback brief 返回 legacy-safe 展示，而不是空白或旧 placeholder。
- `budgetText` 和 `waitingText` 不再是 Feature 2 写死的字符串。

测试草图：

```swift
import Testing
@testable import agentGui

@MainActor
struct AgentTeamWorkbenchPresentationTests {
    @Test
    func presentationPrefersPersistedMissionBrief() {
        let session = Session.fixture(title: "ACP Agent Team", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session)
        state.missionBrief = AgentTeamMissionBrief(
            objective: "为 ACP team 汇总修复方案",
            constraints: ["不改 public API"],
            acceptanceCriteria: ["Focused tests 通过"],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "medium"),
            initialContextSummary: "当前聊天包含失败测试与日志。"
        )

        let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: state)

        #expect(presentation.header.objectiveSummary == "为 ACP team 汇总修复方案")
        #expect(presentation.header.constraints == ["不改 public API"])
        #expect(presentation.header.acceptanceCriteria == ["Focused tests 通过"])
        #expect(presentation.header.contextSummary.contains("失败测试"))
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature3-task4 \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 header 结构还没有 `constraints` / `acceptanceCriteria` / `contextSummary` 字段，presentation 仍依赖 placeholder。

**Step 3: Write the minimal implementation**

改造方向：

- `AgentTeamWorkbenchPresentation.Header` 新增：`constraints: [String]`、`acceptanceCriteria: [String]`、`contextSummary: String`、`budgetSummary: String`、可选 `isFallbackBrief`。
- `AgentTeamWorkbenchPresentation.make(session:state:)` 不再自己拼“待 Feature 3 接入”的文案，而是统一调用 `AgentTeamMissionBriefResolver.resolve(for:state:)`。
- `AgentTeamMissionHeaderView` 增加三个明确区块：Constraints、Acceptance、Initial Context；chip row 继续显示 mode、status、budget，但 budget 文案来自 brief。
- 如果是 fallback brief，可在副标题或 caption 中标明“由历史 team shell 推导，建议补充正式 brief”，但不要阻塞 UI。

要求：

- 不把 constraints / acceptance 塞进一个大字符串；后续 Feature 10 的 evidence mapping 需要可枚举结构。
- 继续保持 Mission Header 的稳定 accessibility ids；必要时新增 `agentTeam.brief.constraintsList`、`agentTeam.brief.acceptanceList`、`agentTeam.brief.contextSummary`。
- `AgentTeamSessionView` 不新增额外业务状态，只消费 presentation。

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift agentGui/Views/Team/AgentTeamMissionHeaderView.swift agentGui/Views/Team/AgentTeamSessionView.swift agentGuiTests/AgentTeamWorkbenchPresentationTests.swift
git commit -m "feat: render team mission header from canonical brief"
```

### Task 5: 增加 brief resolver、legacy fallback 与 provider-facing 单一入口

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamMissionBriefResolver.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamSessionFactory.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamMissionBriefResolverTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/README.md`

**Step 1: Write the failing tests**

这个任务锁住“所有 provider 从同一 brief 出发”的最小可测试 contract，即便真正的 team runtime 还没开始 fan-out。测试至少覆盖：

- `AgentTeamMissionBriefResolver` 对同一 session 的多次解析结果相等且稳定。
- 当 state 上存在 persisted brief 时，resolver 返回 persisted brief；当不存在时，返回由 legacy shell 元数据派生的 fallback brief。
- 用 conductor / worker / reviewer 三个角色模拟读取 brief 时，拿到的是同一份值对象，而不是三份不同拼装结果。
- UI test launch option 可以直接种出带 brief 的 team fixture，方便后续 UI smoke 不再依赖 placeholder。

测试草图：

```swift
import Testing
@testable import agentGui

@MainActor
struct AgentTeamMissionBriefResolverTests {
    @Test
    func sameSessionProducesSingleCanonicalBriefForAllRoles() {
        let session = Session.fixture(title: "ACP Agent Team", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session)
        state.missionBrief = .fixture(objective: "统一修复 ACP team")

        let resolver = AgentTeamMissionBriefResolver()

        let conductor = resolver.resolve(session: session, state: state, role: "conductor")
        let worker = resolver.resolve(session: session, state: state, role: "worker")
        let reviewer = resolver.resolve(session: session, state: state, role: "reviewer")

        #expect(conductor.brief == worker.brief)
        #expect(worker.brief == reviewer.brief)
        #expect(conductor.isFallback == false)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature3-task5 \
  -only-testing:agentGuiTests/AgentTeamMissionBriefResolverTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 resolver 与 role-independent canonical access 还不存在。

**Step 3: Write the minimal implementation**

resolver 最小形态可以是：

```swift
struct AgentTeamMissionBriefResolution: Equatable {
    let brief: AgentTeamMissionBrief
    let isFallback: Bool
}

struct AgentTeamMissionBriefResolver {
    func resolve(session: Session, state: AgentTeamSessionState?, role: String? = nil) -> AgentTeamMissionBriefResolution { ... }
}
```

实现要求：

- persisted brief 存在时，始终优先返回 persisted brief。
- fallback brief 只从一个地方生成，不允许 `AgentTeamWorkbenchPresentation`、`AgentTeamSessionFactory`、未来 provider bootstrap 各自做一套 fallback。
- `role` 参数只用于测试未来调用点和日志可读性，绝不能改变 brief 内容；否则就违背“所有 provider 从同一 brief 出发”。
- `agentGuiApp` 的 UI test fixture 增加 `agentTeamFixtureMode = brief` 或等价模式，能种出带 objective / constraints / acceptance 的 team session。
- `README.md` 增加 Feature 3 focused unit / UI test 命令，方便后续回归。

如需为未来 provider bootstrap 预留更清晰的入口，可再加一个轻量 helper：

```swift
extension Session {
    var resolvedAgentTeamMissionBrief: AgentTeamMissionBriefResolution? { ... }
}
```

但不要在这里就接入真实多 provider orchestration。

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/Team/AgentTeamMissionBriefResolver.swift agentGui/Utilities/TestLaunchOptions.swift agentGui/agentGuiApp.swift agentGuiTests/AgentTeamMissionBriefResolverTests.swift README.md
git commit -m "feat: resolve canonical agent team mission brief across consumers"
```

## 7. Final Verification Pass

在所有任务完成后，做一次 focused verification，确认 Feature 3 没有留下“创建链路有 brief、展示链路还是 placeholder”这种半成品状态。

### Unit / integration focus

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature3-final \
  -only-testing:agentGuiTests/AgentTeamMissionBriefTests \
  -only-testing:agentGuiTests/AgentTeamMissionBriefDraftTests \
  -only-testing:agentGuiTests/AgentTeamMissionBriefResolverTests \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests \
  -only-testing:agentGuiTests/AgentTeamSessionFactoryTests \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests CODE_SIGNING_ALLOWED=NO
```

Expected:

- 所有 brief contract / draft / resolver / factory / presentation 测试 PASS。
- 不再出现“待 Feature 3 接入正式 mission brief 后细化”这类旧 placeholder 断言。

### UI smoke focus

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-team-feature3-ui \
  -only-testing:agentGuiUITests/AgentTeamBriefComposerUITests CODE_SIGNING_ALLOWED=NO
```

Expected:

- Team Mode 入口先出现 brief composer。
- 创建后 `panel.agentTeam` 出现，并能看到 objective / constraints / acceptance 中至少一项真实内容。

### Manual spot-check

1. 从 sidebar 的 `+` 菜单创建 Team Mode，确认没有直接生成空 team session。
2. 从 chat toolbar 的 `+` 菜单创建 Team Mode，确认 source chat 信息会预填到 `initialContextSummary`。
3. 打开一个没有 persisted brief 的老 `agentTeam` session，确认 Mission Header 仍能显示 fallback brief，而不是空白或崩溃。
4. 检查 `AgentTeamSessionFactory` 的 legacy overload，确认它内部也会生成 fallback brief，不会再创建真正“无 brief”的 team session。

## 8. Risks To Watch During Execution

- 最大实现风险是把 brief 同时存在于 `AgentTeamSessionState`、draft view-state、Mission Header presentation、legacy fallback helper 四个地方，最后形成四份稍有差异的数据。执行时必须不断回看：只有一个 canonical brief contract 和一个 canonical resolver。
- 第二个风险是 Team Mode 创建入口分散在三个视图文件里，如果只是局部改一个入口，用户会从另外两个入口继续绕过 brief composer。执行时必须三条入口一起改。
- 第三个风险是 Feature 2 的 UI fixture 和老 team session 数据会因为 `briefJSON` 为空而退化。resolver/fallback 必须在 Feature 3 中一并落地，不能拖到后续修补。
- 第四个风险是把 budget 做成过度复杂的数值模型，导致表单和显示都很重。Feature 3 先把 budget 设计成稳定但轻量的 contract，够用即可。

## 9. Out Of Scope Follow-Ups

Feature 3 完成后，后续 feature 可直接建立在这份 brief 之上：

1. Feature 4 用 `AgentTeamMissionBriefResolver` 作为 claim 前的统一 brief 输入。
2. Feature 5 的 task card board 可以把每张 card 映射回 brief objective / acceptance evidence。
3. Feature 10 的 merge gate 可以直接复用 `acceptanceCriteria` 作为 evidence checklist 的来源。

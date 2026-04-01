# Feature 7: Creative Parallelism 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 支持 `creativeExploration` 模式下的创意型并行：conductor 为同一任务创建 2–3 张独立 draft card，每张分配不同 provider 并行产出 `ideaDraft` artifact；所有草案完成后自动触发 synthesis card（`finalSynthesis` artifact），UI 在 Inspector 展示草案对比与最终收敛结果。

**Architecture:** 依托 Feature 6（Typed Artifact Board）和 Feature 8（Execution Parallelism）。核心扩展点：① `AgentTeamTaskCard` 新增 `kind` + `creativeGroupID` 字段；② `AgentTeamTaskBoardCoordinator.bootstrapBoard` 在 `creativeExploration` 模式下路由到 `bootstrapCreativeBoard`，自动创建 N 张 `.creativeDraft` card + 1 张 `.synthesis` card（synthesis 依赖全部 draft）；③ `AgentTeamMissionPromptBuilder` 新增创意 prompt 变体；④ `AgentTeamLaunchCoordinator.claimBatch` 按 card kind 路由 prompt builder，synthesis card 用 conductor provider 派发；⑤ `AgentTeamWorkbenchPresentation` 投影 creative group 与草案 diff 信息；⑥ View 层展示草案徽章与 Inspector diff 区。现有 wave dispatch 循环（Feature 8）无需修改：wave 1 并行 N 张 draft card，wave 2 自动触发依赖全部解除的 synthesis card。

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test` / `#expect`)，现有 `AgentTeamTaskBoardState`、`AgentTeamArtifactBoardState`、`AgentTeamLaunchCoordinator`、`AgentTeamMissionPromptBuilder`、`AgentTeamWorkbenchPresentation`。

---

## 前置知识

### 关键现有文件

| 文件 | 关联 Feature 7 的作用 |
|---|---|
| `agentGui/Models/AgentTeamTaskBoard.swift` | `AgentTeamTaskCard`、`AgentTeamTaskBoardState`（需扩展） |
| `agentGui/Models/AgentTeamMode.swift` | 目前只有 `.executionDelivery`（需增加 `.creativeExploration`） |
| `agentGui/Models/AgentTeamArtifact.swift` | `AgentTeamArtifactKind.ideaDraft` / `.finalSynthesis` 已存在 |
| `agentGui/Models/AgentTeamSessionState.swift` | `artifactBoardState`、`taskBoardState`（supply-side 已有） |
| `agentGui/Models/AgentTeamMissionBrief.swift` | `AgentTeamMissionBrief.mode: AgentTeamMode` |
| `agentGui/Services/Team/AgentTeamTaskBoardCoordinator.swift` | `bootstrapBoard(from:preferredProvider:)` — 需路由到创意 bootstrap |
| `agentGui/Services/Team/AgentTeamLaunchCoordinator.swift` | `claimBatch(state:)` — 需按 card kind 切换 prompt builder |
| `agentGui/Services/Team/AgentTeamMissionPromptBuilder.swift` | `buildPrompt(brief:card:artifacts:)` — 需增加 creative 变体 |
| `agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift` | `BoardCard`、`InspectorSummary` — 需扩展 |
| `agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift` | `AgentTeamBoardCardView`（需加 kind badge） |
| `agentGuiTests/AgentTeamTaskBoardCoordinatorTests.swift` | 参考 `.fixture` builder 写法 |
| `agentGuiTests/AgentTeamLaunchCoordinatorTests.swift` | 参考 `makeState(...)` 测试模式 |
| `agentGuiTests/AgentTeamArtifactTests.swift` | 参考 artifact fixture 写法 |

### 当前 wave dispatch 流（Feature 8，无需修改）

```
launchTeamMission:
  while true:
    batch = claimBatch(state)   ← Feature 7 在这里切换 prompt builder
    if batch.isEmpty: break
    [yield + save]
    for each in batch: beginWorking(...)
    for each in batch: sendMessage(prompt) → markCardDone
    // 下一轮：synthesis card 的依赖全部 .done，自动进入下一波
```

### Feature 7 card 结构示例（creative mode，2 providers）

```
creative group ID = GGGG

card A  kind=.creativeDraft  creativeGroupID=GGGG  provider=providerA  deps=[]
card B  kind=.creativeDraft  creativeGroupID=GGGG  provider=providerB  deps=[]
card C  kind=.synthesis      creativeGroupID=GGGG  provider=conductor  deps=[A, B]
```

Wave 1: A + B 并行（各用 buildCreativeDraftPrompt，互不知晓对方草案）  
Wave 2: 只有 C，自动触发（用 buildSynthesisPrompt，包含 A+B 的 ideaDraft）

### 测试运行命令（Feature 7）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature7-creative-parallelism \
  -only-testing:agentGuiTests/AgentTeamTaskBoardTests \
  -only-testing:agentGuiTests/AgentTeamTaskBoardCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamLaunchCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamMissionBriefDraftTests \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  -only-testing:agentGuiTests/AgentTeamCreativeParallelismTests \
  CODE_SIGNING_ALLOWED=NO
```

---

## Task 1：`AgentTeamTaskCardKind` + 扩展 `AgentTeamTaskCard`

**Files:**
- Modify: `agentGui/Models/AgentTeamTaskBoard.swift`
- Create: `agentGuiTests/AgentTeamCreativeParallelismTests.swift`

### Step 1：写失败测试

```swift
// agentGuiTests/AgentTeamCreativeParallelismTests.swift
import Foundation
import Testing
@testable import agentGui

// MARK: - Task 1: AgentTeamTaskCardKind

struct AgentTeamTaskCardKindTests {

    @Test
    func standardCardDefaultsToStandardKindAfterJSONRoundTrip() throws {
        // 不写 kind 字段，验证 backward-compat 解码为 .standard
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "title": "主任务",
          "goal": "执行修复",
          "status": "briefed",
          "dependencyIDs": [],
          "artifactIDs": [],
          "lastUpdatedAt": 0
        }
        """.data(using: .utf8)!

        let card = try JSONDecoder().decode(AgentTeamTaskCard.self, from: json)

        #expect(card.kind == .standard)
        #expect(card.creativeGroupID == nil)
    }

    @Test
    func creativeDraftCardRoundTripsThroughJSON() throws {
        let groupID = UUID(uuidString: "gggggggg-gggg-gggg-gggg-gggggggggggg")!
        let card = AgentTeamTaskCard(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            title: "草案 1",
            goal: "产出 ideaDraft",
            status: .briefed,
            kind: .creativeDraft,
            creativeGroupID: groupID,
            lastUpdatedAt: Date(timeIntervalSince1970: 0)
        )

        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(AgentTeamTaskCard.self, from: data)

        #expect(decoded.kind == .creativeDraft)
        #expect(decoded.creativeGroupID == groupID)
    }

    @Test
    func synthesisCardRoundTripsThroughJSON() throws {
        let groupID = UUID(uuidString: "hhhhhhhh-hhhh-hhhh-hhhh-hhhhhhhhhhhh")!
        let draftID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let card = AgentTeamTaskCard(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            title: "综合草案",
            goal: "产出 finalSynthesis",
            status: .briefed,
            kind: .synthesis,
            creativeGroupID: groupID,
            dependencyIDs: [draftID],
            lastUpdatedAt: Date(timeIntervalSince1970: 0)
        )

        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(AgentTeamTaskCard.self, from: data)

        #expect(decoded.kind == .synthesis)
        #expect(decoded.creativeGroupID == groupID)
        #expect(decoded.dependencyIDs == [draftID])
    }
}
```

### Step 2：运行确认测试失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature7-creative-parallelism \
  -only-testing:agentGuiTests/AgentTeamCreativeParallelismTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"
```

预期：编译失败，`AgentTeamTaskCardKind` 未定义。

### Step 3：实现 `AgentTeamTaskCardKind` + 扩展 `AgentTeamTaskCard`

在 `agentGui/Models/AgentTeamTaskBoard.swift` 的 `AgentTeamTaskStatus` 定义之前插入：

```swift
// MARK: - Task Card Kind

enum AgentTeamTaskCardKind: String, Codable, Equatable, Sendable {
    case standard
    case creativeDraft
    case synthesis
}
```

在 `AgentTeamTaskCard` 结构体中新增两个字段（在 `blockerSummary` 之前）：

```swift
var kind: AgentTeamTaskCardKind
var creativeGroupID: UUID?
```

更新 memberwise `init`：
- 新增 `kind: AgentTeamTaskCardKind = .standard` 参数
- 新增 `creativeGroupID: UUID? = nil` 参数
- 赋值 `self.kind = kind; self.creativeGroupID = creativeGroupID`

`CodingKeys` 新增两个 case：

```swift
case kind, creativeGroupID
```

`init(from decoder:)` 内新增（向后兼容，缺失时默认 `.standard`）：

```swift
kind           = (try? c.decode(AgentTeamTaskCardKind.self, forKey: .kind)) ?? .standard
creativeGroupID = try? c.decode(UUID.self, forKey: .creativeGroupID)
```

测试文件中的 `AgentTeamTaskCard.fixture` 扩展（在 `AgentTeamTaskBoardCoordinatorTests.swift`）不需要修改，因为新字段有默认值。

### Step 4：运行确认测试通过

预期：`AgentTeamTaskCardKindTests` 3 个测试全部 PASS，现有 `AgentTeamTaskBoardCoordinatorTests` 不受影响。

### Step 5：提交

```bash
git add agentGui/Models/AgentTeamTaskBoard.swift \
        agentGuiTests/AgentTeamCreativeParallelismTests.swift
git commit -m "feat(agent-team): add AgentTeamTaskCardKind + kind/creativeGroupID to TaskCard"
```

---

## Task 2：`AgentTeamMode.creativeExploration` + `bootstrapCreativeBoard`

**Files:**
- Modify: `agentGui/Models/AgentTeamMode.swift`
- Modify: `agentGui/Services/Team/AgentTeamTaskBoardCoordinator.swift`
- Modify: `agentGuiTests/AgentTeamCreativeParallelismTests.swift`

### Step 1：写失败测试

在 `AgentTeamCreativeParallelismTests.swift` 末尾（文件末 `}` 之前）追加：

```swift
// MARK: - Task 2: bootstrapCreativeBoard

struct AgentTeamBootstrapCreativeBoardTests {

    private func makeBrief(
        objective: String = "生成创意方案",
        providers: [ExecutionProviderReference] = [.builtIn, .externalACP(profileID: "copilot")],
        maxActiveProviders: Int = 3
    ) -> AgentTeamMissionBrief {
        AgentTeamMissionBrief(
            objective: objective,
            constraints: ["风格统一"],
            acceptanceCriteria: ["产出 2 份草案"],
            mode: .creativeExploration,
            budget: .init(maxActiveProviders: maxActiveProviders, tokenBudgetText: "30k", costBudgetText: "medium"),
            initialContextSummary: "参考风格：极简主义",
            providerPlan: .init(
                eligibleProviders: providers,
                preferredConductor: .builtIn,
                preferredReviewer: nil,
                dispatchPolicy: .autoClaim
            )
        )
    }

    @Test
    func bootstrapCreatesTwoDraftCardsPlusSynthesisForTwoProviders() {
        let brief = makeBrief(providers: [.builtIn, .externalACP(profileID: "copilot")])
        let board = AgentTeamTaskBoardCoordinator().bootstrapBoard(
            from: brief, preferredProvider: .builtIn
        )

        let draftCards = board.cards.filter { $0.kind == .creativeDraft }
        let synthesisCards = board.cards.filter { $0.kind == .synthesis }

        #expect(draftCards.count == 2)
        #expect(synthesisCards.count == 1)
    }

    @Test
    func synthesisCardDependsOnAllDraftCards() {
        let brief = makeBrief(providers: [.builtIn, .externalACP(profileID: "copilot")])
        let board = AgentTeamTaskBoardCoordinator().bootstrapBoard(
            from: brief, preferredProvider: .builtIn
        )

        let draftIDs = Set(board.cards.filter { $0.kind == .creativeDraft }.map(\.id))
        let synthesisCard = board.cards.first { $0.kind == .synthesis }

        #expect(synthesisCard != nil)
        #expect(Set(synthesisCard!.dependencyIDs) == draftIDs)
    }

    @Test
    func allCardsShareSameCreativeGroupID() {
        let brief = makeBrief(providers: [.builtIn, .externalACP(profileID: "copilot")])
        let board = AgentTeamTaskBoardCoordinator().bootstrapBoard(
            from: brief, preferredProvider: .builtIn
        )

        let groupIDs = Set(board.cards.compactMap(\.creativeGroupID))

        #expect(groupIDs.count == 1)   // 所有卡共享同一个 group ID
    }

    @Test
    func draftCardsAreAllBriefedWithNoDependencies() {
        let brief = makeBrief()
        let board = AgentTeamTaskBoardCoordinator().bootstrapBoard(
            from: brief, preferredProvider: .builtIn
        )

        let draftCards = board.cards.filter { $0.kind == .creativeDraft }
        #expect(draftCards.allSatisfy { $0.status == .briefed })
        #expect(draftCards.allSatisfy { $0.dependencyIDs.isEmpty })
    }

    @Test
    func synthesisCardIsBriefedWithDependencies() {
        let brief = makeBrief()
        let board = AgentTeamTaskBoardCoordinator().bootstrapBoard(
            from: brief, preferredProvider: .builtIn
        )

        let synthesisCard = board.cards.first { $0.kind == .synthesis }

        #expect(synthesisCard?.status == .briefed)
        #expect(synthesisCard?.dependencyIDs.isEmpty == false)
    }

    @Test
    func draftCountCappedAtThreeEvenWithMoreProviders() {
        // 4 providers → 仍只生成 3 张 draft + 1 张 synthesis
        let providers: [ExecutionProviderReference] = [
            .builtIn,
            .externalACP(profileID: "copilot"),
            .externalACP(profileID: "opencode"),
            .externalACP(profileID: "qoder")
        ]
        let brief = makeBrief(providers: providers, maxActiveProviders: 10)
        let board = AgentTeamTaskBoardCoordinator().bootstrapBoard(
            from: brief, preferredProvider: .builtIn
        )

        let draftCards = board.cards.filter { $0.kind == .creativeDraft }
        #expect(draftCards.count == 3)
    }

    @Test
    func singleProviderCreatesOneDraftPlusSynthesis() {
        let brief = makeBrief(providers: [.builtIn])
        let board = AgentTeamTaskBoardCoordinator().bootstrapBoard(
            from: brief, preferredProvider: .builtIn
        )

        let draftCards = board.cards.filter { $0.kind == .creativeDraft }
        let synthesisCards = board.cards.filter { $0.kind == .synthesis }

        #expect(draftCards.count == 1)
        #expect(synthesisCards.count == 1)
    }

    @Test
    func executionDeliveryModeProducesStandardCards() {
        // 确认 executionDelivery 模式不走创意路径
        let brief = AgentTeamMissionBrief(
            objective: "修复 bug",
            constraints: [],
            acceptanceCriteria: ["Tests pass"],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "low"),
            initialContextSummary: ""
        )

        let board = AgentTeamTaskBoardCoordinator().bootstrapBoard(
            from: brief, preferredProvider: .builtIn
        )

        let creativeDrafts = board.cards.filter { $0.kind == .creativeDraft }
        let synthesis = board.cards.filter { $0.kind == .synthesis }

        #expect(creativeDrafts.isEmpty)
        #expect(synthesis.isEmpty)
    }
}
```

### Step 2：运行确认测试失败

预期：`.creativeExploration` 未定义，编译失败。

### Step 3：实现 `AgentTeamMode.creativeExploration`

将 `agentGui/Models/AgentTeamMode.swift` 修改为：

```swift
import Foundation

enum AgentTeamMode: String, Codable, CaseIterable, Sendable {
    case executionDelivery
    case creativeExploration
}
```

### Step 4：实现 `bootstrapCreativeBoard` + 路由

在 `AgentTeamTaskBoardCoordinator.swift` 中修改 `bootstrapBoard` 方法，在开头加入模式路由：

```swift
func bootstrapBoard(
    from brief: AgentTeamMissionBrief,
    preferredProvider: ExecutionProviderReference
) -> AgentTeamTaskBoardState {
    switch brief.mode {
    case .creativeExploration:
        return bootstrapCreativeBoard(
            from: brief,
            eligibleProviders: brief.providerPlan.eligibleProviders
        )
    case .executionDelivery:
        return bootstrapExecutionBoard(from: brief, preferredProvider: preferredProvider)
    }
}
```

将原来的 `bootstrapBoard` 函数体重命名为 `bootstrapExecutionBoard`（private）：

```swift
private func bootstrapExecutionBoard(
    from brief: AgentTeamMissionBrief,
    preferredProvider: ExecutionProviderReference
) -> AgentTeamTaskBoardState {
    _ = preferredProvider

    let primaryCardID = UUID()
    // ... （原函数体原样保留）
}
```

在同文件末尾增加 `bootstrapCreativeBoard` 方法：

```swift
func bootstrapCreativeBoard(
    from brief: AgentTeamMissionBrief,
    eligibleProviders: [ExecutionProviderReference]
) -> AgentTeamTaskBoardState {
    let groupID = UUID()
    let draftCount = min(3, max(1, eligibleProviders.count))

    let draftCards: [AgentTeamTaskCard] = (0..<draftCount).map { index in
        AgentTeamTaskCard(
            id: UUID(),
            title: "\(brief.objective.prefix(20))（草案 \(index + 1)）",
            goal: brief.objective,
            status: .briefed,
            kind: .creativeDraft,
            creativeGroupID: groupID,
            lastUpdatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    let synthesisCard = AgentTeamTaskCard(
        id: UUID(),
        title: "\(brief.objective.prefix(20))（综合）",
        goal: brief.objective,
        status: .briefed,
        kind: .synthesis,
        creativeGroupID: groupID,
        dependencyIDs: draftCards.map(\.id),
        lastUpdatedAt: Date(timeIntervalSince1970: 0)
    )

    return AgentTeamTaskBoardState(
        cards: draftCards + [synthesisCard],
        claims: []
    )
}
```

### Step 5：运行确认测试通过

预期：`AgentTeamBootstrapCreativeBoardTests` 全部 PASS，现有 `AgentTeamTaskBoardCoordinatorTests` 不受影响。

### Step 6：提交

```bash
git add agentGui/Models/AgentTeamMode.swift \
        agentGui/Services/Team/AgentTeamTaskBoardCoordinator.swift \
        agentGuiTests/AgentTeamCreativeParallelismTests.swift
git commit -m "feat(agent-team): add creativeExploration mode + bootstrapCreativeBoard"
```

---

## Task 3：Creative Prompt Builders

**Files:**
- Modify: `agentGui/Services/Team/AgentTeamMissionPromptBuilder.swift`
- Modify: `agentGuiTests/AgentTeamCreativeParallelismTests.swift`

### Step 1：写失败测试

在 `AgentTeamCreativeParallelismTests.swift` 末尾追加：

```swift
// MARK: - Task 3: Creative Prompt Builders

struct AgentTeamCreativePromptBuilderTests {

    private let brief = AgentTeamMissionBrief(
        objective: "为「极简记账」设计 App Icon",
        constraints: ["避免使用金融图标俗套"],
        acceptanceCriteria: ["独特、易识别"],
        mode: .creativeExploration,
        budget: .init(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "low"),
        initialContextSummary: "App 定位：极简主义, 用色纯白"
    )

    private var draftCard: AgentTeamTaskCard {
        AgentTeamTaskCard(
            id: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            title: "App Icon 草案 1",
            goal: "为「极简记账」设计 App Icon",
            status: .briefed,
            kind: .creativeDraft,
            creativeGroupID: UUID(uuidString: "gggggggg-gggg-gggg-gggg-gggggggggggg")!,
            lastUpdatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private var synthesisCard: AgentTeamTaskCard {
        AgentTeamTaskCard(
            id: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
            title: "App Icon 综合",
            goal: "综合并收敛各草案",
            status: .briefed,
            kind: .synthesis,
            creativeGroupID: UUID(uuidString: "gggggggg-gggg-gggg-gggg-gggggggggggg")!,
            lastUpdatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test
    func creativeDraftPromptIncludesDraftIndexLabel() {
        let prompt = AgentTeamMissionPromptBuilder()
            .buildCreativeDraftPrompt(brief: brief, card: draftCard, draftIndex: 0, totalDrafts: 2)

        #expect(prompt.contains("草案 1 / 2"))
    }

    @Test
    func creativeDraftPromptIncludesIsolationInstruction() {
        let prompt = AgentTeamMissionPromptBuilder()
            .buildCreativeDraftPrompt(brief: brief, card: draftCard, draftIndex: 0, totalDrafts: 2)

        // 确保有明确的草案隔离指令
        #expect(prompt.contains("不要参考") || prompt.contains("do not read") || prompt.contains("独立"))
    }

    @Test
    func creativeDraftPromptIncludesBriefObjective() {
        let prompt = AgentTeamMissionPromptBuilder()
            .buildCreativeDraftPrompt(brief: brief, card: draftCard, draftIndex: 1, totalDrafts: 3)

        #expect(prompt.contains("极简记账"))
    }

    @Test
    func creativeDraftPromptDoesNotLeakOtherDraftContent() {
        // draft prompt 不包含任何来自 artifact 的内容（只有 brief）
        let prompt = AgentTeamMissionPromptBuilder()
            .buildCreativeDraftPrompt(brief: brief, card: draftCard, draftIndex: 0, totalDrafts: 2)

        #expect(!prompt.contains("Existing Artifacts"))
    }

    @Test
    func synthesisPromptIncludesDraftArtifactContent() {
        let draftArtifacts = [
            AgentTeamArtifact(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                kind: .ideaDraft,
                title: "方案 A：几何图形",
                producer: .builtIn,
                taskCardID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
                version: 1,
                summary: "使用简洁几何线条",
                payload: .text("使用细线正方形，白底，淡金色边框"),
                status: .submitted
            ),
            AgentTeamArtifact(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                kind: .ideaDraft,
                title: "方案 B：字母标志",
                producer: .externalACP(profileID: "copilot"),
                taskCardID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
                version: 1,
                summary: "以「记」字变形为核心",
                payload: .text("将「记」字解构为现代字体"),
                status: .submitted
            )
        ]

        let prompt = AgentTeamMissionPromptBuilder()
            .buildSynthesisPrompt(brief: brief, synthesisCard: synthesisCard, draftArtifacts: draftArtifacts)

        #expect(prompt.contains("方案 A：几何图形"))
        #expect(prompt.contains("方案 B：字母标志"))
    }

    @Test
    func synthesisPromptIncludesObjectiveAndSynthesisInstruction() {
        let prompt = AgentTeamMissionPromptBuilder()
            .buildSynthesisPrompt(brief: brief, synthesisCard: synthesisCard, draftArtifacts: [])

        #expect(prompt.contains("极简记账"))
        // 有收敛指令
        #expect(prompt.contains("综合") || prompt.contains("synthesis") || prompt.contains("收敛"))
    }
}
```

### Step 2：运行确认测试失败

预期：`buildCreativeDraftPrompt` / `buildSynthesisPrompt` 未定义，编译失败。

### Step 3：实现 Creative Prompt Builders

在 `AgentTeamMissionPromptBuilder.swift` 末尾追加：

```swift
// MARK: - Creative Parallelism Prompts

extension AgentTeamMissionPromptBuilder {

    /// 为创意 draft card 构建隔离 prompt。
    /// `draftIndex` 从 0 开始；prompt 明确告知 provider 当前是第几号草案、不参考同组其他草案。
    func buildCreativeDraftPrompt(
        brief: AgentTeamMissionBrief,
        card: AgentTeamTaskCard,
        draftIndex: Int,
        totalDrafts: Int
    ) -> String {
        var lines: [String] = []

        lines.append("# Creative Draft \(draftIndex + 1) / \(totalDrafts)")
        lines.append("")
        lines.append("**任务：草案 \(draftIndex + 1) / \(totalDrafts)**（独立创作，不要参考其他草案）")
        lines.append("")
        lines.append("**Objective:** \(brief.objective)")

        if !brief.constraints.isEmpty {
            lines.append("")
            lines.append("**Constraints:**")
            lines.append(contentsOf: brief.constraints.map { "- \($0)" })
        }

        if !brief.acceptanceCriteria.isEmpty {
            lines.append("")
            lines.append("**Acceptance Criteria:**")
            lines.append(contentsOf: brief.acceptanceCriteria.map { "- \($0)" })
        }

        let trimmedContext = brief.initialContextSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedContext.isEmpty {
            lines.append("")
            lines.append("**Context:**")
            lines.append(trimmedContext)
        }

        lines.append("")
        lines.append("**Instructions:** 请独立产出你的创意方案（`ideaDraft`）。本轮与其他草案完全隔离，其他 provider 的草案对你不可见，请勿尝试参考。")

        return lines.joined(separator: "\n")
    }

    /// 为 synthesis card 构建收敛 prompt，包含所有 ideaDraft artifacts。
    func buildSynthesisPrompt(
        brief: AgentTeamMissionBrief,
        synthesisCard: AgentTeamTaskCard,
        draftArtifacts: [AgentTeamArtifact]
    ) -> String {
        var lines: [String] = []

        lines.append("# Creative Synthesis")
        lines.append("")
        lines.append("**Objective:** \(brief.objective)")

        if !brief.constraints.isEmpty {
            lines.append("")
            lines.append("**Constraints:**")
            lines.append(contentsOf: brief.constraints.map { "- \($0)" })
        }

        if !brief.acceptanceCriteria.isEmpty {
            lines.append("")
            lines.append("**Acceptance Criteria:**")
            lines.append(contentsOf: brief.acceptanceCriteria.map { "- \($0)" })
        }

        if !draftArtifacts.isEmpty {
            lines.append("")
            lines.append("## 各草案内容")
            for (index, artifact) in draftArtifacts.enumerated() {
                lines.append("")
                lines.append("### 草案 \(index + 1)：\(artifact.title)")
                lines.append("**摘要：** \(artifact.summary)")
                lines.append("")
                lines.append(artifact.payload.textContent)
            }
        }

        lines.append("")
        lines.append("**Instructions:** 请综合（synthesis）以上所有草案，找出各方案的优势与差异，输出一份统一的收敛方案（`finalSynthesis`）。")

        return lines.joined(separator: "\n")
    }
}
```

### Step 4：运行确认测试通过

预期：`AgentTeamCreativePromptBuilderTests` 全部 PASS。

### Step 5：提交

```bash
git add agentGui/Services/Team/AgentTeamMissionPromptBuilder.swift \
        agentGuiTests/AgentTeamCreativeParallelismTests.swift
git commit -m "feat(agent-team): add buildCreativeDraftPrompt + buildSynthesisPrompt"
```

---

## Task 4：`claimBatch` 按 Card Kind 路由 Prompt Builder

**Files:**
- Modify: `agentGui/Services/Team/AgentTeamLaunchCoordinator.swift`
- Modify: `agentGuiTests/AgentTeamCreativeParallelismTests.swift`

### Step 1：写失败测试

在 `AgentTeamCreativeParallelismTests.swift` 末尾追加：

```swift
// MARK: - Task 4: claimBatch prompt routing

@MainActor
struct AgentTeamClaimBatchCreativeRoutingTests {

    private func makeCreativeState(
        providers: [ExecutionProviderReference] = [
            .builtIn,
            .externalACP(profileID: "copilot")
        ]
    ) -> AgentTeamSessionState {
        let session = Session.fixture(title: "Creative Team", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session, mode: .creativeExploration, status: .created)
        state.missionBrief = AgentTeamMissionBrief(
            objective: "设计 App Icon",
            constraints: [],
            acceptanceCriteria: [],
            mode: .creativeExploration,
            budget: .init(maxActiveProviders: 3, tokenBudgetText: "20k", costBudgetText: "low"),
            initialContextSummary: "",
            providerPlan: .init(
                eligibleProviders: providers,
                preferredConductor: .builtIn,
                preferredReviewer: nil,
                dispatchPolicy: .autoClaim
            )
        )
        // state.taskBoardState = nil → claimBatch 将 bootstrapBoard → creativeExploration 路径
        return state
    }

    @Test
    func claimBatchProducesDraftPromptForCreativeDraftCard() throws {
        let state = makeCreativeState()
        let results = try AgentTeamLaunchCoordinator().claimBatch(state: state)

        let draftResults = results.filter { result in
            state.taskBoardState?.card(id: result.primaryCardID)?.kind == .creativeDraft
        }
        #expect(draftResults.count == 2)
        // draft prompt 包含隔离提示，不包含 "Existing Artifacts"
        for r in draftResults {
            #expect(r.missionPrompt.contains("草案"))
            #expect(!r.missionPrompt.contains("Existing Artifacts"))
        }
    }

    @Test
    func claimBatchDoesNotDispatchSynthesisInFirstWave() throws {
        let state = makeCreativeState()
        let results = try AgentTeamLaunchCoordinator().claimBatch(state: state)

        let synthesisResults = results.filter { result in
            state.taskBoardState?.card(id: result.primaryCardID)?.kind == .synthesis
        }
        // synthesis 依赖 draft，wave 1 不应出现 synthesis
        #expect(synthesisResults.isEmpty)
    }

    @Test
    func claimBatchAssignsConductorToSynthesisCard() throws {
        let state = makeCreativeState()
        let coordinator = AgentTeamLaunchCoordinator()

        // Wave 1: draft cards
        let wave1 = try coordinator.claimBatch(state: state)
        #expect(wave1.count == 2)

        // Manually mark all draft cards as done
        if var taskBoard = state.taskBoardState {
            for i in 0..<taskBoard.cards.count where taskBoard.cards[i].kind == .creativeDraft {
                taskBoard.cards[i] = AgentTeamTaskCard(
                    id: taskBoard.cards[i].id,
                    title: taskBoard.cards[i].title,
                    goal: taskBoard.cards[i].goal,
                    status: .done,
                    kind: .creativeDraft,
                    creativeGroupID: taskBoard.cards[i].creativeGroupID,
                    owner: taskBoard.cards[i].owner,
                    acceptedClaimID: taskBoard.cards[i].acceptedClaimID,
                    lastUpdatedAt: Date()
                )
            }
            state.taskBoardState = taskBoard
        }

        // Wave 2: synthesis card should now appear
        let wave2 = try coordinator.claimBatch(state: state)
        #expect(wave2.count == 1)

        let synthesisResult = wave2[0]
        let synthesisCardOwner = state.taskBoardState?.card(id: synthesisResult.primaryCardID)?.owner
        #expect(synthesisCardOwner == .builtIn) // preferredConductor
    }

    @Test
    func synthesisMissionPromptIncludesDraftArtifactsWhenPresent() throws {
        let state = makeCreativeState()
        let coordinator = AgentTeamLaunchCoordinator()

        // Wave 1
        let wave1 = try coordinator.claimBatch(state: state)
        #expect(!wave1.isEmpty)

        // Add ideaDraft artifacts for each draft card
        var artifactBoard = state.artifactBoardState ?? AgentTeamArtifactBoardState()
        var taskBoard = state.taskBoardState!

        for (i, result) in wave1.enumerated() {
            let artifact = AgentTeamArtifact(
                id: UUID(),
                kind: .ideaDraft,
                title: "草案方案 \(i + 1)",
                producer: result.executionTarget.providerReference,
                taskCardID: result.primaryCardID,
                version: 1,
                summary: "独特的创意方向 \(i + 1)",
                payload: .text("方案内容 \(i + 1): 具体描述"),
                status: .submitted
            )
            artifactBoard.artifacts.append(artifact)
            if let idx = taskBoard.cards.firstIndex(where: { $0.id == result.primaryCardID }) {
                taskBoard.cards[idx].artifactIDs.append(artifact.id)
            }
            // Mark done
            if let idx = taskBoard.cards.firstIndex(where: { $0.id == result.primaryCardID }) {
                taskBoard.cards[idx] = AgentTeamTaskCard(
                    id: taskBoard.cards[idx].id,
                    title: taskBoard.cards[idx].title,
                    goal: taskBoard.cards[idx].goal,
                    status: .done,
                    kind: .creativeDraft,
                    creativeGroupID: taskBoard.cards[idx].creativeGroupID,
                    owner: taskBoard.cards[idx].owner,
                    acceptedClaimID: taskBoard.cards[idx].acceptedClaimID,
                    lastUpdatedAt: Date()
                )
            }
        }
        state.taskBoardState = taskBoard
        state.artifactBoardState = artifactBoard

        // Wave 2: synthesis
        let wave2 = try coordinator.claimBatch(state: state)
        #expect(wave2.count == 1)

        let synthesisPrompt = wave2[0].missionPrompt
        #expect(synthesisPrompt.contains("草案方案 1"))
        #expect(synthesisPrompt.contains("草案方案 2"))
    }
}
```

### Step 2：运行确认测试失败

预期：测试编译通过但部分失败——`claimBatch` 目前对所有 card kind 都使用 `buildPrompt`，不会产出草案隔离 prompt 或 synthesis prompt。

### Step 3：修改 `claimBatch` 支持 Card Kind 路由

在 `AgentTeamLaunchCoordinator.swift` 中，找到 `claimBatch` 里构建 prompt 的这行：

```swift
let prompt = AgentTeamMissionPromptBuilder().buildPrompt(brief: brief, card: card)
```

替换为以下逻辑（需要在循环内先计算 `draftCount`，在循环外计算）：

在 `dispatchable` 获取之后（`let dispatchable = ...`）加入：

```swift
let draftCards = dispatchable.filter { $0.kind == .creativeDraft }
let totalDrafts = draftCards.count
```

然后在 `for (index, card) in dispatchable.enumerated()` 循环内，将 prompt 构建改为：

```swift
let promptBuilder = AgentTeamMissionPromptBuilder()
let prompt: String
switch card.kind {
case .creativeDraft:
    let draftIndex = draftCards.firstIndex(where: { $0.id == card.id }) ?? index
    prompt = promptBuilder.buildCreativeDraftPrompt(
        brief: brief,
        card: card,
        draftIndex: draftIndex,
        totalDrafts: max(totalDrafts, 1)
    )
case .synthesis:
    let groupID = card.creativeGroupID
    let draftArtifacts = (state.artifactBoardState?.artifacts ?? [])
        .filter { artifact in
            guard let gid = groupID else { return false }
            return state.taskBoardState?.card(id: artifact.taskCardID)?.creativeGroupID == gid
        }
        .filter { $0.kind == .ideaDraft }
    prompt = promptBuilder.buildSynthesisPrompt(
        brief: brief,
        synthesisCard: card,
        draftArtifacts: draftArtifacts
    )
case .standard:
    let existingArtifacts = (state.artifactBoardState?.artifacts ?? [])
        .filter { $0.taskCardID == card.id }
    prompt = promptBuilder.buildPrompt(brief: brief, card: card, artifacts: existingArtifacts)
}
```

同时，在 synthesis card 的 provider 分配处，将 `assignedProvider(at:eligibleProviders:)` 替换为对 synthesis 使用 conductor：

```swift
let providerRef: ExecutionProviderReference
if card.kind == .synthesis {
    providerRef = conductor
} else {
    providerRef = assignedProvider(at: index, eligibleProviders: eligibleProviders)
}
```

> **注意**：`artifactBoardState` 在 `AgentTeamSessionState` 中是可选的，上面代码用 `?? []` 安全展开。

### Step 4：运行确认测试通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature7-creative-parallelism \
  -only-testing:agentGuiTests/AgentTeamCreativeParallelismTests \
  -only-testing:agentGuiTests/AgentTeamLaunchCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:"
```

预期：Feature 7 新增测试全部 PASS，原有 `AgentTeamLaunchCoordinatorTests` 不受影响。

### Step 5：提交

```bash
git add agentGui/Services/Team/AgentTeamLaunchCoordinator.swift \
        agentGuiTests/AgentTeamCreativeParallelismTests.swift
git commit -m "feat(agent-team): claimBatch routes prompt builder by card kind for creative mode"
```

---

## Task 5：`AgentTeamWorkbenchPresentation` 投影创意草案信息

**Files:**
- Modify: `agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift`
- Modify: `agentGuiTests/AgentTeamWorkbenchPresentationTests.swift`

### Step 1：写失败测试

在 `AgentTeamWorkbenchPresentationTests.swift` 末尾追加：

```swift
// MARK: - Creative Mode Presentation

@MainActor
struct AgentTeamWorkbenchPresentationCreativeTests {

    private func makeCreativeState() -> (session: Session, state: AgentTeamSessionState) {
        let session = Session.fixture(title: "Icon 设计", kind: .agentTeam)
        let state = AgentTeamSessionState(
            session: session,
            sourceSessionID: "chat-1",
            sourceSessionTitle: "Icon 设计",
            mode: .creativeExploration,
            status: .active
        )
        state.missionBrief = AgentTeamMissionBrief(
            objective: "为「极简记账」设计 App Icon",
            constraints: [],
            acceptanceCriteria: [],
            mode: .creativeExploration,
            budget: .init(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "low"),
            initialContextSummary: ""
        )
        let groupID = UUID(uuidString: "gggggggg-gggg-gggg-gggg-gggggggggggg")!
        let draftID1 = UUID(uuidString: "d1d1d1d1-d1d1-d1d1-d1d1-d1d1d1d1d1d1")!
        let draftID2 = UUID(uuidString: "d2d2d2d2-d2d2-d2d2-d2d2-d2d2d2d2d2d2")!
        let synthID  = UUID(uuidString: "ssssssss-ssss-ssss-ssss-ssssssssssss")!
        state.taskBoardState = AgentTeamTaskBoardState(
            cards: [
                AgentTeamTaskCard(
                    id: draftID1, title: "草案 1", goal: "Icon",
                    status: .done, kind: .creativeDraft, creativeGroupID: groupID,
                    lastUpdatedAt: Date(timeIntervalSince1970: 1)
                ),
                AgentTeamTaskCard(
                    id: draftID2, title: "草案 2", goal: "Icon",
                    status: .done, kind: .creativeDraft, creativeGroupID: groupID,
                    lastUpdatedAt: Date(timeIntervalSince1970: 2)
                ),
                AgentTeamTaskCard(
                    id: synthID, title: "综合", goal: "Icon",
                    status: .working, kind: .synthesis, creativeGroupID: groupID,
                    dependencyIDs: [draftID1, draftID2],
                    lastUpdatedAt: Date(timeIntervalSince1970: 3)
                )
            ],
            claims: []
        )
        return (session, state)
    }

    @Test
    func boardCardExposesKindForCreativeDraftCard() {
        let (session, state) = makeCreativeState()
        let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: state)

        let draftCards = presentation.boardColumns
            .flatMap(\.cards)
            .filter { $0.cardKind == "creativeDraft" }
        #expect(draftCards.count == 2)
    }

    @Test
    func boardCardExposesDraftIndexForCreativeDraftCard() {
        let (session, state) = makeCreativeState()
        let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: state)

        let draftCards = presentation.boardColumns
            .flatMap(\.cards)
            .filter { $0.cardKind == "creativeDraft" }
        let indices = draftCards.compactMap(\.draftIndexText).sorted()
        #expect(indices == ["1", "2"])
    }

    @Test
    func boardCardExposesKindForSynthesisCard() {
        let (session, state) = makeCreativeState()
        let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: state)

        let synthesisCards = presentation.boardColumns
            .flatMap(\.cards)
            .filter { $0.cardKind == "synthesis" }
        #expect(synthesisCards.count == 1)
    }

    @Test
    func inspectorShowsDraftArtifactsForSynthesisCard() {
        let (session, state) = makeCreativeState()

        // Add ideaDraft artifacts for both draft cards
        let groupID = UUID(uuidString: "gggggggg-gggg-gggg-gggg-gggggggggggg")!
        let draftID1 = UUID(uuidString: "d1d1d1d1-d1d1-d1d1-d1d1-d1d1d1d1d1d1")!
        let draftID2 = UUID(uuidString: "d2d2d2d2-d2d2-d2d2-d2d2-d2d2d2d2d2d2")!
        _ = groupID  // used in card setup above

        state.artifactBoardState = AgentTeamArtifactBoardState(artifacts: [
            AgentTeamArtifact(
                id: UUID(uuidString: "a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1")!,
                kind: .ideaDraft, title: "几何方案",
                producer: .builtIn, taskCardID: draftID1,
                version: 1, summary: "简洁线条",
                payload: .text("几何线条设计方案"), status: .submitted
            ),
            AgentTeamArtifact(
                id: UUID(uuidString: "a2a2a2a2-a2a2-a2a2-a2a2-a2a2a2a2a2a2")!,
                kind: .ideaDraft, title: "字形方案",
                producer: .externalACP(profileID: "copilot"), taskCardID: draftID2,
                version: 1, summary: "字体变形",
                payload: .text("字形解构设计方案"), status: .submitted
            )
        ])

        let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: state)
        let draftItems = presentation.inspector.creativeDraftItems

        #expect(draftItems.count == 2)
        #expect(draftItems.map(\.title).contains("几何方案"))
        #expect(draftItems.map(\.title).contains("字形方案"))
    }
}
```

### Step 2：运行确认测试失败

预期：`cardKind`、`draftIndexText`、`creativeDraftItems` 未定义，编译失败。

### Step 3：扩展 `AgentTeamWorkbenchPresentation`

在 `AgentTeamWorkbenchPresentation.BoardCard` 结构体中增加：

```swift
let cardKind: String          // "standard" | "creativeDraft" | "synthesis"
let creativeGroupID: String?  // creative group UUID string，nil for standard
let draftIndexText: String?   // "1", "2", "3" etc. for draft; nil for others
```

在 `AgentTeamWorkbenchPresentation.InspectorSummary` 结构体中增加：

```swift
struct CreativeDraftItem: Identifiable, Equatable {
    let id: String
    let title: String
    let producerSummary: String
    let summary: String
    let contentPreview: String    // payload.textContent 前 200 字
}

let creativeDraftItems: [CreativeDraftItem]    // 当 inspector 聚焦 synthesis card 时填充
```

修改 `InspectorSummary` 的初始化，确保 `creativeDraftItems` 默认为 `[]`。

在 `AgentTeamWorkbenchPresentation.make(session:state:modelContext:)` 中：

1. **BoardCard 投影**（在 `makeBoardColumns` 或等效位置）：  
   - 把 `card.kind.rawValue` 传给 `cardKind`  
   - `creativeGroupID`：`card.creativeGroupID?.uuidString`  
   - `draftIndexText`：当 `card.kind == .creativeDraft` 时，计算该 card 在同 group 所有 draft card 中的 1-based 位置；否则 `nil`  
     ```swift
     var draftIndexText: String? = nil
     if card.kind == .creativeDraft, let gid = card.creativeGroupID {
         let draftsInGroup = taskBoard.cards
             .filter { $0.kind == .creativeDraft && $0.creativeGroupID == gid }
             .sorted { $0.lastUpdatedAt < $1.lastUpdatedAt }
         if let pos = draftsInGroup.firstIndex(where: { $0.id == card.id }) {
             draftIndexText = "\(pos + 1)"
         }
     }
     ```

2. **InspectorSummary** 已聚焦 synthesis card 时填充 `creativeDraftItems`：  
   - 从 `state.artifactBoardState` 中取属于同 group draft card 的 `ideaDraft` artifacts  
   - 映射为 `CreativeDraftItem`

> **注意**：当没有选中任何 card 时，`InspectorSummary.creativeDraftItems` 保持 `[]` 即可；不需要增加专门的"选中 card"参数，仍沿用现有 `make(session:state:modelContext:)` 签名。Inspector 内容反映整个 session 的综合状态，在当前架构下是全量投影。

### Step 4：运行确认测试通过

预期：`AgentTeamWorkbenchPresentationCreativeTests` 全部 PASS，原有 `AgentTeamWorkbenchPresentationTests` 不受影响。

### Step 5：提交

```bash
git add agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift \
        agentGuiTests/AgentTeamWorkbenchPresentationTests.swift
git commit -m "feat(agent-team): presentation exposes cardKind/draftIndexText/creativeDraftItems"
```

---

## Task 6：View 层 — 草案徽章 + Inspector Diff 区

**Files:**
- Modify: `agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift`

> Task 6 是纯 View 变更，不引入新业务逻辑，不需要单独测试文件。通过已有 UI 冒烟或人工预览验证。

### Step 1：`AgentTeamBoardCardView` 增加 Kind Badge

在 `AgentTeamBoardCardView.body` 中，找到已有的锁定图标显示区（`if card.isLocked { Image(...) }`），在它之前或之后根据 `card.cardKind` 显示对应徽章：

```swift
// 在卡标题行 HStack 内，lock badge 之前加入 kind badge
switch card.cardKind {
case "creativeDraft":
    if let indexText = card.draftIndexText {
        Text("草案\(indexText)")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.purple.opacity(0.15))
            .foregroundStyle(.purple)
            .clipShape(Capsule())
    }
case "synthesis":
    Text("综合")
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.indigo.opacity(0.15))
        .foregroundStyle(.indigo)
        .clipShape(Capsule())
default:
    EmptyView()
}
```

### Step 2：Inspector 增加 Creative Draft Diff 区

找到 `AgentTeamInspectorPanelView`（或等效的 inspector view），在 artifact 列表之后增加：

```swift
// creative draft comparison section
if !inspector.creativeDraftItems.isEmpty {
    Divider()
    Text("草案对比")
        .font(.headline)
        .padding(.bottom, 4)
    ForEach(inspector.creativeDraftItems) { item in
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(item.producerSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(item.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !item.contentPreview.isEmpty {
                Text(item.contentPreview)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.75))
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.bottom, 8)
    }
}
```

### Step 3：运行所有 Feature 7 测试确认无回归

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature7-creative-parallelism \
  -only-testing:agentGuiTests/AgentTeamTaskBoardTests \
  -only-testing:agentGuiTests/AgentTeamTaskBoardCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamLaunchCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamMissionBriefDraftTests \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  -only-testing:agentGuiTests/AgentTeamCreativeParallelismTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:"
```

预期：全部 PASS，零 error。

### Step 4：提交

```bash
git add agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift
git commit -m "feat(agent-team): board card creative badge + inspector draft diff view"
```

---

## Task 7：`AgentTeamMissionBriefDraftView` 增加 Creative Mode 入口（可选）

**Files:**
- Modify: `agentGui/Views/Team/AgentTeamMissionBriefDraftView.swift`（或等效的 brief creation view）

> 此 Task 为 UI 入口配置，不影响核心测试。如果现有的 brief draft view 已支持 mode 选择（如 Picker），只需确保 `.creativeExploration` 出现在列表中并有合理显示名称即可。

### Step 1：确认 mode 选择 Picker 已使用 `AgentTeamMode.allCases`

在 brief draft view 中找到 mode 选择控件（应为 `Picker` 或 `Segmented control`），确认其数据源使用 `AgentTeamMode.allCases`。若是，新增的 `.creativeExploration` case 会自动出现。

若有显示名称映射（如 `var displayName: String`），在 `AgentTeamMode` 或相关 extension 中补充：

```swift
extension AgentTeamMode {
    var displayName: String {
        switch self {
        case .executionDelivery:   return "执行交付"
        case .creativeExploration: return "创意探索"
        }
    }
}
```

> `AgentTeamWorkbenchPresentation` 的 `header.modeText` 已使用 `displayName`（或等效逻辑），修改此处后 header 会自动更新，不需要单独改 presentation 层。

### Step 2：提交

```bash
git add agentGui/Models/AgentTeamMode.swift   # 或对应修改文件
git commit -m "feat(agent-team): add displayName for creativeExploration mode"
```

---

## 验收检查

执行完整 Feature 7 测试套件：

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature7-creative-parallelism \
  -only-testing:agentGuiTests/AgentTeamTaskBoardTests \
  -only-testing:agentGuiTests/AgentTeamTaskBoardCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamLaunchCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamMissionBriefDraftTests \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  -only-testing:agentGuiTests/AgentTeamCreativeParallelismTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

预期输出：`** TEST SUCCEEDED **`

### 设计规范验收

| 验收条目 | 覆盖位置 |
|---|---|
| 同一 creative card 可产生 2–3 份并行草案 | Task 2 `bootstrapCreativeBoard`，Task 4 wave 1 |
| providers 在发散阶段不互相读取草稿 | Task 3 `buildCreativeDraftPrompt` 隔离指令，Task 4 `.creativeDraft` 路由不附带 peer artifacts |
| synthesis gate：全部 draft done 后才触发 | Task 2 synthesis card 依赖 draft cards；wave dispatch 天然处理 |
| synthesis prompt 包含所有 draft 内容 | Task 3 `buildSynthesisPrompt`，Task 4 synthesis 路由 |
| UI 能显示草案差异和最终收敛结果 | Task 5 presentation，Task 6 view |
| synthesis card 由 conductor 负责 | Task 4 `card.kind == .synthesis` → `conductor` provider |
| executionDelivery 模式不受影响 | Task 2 routing test |

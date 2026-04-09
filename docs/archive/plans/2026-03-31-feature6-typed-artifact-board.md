# Feature 6: Typed Artifact Board 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 把 provider 间共享从自由文本改为结构化工件（Typed Artifact），引入 artifact schema、持久化层、服务协调器、workbench 投影和 Inspector 展示，使 provider 可提交 artifact、reviewer 与 conductor 可消费 artifact。

**Architecture:** 沿用现有 Features 1–5 的分层模式：新增 `AgentTeamArtifact` 值类型模型 → `AgentTeamArtifactBoardState` 聚合 → SwiftData JSON 列持久化到 `AgentTeamSessionState.artifactBoardJSON` → `AgentTeamArtifactBoardCoordinator` 服务层 → `AgentTeamWorkbenchPresentation` 投影层 → View 层 Inspector 与 board card artifact 信息。

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing (`@Test` / `#expect`)，现有 `ExecutionProviderReference`、`AgentTeamTaskBoardState`。

---

## 前置知识

### 已有相关文件

| 文件 | 作用 |
|---|---|
| `agentGui/Models/AgentTeamTaskBoard.swift` | `AgentTeamTaskCard`、`AgentTeamTaskBoardState` |
| `agentGui/Models/AgentTeamSessionState.swift` | SwiftData 持久化层；所有 board 都以 JSON 列存储 |
| `agentGui/Services/Team/AgentTeamTaskBoardCoordinator.swift` | 状态迁移服务 |
| `agentGui/Services/Team/AgentTeamLaunchCoordinator.swift` | 启动/完成任务 |
| `agentGui/Services/Team/AgentTeamMissionPromptBuilder.swift` | 生成发给 provider 的 prompt |
| `agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift` | 聚合所有 UI 投影数据 |
| `agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift` | 工作台面板 Views |
| `agentGuiTests/AgentTeamTaskBoardTests.swift` | 参考测试写法 |
| `agentGuiTests/AgentTeamSessionStateTests.swift` | 参考 SwiftData in-memory 测试模式 |

### 测试运行命令（Feature 6）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature6-artifact-board \
  -only-testing:agentGuiTests/AgentTeamArtifactTests \
  -only-testing:agentGuiTests/AgentTeamTaskBoardTests \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests \
  -only-testing:agentGuiTests/AgentTeamArtifactBoardCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  CODE_SIGNING_ALLOWED=NO
```

---

## Task 1：AgentTeamArtifact 核心模型

**Files:**
- Create: `agentGui/Models/AgentTeamArtifact.swift`
- Create: `agentGuiTests/AgentTeamArtifactTests.swift`

### Step 1：写失败测试

```swift
// agentGuiTests/AgentTeamArtifactTests.swift
import Foundation
import Testing
@testable import agentGui

struct AgentTeamArtifactTests {

    @Test
    func artifactRoundTripsThroughJSON() throws {
        let producerRef = ExecutionProviderReference.builtIn
        let cardID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let artifact = AgentTeamArtifact(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            kind: .implementationPlan,
            title: "修复方案草案",
            producer: producerRef,
            taskCardID: cardID,
            version: 1,
            summary: "包含三个子步骤的修复计划",
            payload: .text("## 修复步骤\n1. 修改 Actor\n2. 补充 tests\n3. 提交 PR"),
            status: .submitted
        )

        let data = try JSONEncoder().encode(artifact)
        let decoded = try JSONDecoder().decode(AgentTeamArtifact.self, from: data)

        #expect(decoded == artifact)
    }

    @Test
    func artifactBoardStateRoundTripsThroughJSON() throws {
        let cardID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let artifact = AgentTeamArtifact(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            kind: .patchProposal,
            title: "PR #42",
            producer: .builtIn,
            taskCardID: cardID,
            version: 2,
            summary: "新增 AgentTeamArtifact 类型",
            payload: .text("diff --git a/Models/AgentTeamArtifact.swift"),
            status: .accepted
        )
        let board = AgentTeamArtifactBoardState(artifacts: [artifact])

        let data = try JSONEncoder().encode(board)
        let decoded = try JSONDecoder().decode(AgentTeamArtifactBoardState.self, from: data)

        #expect(decoded == board)
    }

    @Test
    func artifactBoardFiltersArtifactsByTaskCard() {
        let cardA = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let cardB = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let artifactForA = AgentTeamArtifact(
            id: UUID(), kind: .ideaDraft, title: "草案A",
            producer: .builtIn, taskCardID: cardA, version: 1,
            summary: "属于卡A", payload: .text("内容A"), status: .draft
        )
        let artifactForB = AgentTeamArtifact(
            id: UUID(), kind: .explorationReport, title: "报告B",
            producer: .builtIn, taskCardID: cardB, version: 1,
            summary: "属于卡B", payload: .text("内容B"), status: .draft
        )
        let board = AgentTeamArtifactBoardState(artifacts: [artifactForA, artifactForB])

        let resultA = board.artifacts(for: cardA)
        let resultB = board.artifacts(for: cardB)

        #expect(resultA.count == 1)
        #expect(resultA.first?.taskCardID == cardA)
        #expect(resultB.count == 1)
        #expect(resultB.first?.taskCardID == cardB)
    }

    @Test
    func artifactBoardFiltersArtifactsByProducer() {
        let cardID = UUID()
        let builtInArtifact = AgentTeamArtifact(
            id: UUID(), kind: .brief, title: "Brief",
            producer: .builtIn, taskCardID: cardID, version: 1,
            summary: "由 builtIn 产出", payload: .text("内容"), status: .submitted
        )
        let externalRef = ExecutionProviderReference.externalACP(
            profileID: LegacyExternalACPProviderKey.githubCopilotCLI.presetProfileID
        )
        let externalArtifact = AgentTeamArtifact(
            id: UUID(), kind: .validationReport, title: "Validation",
            producer: externalRef, taskCardID: cardID, version: 1,
            summary: "由外部 provider 产出", payload: .text("报告内容"), status: .draft
        )
        let board = AgentTeamArtifactBoardState(artifacts: [builtInArtifact, externalArtifact])

        #expect(board.artifacts(by: .builtIn).count == 1)
        #expect(board.artifacts(by: externalRef).count == 1)
    }

    @Test
    func artifactKindCoversAllFirstPhaseKinds() {
        let allKinds: [AgentTeamArtifactKind] = [
            .brief, .ideaDraft, .explorationReport, .implementationPlan,
            .patchProposal, .validationReport, .reviewReport, .finalSynthesis
        ]
        // 确保每个 kind 的 rawValue 可以往返
        for kind in allKinds {
            let restored = AgentTeamArtifactKind(rawValue: kind.rawValue)
            #expect(restored == kind)
        }
    }

    @Test
    func artifactStatusCoversAllExpectedCases() {
        let allStatuses: [AgentTeamArtifactStatus] = [.draft, .submitted, .accepted, .rejected]
        for status in allStatuses {
            let restored = AgentTeamArtifactStatus(rawValue: status.rawValue)
            #expect(restored == status)
        }
    }
}
```

### Step 2：运行测试，确认编译失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature6-artifact-board \
  -only-testing:agentGuiTests/AgentTeamArtifactTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译错误 `cannot find type 'AgentTeamArtifact' in scope`

### Step 3：实现模型

```swift
// agentGui/Models/AgentTeamArtifact.swift
import Foundation

// MARK: - Kind

enum AgentTeamArtifactKind: String, Codable, Equatable, Sendable, CaseIterable {
    case brief
    case ideaDraft
    case explorationReport
    case implementationPlan
    case patchProposal
    case validationReport
    case reviewReport
    case finalSynthesis
}

// MARK: - Status

enum AgentTeamArtifactStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case draft
    case submitted
    case accepted
    case rejected
}

// MARK: - Payload

enum AgentTeamArtifactPayload: Codable, Equatable, Sendable {
    case text(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type_ = try container.decodeIfPresent(String.self, forKey: .type) ?? "text"
        switch type_ {
        case "text":
            let content = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            self = .text(content)
        default:
            let content = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            self = .text(content)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(content):
            try container.encode("text", forKey: .type)
            try container.encode(content, forKey: .text)
        }
    }

    var textContent: String {
        switch self {
        case let .text(content): return content
        }
    }
}

// MARK: - Artifact

struct AgentTeamArtifact: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let kind: AgentTeamArtifactKind
    let title: String
    let producer: ExecutionProviderReference
    let taskCardID: UUID
    let version: Int
    let summary: String
    let payload: AgentTeamArtifactPayload
    var status: AgentTeamArtifactStatus
}

// MARK: - Board State

struct AgentTeamArtifactBoardState: Codable, Equatable, Sendable {
    var artifacts: [AgentTeamArtifact]

    init(artifacts: [AgentTeamArtifact] = []) {
        self.artifacts = artifacts
    }

    func artifacts(for taskCardID: UUID) -> [AgentTeamArtifact] {
        artifacts.filter { $0.taskCardID == taskCardID }
    }

    func artifacts(by producer: ExecutionProviderReference) -> [AgentTeamArtifact] {
        artifacts.filter { $0.producer == producer }
    }

    func artifact(id: UUID) -> AgentTeamArtifact? {
        artifacts.first { $0.id == id }
    }
}
```

### Step 4：运行测试，确认全部通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature6-artifact-board \
  -only-testing:agentGuiTests/AgentTeamArtifactTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：所有测试 PASS

### Step 5：提交

```bash
git add agentGui/Models/AgentTeamArtifact.swift agentGuiTests/AgentTeamArtifactTests.swift
git commit -m "feat(feature6): add AgentTeamArtifact model, payload, kind, status, board state"
```

---

## Task 2：AgentTeamTaskCard 增加 artifactIDs（向后兼容）

**Files:**
- Modify: `agentGui/Models/AgentTeamTaskBoard.swift`
- Modify: `agentGuiTests/AgentTeamTaskBoardTests.swift`

### Step 1：写失败测试

在 `agentGuiTests/AgentTeamTaskBoardTests.swift` 末尾追加：

```swift
    @Test
    func taskCardDecodesLegacyJSONWithoutArtifactIDs() throws {
        // JSON 不含 artifactIDs 字段（旧版序列化数据），应当降级为空数组
        let legacyJSON = """
        {
            "id": "55555555-5555-5555-5555-555555555555",
            "title": "旧版卡片",
            "goal": "测试向后兼容",
            "status": "briefed",
            "dependencyIDs": [],
            "lastUpdatedAt": 0
        }
        """
        let data = legacyJSON.data(using: .utf8)!
        let card = try JSONDecoder().decode(AgentTeamTaskCard.self, from: data)

        #expect(card.artifactIDs == [])
    }

    @Test
    func taskCardRoundTripsArtifactIDs() throws {
        let artifactID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let cardID = UUID(uuidString: "55555555-5555-5555-5555-555555555556")!
        let card = AgentTeamTaskCard(
            id: cardID,
            title: "含工件的卡片",
            goal: "测试 artifactIDs 序列化",
            status: .working,
            owner: .builtIn,
            acceptedClaimID: nil,
            dependencyIDs: [],
            artifactIDs: [artifactID],
            blockerSummary: nil,
            lastUpdatedAt: Date(timeIntervalSince1970: 100)
        )

        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(AgentTeamTaskCard.self, from: data)

        #expect(decoded.artifactIDs == [artifactID])
    }
```

### Step 2：运行测试，确认失败

预期：`AgentTeamTaskCard` 没有 `artifactIDs` 参数，编译错误

### Step 3：修改 `AgentTeamTaskCard`

在 `agentGui/Models/AgentTeamTaskBoard.swift` 中找到 `AgentTeamTaskCard` struct 定义：

**改前：**
```swift
struct AgentTeamTaskCard: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var goal: String
    var status: AgentTeamTaskStatus
    var owner: ExecutionProviderReference?
    var acceptedClaimID: UUID?
    var dependencyIDs: [UUID]
    var blockerSummary: String?
    var lastUpdatedAt: Date
}
```

**改后：**
```swift
struct AgentTeamTaskCard: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var goal: String
    var status: AgentTeamTaskStatus
    var owner: ExecutionProviderReference?
    var acceptedClaimID: UUID?
    var dependencyIDs: [UUID]
    var artifactIDs: [UUID]
    var blockerSummary: String?
    var lastUpdatedAt: Date

    // MARK: - Backward-compatible init

    init(
        id: UUID,
        title: String,
        goal: String,
        status: AgentTeamTaskStatus,
        owner: ExecutionProviderReference? = nil,
        acceptedClaimID: UUID? = nil,
        dependencyIDs: [UUID] = [],
        artifactIDs: [UUID] = [],
        blockerSummary: String? = nil,
        lastUpdatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.goal = goal
        self.status = status
        self.owner = owner
        self.acceptedClaimID = acceptedClaimID
        self.dependencyIDs = dependencyIDs
        self.artifactIDs = artifactIDs
        self.blockerSummary = blockerSummary
        self.lastUpdatedAt = lastUpdatedAt
    }

    // MARK: - Codable (backward-compatible decode)

    private enum CodingKeys: String, CodingKey {
        case id, title, goal, status, owner, acceptedClaimID
        case dependencyIDs, artifactIDs, blockerSummary, lastUpdatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(UUID.self,    forKey: .id)
        title          = try c.decode(String.self,  forKey: .title)
        goal           = try c.decode(String.self,  forKey: .goal)
        status         = try c.decode(AgentTeamTaskStatus.self, forKey: .status)
        owner          = try c.decodeIfPresent(ExecutionProviderReference.self, forKey: .owner)
        acceptedClaimID = try c.decodeIfPresent(UUID.self, forKey: .acceptedClaimID)
        dependencyIDs  = (try? c.decode([UUID].self, forKey: .dependencyIDs)) ?? []
        artifactIDs    = (try? c.decode([UUID].self, forKey: .artifactIDs)) ?? []
        blockerSummary = try c.decodeIfPresent(String.self, forKey: .blockerSummary)
        lastUpdatedAt  = try c.decode(Date.self, forKey: .lastUpdatedAt)
    }
}
```

**注意：** 同时要更新 `migrating(_:)` 中的 `AgentTeamTaskCard` 初始化调用，补上 `artifactIDs: []` 参数（由于有默认值，实际上不需要显式传，但如果 migrating 用了逐字段 init 就需要更新）。

在 `AgentTeamTaskBoardState.migrating(_:)` 中：

```swift
return AgentTeamTaskCard(
    id: legacyCard.id,
    title: legacyCard.title,
    goal: legacyCard.goal,
    status: legacyCard.phase.taskStatus,
    owner: legacyCard.owner,
    acceptedClaimID: acceptedClaim?.id,
    dependencyIDs: [],
    artifactIDs: [],   // ← 新增，向后兼容迁移默认为空
    blockerSummary: nil,
    lastUpdatedAt: acceptedClaim?.submittedAt ?? Date(timeIntervalSince1970: 0)
)
```

类似地，`bootstrapBoard(from:preferredProvider:)` 中的 `AgentTeamTaskCard` 初始化也要补上 `artifactIDs: []`（已有默认值，显式传以防混淆）。

### Step 4：运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature6-artifact-board \
  -only-testing:agentGuiTests/AgentTeamTaskBoardTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：所有 AgentTeamTaskBoardTests 通过

### Step 5：提交

```bash
git add agentGui/Models/AgentTeamTaskBoard.swift agentGuiTests/AgentTeamTaskBoardTests.swift
git commit -m "feat(feature6): add artifactIDs to AgentTeamTaskCard with backward-compatible Codable decode"
```

---

## Task 3：AgentTeamSessionState 增加 artifact 持久化

**Files:**
- Modify: `agentGui/Models/AgentTeamSessionState.swift`
- Modify: `agentGuiTests/AgentTeamSessionStateTests.swift`

### Step 1：写失败测试

追加到 `agentGuiTests/AgentTeamSessionStateTests.swift`：

```swift
    @Test
    func artifactBoardStateRoundTripsThroughPersistenceSlot() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session)
        let cardID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let artifact = AgentTeamArtifact(
            id: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
            kind: .patchProposal,
            title: "修复 PR",
            producer: .builtIn,
            taskCardID: cardID,
            version: 1,
            summary: "新增 artifact 持久化",
            payload: .text("--- diff ---"),
            status: .submitted
        )
        let board = AgentTeamArtifactBoardState(artifacts: [artifact])

        state.artifactBoardState = board

        #expect(state.artifactBoardState == board)
        #expect(state.artifactBoardJSON.isEmpty == false)
    }

    @Test
    func emptyArtifactBoardJSONReturnsNil() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session)

        #expect(state.artifactBoardJSON == "")
        #expect(state.artifactBoardState == nil)
    }

    @Test
    func updatingArtifactBoardRefreshesUpdatedAt() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let originalUpdatedAt = Date(timeIntervalSince1970: 1)
        let state = AgentTeamSessionState(
            session: session,
            updatedAt: originalUpdatedAt
        )

        state.artifactBoardState = AgentTeamArtifactBoardState(artifacts: [])

        #expect(state.updatedAt >= originalUpdatedAt)
    }
```

### Step 2：运行测试，确认失败

预期：`AgentTeamSessionState` 未含 `artifactBoardJSON` 及相关属性，编译错误

### Step 3：修改 `AgentTeamSessionState`

在 `agentGui/Models/AgentTeamSessionState.swift` 中：

1. 在 `@Model final class AgentTeamSessionState` 的属性列表里，在 `var taskBoardJSON: String=""` 之后**新增**：

```swift
    var artifactBoardJSON: String = ""
```

2. 在 `init(...)` 参数列表里添加（带默认值）：

```swift
    init(
        session: Session,
        sourceSessionID: String = "",
        sourceSessionTitle: String = "",
        briefJSON: String = "",
        claimBoardJSON: String = "",
        taskBoardJSON: String = "",
        artifactBoardJSON: String = "",   // ← 新增
        mode: AgentTeamMode = .executionDelivery,
        status: AgentTeamRunStatus = .created,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        // ...已有字段...
        self.artifactBoardJSON = artifactBoardJSON  // ← 新增
        // ...
    }
```

3. 在 `extension AgentTeamSessionState` 中追加 computed property 和 helper：

```swift
    var artifactBoardState: AgentTeamArtifactBoardState? {
        get {
            guard let data = artifactBoardJSON.data(using: .utf8),
                  let board = try? JSONDecoder().decode(AgentTeamArtifactBoardState.self, from: data) else {
                return nil
            }
            return board
        }
        set {
            updateArtifactBoard(newValue)
        }
    }

    func updateArtifactBoard(_ board: AgentTeamArtifactBoardState?) {
        guard let board else {
            artifactBoardJSON = ""
            updatedAt = Date()
            return
        }

        guard let data = try? JSONEncoder().encode(board),
              let encoded = String(data: data, encoding: .utf8) else {
            artifactBoardJSON = ""
            updatedAt = Date()
            return
        }

        artifactBoardJSON = encoded
        updatedAt = Date()
    }
```

### Step 4：运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature6-artifact-board \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

### Step 5：提交

```bash
git add agentGui/Models/AgentTeamSessionState.swift agentGuiTests/AgentTeamSessionStateTests.swift
git commit -m "feat(feature6): add artifactBoardJSON persistence to AgentTeamSessionState"
```

---

## Task 4：AgentTeamArtifactBoardCoordinator 服务层

负责：提交 artifact（同时把 artifact ID 连接到 task card）、更新 artifact 状态。

**Files:**
- Create: `agentGui/Services/Team/AgentTeamArtifactBoardCoordinator.swift`
- Create: `agentGuiTests/AgentTeamArtifactBoardCoordinatorTests.swift`

### Step 1：写失败测试

```swift
// agentGuiTests/AgentTeamArtifactBoardCoordinatorTests.swift
import Foundation
import Testing
@testable import agentGui

struct AgentTeamArtifactBoardCoordinatorTests {

    // MARK: - submitArtifact

    @Test
    func submitArtifactAppendsToBoard() throws {
        let cardID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        var taskBoard = makeTaskBoardWithWorkingCard(cardID: cardID)
        var artifactBoard = AgentTeamArtifactBoardState()
        let coordinator = AgentTeamArtifactBoardCoordinator()

        let artifact = makeArtifact(kind: .patchProposal, cardID: cardID)
        let (updatedArtifactBoard, updatedTaskBoard) = try coordinator.submitArtifact(
            artifact,
            into: artifactBoard,
            linking: &taskBoard
        )

        #expect(updatedArtifactBoard.artifacts.count == 1)
        #expect(updatedArtifactBoard.artifacts.first?.id == artifact.id)
        #expect(updatedTaskBoard.card(id: cardID)?.artifactIDs.contains(artifact.id) == true)
    }

    @Test
    func submitArtifactWithUnknownCardIDThrows() {
        let cardID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let unknownCardID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        var taskBoard = makeTaskBoardWithWorkingCard(cardID: cardID)
        var artifactBoard = AgentTeamArtifactBoardState()
        let coordinator = AgentTeamArtifactBoardCoordinator()

        let artifact = makeArtifact(kind: .validationReport, cardID: unknownCardID)

        #expect(throws: AgentTeamArtifactBoardCoordinator.Error.taskCardNotFound(unknownCardID)) {
            _ = try coordinator.submitArtifact(artifact, into: artifactBoard, linking: &taskBoard)
        }
    }

    @Test
    func submitDuplicateArtifactIDThrows() throws {
        let cardID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        var taskBoard = makeTaskBoardWithWorkingCard(cardID: cardID)
        let coordinator = AgentTeamArtifactBoardCoordinator()
        let artifact = makeArtifact(kind: .brief, cardID: cardID)

        var (board, _) = try coordinator.submitArtifact(artifact, into: AgentTeamArtifactBoardState(), linking: &taskBoard)

        #expect(throws: AgentTeamArtifactBoardCoordinator.Error.duplicateArtifactID(artifact.id)) {
            _ = try coordinator.submitArtifact(artifact, into: board, linking: &taskBoard)
        }
    }

    // MARK: - updateArtifactStatus

    @Test
    func updateArtifactStatusTransitionsCorrectly() throws {
        let cardID = UUID()
        var taskBoard = makeTaskBoardWithWorkingCard(cardID: cardID)
        let coordinator = AgentTeamArtifactBoardCoordinator()
        let artifact = makeArtifact(kind: .reviewReport, cardID: cardID, status: .submitted)
        let (board, _) = try coordinator.submitArtifact(artifact, into: AgentTeamArtifactBoardState(), linking: &taskBoard)

        let updatedBoard = try coordinator.updateArtifactStatus(artifact.id, to: .accepted, in: board)

        #expect(updatedBoard.artifact(id: artifact.id)?.status == .accepted)
    }

    @Test
    func updateStatusForUnknownArtifactIDThrows() {
        let unknownID = UUID()
        let board = AgentTeamArtifactBoardState()
        let coordinator = AgentTeamArtifactBoardCoordinator()

        #expect(throws: AgentTeamArtifactBoardCoordinator.Error.artifactNotFound(unknownID)) {
            _ = try coordinator.updateArtifactStatus(unknownID, to: .rejected, in: board)
        }
    }

    // MARK: - Helpers

    private func makeTaskBoardWithWorkingCard(cardID: UUID) -> AgentTeamTaskBoardState {
        let claim = acceptedClaimFixture(id: UUID(), taskCardID: cardID)
        return AgentTeamTaskBoardState(
            cards: [
                AgentTeamTaskCard(
                    id: cardID,
                    title: "测试卡",
                    goal: "用于 artifact 测试",
                    status: .working,
                    owner: .builtIn,
                    acceptedClaimID: claim.id,
                    dependencyIDs: [],
                    artifactIDs: [],
                    blockerSummary: nil,
                    lastUpdatedAt: Date(timeIntervalSince1970: 1)
                )
            ],
            claims: [claim]
        )
    }

    private func makeArtifact(
        kind: AgentTeamArtifactKind,
        cardID: UUID,
        status: AgentTeamArtifactStatus = .draft
    ) -> AgentTeamArtifact {
        AgentTeamArtifact(
            id: UUID(),
            kind: kind,
            title: "\(kind.rawValue) artifact",
            producer: .builtIn,
            taskCardID: cardID,
            version: 1,
            summary: "测试用摘要",
            payload: .text("测试内容"),
            status: status
        )
    }
}
```

**注意：** `acceptedClaimFixture` 来自 `agentGuiTests/TestSupport/`，直接复用。

### Step 2：运行测试，确认编译失败

预期：`AgentTeamArtifactBoardCoordinator` 不存在

### Step 3：实现服务

```swift
// agentGui/Services/Team/AgentTeamArtifactBoardCoordinator.swift
import Foundation

/// 管理 AgentTeamArtifactBoardState 的状态变更：
/// - 提交新 artifact，同时把 artifact ID 连接到对应的 task card
/// - 更新已有 artifact 的状态
struct AgentTeamArtifactBoardCoordinator {

    // MARK: - Error

    enum Error: LocalizedError, Equatable {
        case taskCardNotFound(UUID)
        case duplicateArtifactID(UUID)
        case artifactNotFound(UUID)

        var errorDescription: String? {
            switch self {
            case let .taskCardNotFound(cardID):
                return "未找到 task card：\(cardID.uuidString.lowercased())，无法提交 artifact。"
            case let .duplicateArtifactID(artifactID):
                return "artifact \(artifactID.uuidString.lowercased()) 已存在，请勿重复提交。"
            case let .artifactNotFound(artifactID):
                return "未找到 artifact：\(artifactID.uuidString.lowercased())。"
            }
        }
    }

    // MARK: - Submit

    /// 提交 artifact 到 artifact board，并将 artifact.id 追加到对应 task card 的 artifactIDs 中。
    /// 返回 (更新后的 artifactBoard, 更新后的 taskBoard)。
    func submitArtifact(
        _ artifact: AgentTeamArtifact,
        into artifactBoard: AgentTeamArtifactBoardState,
        linking taskBoard: inout AgentTeamTaskBoardState
    ) throws -> (AgentTeamArtifactBoardState, AgentTeamTaskBoardState) {
        guard taskBoard.card(id: artifact.taskCardID) != nil else {
            throw Error.taskCardNotFound(artifact.taskCardID)
        }
        guard artifactBoard.artifact(id: artifact.id) == nil else {
            throw Error.duplicateArtifactID(artifact.id)
        }

        // Append to artifact board
        var nextArtifactBoard = artifactBoard
        nextArtifactBoard.artifacts.append(artifact)

        // Link artifact ID to task card
        var nextTaskBoard = taskBoard
        if let idx = nextTaskBoard.cards.firstIndex(where: { $0.id == artifact.taskCardID }) {
            nextTaskBoard.cards[idx].artifactIDs.append(artifact.id)
        }
        taskBoard = nextTaskBoard

        return (nextArtifactBoard, nextTaskBoard)
    }

    // MARK: - Update Status

    /// 更新指定 artifact 的 status。
    func updateArtifactStatus(
        _ artifactID: UUID,
        to status: AgentTeamArtifactStatus,
        in board: AgentTeamArtifactBoardState
    ) throws -> AgentTeamArtifactBoardState {
        guard let idx = board.artifacts.firstIndex(where: { $0.id == artifactID }) else {
            throw Error.artifactNotFound(artifactID)
        }

        var next = board
        next.artifacts[idx].status = status
        return next
    }
}
```

### Step 4：运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature6-artifact-board \
  -only-testing:agentGuiTests/AgentTeamArtifactBoardCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

### Step 5：提交

```bash
git add agentGui/Services/Team/AgentTeamArtifactBoardCoordinator.swift \
        agentGuiTests/AgentTeamArtifactBoardCoordinatorTests.swift
git commit -m "feat(feature6): add AgentTeamArtifactBoardCoordinator with submit and status update"
```

---

## Task 5：AgentTeamWorkbenchPresentation artifact 投影

**Files:**
- Modify: `agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift`
- Modify: `agentGuiTests/AgentTeamWorkbenchPresentationTests.swift`

### Step 1：写失败测试

追加到 `agentGuiTests/AgentTeamWorkbenchPresentationTests.swift`：

```swift
    @Test
    func presentationProjectsArtifactsForFocusedCard() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session)

        let cardID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let artifactID = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!

        state.missionBrief = AgentTeamMissionBrief(
            objective: "测试 artifact 投影",
            constraints: [],
            acceptanceCriteria: [],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: 1, tokenBudgetText: "10k", costBudgetText: "low"),
            initialContextSummary: ""
        )

        // Build task board with one working card that references the artifact
        let claim = AgentTeamClaim(
            id: UUID(),
            providerReference: .builtIn,
            taskCardID: cardID,
            confidence: 1.0,
            rationaleSummary: "auto",
            requiredCapabilities: [],
            expectedArtifacts: [],
            estimatedCostSummary: "low",
            status: .accepted,
            submittedAt: Date(timeIntervalSince1970: 1)
        )
        state.taskBoardState = AgentTeamTaskBoardState(
            cards: [
                AgentTeamTaskCard(
                    id: cardID,
                    title: "主任务",
                    goal: "测试",
                    status: .working,
                    owner: .builtIn,
                    acceptedClaimID: claim.id,
                    dependencyIDs: [],
                    artifactIDs: [artifactID],
                    blockerSummary: nil,
                    lastUpdatedAt: Date(timeIntervalSince1970: 1)
                )
            ],
            claims: [claim]
        )

        // Persist artifact board
        state.artifactBoardState = AgentTeamArtifactBoardState(
            artifacts: [
                AgentTeamArtifact(
                    id: artifactID,
                    kind: .patchProposal,
                    title: "PR #99",
                    producer: .builtIn,
                    taskCardID: cardID,
                    version: 1,
                    summary: "新增 artifact 投影测试",
                    payload: .text("diff内容"),
                    status: .submitted
                )
            ]
        )

        let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: state)

        // Inspector 应包含 artifact 列表信息
        #expect(presentation.inspector.artifactItems.count == 1)
        #expect(presentation.inspector.artifactItems.first?.title == "PR #99")
        #expect(presentation.inspector.artifactItems.first?.kindText == "patchProposal")
        #expect(presentation.inspector.artifactItems.first?.statusText == "submitted")

        // Board card 应显示 artifact 数量
        let workingCard = presentation.boardColumns
            .first(where: { $0.id == AgentTeamTaskStatus.working.rawValue })?
            .cards
            .first(where: { $0.id == cardID.uuidString })
        #expect(workingCard?.artifactCountText == "1 件工件")
    }

    @Test
    func presentationEmptyArtifactBoardShowsNoItems() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session)
        state.missionBrief = AgentTeamMissionBrief(
            objective: "空 artifact board 测试",
            constraints: [],
            acceptanceCriteria: [],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: 1, tokenBudgetText: "5k", costBudgetText: "low"),
            initialContextSummary: ""
        )

        let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: state)

        #expect(presentation.inspector.artifactItems.isEmpty)
    }
```

### Step 2：运行测试，确认失败

预期：`InspectorSummary.artifactItems`、`BoardCard.artifactCountText` 不存在，编译错误

### Step 3：更新 `AgentTeamWorkbenchPresentation`

在 `agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift` 中做如下修改：

**3a. 新增 `ArtifactItem` struct（在其他 struct 附近）：**

```swift
    struct ArtifactItem: Identifiable, Equatable {
        let id: String         // artifact UUID string
        let title: String
        let kindText: String
        let producerSummary: String
        let statusText: String
        let summary: String
    }
```

**3b. 在 `InspectorSummary` 中追加 artifactItems：**

```swift
    struct InspectorSummary: Equatable {
        let title: String
        let ownerSummary: String
        let dependencySummary: String
        let blockerSummary: String
        let downstreamSummary: String
        let artifactItems: [ArtifactItem]   // ← 新增
    }
```

**3c. 在 `BoardCard` 中追加 artifactCountText：**

```swift
    struct BoardCard: Identifiable, Equatable {
        let id: String
        let title: String
        let summary: String
        let owner: String
        let statusText: String
        let claimCountText: String
        let dependencySummary: String
        let blockerSummary: String?
        let artifactCountText: String      // ← 新增
    }
```

**3d. 更新 `make(session:state:modelContext:)` 方法：**

在该方法中，访问 `state.artifactBoardState`，将其传入 `makeBoardColumns` 和 `makeInspectorSummary`：

```swift
        let artifactBoard = state?.artifactBoardState
```

**3e. 更新 `makeBoardColumns` 使其接收 artifactBoard 参数**（或在内部通过参数传递），为每张 card 生成 `artifactCountText`：

```swift
    private static func artifactCountText(for card: AgentTeamTaskCard, artifactBoard: AgentTeamArtifactBoardState?) -> String {
        let count = artifactBoard?.artifacts(for: card.id).count ?? 0
        switch count {
        case 0: return "无工件"
        case 1: return "1 件工件"
        default: return "\(count) 件工件"
        }
    }
```

在 `makeBoardColumns` 将 `BoardCard` 的 `artifactCountText` 字段填充为：
```swift
artifactCountText: artifactCountText(for: taskCard, artifactBoard: artifactBoard)
```

**3f. 更新 `makeInspectorSummary` 使其接收 artifactBoard 参数**，生成 focused card 的 artifact items：

关键逻辑：取第一张 `.working` 状态的 card 作为 "focused card"（或最后更新的 card）：

```swift
    private static func makeInspectorSummary(
        from boardState: AgentTeamTaskBoardState?,
        artifactBoard: AgentTeamArtifactBoardState?,
        modelContext: ModelContext?
    ) -> InspectorSummary {
        guard let boardState, let focusedCard = boardState.cards.first(where: { $0.status == .working })
            ?? boardState.cards.max(by: { $0.lastUpdatedAt < $1.lastUpdatedAt }) else {
            return InspectorSummary(
                title: "暂无活跃任务",
                ownerSummary: "—",
                dependencySummary: "无依赖",
                blockerSummary: "无阻塞",
                downstreamSummary: "无下游",
                artifactItems: []
            )
        }

        let ownerName = focusedCard.owner.map { displayName(for: $0, modelContext: modelContext) } ?? "待认领"
        let depIDs = focusedCard.dependencyIDs
        let depSummary = depIDs.isEmpty ? "无依赖" : "依赖 \(depIDs.count) 张卡"
        let downstreamIDs = boardState.cards.filter { $0.dependencyIDs.contains(focusedCard.id) }.map(\.id)
        let downstreamSummary = downstreamIDs.isEmpty ? "无下游" : "下游 \(downstreamIDs.count) 张卡"

        let artifactItems: [ArtifactItem] = (artifactBoard?.artifacts(for: focusedCard.id) ?? [])
            .map { artifact in
                ArtifactItem(
                    id: artifact.id.uuidString,
                    title: artifact.title,
                    kindText: artifact.kind.rawValue,
                    producerSummary: displayName(for: artifact.producer, modelContext: modelContext),
                    statusText: artifact.status.rawValue,
                    summary: artifact.summary
                )
            }

        return InspectorSummary(
            title: focusedCard.title,
            ownerSummary: "Owner：\(ownerName)",
            dependencySummary: depSummary,
            blockerSummary: focusedCard.blockerSummary.map { "阻塞：\($0)" } ?? "无阻塞",
            downstreamSummary: downstreamSummary,
            artifactItems: artifactItems
        )
    }
```

**所有调用 `makeInspectorSummary` 的地方都要更新签名，传入 `artifactBoard` 参数。**

### Step 4：运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature6-artifact-board \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

### Step 5：提交

```bash
git add agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift \
        agentGuiTests/AgentTeamWorkbenchPresentationTests.swift
git commit -m "feat(feature6): add ArtifactItem projection to InspectorSummary and artifactCountText to BoardCard"
```

---

## Task 6：View 层展示 artifact list 与 inspector

**Files:**
- Modify: `agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift`

本 Task 不需要新增测试（纯 View 变更，逻辑已由 Task 5 的 Presentation 测试覆盖）。

### Step 1：更新 `AgentTeamInspectorPanelView`

在 `agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift` 里找到 `AgentTeamInspectorPanelView`：

**改前：**
```swift
struct AgentTeamInspectorPanelView: View {
    let summary: AgentTeamWorkbenchPresentation.InspectorSummary

    var body: some View {
        WorkbenchSidebarSectionCard(title: "Inspector", systemImage: "sidebar.right") {
            VStack(alignment: .leading, spacing: 10) {
                Text(summary.title)
                    .font(.headline)
                Text(summary.ownerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(summary.dependencySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(summary.blockerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(summary.downstreamSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
```

**改后：**
```swift
struct AgentTeamInspectorPanelView: View {
    let summary: AgentTeamWorkbenchPresentation.InspectorSummary

    var body: some View {
        WorkbenchSidebarSectionCard(title: "Inspector", systemImage: "sidebar.right") {
            VStack(alignment: .leading, spacing: 10) {
                Text(summary.title)
                    .font(.headline)
                Text(summary.ownerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(summary.dependencySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(summary.blockerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(summary.downstreamSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !summary.artifactItems.isEmpty {
                    Divider()
                    Text("Artifacts")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(summary.artifactItems) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.caption.weight(.medium))
                            Text("\(item.kindText) · \(item.statusText)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(item.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
```

### Step 2：更新 `AgentTeamBoardPanelView` 中的 BoardCard 展示

在 `AgentTeamBoardPanelView` 的 card VStack 里，把已有的 `claimCountText` 行下方加上 artifactCountText：

**在 `Text(card.claimCountText)` 行之后插入：**

```swift
                                    Text(card.artifactCountText)
                                        .font(.caption2)
                                        .foregroundStyle(card.artifactCountText == "无工件" ? .secondary : .blue)
```

### Step 3：验证编译通过

```bash
xcodebuild build \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-feature6-artifact-board \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED"
```

预期：`BUILD SUCCEEDED`

### Step 4：提交

```bash
git add agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift
git commit -m "feat(feature6): show artifact list in Inspector and artifact count on board cards"
```

---

## Task 7：AgentTeamMissionPromptBuilder 注入 artifact context

供 conductor/reviewer 在后续 card launch 时感知现有 artifacts（Feature 8 多卡场景将直接使用此重载）。

**Files:**
- Modify: `agentGui/Services/Team/AgentTeamMissionPromptBuilder.swift`
- 不需要新增测试文件（追加到现有测试用例即可，但该文件目前无专属测试，如没有则创建）

检查是否已有测试文件：如不存在 `agentGuiTests/AgentTeamMissionPromptBuilderTests.swift`，则创建。

### Step 1：写测试（追加或新建）

若 `agentGuiTests/AgentTeamMissionPromptBuilderTests.swift` 不存在，则创建：

```swift
// agentGuiTests/AgentTeamMissionPromptBuilderTests.swift
import Foundation
import Testing
@testable import agentGui

struct AgentTeamMissionPromptBuilderTests {

    @Test
    func promptIncludesObjectiveAndCard() {
        let brief = AgentTeamMissionBrief(
            objective: "为 ACP 修复并发 bug",
            constraints: ["不改 public API"],
            acceptanceCriteria: ["Focused tests 通过"],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "medium"),
            initialContextSummary: "聊天包含错误日志"
        )
        let card = AgentTeamTaskCard(
            id: UUID(),
            title: "主修复任务",
            goal: "修复 Actor isolation 问题",
            status: .working,
            owner: .builtIn,
            acceptedClaimID: nil,
            dependencyIDs: [],
            artifactIDs: [],
            blockerSummary: nil,
            lastUpdatedAt: Date(timeIntervalSince1970: 0)
        )

        let prompt = AgentTeamMissionPromptBuilder().buildPrompt(brief: brief, card: card)

        #expect(prompt.contains("为 ACP 修复并发 bug"))
        #expect(prompt.contains("主修复任务"))
        #expect(prompt.contains("不改 public API"))
        #expect(prompt.contains("Focused tests 通过"))
        #expect(prompt.contains("聊天包含错误日志"))
    }

    @Test
    func promptWithArtifactsIncludesArtifactSection() {
        let cardID = UUID()
        let brief = AgentTeamMissionBrief(
            objective: "完成 PR 审核",
            constraints: [],
            acceptanceCriteria: ["通过 review"],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: 1, tokenBudgetText: "5k", costBudgetText: "low"),
            initialContextSummary: ""
        )
        let card = AgentTeamTaskCard(
            id: cardID,
            title: "审核卡",
            goal: "审核 PR",
            status: .reviewing,
            owner: .builtIn,
            acceptedClaimID: nil,
            dependencyIDs: [],
            artifactIDs: [],
            blockerSummary: nil,
            lastUpdatedAt: Date(timeIntervalSince1970: 0)
        )
        let artifacts = [
            AgentTeamArtifact(
                id: UUID(),
                kind: .patchProposal,
                title: "PR #99",
                producer: .builtIn,
                taskCardID: cardID,
                version: 1,
                summary: "修复 Actor isolation",
                payload: .text("diff 内容"),
                status: .submitted
            )
        ]

        let prompt = AgentTeamMissionPromptBuilder().buildPrompt(
            brief: brief,
            card: card,
            artifacts: artifacts
        )

        #expect(prompt.contains("Existing Artifacts"))
        #expect(prompt.contains("PR #99"))
        #expect(prompt.contains("修复 Actor isolation"))
        #expect(prompt.contains("patchProposal"))
    }

    @Test
    func promptWithEmptyArtifactsOmitsArtifactSection() {
        let brief = AgentTeamMissionBrief(
            objective: "测试",
            constraints: [],
            acceptanceCriteria: [],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: 1, tokenBudgetText: "5k", costBudgetText: "low"),
            initialContextSummary: ""
        )
        let card = AgentTeamTaskCard(
            id: UUID(),
            title: "测试卡",
            goal: "测试",
            status: .working,
            owner: .builtIn,
            acceptedClaimID: nil,
            dependencyIDs: [],
            artifactIDs: [],
            blockerSummary: nil,
            lastUpdatedAt: Date(timeIntervalSince1970: 0)
        )

        let prompt = AgentTeamMissionPromptBuilder().buildPrompt(
            brief: brief,
            card: card,
            artifacts: []
        )

        #expect(prompt.contains("Existing Artifacts") == false)
    }
}
```

### Step 2：运行测试，确认编译失败

预期：`buildPrompt(brief:card:artifacts:)` 重载不存在

### Step 3：在 `AgentTeamMissionPromptBuilder` 添加重载

```swift
// 在 agentGui/Services/Team/AgentTeamMissionPromptBuilder.swift 中追加

extension AgentTeamMissionPromptBuilder {
    /// 带 artifact context 的重载，供 reviewer / 多卡 conductor 使用。
    func buildPrompt(
        brief: AgentTeamMissionBrief,
        card: AgentTeamTaskCard,
        artifacts: [AgentTeamArtifact]
    ) -> String {
        var prompt = buildPrompt(brief: brief, card: card)

        guard !artifacts.isEmpty else {
            return prompt
        }

        var lines: [String] = ["", "**Existing Artifacts:**"]
        for artifact in artifacts {
            lines.append("- [\(artifact.kind.rawValue)] **\(artifact.title)** (v\(artifact.version), \(artifact.status.rawValue))")
            let trimmedSummary = artifact.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSummary.isEmpty {
                lines.append("  \(trimmedSummary)")
            }
        }

        prompt += lines.joined(separator: "\n")
        return prompt
    }
}
```

### Step 4：运行全套 Feature 6 测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature6-artifact-board \
  -only-testing:agentGuiTests/AgentTeamArtifactTests \
  -only-testing:agentGuiTests/AgentTeamTaskBoardTests \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests \
  -only-testing:agentGuiTests/AgentTeamArtifactBoardCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  -only-testing:agentGuiTests/AgentTeamMissionPromptBuilderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Test Suite"
```

预期：全部 PASS

### Step 5：提交

```bash
git add agentGui/Services/Team/AgentTeamMissionPromptBuilder.swift \
        agentGuiTests/AgentTeamMissionPromptBuilderTests.swift
git commit -m "feat(feature6): add buildPrompt(brief:card:artifacts:) overload for artifact-aware dispatch"
```

---

## 整体验收检查

运行完整的 Feature 6 测试套件：

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature6-artifact-board \
  -only-testing:agentGuiTests/AgentTeamArtifactTests \
  -only-testing:agentGuiTests/AgentTeamTaskBoardTests \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests \
  -only-testing:agentGuiTests/AgentTeamArtifactBoardCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  -only-testing:agentGuiTests/AgentTeamMissionPromptBuilderTests \
  CODE_SIGNING_ALLOWED=NO
```

验收标准清单：

- [ ] `AgentTeamArtifact` 模型完整：8 种 kind，4 种 status，text payload，JSON 可往返
- [ ] `AgentTeamTaskCard.artifactIDs` 支持向后兼容 Codable decode（旧 JSON 中缺 `artifactIDs` 字段不会崩溃）
- [ ] `AgentTeamSessionState.artifactBoardState` 可读写，通过 `artifactBoardJSON` 持久化
- [ ] `AgentTeamArtifactBoardCoordinator` 提交时校验 taskCardID 存在性、防止重复 artifactID
- [ ] `AgentTeamWorkbenchPresentation.InspectorSummary` 包含 `artifactItems`
- [ ] `AgentTeamWorkbenchPresentation.BoardCard` 包含 `artifactCountText`
- [ ] Inspector View 展示 artifact 列表（kind、status、summary）
- [ ] Board card 展示 artifact 数量（有 artifact 时以蓝色高亮）
- [ ] `AgentTeamMissionPromptBuilder.buildPrompt(brief:card:artifacts:)` 仅在 artifacts 非空时输出 `Existing Artifacts` section

---

## 文件变更汇总

| 操作 | 文件 |
|---|---|
| 新建 | `agentGui/Models/AgentTeamArtifact.swift` |
| 修改 | `agentGui/Models/AgentTeamTaskBoard.swift` |
| 修改 | `agentGui/Models/AgentTeamSessionState.swift` |
| 新建 | `agentGui/Services/Team/AgentTeamArtifactBoardCoordinator.swift` |
| 修改 | `agentGui/Services/Team/AgentTeamMissionPromptBuilder.swift` |
| 修改 | `agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift` |
| 修改 | `agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift` |
| 新建 | `agentGuiTests/AgentTeamArtifactTests.swift` |
| 新建 | `agentGuiTests/AgentTeamArtifactBoardCoordinatorTests.swift` |
| 新建/修改 | `agentGuiTests/AgentTeamMissionPromptBuilderTests.swift` |
| 修改 | `agentGuiTests/AgentTeamTaskBoardTests.swift` |
| 修改 | `agentGuiTests/AgentTeamSessionStateTests.swift` |
| 修改 | `agentGuiTests/AgentTeamWorkbenchPresentationTests.swift` |

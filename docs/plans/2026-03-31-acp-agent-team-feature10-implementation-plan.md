# ACP Agent Team Feature 10 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 agentGui Agent Team 落地 Feature 10 的 Review Report / Merge Gate：引入结构化 review report 模型、merge gate 评估器、review 协调器，并把 merge gate 状态投影进 Commit Bar，使系统能在 executionDelivery 模式下对最终产出做语义校验、冲突检测与发布批准，并在全部条件满足前阻止用户触发 Merge。

**Architecture:** 沿用 Features 1–6 已建立的分层模式。新增 `AgentTeamReviewReport` 值类型，作为 `AgentTeamArtifactPayload` 的新 case 嵌入现有 artifact 系统；新增 `AgentTeamMergeGateStatus` + `AgentTeamMergeGateEvaluator` 纯逻辑层，对 `AgentTeamTaskBoardState` 与 `AgentTeamArtifactBoardState` 做组合查询，不新增持久化列；新增 `AgentTeamReviewCoordinator` 服务，负责提交 review artifact 并驱动 task card 状态流转（`.reviewing` → `.done` / `.working` / `.blocked`）；`AgentTeamWorkbenchPresentation` 扩展 `CommitBarState` 投影；View 层 Commit Bar 和 Inspector 根据投影数据更新。整套修改不破坏 Feature 6 已有 artifact 数据；现有 `reviewReport` artifact kind 与 `AgentTeamArtifactPayload.text` 数据均可兼容读取。

**Tech Stack:** Swift 6、SwiftUI for macOS、SwiftData、Swift Testing (`@Test` / `#expect`)，现有 `AgentTeamArtifact`、`AgentTeamArtifactBoardCoordinator`、`AgentTeamTaskBoardState`、`AgentTeamWorkbenchPresentation`。

**Depends On:** [docs/plans/2026-03-30-acp-agent-team-design.md](../plans/2026-03-30-acp-agent-team-design.md), [docs/plans/2026-03-30-acp-agent-team-feature1-implementation-plan.md](../plans/2026-03-30-acp-agent-team-feature1-implementation-plan.md), [docs/plans/2026-03-31-acp-agent-team-feature5-implementation-plan.md](../plans/2026-03-31-acp-agent-team-feature5-implementation-plan.md), [docs/plans/2026-03-31-feature6-typed-artifact-board.md](../plans/2026-03-31-feature6-typed-artifact-board.md)

---

## 0. 执行约束

- 这份计划只覆盖 Feature 10，不提前实现 Feature 7（creative divergence/synthesis）、Feature 8（真实多卡并发调度）、Feature 9（memo feed）。
- review report 必须走现有 artifact 系统，以 `AgentTeamArtifactKind.reviewReport` + 新增 `AgentTeamArtifactPayload.reviewReport(AgentTeamReviewReport)` case 落地，不另起一套独立持久化表。
- `AgentTeamArtifactPayload` 新增 case 必须保持向后兼容：旧数据（JSON 中无 `reviewReport` type）能被解码为 `.text("")` 而非 crash。现有所有 artifact 测试必须继续通过。
- Merge Gate 评估器必须是无副作用纯函数，评估结果不持久化，只在 presentation 层按需计算。不引入 `@Observable` 或 `@MainActor` 要求，便于纯单元测试。
- review 提交后的卡片状态流转规则由 `AgentTeamReviewCoordinator` 独立管理，不把判断散落进 view 或 presenter。
- Commit Bar 上的 Merge 按钮的 enable/disable 判断必须来自 `CommitBarState.isReadyToMerge`，不在 view body 内临时查询 state。
- `AgentTeamSessionState` 不新增 SwiftData 列（不触发 schema migration）。
- 严格按 @test-driven-development 执行：每个任务先写失败测试，再写最小实现，再回归验证。
- 全部 6 个任务完成后，用 @requesting-code-review 做 focused review，重点检查：review report 是否正确嵌入 artifact 系统、merge gate 逻辑是否覆盖所有阻塞场景、冲突处理路径是否有测试、Commit Bar 是否真正在 blocked 时禁用 Merge。

## 1. 当前状态摘要

- [agentGui/Models/AgentTeamArtifact.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamArtifact.swift)：已有 `AgentTeamArtifactKind.reviewReport` case、`AgentTeamArtifactPayload`（仅含 `.text(String)` 一个 case）、`AgentTeamArtifactStatus`（draft/submitted/accepted/rejected）、`AgentTeamArtifactBoardState`。但 `payload` 无结构化 review report，无法携带 decision / issues / conflict pairs。
- [agentGui/Models/AgentTeamTaskBoard.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamTaskBoard.swift)：已有 `.reviewing` 状态，但没有任何 coordinator 真正对 `.reviewing` → `.done` / `.blocked` 做状态流转。
- [agentGui/Services/Team/AgentTeamArtifactBoardCoordinator.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Team/AgentTeamArtifactBoardCoordinator.swift)：管理 artifact 的提交与状态更新，Feature 10 的 `AgentTeamReviewCoordinator` 将复用其 `submitArtifact`。
- [agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift)：已提供 `header`、`roster`、`boardColumns`、`inspector`，但没有 `CommitBarState` 投影，Commit Bar 是纯 UI 占位。
- [agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift)：已有 Commit Bar 区域，但 Merge 按钮不受任何数据驱动，始终可点击。
- 当前测试已覆盖 artifact round-trip、submit、status update，相关文件见 [agentGuiTests/AgentTeamArtifactTests.swift](/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamArtifactTests.swift)、[agentGuiTests/AgentTeamArtifactBoardCoordinatorTests.swift](/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamArtifactBoardCoordinatorTests.swift)。Feature 10 在这套基线上做演进，不能破坏已有测试。

## 2. Feature 10 目标态

完成后系统应满足以下条件：

1. `AgentTeamArtifactPayload` 支持 `.reviewReport(AgentTeamReviewReport)` case；现有含 `.text` payload 的 artifact JSON 可以无损 decode。
2. `AgentTeamReviewReport` 携带：reviewer、reviewedArtifactIDs、kind（semantic/validation/approval）、decision（approved/needsWork/rejected/conflictDetected）、rationale、issues、conflictingArtifactPairs、submittedAt。
3. `AgentTeamMergeGateEvaluator` 能基于当前 task board 和 artifact board 计算出 `AgentTeamMergeGateStatus`，包含 `isReady: Bool` 和 `blocks: [AgentTeamMergeGateBlock]`。
4. `AgentTeamReviewCoordinator` 提交 review report 后，task card 状态根据 decision 流转：approved → done；needsWork → working；rejected/conflictDetected → blocked。
5. `AgentTeamWorkbenchPresentation` 包含 `commitBarState: CommitBarState`，展示 merge 是否就绪、阻塞原因和待 review 数量。
6. Commit Bar 的 Merge 按钮在 `commitBarState.isReadyToMerge == false` 时禁用，并以 chip/list 形式展示每条阻塞原因。
7. Inspector 在选中 task card 时展示对应 review report 的 decision、rationale 和 issues。
8. focused tests 覆盖：review report JSON round-trip、payload backward-compat、merge gate 各阻塞场景、review coordinator 状态流转、workbench presentation commit bar 投影。

## 3. Scope Guardrails

- Feature 10 只实现单张卡的 review 流程；多轮修复（fix loop）在本期只做"needsWork 返工"的状态流转，不做自动触发重执行。
- 不实现 memo feed（Feature 9）；review 的 rationale 以文本形式存在 report 内，不通过 memo 传递。
- 不实现 creative divergence 的 synthesis gate（Feature 7）；Feature 10 的 merge gate 仅适用于 executionDelivery 模式。
- 不在 Commit Bar 上实现 "Ask human" / "Replan" / "Stop" 等其他动作的真实逻辑；Feature 10 只保证 Merge 按钮受 gate 状态控制，其他按钮仍为占位。
- 不替换普通 chat transcript；publish 到 chat 沿用 Feature 1 已有路径。
- `conflictingArtifactPairs` 只记录冲突信息，不实现自动 merge/discard 决策；Feature 10 只把冲突卡片标记为 blocked，由用户或 conductor 在后续 feature 中处理。

## 4. 设计建议

### 4.1 ReviewReport Payload 嵌入策略

在 `AgentTeamArtifactPayload` 中新增 `.reviewReport` case，并在 Codable 实现中把 `type == "reviewReport"` 路由到结构化解码：

```swift
// 新增 case
case reviewReport(AgentTeamReviewReport)

// encode
case let .reviewReport(report):
    try container.encode("reviewReport", forKey: .type)
    try container.encode(report, forKey: .reviewReportData)

// decode
case "reviewReport":
    let report = try container.decode(AgentTeamReviewReport.self, forKey: .reviewReportData)
    self = .reviewReport(report)
```

`textContent` computed property 的 switch 需加 `.reviewReport` 分支，返回 `report.rationale`，以保证现有代码（依赖 `textContent` 做 fallback 显示）不会崩溃。

### 4.2 Merge Gate 评估逻辑

Merge Gate 的四项检查（按优先级排序）：

1. **incomplete cards check**：cards 中有 `.briefed`、`.claimed`、`.working` 状态 → `incompleteCardsExist(count: N)` block。
2. **pending review check**：cards 中有 `.reviewing` 状态且无 `reviewReport` kind artifact with `approved` decision → `pendingReviewsExist(count: N)` block。
3. **blocked cards check**：cards 中有 `.blocked` 状态 → `blockedCardsExist(count: N)` block。
4. **unresolved conflict check**：`artifactBoard` 中有 `reviewReport` payload decision == `.conflictDetected`，且同 taskCardID 下没有后续 `approved` review → `unresolvedConflictsExist(count: N)` block。

`isReady` 仅在 blocks 为空时为 `true`。

### 4.3 Review Coordinator 状态流转

```
card.status == .reviewing → submitReview(decision: .approved)    → card.status = .done
card.status == .reviewing → submitReview(decision: .needsWork)   → card.status = .working, card.blockerSummary = rationale
card.status == .reviewing → submitReview(decision: .rejected)    → card.status = .blocked, card.blockerSummary = rationale
card.status == .reviewing → submitReview(decision: .conflictDetected) → card.status = .blocked, card.blockerSummary = conflictSummary
```

`submitReview` 提交给一张不在 `.reviewing` 状态的 card 应抛出 `AgentTeamReviewCoordinator.Error.unexpectedCardStatus`。

---

## Task 1：AgentTeamReviewReport 核心模型

**Files:**
- Create: `agentGui/Models/AgentTeamReviewReport.swift`
- Modify: `agentGui/Models/AgentTeamArtifact.swift`（扩展 `AgentTeamArtifactPayload`）
- Create: `agentGuiTests/AgentTeamReviewReportTests.swift`

### Step 1：写失败测试

```swift
// agentGuiTests/AgentTeamReviewReportTests.swift
import Foundation
import Testing
@testable import agentGui

struct AgentTeamReviewReportTests {

    @Test
    func reviewReportRoundTripsThroughJSON() throws {
        let report = AgentTeamReviewReport(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            reviewer: .builtIn,
            reviewedArtifactIDs: [UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!],
            kind: .validation,
            decision: .approved,
            rationale: "全部验证通过，无遗漏。",
            issues: [],
            conflictingArtifactPairs: [],
            submittedAt: Date(timeIntervalSince1970: 1_000_000)
        )

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(AgentTeamReviewReport.self, from: data)
        #expect(decoded == report)
    }

    @Test
    func reviewReportIssueRoundTripsThroughJSON() throws {
        let issue = AgentTeamReviewIssue(
            id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
            severity: .critical,
            description: "输出缺少 acceptance criterion #3 的证明。",
            targetArtifactID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        )

        let data = try JSONEncoder().encode(issue)
        let decoded = try JSONDecoder().decode(AgentTeamReviewIssue.self, from: data)
        #expect(decoded == issue)
    }

    @Test
    func payloadReviewReportRoundTripsThroughJSON() throws {
        let report = AgentTeamReviewReport(
            id: UUID(),
            reviewer: .builtIn,
            reviewedArtifactIDs: [],
            kind: .approval,
            decision: .conflictDetected,
            rationale: "PR #1 与 PR #2 修改了同一文件的相同行。",
            issues: [],
            conflictingArtifactPairs: [
                [UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                 UUID(uuidString: "22222222-2222-2222-2222-222222222222")!]
            ],
            submittedAt: Date(timeIntervalSince1970: 2_000_000)
        )
        let payload = AgentTeamArtifactPayload.reviewReport(report)

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(AgentTeamArtifactPayload.self, from: data)
        #expect(decoded == payload)
    }

    @Test
    func payloadLegacyTextDecodesWithoutCrash() throws {
        // 旧 .text payload JSON 在新代码下仍能 decode
        let legacyJSON = """
        {"type":"text","text":"hello world"}
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(AgentTeamArtifactPayload.self, from: legacyJSON)
        #expect(payload == .text("hello world"))
    }

    @Test
    func payloadReviewReportTextContentReturnRationale() {
        let report = AgentTeamReviewReport(
            id: UUID(), reviewer: .builtIn, reviewedArtifactIDs: [],
            kind: .semantic, decision: .needsWork,
            rationale: "缺少错误处理。", issues: [], conflictingArtifactPairs: [],
            submittedAt: Date()
        )
        let payload = AgentTeamArtifactPayload.reviewReport(report)
        #expect(payload.textContent == "缺少错误处理。")
    }
}
```

### Step 2：运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature10-review-gate \
  -only-testing:agentGuiTests/AgentTeamReviewReportTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|error:|AgentTeamReviewReport"
```

预期：编译错误，`AgentTeamReviewReport` 类型未找到。

### Step 3：实现 `AgentTeamReviewReport`

```swift
// agentGui/Models/AgentTeamReviewReport.swift
import Foundation

// MARK: - Review Kind

enum AgentTeamReviewKind: String, Codable, Equatable, Sendable, CaseIterable {
    case semantic    // 语义正确性：输出是否满足 goal 与 acceptance criteria
    case validation  // 技术验证：实现是否正确、无回归
    case approval    // 发布批准：conductor/reviewer 的最终 approve
}

// MARK: - Review Decision

enum AgentTeamReviewDecision: String, Codable, Equatable, Sendable, CaseIterable {
    case approved           // 通过，对应 task card → .done
    case needsWork          // 需返工，对应 task card → .working
    case rejected           // 拒绝（不可修复），对应 task card → .blocked
    case conflictDetected   // 发现冲突，对应 task card → .blocked
}

// MARK: - Review Issue Severity

enum AgentTeamReviewIssueSeverity: String, Codable, Equatable, Sendable, CaseIterable {
    case critical  // 必须修复，否则阻塞 merge
    case warning   // 建议修复，不阻塞 merge
    case info      // 信息性，不影响 merge
}

// MARK: - Review Issue

struct AgentTeamReviewIssue: Codable, Equatable, Sendable {
    let id: UUID
    let severity: AgentTeamReviewIssueSeverity
    let description: String
    let targetArtifactID: UUID?  // 可选，指向出现问题的 artifact
}

// MARK: - Review Report

struct AgentTeamReviewReport: Codable, Equatable, Sendable {
    let id: UUID
    let reviewer: ExecutionProviderReference
    let reviewedArtifactIDs: [UUID]
    let kind: AgentTeamReviewKind
    let decision: AgentTeamReviewDecision
    let rationale: String
    let issues: [AgentTeamReviewIssue]
    /// 每个内层数组为一对冲突的 artifact ID，如 [[a, b], [c, d]]
    let conflictingArtifactPairs: [[UUID]]
    let submittedAt: Date
}
```

### Step 4：扩展 `AgentTeamArtifactPayload`

在 `agentGui/Models/AgentTeamArtifact.swift` 中找到 `AgentTeamArtifactPayload`，按以下方式修改：

```swift
// 原有文件中的 AgentTeamArtifactPayload:
enum AgentTeamArtifactPayload: Codable, Equatable, Sendable {
    case text(String)
    case reviewReport(AgentTeamReviewReport)    // 新增

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case reviewReportData                   // 新增 key
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type_ = try container.decodeIfPresent(String.self, forKey: .type) ?? "text"
        switch type_ {
        case "text":
            let content = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            self = .text(content)
        case "reviewReport":                    // 新增分支
            let report = try container.decode(AgentTeamReviewReport.self, forKey: .reviewReportData)
            self = .reviewReport(report)
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
        case let .reviewReport(report):         // 新增分支
            try container.encode("reviewReport", forKey: .type)
            try container.encode(report, forKey: .reviewReportData)
        }
    }

    var textContent: String {
        switch self {
        case let .text(content): return content
        case let .reviewReport(report): return report.rationale   // 新增分支
        }
    }
}
```

### Step 5：运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature10-review-gate \
  -only-testing:agentGuiTests/AgentTeamReviewReportTests \
  -only-testing:agentGuiTests/AgentTeamArtifactTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：`AgentTeamReviewReportTests` 和现有 `AgentTeamArtifactTests` 全部 PASS。

### Step 6：Commit

```bash
git add agentGui/Models/AgentTeamReviewReport.swift \
        agentGui/Models/AgentTeamArtifact.swift \
        agentGuiTests/AgentTeamReviewReportTests.swift
git commit -m "feat(team): add AgentTeamReviewReport model and extend ArtifactPayload"
```

---

## Task 2：AgentTeamMergeGate 评估器

**Files:**
- Create: `agentGui/Models/AgentTeamMergeGate.swift`
- Create: `agentGuiTests/AgentTeamMergeGateEvaluatorTests.swift`

### Step 1：写失败测试

```swift
// agentGuiTests/AgentTeamMergeGateEvaluatorTests.swift
import Foundation
import Testing
@testable import agentGui

struct AgentTeamMergeGateEvaluatorTests {

    private func makeCard(
        id: UUID = UUID(),
        status: AgentTeamTaskStatus,
        artifactIDs: [UUID] = []
    ) -> AgentTeamTaskCard {
        AgentTeamTaskCard(
            id: id, title: "T", goal: "G", status: status,
            artifactIDs: artifactIDs, lastUpdatedAt: Date()
        )
    }

    private func makeReviewArtifact(
        taskCardID: UUID,
        decision: AgentTeamReviewDecision
    ) -> AgentTeamArtifact {
        let report = AgentTeamReviewReport(
            id: UUID(), reviewer: .builtIn, reviewedArtifactIDs: [],
            kind: .validation, decision: decision,
            rationale: "test", issues: [], conflictingArtifactPairs: [],
            submittedAt: Date()
        )
        return AgentTeamArtifact(
            id: UUID(), kind: .reviewReport, title: "Review",
            producer: .builtIn, taskCardID: taskCardID, version: 1,
            summary: "review", payload: .reviewReport(report), status: .submitted
        )
    }

    @Test
    func readyWhenAllCardsDoneAndReviewed() {
        let cardID = UUID()
        let card = makeCard(id: cardID, status: .done)
        let reviewArtifact = makeReviewArtifact(taskCardID: cardID, decision: .approved)
        let taskBoard = AgentTeamTaskBoardState(cards: [card], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [reviewArtifact])

        let status = AgentTeamMergeGateEvaluator().evaluate(
            taskBoard: taskBoard, artifactBoard: artifactBoard
        )
        #expect(status.isReady == true)
        #expect(status.blocks.isEmpty)
    }

    @Test
    func blockedWhenIncompleteCardExists() {
        let card = makeCard(status: .working)
        let taskBoard = AgentTeamTaskBoardState(cards: [card], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [])

        let status = AgentTeamMergeGateEvaluator().evaluate(
            taskBoard: taskBoard, artifactBoard: artifactBoard
        )
        #expect(status.isReady == false)
        #expect(status.blocks.contains { block in
            if case .incompleteCardsExist = block { return true }
            return false
        })
    }

    @Test
    func blockedWhenReviewingCardHasNoApprovedReview() {
        let cardID = UUID()
        let card = makeCard(id: cardID, status: .reviewing)
        let taskBoard = AgentTeamTaskBoardState(cards: [card], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [])

        let status = AgentTeamMergeGateEvaluator().evaluate(
            taskBoard: taskBoard, artifactBoard: artifactBoard
        )
        #expect(status.isReady == false)
        #expect(status.blocks.contains { block in
            if case .pendingReviewsExist = block { return true }
            return false
        })
    }

    @Test
    func blockedWhenBlockedCardExists() {
        let card = makeCard(status: .blocked)
        let taskBoard = AgentTeamTaskBoardState(cards: [card], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [])

        let status = AgentTeamMergeGateEvaluator().evaluate(
            taskBoard: taskBoard, artifactBoard: artifactBoard
        )
        #expect(status.isReady == false)
        #expect(status.blocks.contains { block in
            if case .blockedCardsExist = block { return true }
            return false
        })
    }

    @Test
    func blockedWhenConflictDetectedWithNoSubsequentApproval() {
        let cardID = UUID()
        let card = makeCard(id: cardID, status: .blocked)
        let conflictReview = makeReviewArtifact(taskCardID: cardID, decision: .conflictDetected)
        let taskBoard = AgentTeamTaskBoardState(cards: [card], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [conflictReview])

        let status = AgentTeamMergeGateEvaluator().evaluate(
            taskBoard: taskBoard, artifactBoard: artifactBoard
        )
        #expect(status.isReady == false)
        #expect(status.blocks.contains { block in
            if case .unresolvedConflictsExist = block { return true }
            return false
        })
    }

    @Test
    func resolvedConflictNotCountedAsBlock() {
        let cardID = UUID()
        let card = makeCard(id: cardID, status: .done)
        let conflictReview = makeReviewArtifact(taskCardID: cardID, decision: .conflictDetected)
        let approvalReview = makeReviewArtifact(taskCardID: cardID, decision: .approved)
        let taskBoard = AgentTeamTaskBoardState(cards: [card], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [conflictReview, approvalReview])

        let status = AgentTeamMergeGateEvaluator().evaluate(
            taskBoard: taskBoard, artifactBoard: artifactBoard
        )
        // conflict resolved by subsequent approval → no unresolvedConflictsExist block
        #expect(!status.blocks.contains { block in
            if case .unresolvedConflictsExist = block { return true }
            return false
        })
    }

    @Test
    func emptyBoardIsReady() {
        let taskBoard = AgentTeamTaskBoardState(cards: [], claims: [])
        let artifactBoard = AgentTeamArtifactBoardState(artifacts: [])
        let status = AgentTeamMergeGateEvaluator().evaluate(
            taskBoard: taskBoard, artifactBoard: artifactBoard
        )
        #expect(status.isReady == true)
    }
}
```

### Step 2：运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature10-review-gate \
  -only-testing:agentGuiTests/AgentTeamMergeGateEvaluatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|error:|AgentTeamMergeGate"
```

预期：编译错误，`AgentTeamMergeGateEvaluator` 未找到。

### Step 3：实现 `AgentTeamMergeGate`

```swift
// agentGui/Models/AgentTeamMergeGate.swift
import Foundation

// MARK: - Block Reason

enum AgentTeamMergeGateBlock: Equatable, Sendable {
    case incompleteCardsExist(count: Int)        // 有卡未进入 reviewing/done/blocked
    case pendingReviewsExist(count: Int)         // 有 reviewing 卡尚无 approved review
    case blockedCardsExist(count: Int)           // 有 blocked 卡
    case unresolvedConflictsExist(count: Int)    // 有 conflictDetected review 未被后续 approved 覆盖

    var localizedDescription: String {
        switch self {
        case let .incompleteCardsExist(n):
            return "\(n) 张任务卡尚未完成"
        case let .pendingReviewsExist(n):
            return "\(n) 张卡等待 review 批准"
        case let .blockedCardsExist(n):
            return "\(n) 张卡处于阻塞状态"
        case let .unresolvedConflictsExist(n):
            return "\(n) 处冲突尚未解决"
        }
    }
}

// MARK: - Gate Status

struct AgentTeamMergeGateStatus: Equatable, Sendable {
    let isReady: Bool
    let blocks: [AgentTeamMergeGateBlock]

    static let ready = AgentTeamMergeGateStatus(isReady: true, blocks: [])
}

// MARK: - Evaluator

struct AgentTeamMergeGateEvaluator {

    func evaluate(
        taskBoard: AgentTeamTaskBoardState,
        artifactBoard: AgentTeamArtifactBoardState
    ) -> AgentTeamMergeGateStatus {
        var blocks: [AgentTeamMergeGateBlock] = []

        // 1. incomplete cards（briefed / claimed / working）
        let incompleteStatuses: Set<AgentTeamTaskStatus> = [.briefed, .claimed, .working]
        let incompleteCount = taskBoard.cards.filter { incompleteStatuses.contains($0.status) }.count
        if incompleteCount > 0 {
            blocks.append(.incompleteCardsExist(count: incompleteCount))
        }

        // 2. reviewing cards without approved review
        let reviewingCards = taskBoard.cards.filter { $0.status == .reviewing }
        let pendingCount = reviewingCards.filter { card in
            !artifactBoard.reviewReports(for: card.id).contains { $0.decision == .approved }
        }.count
        if pendingCount > 0 {
            blocks.append(.pendingReviewsExist(count: pendingCount))
        }

        // 3. blocked cards
        let blockedCount = taskBoard.cards.filter { $0.status == .blocked }.count
        if blockedCount > 0 {
            blocks.append(.blockedCardsExist(count: blockedCount))
        }

        // 4. unresolved conflicts: conflictDetected review exists, but no subsequent approved review for same card
        let unresolvedConflictCount = taskBoard.cards.filter { card in
            let reports = artifactBoard.reviewReports(for: card.id)
            let hasConflict = reports.contains { $0.decision == .conflictDetected }
            let hasResolution = reports.contains { $0.decision == .approved }
            return hasConflict && !hasResolution
        }.count
        if unresolvedConflictCount > 0 {
            blocks.append(.unresolvedConflictsExist(count: unresolvedConflictCount))
        }

        return AgentTeamMergeGateStatus(isReady: blocks.isEmpty, blocks: blocks)
    }
}
```

在 `AgentTeamArtifactBoardState` 中新增 `reviewReports(for:)` 辅助方法。直接在 `agentGui/Models/AgentTeamArtifact.swift` 末尾扩展：

```swift
// 在 AgentTeamArtifactBoardState 的 extension 中新增：
extension AgentTeamArtifactBoardState {
    /// 返回指定 task card 下、kind 为 reviewReport 且 payload 为 .reviewReport 的所有报告。
    func reviewReports(for taskCardID: UUID) -> [AgentTeamReviewReport] {
        artifacts(for: taskCardID)
            .filter { $0.kind == .reviewReport }
            .compactMap {
                if case let .reviewReport(report) = $0.payload { return report }
                return nil
            }
    }
}
```

### Step 4：运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature10-review-gate \
  -only-testing:agentGuiTests/AgentTeamMergeGateEvaluatorTests \
  -only-testing:agentGuiTests/AgentTeamReviewReportTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：全部 PASS。

### Step 5：Commit

```bash
git add agentGui/Models/AgentTeamMergeGate.swift \
        agentGui/Models/AgentTeamArtifact.swift \
        agentGuiTests/AgentTeamMergeGateEvaluatorTests.swift
git commit -m "feat(team): add AgentTeamMergeGate model and evaluator"
```

---

## Task 3：AgentTeamReviewCoordinator 服务

**Files:**
- Create: `agentGui/Services/Team/AgentTeamReviewCoordinator.swift`
- Create: `agentGuiTests/AgentTeamReviewCoordinatorTests.swift`

### Step 1：写失败测试

```swift
// agentGuiTests/AgentTeamReviewCoordinatorTests.swift
import Foundation
import Testing
@testable import agentGui

struct AgentTeamReviewCoordinatorTests {

    private func makeReviewingCard(id: UUID = UUID()) -> AgentTeamTaskCard {
        AgentTeamTaskCard(
            id: id, title: "T", goal: "G", status: .reviewing, lastUpdatedAt: Date()
        )
    }

    private func makeReport(decision: AgentTeamReviewDecision, cardID: UUID) -> AgentTeamReviewReport {
        AgentTeamReviewReport(
            id: UUID(), reviewer: .builtIn, reviewedArtifactIDs: [],
            kind: .validation, decision: decision,
            rationale: "test rationale", issues: [], conflictingArtifactPairs: [],
            submittedAt: Date()
        )
    }

    @Test
    func approvedReviewTransitionsCardToDone() throws {
        let cardID = UUID()
        var taskBoard = AgentTeamTaskBoardState(cards: [makeReviewingCard(id: cardID)], claims: [])
        var artifactBoard = AgentTeamArtifactBoardState(artifacts: [])
        let report = makeReport(decision: .approved, cardID: cardID)

        let (nextArtifactBoard, nextTaskBoard) = try AgentTeamReviewCoordinator().submitReview(
            report, forTaskCardID: cardID, into: artifactBoard, linking: &taskBoard
        )

        let card = nextTaskBoard.card(id: cardID)
        #expect(card?.status == .done)
        #expect(card?.blockerSummary == nil)
        #expect(nextArtifactBoard.reviewReports(for: cardID).count == 1)
    }

    @Test
    func needsWorkReviewTransitionsCardToWorking() throws {
        let cardID = UUID()
        var taskBoard = AgentTeamTaskBoardState(cards: [makeReviewingCard(id: cardID)], claims: [])
        var artifactBoard = AgentTeamArtifactBoardState(artifacts: [])
        let report = makeReport(decision: .needsWork, cardID: cardID)

        let (_, nextTaskBoard) = try AgentTeamReviewCoordinator().submitReview(
            report, forTaskCardID: cardID, into: artifactBoard, linking: &taskBoard
        )

        let card = nextTaskBoard.card(id: cardID)
        #expect(card?.status == .working)
        #expect(card?.blockerSummary == "test rationale")
    }

    @Test
    func rejectedReviewTransitionsCardToBlocked() throws {
        let cardID = UUID()
        var taskBoard = AgentTeamTaskBoardState(cards: [makeReviewingCard(id: cardID)], claims: [])
        var artifactBoard = AgentTeamArtifactBoardState(artifacts: [])
        let report = makeReport(decision: .rejected, cardID: cardID)

        let (_, nextTaskBoard) = try AgentTeamReviewCoordinator().submitReview(
            report, forTaskCardID: cardID, into: artifactBoard, linking: &taskBoard
        )

        #expect(nextTaskBoard.card(id: cardID)?.status == .blocked)
    }

    @Test
    func conflictDetectedTransitionsCardToBlocked() throws {
        let cardID = UUID()
        var taskBoard = AgentTeamTaskBoardState(cards: [makeReviewingCard(id: cardID)], claims: [])
        var artifactBoard = AgentTeamArtifactBoardState(artifacts: [])
        let report = makeReport(decision: .conflictDetected, cardID: cardID)

        let (_, nextTaskBoard) = try AgentTeamReviewCoordinator().submitReview(
            report, forTaskCardID: cardID, into: artifactBoard, linking: &taskBoard
        )

        #expect(nextTaskBoard.card(id: cardID)?.status == .blocked)
    }

    @Test
    func submitToNonReviewingCardThrows() throws {
        let cardID = UUID()
        let card = AgentTeamTaskCard(
            id: cardID, title: "T", goal: "G", status: .working, lastUpdatedAt: Date()
        )
        var taskBoard = AgentTeamTaskBoardState(cards: [card], claims: [])
        var artifactBoard = AgentTeamArtifactBoardState(artifacts: [])
        let report = makeReport(decision: .approved, cardID: cardID)

        #expect(throws: AgentTeamReviewCoordinator.Error.self) {
            _ = try AgentTeamReviewCoordinator().submitReview(
                report, forTaskCardID: cardID, into: artifactBoard, linking: &taskBoard
            )
        }
    }

    @Test
    func submitToMissingCardThrows() throws {
        let missingID = UUID()
        var taskBoard = AgentTeamTaskBoardState(cards: [], claims: [])
        var artifactBoard = AgentTeamArtifactBoardState(artifacts: [])
        let report = makeReport(decision: .approved, cardID: missingID)

        #expect(throws: AgentTeamReviewCoordinator.Error.self) {
            _ = try AgentTeamReviewCoordinator().submitReview(
                report, forTaskCardID: missingID, into: artifactBoard, linking: &taskBoard
            )
        }
    }
}
```

### Step 2：运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature10-review-gate \
  -only-testing:agentGuiTests/AgentTeamReviewCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|error:|AgentTeamReviewCoordinator"
```

预期：编译错误，`AgentTeamReviewCoordinator` 未找到。

### Step 3：实现 `AgentTeamReviewCoordinator`

```swift
// agentGui/Services/Team/AgentTeamReviewCoordinator.swift
import Foundation

struct AgentTeamReviewCoordinator {

    // MARK: - Error

    enum Error: LocalizedError, Equatable {
        case taskCardNotFound(UUID)
        case unexpectedCardStatus(AgentTeamTaskStatus)

        var errorDescription: String? {
            switch self {
            case let .taskCardNotFound(id):
                return "未找到 task card：\(id.uuidString.lowercased())"
            case let .unexpectedCardStatus(status):
                return "task card 当前状态为 \(status.rawValue)，必须处于 reviewing 才能提交 review。"
            }
        }
    }

    private let artifactCoordinator = AgentTeamArtifactBoardCoordinator()

    // MARK: - Submit Review

    /// 提交 review report artifact，并根据 decision 驱动 task card 状态流转。
    /// 返回 (更新后的 artifactBoard, 更新后的 taskBoard)。
    func submitReview(
        _ report: AgentTeamReviewReport,
        forTaskCardID cardID: UUID,
        into artifactBoard: AgentTeamArtifactBoardState,
        linking taskBoard: inout AgentTeamTaskBoardState
    ) throws -> (AgentTeamArtifactBoardState, AgentTeamTaskBoardState) {
        // 1. 验证 card 存在且状态为 .reviewing
        guard let card = taskBoard.card(id: cardID) else {
            throw Error.taskCardNotFound(cardID)
        }
        guard card.status == .reviewing else {
            throw Error.unexpectedCardStatus(card.status)
        }

        // 2. 构造 reviewReport artifact
        let artifact = AgentTeamArtifact(
            id: report.id,
            kind: .reviewReport,
            title: "Review（\(report.kind.rawValue)）",
            producer: report.reviewer,
            taskCardID: cardID,
            version: 1,
            summary: report.rationale,
            payload: .reviewReport(report),
            status: .submitted
        )

        // 3. 提交 artifact
        var (nextArtifactBoard, nextTaskBoard) = try artifactCoordinator.submitArtifact(
            artifact, into: artifactBoard, linking: &taskBoard
        )

        // 4. 根据 decision 流转 task card 状态
        guard let idx = nextTaskBoard.cards.firstIndex(where: { $0.id == cardID }) else {
            throw Error.taskCardNotFound(cardID)
        }
        switch report.decision {
        case .approved:
            nextTaskBoard.cards[idx].status = .done
            nextTaskBoard.cards[idx].blockerSummary = nil
        case .needsWork:
            nextTaskBoard.cards[idx].status = .working
            nextTaskBoard.cards[idx].blockerSummary = report.rationale
        case .rejected:
            nextTaskBoard.cards[idx].status = .blocked
            nextTaskBoard.cards[idx].blockerSummary = report.rationale
        case .conflictDetected:
            let conflictSummary = report.conflictingArtifactPairs.isEmpty
                ? report.rationale
                : "冲突检测：\(report.conflictingArtifactPairs.count) 处冲突。\(report.rationale)"
            nextTaskBoard.cards[idx].status = .blocked
            nextTaskBoard.cards[idx].blockerSummary = conflictSummary
        }
        nextTaskBoard.cards[idx].lastUpdatedAt = report.submittedAt

        taskBoard = nextTaskBoard
        return (nextArtifactBoard, nextTaskBoard)
    }
}
```

### Step 4：运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature10-review-gate \
  -only-testing:agentGuiTests/AgentTeamReviewCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamMergeGateEvaluatorTests \
  -only-testing:agentGuiTests/AgentTeamReviewReportTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：全部 PASS。

### Step 5：Commit

```bash
git add agentGui/Services/Team/AgentTeamReviewCoordinator.swift \
        agentGuiTests/AgentTeamReviewCoordinatorTests.swift
git commit -m "feat(team): add AgentTeamReviewCoordinator with decision-driven card transitions"
```

---

## Task 4：Presentation 层 CommitBarState 投影

**Files:**
- Modify: `agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift`
- Modify: `agentGuiTests/AgentTeamWorkbenchPresentationTests.swift`

### Step 1：写失败测试

在 [agentGuiTests/AgentTeamWorkbenchPresentationTests.swift](/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamWorkbenchPresentationTests.swift) 末尾追加：

```swift
// 新增测试 extension
extension AgentTeamWorkbenchPresentationTests {

    @Test
    func commitBarReadyWhenAllCardsDoneWithApprovedReview() throws {
        // 构造 session + state：一张 done card + approved reviewReport artifact
        let session = try makeTeamSession()
        let state = AgentTeamSessionState(session: session)
        let cardID = UUID()
        let card = AgentTeamTaskCard(
            id: cardID, title: "T", goal: "G", status: .done, lastUpdatedAt: Date()
        )
        var taskBoard = AgentTeamTaskBoardState(cards: [card], claims: [])
        let report = AgentTeamReviewReport(
            id: UUID(), reviewer: .builtIn, reviewedArtifactIDs: [],
            kind: .approval, decision: .approved,
            rationale: "all good", issues: [], conflictingArtifactPairs: [],
            submittedAt: Date()
        )
        let reviewArtifact = AgentTeamArtifact(
            id: UUID(), kind: .reviewReport, title: "Review",
            producer: .builtIn, taskCardID: cardID, version: 1,
            summary: "all good", payload: .reviewReport(report), status: .submitted
        )
        var artifactBoard = AgentTeamArtifactBoardState(artifacts: [reviewArtifact])
        state.taskBoardState = taskBoard
        state.artifactBoardState = artifactBoard

        let presentation = AgentTeamWorkbenchPresentation.make(
            session: session, state: state, modelContext: nil
        )
        #expect(presentation.commitBarState.isReadyToMerge == true)
        #expect(presentation.commitBarState.mergeBlockDescriptions.isEmpty)
    }

    @Test
    func commitBarBlockedWhenWorkingCardExists() throws {
        let session = try makeTeamSession()
        let state = AgentTeamSessionState(session: session)
        let card = AgentTeamTaskCard(
            id: UUID(), title: "T", goal: "G", status: .working, lastUpdatedAt: Date()
        )
        state.taskBoardState = AgentTeamTaskBoardState(cards: [card], claims: [])
        state.artifactBoardState = AgentTeamArtifactBoardState(artifacts: [])

        let presentation = AgentTeamWorkbenchPresentation.make(
            session: session, state: state, modelContext: nil
        )
        #expect(presentation.commitBarState.isReadyToMerge == false)
        #expect(!presentation.commitBarState.mergeBlockDescriptions.isEmpty)
    }

    @Test
    func commitBarShowsPendingReviewCount() throws {
        let session = try makeTeamSession()
        let state = AgentTeamSessionState(session: session)
        let card1 = AgentTeamTaskCard(id: UUID(), title: "T1", goal: "G", status: .reviewing, lastUpdatedAt: Date())
        let card2 = AgentTeamTaskCard(id: UUID(), title: "T2", goal: "G", status: .reviewing, lastUpdatedAt: Date())
        state.taskBoardState = AgentTeamTaskBoardState(cards: [card1, card2], claims: [])
        state.artifactBoardState = AgentTeamArtifactBoardState(artifacts: [])

        let presentation = AgentTeamWorkbenchPresentation.make(
            session: session, state: state, modelContext: nil
        )
        #expect(presentation.commitBarState.pendingReviewCount == 2)
    }
}
```

### Step 2：运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature10-review-gate \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|error:|commitBarState"
```

预期：编译错误，`commitBarState` 属性不存在。

### Step 3：在 `AgentTeamWorkbenchPresentation` 中新增 `CommitBarState`

在 `AgentTeamWorkbenchPresentation.swift` 的结构体内新增：

```swift
struct CommitBarState: Equatable {
    let isReadyToMerge: Bool
    let mergeBlockDescriptions: [String]
    let pendingReviewCount: Int
    let mergeButtonLabel: String
}
```

在顶层结构体中新增属性：

```swift
let commitBarState: CommitBarState
```

在 `make(session:state:modelContext:)` 方法内，在计算 `inspector` 之后添加：

```swift
let commitBarState = makeCommitBarState(
    taskBoard: boardState, artifactBoard: artifactBoard
)
```

在 `return Self(...)` 中补充 `commitBarState: commitBarState`。

新增私有方法：

```swift
private static func makeCommitBarState(
    taskBoard: AgentTeamTaskBoardState?,
    artifactBoard: AgentTeamArtifactBoardState?
) -> CommitBarState {
    guard let taskBoard else {
        return CommitBarState(
            isReadyToMerge: false,
            mergeBlockDescriptions: ["Task board 尚未初始化"],
            pendingReviewCount: 0,
            mergeButtonLabel: "合并输出"
        )
    }
    let resolvedArtifactBoard = artifactBoard ?? AgentTeamArtifactBoardState(artifacts: [])
    let gateStatus = AgentTeamMergeGateEvaluator().evaluate(
        taskBoard: taskBoard,
        artifactBoard: resolvedArtifactBoard
    )
    let pendingReviewCount = taskBoard.cards.filter { $0.status == .reviewing }.count
    return CommitBarState(
        isReadyToMerge: gateStatus.isReady,
        mergeBlockDescriptions: gateStatus.blocks.map { $0.localizedDescription },
        pendingReviewCount: pendingReviewCount,
        mergeButtonLabel: gateStatus.isReady ? "检查通过，合并输出" : "合并输出"
    )
}
```

### Step 4：运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature10-review-gate \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：全部 PASS（包含原有测试）。

### Step 5：Commit

```bash
git add agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift \
        agentGuiTests/AgentTeamWorkbenchPresentationTests.swift
git commit -m "feat(team): add CommitBarState to WorkbenchPresentation with merge gate projection"
```

---

## Task 5：`AgentTeamSessionState` 便利访问器

**Files:**
- Modify: `agentGui/Models/AgentTeamSessionState.swift`
- Modify: `agentGuiTests/AgentTeamSessionStateTests.swift`

### Step 1：写失败测试

在 [agentGuiTests/AgentTeamSessionStateTests.swift](/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentTeamSessionStateTests.swift) 末尾追加：

```swift
extension AgentTeamSessionStateTests {

    @Test
    func artifactBoardStateRoundTripsThroughSessionState() throws {
        let container = try ModelContainer(
            for: Session.self, AgentTeamSessionState.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext
        let session = Session(title: "Test")
        ctx.insert(session)
        let state = AgentTeamSessionState(session: session)
        ctx.insert(state)

        let cardID = UUID()
        let report = AgentTeamReviewReport(
            id: UUID(), reviewer: .builtIn, reviewedArtifactIDs: [],
            kind: .approval, decision: .approved,
            rationale: "all good", issues: [], conflictingArtifactPairs: [],
            submittedAt: Date(timeIntervalSince1970: 3_000_000)
        )
        let artifact = AgentTeamArtifact(
            id: UUID(), kind: .reviewReport, title: "R",
            producer: .builtIn, taskCardID: cardID, version: 1,
            summary: "ok", payload: .reviewReport(report), status: .submitted
        )
        state.artifactBoardState = AgentTeamArtifactBoardState(artifacts: [artifact])

        let reloaded = state.artifactBoardState
        #expect(reloaded?.artifacts.count == 1)
        let reloadedReports = reloaded?.reviewReports(for: cardID)
        #expect(reloadedReports?.count == 1)
        #expect(reloadedReports?.first?.decision == .approved)
    }
}
```

### Step 2：运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature10-review-gate \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|error:|reviewReports"
```

预期：编译错误，`reviewReports(for:)` 未找到（待 Task 2 Step 3 可能已添加）。若 Task 2 已完成则直接进入 Step 3。

### Step 3：检查 `AgentTeamSessionState.artifactBoardState` setter 支持

打开 [agentGui/Models/AgentTeamSessionState.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentTeamSessionState.swift)，确认 `artifactBoardState` 已有 getter/setter。若 setter 缺失，按以下方式补充：

```swift
var artifactBoardState: AgentTeamArtifactBoardState? {
    get {
        guard let data = artifactBoardJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentTeamArtifactBoardState.self, from: data)
    }
    set {
        if let value = newValue,
           let data = try? JSONEncoder().encode(value),
           let str = String(data: data, encoding: .utf8) {
            artifactBoardJSON = str
        } else {
            artifactBoardJSON = ""
        }
    }
}
```

### Step 4：运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature10-review-gate \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：全部 PASS。

### Step 5：Commit

```bash
git add agentGui/Models/AgentTeamSessionState.swift \
        agentGuiTests/AgentTeamSessionStateTests.swift
git commit -m "feat(team): ensure artifactBoardState setter supports reviewReport artifacts"
```

---

## Task 6：UI 更新 — Commit Bar + Inspector Review 展示

**Files:**
- Modify: `agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift`

> **注意：** 本任务不写单元测试（UI 变化属于视觉层），但应做手动 smoke 验证，并检查 accessibility identifier 是否保持不变。

### Step 1：更新 Commit Bar

在 `AgentTeamWorkbenchPanelViews.swift` 中找到 Commit Bar 区域（通常含 Merge / Stop 等按钮）。

1. 找到 Merge 按钮的 `Button` 声明，将其 `disabled` 条件绑定到 `presentation.commitBarState.isReadyToMerge`：

```swift
Button(presentation.commitBarState.mergeButtonLabel) {
    onMerge?()
}
.disabled(!presentation.commitBarState.isReadyToMerge)
.buttonStyle(.borderedProminent)
.accessibilityIdentifier("teamCommitBar.mergeButton")
```

2. 在 Merge 按钮下方，根据 `mergeBlockDescriptions` 显示阻塞原因 chips：

```swift
if !presentation.commitBarState.mergeBlockDescriptions.isEmpty {
    VStack(alignment: .leading, spacing: 4) {
        ForEach(presentation.commitBarState.mergeBlockDescriptions, id: \.self) { reason in
            Label(reason, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
    .padding(.top, 4)
}
```

3. 若有 `pendingReviewCount > 0`，在 Commit Bar 显示有多少张卡等待 review：

```swift
if presentation.commitBarState.pendingReviewCount > 0 {
    Text("\(presentation.commitBarState.pendingReviewCount) 张卡等待 review")
        .font(.caption2)
        .foregroundStyle(.secondary)
}
```

### Step 2：更新 Inspector — 展示 review report

在 Inspector 区域，找到 `artifactItems` 列表的渲染部分。在每个 artifact item 下，若 kind 为 `reviewReport`，额外展示 decision 标签和 rationale：

```swift
ForEach(presentation.inspector.artifactItems) { item in
    VStack(alignment: .leading, spacing: 2) {
        HStack {
            Image(systemName: artifactIcon(for: item.kindText))
                .foregroundStyle(.secondary)
            Text(item.title)
                .font(.subheadline)
            Spacer()
            Text(item.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text(item.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        // review badge：kindText 为 "review_report" 时显示
        if item.kindText == "reviewReport" {
            Text("📋 \(item.producerSummary)")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }
    .padding(.vertical, 2)
}
```

### Step 3：手动 Smoke 检查

在 Xcode 中运行 App，进入 Agent Team Workbench：

1. 创建一个 team session，确认 Commit Bar 的 Merge 按钮初始**禁用**（无 done 卡片）。
2. 在 code / REPL 中调用 `AgentTeamReviewCoordinator().submitReview(...)` 把一张卡 → `.done`，确认 Merge 按钮**仍禁用**（未添加 approved review artifact）。
3. 同时通过 `AgentTeamArtifactBoardCoordinator` 提交一个 `approved` review artifact，确认 Merge 按钮**启用**。
4. 故意遗留一张 `.blocked` 卡，确认 Merge 按钮**再次禁用**，Commit Bar 显示对应阻塞原因。

### Step 4：Commit

```bash
git add agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift
git commit -m "feat(team): wire CommitBarState to UI, gate Merge button on review completion"
```

---

## Final：完整回归测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature10-review-gate \
  -only-testing:agentGuiTests/AgentTeamReviewReportTests \
  -only-testing:agentGuiTests/AgentTeamMergeGateEvaluatorTests \
  -only-testing:agentGuiTests/AgentTeamReviewCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamArtifactTests \
  -only-testing:agentGuiTests/AgentTeamArtifactBoardCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests \
  -only-testing:agentGuiTests/AgentTeamTaskBoardTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|error:"
```

预期：TEST SUCCEEDED，全部 8 个测试 target 通过，无回归。

---

## Tagging

```bash
git tag feature/10-review-merge-gate
```

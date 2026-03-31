import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct AgentTeamSessionStateTests {
    @Test
    func teamStateBindsToAgentTeamSession() throws {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let session = Session(title: "修复 ACP", kind: .agentTeam)
        context.insert(session)

        let state = AgentTeamSessionState(
            session: session,
            sourceSessionID: "chat-1",
            sourceSessionTitle: "修复 ACP"
        )
        context.insert(state)

        #expect(state.session === session)
        #expect(state.status == .created)
        #expect(state.mode == .executionDelivery)
        #expect(state.sourceSessionID == "chat-1")
        #expect(state.sourceSessionTitle == "修复 ACP")
    }

    @Test
    func updatingStatusRefreshesUpdatedAt() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let originalUpdatedAt = Date(timeIntervalSince1970: 2)
        let state = AgentTeamSessionState(
            session: session,
            status: .created,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: originalUpdatedAt
        )

        state.status = AgentTeamRunStatus.failed

        #expect(state.status == AgentTeamRunStatus.failed)
        #expect(state.updatedAt > originalUpdatedAt)
    }

    @Test
    func missionBriefRoundTripsThroughPersistenceSlot() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session)
        let brief = AgentTeamMissionBrief(
            objective: "为 ACP team 汇总修复方案",
            constraints: ["仅修改 Swift 文件", "保持 focused tests"],
            acceptanceCriteria: ["Mission Header 回显 brief", "team session 持久化 brief"],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "medium"),
            initialContextSummary: "当前聊天包含失败测试与日志。"
        )

        state.missionBrief = brief

        #expect(state.briefJSON.isEmpty == false)
        #expect(state.missionBrief == brief)
    }

    @Test
    func updatingMissionBriefRefreshesUpdatedAt() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let originalUpdatedAt = Date(timeIntervalSince1970: 2)
        let state = AgentTeamSessionState(
            session: session,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: originalUpdatedAt
        )

        state.missionBrief = AgentTeamMissionBrief(
            objective: "统一 ACP team brief",
            constraints: ["不改 public API"],
            acceptanceCriteria: ["Focused tests 通过"],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "medium"),
            initialContextSummary: "当前聊天包含失败测试与日志。"
        )

        #expect(state.updatedAt > originalUpdatedAt)
    }

    @Test
    func claimBoardRoundTripsThroughPersistenceSlot() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session)
        let claim = AgentTeamClaim(
            id: UUID(),
            providerReference: .builtIn,
            taskCardID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            confidence: 0.88,
            rationaleSummary: "负责主执行路径",
            requiredCapabilities: ["swift"],
            expectedArtifacts: ["patchProposal"],
            estimatedCostSummary: "low",
            status: .pending,
            submittedAt: Date(timeIntervalSince1970: 10)
        )
        let board = AgentTeamClaimBoardState(
            cards: [
                AgentTeamClaimCard(
                    id: claim.taskCardID,
                    title: "修复主路径",
                    goal: "建立 claim gate",
                    phase: .claiming,
                    owner: nil,
                    claimIDs: [claim.id]
                )
            ],
            claims: [claim]
        )

        state.claimBoardState = board

        #expect(state.claimBoardJSON.isEmpty == false)
        #expect(state.claimBoardState == board)
    }

    @Test
    func updatingClaimBoardRefreshesUpdatedAt() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let originalUpdatedAt = Date(timeIntervalSince1970: 2)
        let state = AgentTeamSessionState(
            session: session,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: originalUpdatedAt
        )
        let board = AgentTeamClaimBoardState(
            cards: [
                AgentTeamClaimCard(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    title: "认领主任务",
                    goal: "选择 owner",
                    phase: .claiming,
                    owner: .builtIn,
                    claimIDs: []
                )
            ],
            claims: []
        )

        state.claimBoardState = board

        #expect(state.updatedAt > originalUpdatedAt)
    }

    @Test
    func taskBoardStatePrefersPersistedTaskBoardJSONOverLegacyClaimBoardJSON() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session)
        let legacyCardID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let taskCardID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let claimID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!

        state.claimBoardState = AgentTeamClaimBoardState(
            cards: [
                AgentTeamClaimCard(
                    id: legacyCardID,
                    title: "旧 claim 卡",
                    goal: "兼容历史数据",
                    phase: .claiming,
                    owner: nil,
                    claimIDs: []
                )
            ],
            claims: []
        )
        state.taskBoardState = AgentTeamTaskBoardState(
            cards: [
                AgentTeamTaskCard(
                    id: taskCardID,
                    title: "新 task 卡",
                    goal: "优先读取 taskBoardJSON",
                    status: .working,
                    owner: .builtIn,
                    acceptedClaimID: claimID,
                    dependencyIDs: [],
                    blockerSummary: nil,
                    lastUpdatedAt: Date(timeIntervalSince1970: 30)
                )
            ],
            claims: [
                AgentTeamClaim(
                    id: claimID,
                    providerReference: .builtIn,
                    taskCardID: taskCardID,
                    confidence: 0.91,
                    rationaleSummary: "接受的新 owner",
                    requiredCapabilities: ["swift"],
                    expectedArtifacts: ["patchProposal"],
                    estimatedCostSummary: "medium",
                    status: .accepted,
                    submittedAt: Date(timeIntervalSince1970: 31)
                )
            ]
        )

        #expect(state.taskBoardState?.cards.map(\.id) == [taskCardID])
        #expect(state.taskBoardState?.cards.first?.status == .working)
    }

    @Test
    func taskBoardStateFallsBackToLegacyClaimBoardMigration() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session)
        let cardID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let claimID = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!

        state.claimBoardState = AgentTeamClaimBoardState(
            cards: [
                AgentTeamClaimCard(
                    id: cardID,
                    title: "旧 claim 卡",
                    goal: "从 claim 迁移到 task board",
                    phase: .claimed,
                    owner: .builtIn,
                    claimIDs: [claimID]
                )
            ],
            claims: [
                AgentTeamClaim(
                    id: claimID,
                    providerReference: .builtIn,
                    taskCardID: cardID,
                    confidence: 0.96,
                    rationaleSummary: "历史 accepted claim",
                    requiredCapabilities: ["swift"],
                    expectedArtifacts: ["patchProposal"],
                    estimatedCostSummary: "low",
                    status: .accepted,
                    submittedAt: Date(timeIntervalSince1970: 40)
                )
            ]
        )

        let board = state.taskBoardState

        #expect(board?.cards.map(\.id) == [cardID])
        #expect(board?.cards.first?.status == .claimed)
        #expect(board?.cards.first?.acceptedClaimID == claimID)
    }

    @Test
    func updatingTaskBoardRefreshesUpdatedAt() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let originalUpdatedAt = Date(timeIntervalSince1970: 2)
        let state = AgentTeamSessionState(
            session: session,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: originalUpdatedAt
        )

        state.taskBoardState = AgentTeamTaskBoardState(
            cards: [
                AgentTeamTaskCard(
                    id: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
                    title: "任务卡",
                    goal: "刷新 updatedAt",
                    status: .briefed,
                    owner: nil,
                    acceptedClaimID: nil,
                    dependencyIDs: [],
                    blockerSummary: nil,
                    lastUpdatedAt: Date(timeIntervalSince1970: 50)
                )
            ],
            claims: []
        )

        #expect(state.updatedAt > originalUpdatedAt)
    }

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

    @Test
    func artifactBoardStateReviewReportRoundTrip() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session)
        let cardID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
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
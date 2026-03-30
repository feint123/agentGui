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
}
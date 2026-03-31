import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct AgentTeamWorkbenchPresentationTests {
    @Test
    func presentationPrefersPersistedMissionBrief() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let state = AgentTeamSessionState(
            session: session,
            sourceSessionID: "chat-1",
            sourceSessionTitle: "修复 ACP",
            mode: .executionDelivery,
            status: .active
        )
        state.missionBrief = AgentTeamMissionBrief(
            objective: "为 ACP team 汇总修复方案",
            constraints: ["不改 public API"],
            acceptanceCriteria: ["Focused tests 通过"],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "medium"),
            initialContextSummary: "当前聊天包含失败测试与日志。"
        )

        let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: state)

        #expect(presentation.header.title == "修复 ACP")
        #expect(presentation.header.statusText == "进行中")
        #expect(presentation.header.objectiveSummary == "为 ACP team 汇总修复方案")
        #expect(presentation.header.sourceSummary.contains("修复 ACP"))
        #expect(presentation.header.modeText == "执行交付")
        #expect(presentation.header.constraints == ["不改 public API"])
        #expect(presentation.header.acceptanceCriteria == ["Focused tests 通过"])
        #expect(presentation.header.contextSummary.contains("失败测试"))
        #expect(presentation.header.budgetSummary == "预算：并发 2 · Token 20k · 成本 medium")
        #expect(presentation.header.isFallbackBrief == false)
        #expect(presentation.roster.count == 3)
        #expect(presentation.roster.map(\ .role) == ["conductor", "worker", "reviewer"])
        #expect(presentation.boardColumns.isEmpty == false)
        #expect(presentation.boardColumns.flatMap(\ .cards).isEmpty == false)
    }

    @Test
    func presentationProjectsAcceptedOwnerFromClaimBoard() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session)
        state.missionBrief = AgentTeamMissionBrief(
            objective: "为 ACP team 汇总修复方案",
            constraints: ["仅修改 Swift 文件"],
            acceptanceCriteria: ["Focused tests 通过"],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "medium"),
            initialContextSummary: "当前聊天包含失败测试与日志。",
            providerPlan: .init(
                eligibleProviders: [
                    .builtIn,
                    .externalACP(profileID: LegacyExternalACPProviderKey.githubCopilotCLI.presetProfileID)
                ],
                preferredConductor: .externalACP(profileID: LegacyExternalACPProviderKey.githubCopilotCLI.presetProfileID),
                preferredReviewer: .builtIn,
                dispatchPolicy: .manualSelection
            )
        )

        let cardID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let claim = AgentTeamClaim(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            providerReference: .builtIn,
            taskCardID: cardID,
            confidence: 0.95,
            rationaleSummary: "适合负责主执行路径",
            requiredCapabilities: ["swift"],
            expectedArtifacts: ["patchProposal"],
            estimatedCostSummary: "medium",
            status: .accepted,
            submittedAt: Date(timeIntervalSince1970: 1)
        )
        let reviewID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let blockedID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        state.taskBoardState = AgentTeamTaskBoardState(
            cards: [
                AgentTeamTaskCard(
                    id: cardID,
                    title: "修复主路径",
                    goal: "建立 claim gate",
                    status: .claimed,
                    owner: .builtIn,
                    acceptedClaimID: claim.id,
                    dependencyIDs: [],
                    blockerSummary: nil,
                    lastUpdatedAt: Date(timeIntervalSince1970: 1)
                ),
                AgentTeamTaskCard(
                    id: reviewID,
                    title: "回归验证",
                    goal: "确认聚焦测试全部通过",
                    status: .reviewing,
                    owner: .builtIn,
                    acceptedClaimID: nil,
                    dependencyIDs: [cardID],
                    blockerSummary: nil,
                    lastUpdatedAt: Date(timeIntervalSince1970: 2)
                ),
                AgentTeamTaskCard(
                    id: blockedID,
                    title: "整理发布说明",
                    goal: "补齐迁移说明",
                    status: .blocked,
                    owner: nil,
                    acceptedClaimID: nil,
                    dependencyIDs: [reviewID],
                    blockerSummary: "等待 review 结论",
                    lastUpdatedAt: Date(timeIntervalSince1970: 3)
                )
            ],
            claims: [claim]
        )

        let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: state)
        let claimedColumn = presentation.boardColumns.first(where: { $0.id == AgentTeamTaskStatus.claimed.rawValue })
        let reviewColumn = presentation.boardColumns.first(where: { $0.id == AgentTeamTaskStatus.reviewing.rawValue })
        let blockedColumn = presentation.boardColumns.first(where: { $0.id == AgentTeamTaskStatus.blocked.rawValue })
        let card = claimedColumn?.cards.first
        let conductor = presentation.roster.first(where: { $0.role == "conductor" })
        let reviewer = presentation.roster.first(where: { $0.role == "reviewer" })

        #expect(card?.owner == "Built-In Agent")
        #expect(card?.statusText == "Claimed")
        #expect(card?.claimCountText == "1 个 claim")
        #expect(card?.dependencySummary == "无依赖")
        #expect(reviewColumn?.cards.first?.dependencySummary == "依赖 1 张卡：修复主路径")
        #expect(blockedColumn?.cards.first?.blockerSummary == "等待 review 结论")
        #expect(card?.summary.contains("建立 claim gate") == true)
        #expect(presentation.header.providerSummary == "Providers：Built-In Agent、GitHub Copilot CLI")
        #expect(presentation.header.conductorSummary == "Conductor：GitHub Copilot CLI")
        #expect(presentation.header.reviewerSummary == "Reviewer：Built-In Agent")
        #expect(conductor?.title == "GitHub Copilot CLI")
        #expect(conductor?.focus == "负责 brief、claim 决策与调度")
        #expect(reviewer?.title == "Built-In Agent")
        #expect(reviewer?.readiness == "已配置 reviewer")
        #expect(presentation.boardColumns.map(\ .title) == ["Briefed", "Claimed", "Working", "Reviewing", "Done", "Blocked"])
        #expect(presentation.inspector.title == "修复主路径")
        #expect(presentation.inspector.ownerSummary == "Owner：Built-In Agent")
        #expect(presentation.inspector.dependencySummary == "上游依赖：无")
        #expect(presentation.inspector.blockerSummary == "阻塞：无")
        #expect(presentation.inspector.downstreamSummary == "下游任务：回归验证")
    }

    @Test
    func presentationFallsBackWhenStateIsMissing() {
        let session = Session.fixture(title: "Agent Team", kind: .agentTeam)

        let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: nil)

        #expect(presentation.header.title == "Agent Team")
        #expect(presentation.header.statusText == "待开始")
        #expect(presentation.header.sourceSummary.contains("无来源聊天"))
        #expect(presentation.header.isFallbackBrief == true)
        #expect(presentation.header.constraints.isEmpty == false)
        #expect(presentation.header.acceptanceCriteria.isEmpty == false)
        #expect(presentation.inspector.title.contains("待选中"))
        #expect(presentation.boardColumns.map(\ .title) == ["Briefed", "Claimed", "Working", "Reviewing", "Done", "Blocked"])
    }

        @Test
        func presentationUsesDynamicACPProfileDisplayNameWhenAvailable() throws {
            let container = try ModelContainer(
                for: Schema(PersistenceSchema.sharedModelTypes),
                configurations: [ModelConfiguration(schema: Schema(PersistenceSchema.sharedModelTypes), isStoredInMemoryOnly: true)]
            )
            let modelContext = ModelContext(container)
            let profileID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
            _ = try ACPProviderProfileRepository(modelContext: modelContext).save(
                profileDraft: ACPProviderProfileDraft(
                    id: profileID,
                    displayName: "Qoder Agent",
                    executablePath: "/usr/local/bin/qoder"
                )
            )

            let session = Session.fixture(title: "动态 Provider", kind: .agentTeam)
            let state = AgentTeamSessionState(session: session)
            state.missionBrief = AgentTeamMissionBrief(
                objective: "展示真实 provider 名称",
                constraints: ["仅修改展示层"],
                acceptanceCriteria: ["显示 profile.displayName"],
                mode: .executionDelivery,
                budget: .init(maxActiveProviders: 1, tokenBudgetText: "10k", costBudgetText: "low"),
                initialContextSummary: "当前会话引用了 dynamic ACP profile。",
                providerPlan: .init(
                    eligibleProviders: [.externalACP(profileID: profileID)],
                    preferredConductor: .externalACP(profileID: profileID),
                    preferredReviewer: nil,
                    dispatchPolicy: .manualSelection
                )
            )

            let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: state, modelContext: modelContext)

            #expect(presentation.header.providerSummary == "Providers：Qoder Agent")
            #expect(presentation.header.conductorSummary == "Conductor：Qoder Agent")
            #expect(presentation.roster.first(where: { $0.role == "conductor" })?.title == "Qoder Agent")
            #expect(presentation.roster.first(where: { $0.role == "worker" })?.focus == "Qoder Agent")
        }
}
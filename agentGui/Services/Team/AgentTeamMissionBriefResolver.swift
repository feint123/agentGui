import Foundation

struct AgentTeamMissionBriefResolution: Equatable, Sendable {
    let brief: AgentTeamMissionBrief
    let isFallback: Bool
}

struct AgentTeamMissionBriefResolver {
    func resolve(
        session: Session,
        state: AgentTeamSessionState?,
        role: String? = nil
    ) -> AgentTeamMissionBriefResolution {
        _ = role

        if let brief = state?.missionBrief {
            return AgentTeamMissionBriefResolution(brief: brief, isFallback: false)
        }

        return AgentTeamMissionBriefResolution(
            brief: Self.fallbackBrief(
                sessionTitle: session.title,
                sourceTitle: state?.sourceSessionTitle,
                mode: state?.mode ?? .executionDelivery
            ),
            isFallback: true
        )
    }

    static func fallbackBrief(
        sessionTitle: String,
        sourceTitle: String?,
        mode: AgentTeamMode
    ) -> AgentTeamMissionBrief {
        let trimmedSourceTitle = sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSourceTitle = trimmedSourceTitle?.isEmpty == false
        let resolvedSourceTitle = hasSourceTitle ? trimmedSourceTitle! : "无来源聊天"
        let objective: String
        let initialContextSummary: String

        if hasSourceTitle {
            objective = "围绕 \(resolvedSourceTitle) 组织 Team Mode 协作"
            initialContextSummary = "该 Team 会话创建于正式 mission brief 持久化之前。来源上下文为 \(resolvedSourceTitle)，建议补充完整目标、约束与验收标准。"
        } else {
            objective = "围绕 \(sessionTitle) 建立 Team Mode 协作"
            initialContextSummary = "该 Team 会话创建于正式 mission brief 持久化之前，目前没有来源聊天。建议补充任务背景、关键约束与验收标准。"
        }

        return AgentTeamMissionBrief(
            objective: objective,
            constraints: [
                "该会话缺少持久化 mission brief，请补充正式约束。"
            ],
            acceptanceCriteria: [
                "补充正式 mission brief",
                "确认团队目标、预算和初始上下文"
            ],
            mode: mode,
            budget: AgentTeamBudget(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "medium"),
            initialContextSummary: initialContextSummary,
            providerPlan: AgentTeamProviderPlan(
                eligibleProviders: [.builtIn],
                preferredConductor: .builtIn,
                preferredReviewer: nil,
                dispatchPolicy: .manualSelection
            )
        )
    }
}
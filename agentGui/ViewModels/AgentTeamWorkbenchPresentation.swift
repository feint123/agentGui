import Foundation

struct AgentTeamWorkbenchPresentation: Equatable {
    struct Header: Equatable {
        let title: String
        let objectiveSummary: String
        let sourceSummary: String
        let modeText: String
        let statusText: String
        let budgetSummary: String
        let constraints: [String]
        let acceptanceCriteria: [String]
        let contextSummary: String
        let isFallbackBrief: Bool
    }

    struct RosterItem: Identifiable, Equatable {
        let id: String
        let role: String
        let title: String
        let readiness: String
        let focus: String
        let blocker: String
    }

    struct BoardCard: Identifiable, Equatable {
        let id: String
        let title: String
        let summary: String
        let owner: String
    }

    struct BoardColumn: Identifiable, Equatable {
        let id: String
        let title: String
        let cards: [BoardCard]
    }

    struct InspectorSummary: Equatable {
        let title: String
        let artifactSummary: String
        let reviewSummary: String
        let traceSummary: String
    }

    let header: Header
    let roster: [RosterItem]
    let boardColumns: [BoardColumn]
    let inspector: InspectorSummary

    static func make(session: Session, state: AgentTeamSessionState?) -> Self {
        let sourceTitle = state?.sourceSessionTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedSourceTitle = sourceTitle.isEmpty ? "无来源聊天" : sourceTitle
        let resolution = AgentTeamMissionBriefResolver().resolve(session: session, state: state)
        let brief = resolution.brief

        return Self(
            header: Header(
                title: session.title,
                objectiveSummary: brief.objective,
                sourceSummary: "来源上下文：\(resolvedSourceTitle)",
                modeText: modeText(for: brief.mode),
                statusText: statusText(for: state?.status ?? .created),
                budgetSummary: budgetSummary(for: brief.budget),
                constraints: brief.constraints,
                acceptanceCriteria: brief.acceptanceCriteria,
                contextSummary: brief.initialContextSummary,
                isFallbackBrief: resolution.isFallback
            ),
            roster: [
                RosterItem(
                    id: "conductor",
                    role: "conductor",
                    title: "Conductor",
                    readiness: "已就绪",
                    focus: "拆分任务与同步上下文",
                    blocker: "无"
                ),
                RosterItem(
                    id: "worker",
                    role: "worker",
                    title: "Worker",
                    readiness: "待命",
                    focus: "执行当前工作流占位任务",
                    blocker: "等待正式 task card"
                ),
                RosterItem(
                    id: "reviewer",
                    role: "reviewer",
                    title: "Reviewer",
                    readiness: "待命",
                    focus: "校验 artifact 与 review gate",
                    blocker: "等待首个产物"
                )
            ],
            boardColumns: [
                BoardColumn(
                    id: "briefing",
                    title: "Briefing",
                    cards: [
                        BoardCard(
                            id: "brief-1",
                            title: "对齐 mission 占位信息",
                            summary: "建立目标、来源、模式和验收摘要的展示结构。",
                            owner: "Conductor"
                        )
                    ]
                ),
                BoardColumn(
                    id: "working",
                    title: "Working",
                    cards: [
                        BoardCard(
                            id: "work-1",
                            title: "等待 Feature 5 task cards",
                            summary: "当前以占位卡展示并行为后续任务板预留承载面。",
                            owner: "Worker"
                        )
                    ]
                ),
                BoardColumn(
                    id: "reviewing",
                    title: "Reviewing",
                    cards: [
                        BoardCard(
                            id: "review-1",
                            title: "等待首个 artifact",
                            summary: "后续在此承接 review trace、merge gate 与人工介入。",
                            owner: "Reviewer"
                        )
                    ]
                )
            ],
            inspector: InspectorSummary(
                title: "待选中 work item",
                artifactSummary: "Artifact：当前显示占位说明，后续承接 Feature 6 typed artifacts。",
                reviewSummary: "Review：当前显示占位说明，后续承接 Feature 10 review gate。",
                traceSummary: "Trace：当前显示占位说明，后续接入 team execution timeline。"
            )
        )
    }

    private static func modeText(for mode: AgentTeamMode) -> String {
        switch mode {
        case .executionDelivery:
            return "执行交付"
        }
    }

    private static func statusText(for status: AgentTeamRunStatus) -> String {
        switch status {
        case .created:
            return "待开始"
        case .active:
            return "进行中"
        case .completed:
            return "已完成"
        case .failed:
            return "已失败"
        }
    }

    private static func budgetSummary(for budget: AgentTeamBudget) -> String {
        "预算：并发 \(budget.maxActiveProviders) · Token \(budget.tokenBudgetText) · 成本 \(budget.costBudgetText)"
    }
}
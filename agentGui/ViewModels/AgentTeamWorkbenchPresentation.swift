import Foundation

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

        return Self(
            header: Header(
                title: session.title,
                objectiveSummary: objectiveSummary(for: session.title, sourceTitle: resolvedSourceTitle),
                sourceSummary: "来源上下文：\(resolvedSourceTitle)",
                modeText: modeText(for: state?.mode ?? .executionDelivery),
                statusText: statusText(for: state?.status ?? .created),
                budgetText: "预算：待配置",
                waitingText: "用户输入：当前无需补充",
                acceptanceSummary: "验收：待 Feature 3 接入正式 mission brief 后细化"
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

    private static func objectiveSummary(for sessionTitle: String, sourceTitle: String) -> String {
        if sourceTitle == "无来源聊天" {
            return "围绕 \(sessionTitle) 建立独立 Team Workbench 壳层，并为后续 mission brief 预留承载位置。"
        }

        return "围绕 \(sourceTitle) 拆分团队协作工作面，并在 \(sessionTitle) 中持续展示 mission 与 workstream 占位信息。"
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
}
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
        let claimStatusText: String
        let claimCountText: String
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
        let boardProjection = makeBoardColumns(from: state?.claimBoardState)
        let acceptedOwnerNames = Set(
            boardProjection
                .flatMap(\ .cards)
                .map(\ .owner)
                .filter { $0 != "待认领" }
        )

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
                    readiness: acceptedOwnerNames.isEmpty ? "协调认领" : "已完成 owner 决策",
                    focus: acceptedOwnerNames.isEmpty ? "等待 provider 提交 claim" : "同步认领结果与团队焦点",
                    blocker: "无"
                ),
                RosterItem(
                    id: "worker",
                    role: "worker",
                    title: "Worker",
                    readiness: acceptedOwnerNames.isEmpty ? "待认领" : "已认领",
                    focus: acceptedOwnerNames.isEmpty ? "等待 owner 分配" : acceptedOwnerNames.joined(separator: "、"),
                    blocker: acceptedOwnerNames.isEmpty ? "等待 accepted claim" : "无"
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
            boardColumns: boardProjection,
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

    private static func makeBoardColumns(from board: AgentTeamClaimBoardState?) -> [BoardColumn] {
        guard let board, !board.cards.isEmpty else {
            return [
                BoardColumn(
                    id: "claiming",
                    title: "待认领",
                    cards: [
                        BoardCard(
                            id: "claim-placeholder",
                            title: "等待 claim board 初始化",
                            summary: "当前会话尚未生成可认领 card。",
                            owner: "待认领",
                            claimStatusText: "待认领",
                            claimCountText: "0 个 claim"
                        )
                    ]
                )
            ]
        }

        let boardCards = board.cards.map { card in
            let claims = board.claims(for: card.id)
            let acceptedClaim = board.acceptedClaim(for: card.id)
            let ownerReference = card.owner ?? acceptedClaim?.providerReference
            let claimStatusText: String

            if ownerReference != nil {
                claimStatusText = "已认领"
            } else if claims.count > 1 {
                claimStatusText = "竞争认领"
            } else {
                claimStatusText = "待认领"
            }

            return BoardCard(
                id: card.id.uuidString,
                title: card.title,
                summary: card.goal,
                owner: ownerReference.map(displayName(for:)) ?? "待认领",
                claimStatusText: claimStatusText,
                claimCountText: "\(claims.count) 个 claim"
            )
        }

        let claimedCards = boardCards.filter { $0.claimStatusText == "已认领" }
        let unclaimedCards = boardCards.filter { $0.claimStatusText != "已认领" }
        var columns: [BoardColumn] = []

        if !unclaimedCards.isEmpty {
            columns.append(BoardColumn(id: "claiming", title: "待认领", cards: unclaimedCards))
        }
        if !claimedCards.isEmpty {
            columns.append(BoardColumn(id: "claimed", title: "已认领", cards: claimedCards))
        }

        return columns
    }

    private static func displayName(for providerReference: ExecutionProviderReference) -> String {
        switch providerReference {
        case .builtIn:
            return "Built-In Agent"
        case let .externalACP(profileID):
            if let key = LegacyExternalACPProviderKey.allCases.first(where: { $0.presetProfileID == profileID }) {
                switch key {
                case .githubCopilotCLI:
                    return "GitHub Copilot CLI"
                case .openCodeCLI:
                    return "OpenCode CLI"
                case .claudeAdapterCLI:
                    return "Claude Adapter CLI"
                }
            }
            return "External ACP"
        }
    }
}
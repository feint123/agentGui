import Foundation
import SwiftData

struct AgentTeamWorkbenchPresentation: Equatable {
    struct Header: Equatable {
        let title: String
        let objectiveSummary: String
        let sourceSummary: String
        let modeText: String
        let statusText: String
        let budgetSummary: String
        let providerSummary: String
        let conductorSummary: String
        let reviewerSummary: String
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
        let statusText: String
        let claimCountText: String
        let dependencySummary: String
        let blockerSummary: String?
        let artifactCountText: String
        let isLocked: Bool          // .briefed 且有未完成依赖时为 true
    }

    struct BoardColumn: Identifiable, Equatable {
        let id: String
        let title: String
        let cards: [BoardCard]
    }

    struct ArtifactItem: Identifiable, Equatable {
        let id: String
        let title: String
        let kindText: String
        let producerSummary: String
        let statusText: String
        let summary: String
    }

    struct InspectorSummary: Equatable {
        let title: String
        let ownerSummary: String
        let dependencySummary: String
        let blockerSummary: String
        let downstreamSummary: String
        let artifactItems: [ArtifactItem]
    }

    struct CommitBarState: Equatable {
        let isReadyToMerge: Bool
        let mergeBlockDescriptions: [String]
        let pendingReviewCount: Int
        let mergeButtonLabel: String
    }

    let header: Header
    let roster: [RosterItem]
    let boardColumns: [BoardColumn]
    let inspector: InspectorSummary
    let commitBarState: CommitBarState

    static func make(session: Session, state: AgentTeamSessionState?, modelContext: ModelContext? = nil) -> Self {
        let sourceTitle = state?.sourceSessionTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedSourceTitle = sourceTitle.isEmpty ? "无来源聊天" : sourceTitle
        let resolution = AgentTeamMissionBriefResolver().resolve(session: session, state: state)
        let brief = resolution.brief
        let providerPlan = brief.providerPlan
        let eligibleProviderNames = providerPlan.eligibleProviders.map { displayName(for: $0, modelContext: modelContext) }
        let conductorName = displayName(for: providerPlan.preferredConductor, modelContext: modelContext)
        let reviewerName = providerPlan.preferredReviewer.map { displayName(for: $0, modelContext: modelContext) } ?? "未设置"
        let boardState = state?.taskBoardState
        let artifactBoard = state?.artifactBoardState
        let boardProjection = makeBoardColumns(from: boardState, artifactBoard: artifactBoard, modelContext: modelContext)
        let acceptedOwnerNames = Set(
            boardProjection
                .flatMap(\ .cards)
                .map(\ .owner)
                .filter { $0 != "待认领" }
        )
        let inspector = makeInspectorSummary(from: boardState, artifactBoard: artifactBoard, modelContext: modelContext)
        let commitBarState = makeCommitBarState(taskBoard: boardState, artifactBoard: artifactBoard)

        return Self(
            header: Header(
                title: session.title,
                objectiveSummary: brief.objective,
                sourceSummary: "来源上下文：\(resolvedSourceTitle)",
                modeText: modeText(for: brief.mode),
                statusText: statusText(for: state?.status ?? .created),
                budgetSummary: budgetSummary(for: brief.budget),
                providerSummary: "Providers：\(eligibleProviderNames.joined(separator: "、"))",
                conductorSummary: "Conductor：\(conductorName)",
                reviewerSummary: "Reviewer：\(reviewerName)",
                constraints: brief.constraints,
                acceptanceCriteria: brief.acceptanceCriteria,
                contextSummary: brief.initialContextSummary,
                isFallbackBrief: resolution.isFallback
            ),
            roster: [
                RosterItem(
                    id: "conductor",
                    role: "conductor",
                    title: conductorName,
                    readiness: acceptedOwnerNames.isEmpty ? "协调认领" : "已完成 owner 决策",
                    focus: "负责 brief、claim 决策与调度",
                    blocker: "无"
                ),
                RosterItem(
                    id: "worker",
                    role: "worker",
                    title: "Eligible Providers",
                    readiness: "已选择 \(eligibleProviderNames.count) 个 provider",
                    focus: eligibleProviderNames.joined(separator: "、"),
                    blocker: acceptedOwnerNames.isEmpty ? "等待 accepted claim" : "无"
                ),
                RosterItem(
                    id: "reviewer",
                    role: "reviewer",
                    title: reviewerName,
                    readiness: providerPlan.preferredReviewer == nil ? "未配置 reviewer" : "已配置 reviewer",
                    focus: "校验 artifact 与 review gate",
                    blocker: providerPlan.preferredReviewer == nil ? "等待 reviewer 指定" : "等待首个产物"
                )
            ],
            boardColumns: boardProjection,
            inspector: inspector,
            commitBarState: commitBarState
        )
    }

    private static let statusColumnOrder: [AgentTeamTaskStatus] = [.briefed, .claimed, .working, .reviewing, .done, .blocked]

    private static func modeText(for mode: AgentTeamMode) -> String {
        mode.displayName
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

    private static func makeBoardColumns(
        from board: AgentTeamTaskBoardState?,
        artifactBoard: AgentTeamArtifactBoardState?,
        modelContext: ModelContext?
    ) -> [BoardColumn] {
        guard let board else {
            return statusColumnOrder.map { status in
                BoardColumn(
                    id: status.rawValue,
                    title: title(for: status),
                    cards: status == .briefed ? [
                        BoardCard(
                            id: "task-placeholder",
                            title: "等待 task board 初始化",
                            summary: "当前会话尚未生成可执行 task card。",
                            owner: "待认领",
                            statusText: title(for: .briefed),
                            claimCountText: "0 个 claim",
                            dependencySummary: "无依赖",
                            blockerSummary: nil,
                            artifactCountText: "无工件",
                            isLocked: false
                        )
                    ] : []
                )
            }
        }

        return statusColumnOrder.map { status in
            BoardColumn(
                id: status.rawValue,
                title: title(for: status),
                cards: board.cards
                    .filter { $0.status == status }
                    .map { card in
                        let claims = board.claims(for: card.id)
                        let acceptedClaim = board.acceptedClaim(for: card.id)
                        let ownerReference = card.owner ?? acceptedClaim?.providerReference
                        let unresolvedDependencies = board.unresolvedDependencies(for: card.id)
                        let artifactCount = artifactBoard?.artifacts(for: card.id).count ?? 0
                        let isLocked = card.status == .briefed && !unresolvedDependencies.isEmpty

                        return BoardCard(
                            id: card.id.uuidString,
                            title: card.title,
                            summary: card.goal,
                            owner: ownerReference.map { displayName(for: $0, modelContext: modelContext) } ?? "待认领",
                            statusText: title(for: status),
                            claimCountText: "\(claims.count) 个 claim",
                            dependencySummary: dependencySummary(for: card, unresolvedDependencies: unresolvedDependencies, in: board),
                            blockerSummary: card.blockerSummary,
                            artifactCountText: artifactCountText(artifactCount),
                            isLocked: isLocked
                        )
                    }
            )
        }
    }

    private static func artifactCountText(_ count: Int) -> String {
        switch count {
        case 0: return "无工件"
        case 1: return "1 件工件"
        default: return "\(count) 件工件"
        }
    }

    private static func makeInspectorSummary(
        from board: AgentTeamTaskBoardState?,
        artifactBoard: AgentTeamArtifactBoardState?,
        modelContext: ModelContext?
    ) -> InspectorSummary {
        guard let board,
              let focusedCard = statusColumnOrder
                .compactMap({ status in board.cards.first(where: { $0.status == status }) })
                .first else {
            return InspectorSummary(
                title: "待选中 work item",
                ownerSummary: "Owner：待认领",
                dependencySummary: "上游依赖：无",
                blockerSummary: "阻塞：无",
                downstreamSummary: "下游任务：无",
                artifactItems: []
            )
        }

        let acceptedClaim = board.acceptedClaim(for: focusedCard.id)
        let ownerReference = focusedCard.owner ?? acceptedClaim?.providerReference
        let ownerSummary = ownerReference.map { "Owner：\(displayName(for: $0, modelContext: modelContext))" } ?? "Owner：待认领"
        let upstreamTitles = focusedCard.dependencyIDs.compactMap { board.card(id: $0)?.title }
        let downstreamTitles = board.cards
            .filter { $0.dependencyIDs.contains(focusedCard.id) }
            .map(\ .title)

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
            ownerSummary: ownerSummary,
            dependencySummary: "上游依赖：\(upstreamTitles.isEmpty ? "无" : upstreamTitles.joined(separator: "、"))",
            blockerSummary: "阻塞：\((focusedCard.blockerSummary?.isEmpty == false ? focusedCard.blockerSummary! : "无"))",
            downstreamSummary: "下游任务：\(downstreamTitles.isEmpty ? "无" : downstreamTitles.joined(separator: "、"))",
            artifactItems: artifactItems
        )
    }

    private static func title(for status: AgentTeamTaskStatus) -> String {
        switch status {
        case .briefed:
            return "Briefed"
        case .claimed:
            return "Claimed"
        case .working:
            return "Working"
        case .reviewing:
            return "Reviewing"
        case .done:
            return "Done"
        case .blocked:
            return "Blocked"
        }
    }

    private static func dependencySummary(
        for card: AgentTeamTaskCard,
        unresolvedDependencies: [UUID],
        in board: AgentTeamTaskBoardState
    ) -> String {
        guard card.dependencyIDs.isEmpty == false else {
            return "无依赖"
        }

        if unresolvedDependencies.isEmpty {
            return "依赖 \(card.dependencyIDs.count) 张卡，均已完成"
        }

        let unresolvedTitles = unresolvedDependencies.compactMap { board.card(id: $0)?.title }
        if unresolvedTitles.isEmpty {
            return "依赖 \(card.dependencyIDs.count) 张卡"
        }
        return "依赖 \(card.dependencyIDs.count) 张卡：\(unresolvedTitles.joined(separator: "、"))"
    }

    private static func displayName(for providerReference: ExecutionProviderReference, modelContext: ModelContext?) -> String {
        switch providerReference {
        case .builtIn:
            return "Built-In Agent"
        case let .externalACP(profileID):
            if let modelContext,
               let profile = try? ACPProviderProfileRepository(modelContext: modelContext).allProfiles().first(where: { $0.id == profileID }) {
                return profile.displayName
            }
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
}
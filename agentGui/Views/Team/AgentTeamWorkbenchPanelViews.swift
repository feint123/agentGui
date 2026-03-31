import SwiftUI

struct AgentTeamRosterPanelView: View {
    let items: [AgentTeamWorkbenchPresentation.RosterItem]

    var body: some View {
        WorkbenchSidebarSectionCard(title: "Team Roster", systemImage: "person.3") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.headline)
                        Text("角色：\(item.role)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Readiness：\(item.readiness)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Focus：\(item.focus)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Blocker：\(item.blocker)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 6)
                }
            }
        }
    }
}

private struct AgentTeamBoardCardView: View {
    let card: AgentTeamWorkbenchPresentation.BoardCard
    let isFirst: Bool
    let columnID: String
    let isExecuting: Bool
    let onCardDone: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 4) {
                Text(card.title)
                    .font(.subheadline.weight(.semibold))
                if card.isLocked {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .help("此卡有未完成的上游依赖，无法派发")
                }
            }
            Text(card.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Owner：\(card.owner)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(isFirst ? AgentTeamSessionView.claimOwnerAccessibilityIdentifier : "")
            Text("状态：\(card.statusText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(isFirst ? AgentTeamSessionView.claimStatusAccessibilityIdentifier : "")
            Text(card.dependencySummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(isFirst ? AgentTeamSessionView.taskDependencyAccessibilityIdentifier : "")
            if let blockerSummary = card.blockerSummary, !blockerSummary.isEmpty {
                Text("阻塞：\(blockerSummary)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(isFirst ? AgentTeamSessionView.taskBlockerAccessibilityIdentifier : "")
            }
            Text(card.claimCountText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(card.artifactCountText)
                .font(.caption2)
                .foregroundStyle(card.artifactCountText == "无工件" ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.blue))
            if columnID == AgentTeamTaskStatus.working.rawValue {
                if isExecuting {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("执行中…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("agentTeam.card.executionProgress.\(card.id)")
                }
                if let onCardDone {
                    Button("标记完成") { onCardDone(card.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .accessibilityIdentifier("agentTeam.card.markDone.\(card.id)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct AgentTeamBoardPanelView: View {
    let columns: [AgentTeamWorkbenchPresentation.BoardColumn]
    var isExecuting: Bool = false
    var onCardDone: ((String) -> Void)? = nil

    var body: some View {
        WorkbenchSidebarSectionCard(title: "Workstream Board", systemImage: "square.grid.3x3.topleft.filled") {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(columns) { column in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(column.title)
                                .font(.headline)
                            ForEach(column.cards) { card in
                                AgentTeamBoardCardView(
                                    card: card,
                                    isFirst: card.id == firstCardID,
                                    columnID: column.id,
                                    isExecuting: isExecuting && column.id == AgentTeamTaskStatus.working.rawValue,
                                    onCardDone: onCardDone
                                )
                            }
                        }
                        .frame(width: 220, alignment: .topLeading)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var firstCardID: String? {
        columns.first(where: { !$0.cards.isEmpty })?.cards.first?.id
    }
}

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
                    Text("工件")
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
                            if item.kindText == "reviewReport" {
                                Text("📋 \(item.producerSummary)")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
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

// MARK: - Commit Bar

/// The fixed bottom action bar on the Team Workbench.
/// Surfaces the primary lifecycle controls: launch, stop.
struct AgentTeamCommitBarView: View {
    let status: AgentTeamRunStatus
    let isLaunching: Bool
    let commitBarState: AgentTeamWorkbenchPresentation.CommitBarState
    let onLaunch: () -> Void
    let onStop: () -> Void
    var onMerge: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            switch status {
            case .created:
                Button(action: onLaunch) {
                    if isLaunching {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("启动中…")
                        }
                    } else {
                        Label("启动 Team", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLaunching)
                .accessibilityIdentifier(AgentTeamSessionView.launchButtonAccessibilityIdentifier)

            case .active:
                Button(role: .destructive, action: onStop) {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AgentTeamSessionView.stopButtonAccessibilityIdentifier)

            case .completed:
                Label("已完成", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline.weight(.medium))

            case .failed:
                Label("已停止", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.subheadline.weight(.medium))

                Button(action: onLaunch) {
                    Label("重新启动", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isLaunching)
                .accessibilityIdentifier(AgentTeamSessionView.launchButtonAccessibilityIdentifier)
            }

            Divider()
                .frame(height: 20)

            VStack(alignment: .leading, spacing: 4) {
                Button(commitBarState.mergeButtonLabel) {
                    onMerge?()
                }
                .disabled(!commitBarState.isReadyToMerge)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("teamCommitBar.mergeButton")

                if !commitBarState.mergeBlockDescriptions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(commitBarState.mergeBlockDescriptions, id: \.self) { reason in
                            Label(reason, systemImage: "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if commitBarState.pendingReviewCount > 0 {
                    Text("\(commitBarState.pendingReviewCount) 张卡等待 review")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
        .accessibilityIdentifier(AgentTeamSessionView.commitBarAccessibilityIdentifier)
    }
}
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

struct AgentTeamBoardPanelView: View {
    let columns: [AgentTeamWorkbenchPresentation.BoardColumn]
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
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(card.title)
                                        .font(.subheadline.weight(.semibold))
                                    Text(card.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("Owner：\(card.owner)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier(card.id == firstCardID ? AgentTeamSessionView.claimOwnerAccessibilityIdentifier : "")
                                    Text("状态：\(card.statusText)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier(card.id == firstCardID ? AgentTeamSessionView.claimStatusAccessibilityIdentifier : "")
                                    Text(card.dependencySummary)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier(card.id == firstCardID ? AgentTeamSessionView.taskDependencyAccessibilityIdentifier : "")
                                    if let blockerSummary = card.blockerSummary, blockerSummary.isEmpty == false {
                                        Text("阻塞：\(blockerSummary)")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                            .accessibilityIdentifier(card.id == firstCardID ? AgentTeamSessionView.taskBlockerAccessibilityIdentifier : "")
                                    }
                                    Text(card.claimCountText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    if column.id == AgentTeamTaskStatus.working.rawValue,
                                       let onCardDone {
                                        Button("标记完成") { onCardDone(card.id) }
                                            .buttonStyle(.bordered)
                                            .controlSize(.mini)
                                            .accessibilityIdentifier("agentTeam.card.markDone.\(card.id)")
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    let onLaunch: () -> Void
    let onStop: () -> Void

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
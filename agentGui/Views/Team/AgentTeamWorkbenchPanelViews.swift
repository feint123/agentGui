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
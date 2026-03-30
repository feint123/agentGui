import SwiftUI

struct AgentTeamMissionHeaderView: View {
    let presentation: AgentTeamWorkbenchPresentation.Header

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(presentation.title)
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier(AgentTeamSessionView.titleAccessibilityIdentifier)

                Text(presentation.objectiveSummary)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier(AgentTeamSessionView.placeholderAccessibilityIdentifier)

                Text(presentation.sourceSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            chipRow

            Text(presentation.acceptanceSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .workbenchSidebarCardStyle(padding: 18)
    }

    private var chipRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                chip(title: presentation.modeText)
                chip(title: presentation.statusText)
                chip(title: presentation.budgetText)
                chip(title: presentation.waitingText)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    chip(title: presentation.modeText)
                    chip(title: presentation.statusText)
                }

                HStack(spacing: 10) {
                    chip(title: presentation.budgetText)
                    chip(title: presentation.waitingText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
    }
}
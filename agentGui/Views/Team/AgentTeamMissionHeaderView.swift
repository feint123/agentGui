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

            providerPlanSection

            if presentation.isFallbackBrief {
                Text("该 Team 会话由历史壳层推导出 fallback brief，建议补充正式 mission brief。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            detailSection(
                title: "Constraints",
                items: presentation.constraints,
                accessibilityIdentifier: AgentTeamSessionView.constraintsAccessibilityIdentifier
            )

            detailSection(
                title: "Acceptance",
                items: presentation.acceptanceCriteria,
                accessibilityIdentifier: AgentTeamSessionView.acceptanceAccessibilityIdentifier
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Initial Context")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(presentation.contextSummary)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
            .accessibilityIdentifier(AgentTeamSessionView.contextSummaryAccessibilityIdentifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .workbenchSidebarCardStyle(padding: 18)
    }

    private var chipRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                chip(title: presentation.modeText)
                chip(title: presentation.statusText)
                chip(title: presentation.budgetSummary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    chip(title: presentation.modeText)
                    chip(title: presentation.statusText)
                }

                chip(title: presentation.budgetSummary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var providerPlanSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Provider Plan")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(presentation.providerSummary)
                .font(.body)
                .foregroundStyle(.primary)

            Text(presentation.conductorSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(presentation.reviewerSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func detailSection(
        title: String,
        items: [String],
        accessibilityIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(items, id: \.self) { item in
                Text("• \(item)")
                    .font(.body)
                    .foregroundStyle(.primary)
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
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
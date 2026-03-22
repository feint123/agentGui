import SwiftUI

struct SessionWorkspaceBadgeView: View {
    let presentation: SessionWorkspacePresentation

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: presentation.isMissing ? "folder.badge.questionmark" : "folder")
                .font(.caption2)
                .foregroundStyle(presentation.isMissing ? .tertiary : .secondary)

            Text(presentation.title)
                .font(.caption)
                .foregroundStyle(presentation.isMissing ? .tertiary : .secondary)
                .lineLimit(1)

            Text(presentation.kindLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
}
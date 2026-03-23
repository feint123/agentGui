import SwiftUI

struct GitSidebarOverviewSection: View {
    let snapshot: GitRepositorySnapshot
    let operationState: GitOperationState

    var body: some View {
        sectionCard("概览", systemImage: "point.topleft.down.curvedto.point.bottomright.up") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.repositoryName)
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("git.summary.repository")
                        Text(snapshot.branchName)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("git.summary.branch")
                    }
                    Spacer(minLength: 0)
                    if case let .running(label) = operationState {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    statPill("Staged", count: snapshot.stagedChanges.count)
                    statPill("Modified", count: snapshot.unstagedChanges.count)
                    statPill("Untracked", count: snapshot.untrackedChanges.count)
                }
                .accessibilityIdentifier("git.panel.summary")

                if snapshot.hasRemoteTrackingBranch {
                    Text("Ahead \(snapshot.aheadCount) · Behind \(snapshot.behindCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if snapshot.stagedChanges.isEmpty && snapshot.unstagedChanges.isEmpty && snapshot.untrackedChanges.isEmpty {
                    Text("工作区干净")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private func statPill(_ title: String, count: Int) -> some View {
    HStack(spacing: 4) {
        Text(title)
        Text("\(count)")
            .monospacedDigit()
    }
    .font(.caption)
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(Color.primary.opacity(0.06), in: Capsule())
}

func sectionCard<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
}
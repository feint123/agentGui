import SwiftUI

struct GitSidebarHistorySection: View {
    let panelViewModel: GitPanelViewModel

    @State private var selectedCommitID: String?

    var body: some View {
        sectionCard("历史", systemImage: "clock") {
            if panelViewModel.historyEntries.isEmpty {
                Text("暂无提交记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(panelViewModel.historyEntries) { commit in
                        commitRow(commit)
                            .background(
                                selectedCommitID == commit.id
                                    ? Color.accentColor.opacity(0.1)
                                    : Color.clear
                            )
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedCommitID = selectedCommitID == commit.id ? nil : commit.id
                                }
                            }
                    }

                    loadMoreButton
                }
            }
        }
    }

    // MARK: - Commit Row

    @ViewBuilder
    private func commitRow(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(commit.shortSha)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)

                Text(commit.message)
                    .font(.caption)
                    .lineLimit(selectedCommitID == commit.id ? nil : 1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                Text(commit.date.relativeFormatted)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if selectedCommitID == commit.id {
                commitDetail(commit)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .accessibilityIdentifier("git.history.commit.\(commit.shortSha)")
        .help(commit.fullMessage.isEmpty ? commit.message : commit.fullMessage)
    }

    // MARK: - Commit Detail (expanded)

    @ViewBuilder
    private func commitDetail(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()

            if !commit.fullMessage.isEmpty && commit.fullMessage != commit.message {
                Text(commit.fullMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 12) {
                Label(commit.author, systemImage: "person")
                Label(commit.sha, systemImage: "number")
                    .onTapGesture {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commit.sha, forType: .string)
                    }
                    .help("点击复制完整 SHA")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text(commit.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }

    // MARK: - Load More

    @ViewBuilder
    private var loadMoreButton: some View {
        if !panelViewModel.historyEntries.isEmpty {
            Button {
                Task { await panelViewModel.loadMoreHistory() }
            } label: {
                HStack(spacing: 4) {
                    if panelViewModel.isLoadingHistory {
                        ProgressView().controlSize(.mini)
                    }
                    Text("加载更多")
                }
                .font(.caption)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(.top, 6)
            .disabled(panelViewModel.isLoadingHistory)
        }
    }
}

// MARK: - Date Helper

private extension Date {
    var relativeFormatted: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

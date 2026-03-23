import SwiftUI

struct GitSidebarCommitSection: View {
    let sidebarViewModel: GitSidebarViewModel
    let workspaceState: WorkspaceState

    var body: some View {
        @Bindable var sidebarViewModel = sidebarViewModel

        return sectionCard("提交", systemImage: "square.and.pencil") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("摘要", text: $sidebarViewModel.commitDraft.summary)
                    .textFieldStyle(.roundedBorder)

                TextField("描述（可选）", text: $sidebarViewModel.commitDraft.description, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)

                if let reason = sidebarViewModel.commitDisabledReason {
                    Text(disabledMessage(for: reason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("创建提交") {
                    Task { await sidebarViewModel.commit(workspaceState: workspaceState) }
                }
                .disabled(sidebarViewModel.commitDisabledReason != nil)
            }
        }
    }

    private func disabledMessage(for reason: GitCommitDisabledReason) -> String {
        switch reason {
        case .missingSummary:
            "请填写提交摘要。"
        case .noStagedChanges:
            "至少需要一个已暂存文件。"
        }
    }
}
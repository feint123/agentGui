import SwiftUI

struct GitSidebarUtilitiesSection: View {
    let sidebarViewModel: GitSidebarViewModel
    let workspaceState: WorkspaceState

    var body: some View {
        @Bindable var sidebarViewModel = sidebarViewModel
        let panelViewModel = sidebarViewModel.panelViewModel

        return sectionCard("工具", systemImage: "shippingbox") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("stash 说明（可选）", text: $sidebarViewModel.stashMessage)
                        .textFieldStyle(.roundedBorder)
                    Button("保存") {
                        Task { await sidebarViewModel.saveStash(workspaceState: workspaceState) }
                    }
                    .disabled(!sidebarViewModel.canSaveStash)
                }

                if panelViewModel.stashEntries.isEmpty {
                    Text("暂无 stash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(panelViewModel.stashEntries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.id)
                                        .font(.caption.monospaced())
                                    Text(entry.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Button("Apply") {
                                    Task { await panelViewModel.applyStash(id: entry.id, pop: false, workspaceState: workspaceState) }
                                }
                                .buttonStyle(.borderless)

                                Button("Pop") {
                                    Task { await panelViewModel.applyStash(id: entry.id, pop: true, workspaceState: workspaceState) }
                                }
                                .buttonStyle(.borderless)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }
}
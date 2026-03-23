import SwiftUI

struct GitSidebarBranchSection: View {
    let sidebarViewModel: GitSidebarViewModel
    let workspaceState: WorkspaceState

    var body: some View {
        @Bindable var sidebarViewModel = sidebarViewModel
        let panelViewModel = sidebarViewModel.panelViewModel

        return sectionCard("分支与同步", systemImage: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Menu {
                        if panelViewModel.availableBranches.isEmpty {
                            Text("暂无可切换分支")
                        } else {
                            ForEach(panelViewModel.availableBranches) { branch in
                                Button(branch.name) {
                                    Task { await panelViewModel.switchBranch(to: branch.name) }
                                }
                                .disabled(branch.isCurrent || panelViewModel.isSwitchingBranch)
                            }
                        }
                    } label: {
                        Label(panelViewModel.isSwitchingBranch ? "切换中..." : "切换分支", systemImage: "arrow.triangle.branch")
                            .font(.caption)
                    }
                    .accessibilityIdentifier("git.branch.menu")
                    .disabled(panelViewModel.availableBranches.isEmpty)

                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    TextField("新分支名", text: $sidebarViewModel.newBranchName)
                        .textFieldStyle(.roundedBorder)
                    Button("创建并切换") {
                        Task { await sidebarViewModel.createBranch(switchAfterCreate: true, workspaceState: workspaceState) }
                    }
                    .disabled(sidebarViewModel.newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                HStack(spacing: 8) {
                    Button("Fetch") {
                        Task { await panelViewModel.fetch(workspaceState: workspaceState) }
                    }
                    .buttonStyle(.borderless)

                    Button("Pull") {
                        Task { await panelViewModel.pull(workspaceState: workspaceState) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!sidebarViewModel.canSync)

                    Button("Push") {
                        Task { await panelViewModel.push(workspaceState: workspaceState) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!sidebarViewModel.canSync)
                }
                .font(.caption)
            }
        }
    }
}
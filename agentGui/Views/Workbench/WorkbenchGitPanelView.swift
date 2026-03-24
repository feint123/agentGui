import SwiftUI
import SwiftData

struct WorkbenchGitPanelView: View {
    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(GitPanelViewModel.self) private var gitPanelViewModel
    @Environment(PersistenceCoordinator.self) private var persistenceCoordinator
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchSidebarPanelHeader {
                GitPanelHeaderBar(
                    isLoading: gitPanelViewModel.isLoading,
                    canRefresh: gitPanelViewModel.currentWorkingDirectory != nil,
                    onRefresh: refreshFromCurrentDirectory
                )
            }

            WorkbenchSidebarPanelScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSidebarPanelStyle.sectionSpacing) {
                    GitPanelView(showsBackground: false, showsHeader: false)
                }
            }
        }
        .task(id: refreshKey) {
            await refreshSnapshot()
        }
    }

    private var refreshKey: String {
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        return "\(workspaceState.selectedSession?.sessionId ?? "")|\(workspaceState.selectedFile?.path ?? "")|\(workspaceState.effectiveWorkingDirectory(globalDefault: settings.workingDirectory))"
    }

    private func refreshSnapshot() async {
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        let workingDirectory = workspaceState.effectiveWorkingDirectory(globalDefault: settings.workingDirectory)
        guard !workingDirectory.isEmpty else { return }
        await gitPanelViewModel.refresh(for: URL(fileURLWithPath: workingDirectory), workspaceState: workspaceState)
    }

    private func refreshFromCurrentDirectory() {
        guard let workingDirectory = gitPanelViewModel.currentWorkingDirectory else { return }
        Task {
            await gitPanelViewModel.refresh(for: workingDirectory, workspaceState: workspaceState)
        }
    }
}
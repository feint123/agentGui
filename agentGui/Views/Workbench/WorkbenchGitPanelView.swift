import SwiftUI
import SwiftData

struct WorkbenchGitPanelView: View {
    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(GitPanelViewModel.self) private var gitPanelViewModel
    @Environment(PersistenceCoordinator.self) private var persistenceCoordinator
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GitPanelView(showsBackground: false)
            }
            .padding(12)
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
}
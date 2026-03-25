import Observation
import SwiftData

@Observable
@MainActor
final class WorkbenchSceneServices {
    let workspaceState: WorkspaceState
    let workbenchState: WorkbenchState
    let gitPanelViewModel: GitPanelViewModel
    let changeReviewProjectionStore: ChangeReviewProjectionStore

    init() {
        let workspaceState = WorkspaceState()

        self.workspaceState = workspaceState
        self.workbenchState = WorkbenchState(selectedItem: TestLaunchOptions.current.initialWorkbenchItem)
        self.gitPanelViewModel = GitPanelViewModel()
        self.changeReviewProjectionStore = ChangeReviewProjectionStore()
    }

    func makeCommandContext(
        focusedScene: AppFocusedSceneKind,
        openWindowByID: ((String) -> Void)? = nil,
        modelContext: ModelContext? = nil
    ) -> AppCommandContext {
        AppCommandContext(
            workspaceState: workspaceState,
            workbenchState: workbenchState,
            modelContext: modelContext,
            focusedScene: focusedScene,
            openWindowByID: openWindowByID
        )
    }
}
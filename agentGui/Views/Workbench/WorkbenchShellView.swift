import SwiftUI
import SwiftData

struct WorkbenchShellView: View {
    @Environment(ClaudeService.self) private var claudeService
    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(WorkbenchState.self) private var workbenchState
    @Environment(GitPanelViewModel.self) private var gitPanelViewModel
    @Environment(ChangeReviewProjectionStore.self) private var changeReviewProjectionStore
    @Environment(WorkbenchContextWindowState.self) private var contextWindowState
    @Environment(\.openWindow) private var openWindow

    @Environment(\.modelContext) private var modelContext
    private let launchOptions = TestLaunchOptions.current

    @Query(sort: \Session.updatedAt, order: .reverse)
    private var sessions: [Session]

    init() {}

    var body: some View {
        let settings = AppSettings.getOrCreate(in: modelContext)
        let titlePresentation = WorkbenchTitlePresentation.make(
            selectedItem: workbenchState.selectedItem,
            workspaceState: workspaceState,
            globalWorkingDirectory: settings.workingDirectory
        )

        NavigationSplitView {
            WorkbenchSidebarView()
                .navigationSplitViewColumnWidth(
                    min: 220,
                    ideal: 280,
                    max: 360
                )
        } detail: {
            WorkbenchConversationPane()
        }
        .navigationTitle(titlePresentation.title)
        .navigationSubtitle(titlePresentation.subtitle)
        .onAppear(perform: configureOnAppear)
        .onChange(of: sessions, initial: false, synchronizeSessionSelection)
        .onChange(of: contextWindowState.openRequestToken) { _, _ in
            openWindow(id: WorkbenchContextWindowScene.id)
        }
    }

    private func configureOnAppear() {
        claudeService.changeReviewProjectionStore = changeReviewProjectionStore
        Task { @MainActor in
            try? await ChangeReviewBootstrapper.restorePendingProposals(
                modelContext: modelContext,
                projectionStore: changeReviewProjectionStore
            )
        }
        configureInitialSelection()
    }

    private func configureInitialSelection() {
        if workspaceState.selectedSession == nil {
            workspaceState.selectedSession = sessions.first
        }

        if let selectedFilePath = launchOptions.selectedFilePath {
            let selectedFileURL = URL(fileURLWithPath: selectedFilePath).standardizedFileURL
            if FileManager.default.fileExists(atPath: selectedFileURL.path) {
                workspaceState.showFileDetail(selectedFileURL)
            }
        }
    }

    private func synchronizeSessionSelection(oldValue _: [Session], newValue newSessions: [Session]) {
        if let current = workspaceState.selectedSession,
           !newSessions.contains(where: { $0.persistentModelID == current.persistentModelID }) {
            workspaceState.selectedSession = newSessions.first
        }

        if workspaceState.selectedSession == nil {
            workspaceState.selectedSession = newSessions.first
        }
    }
}
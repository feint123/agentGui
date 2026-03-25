import SwiftUI
import SwiftData

struct WorkbenchShellView: View {
    @Environment(ClaudeService.self) private var claudeService
    @Environment(CommandPaletteViewModel.self) private var commandPaletteViewModel
    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(WorkbenchState.self) private var workbenchState
    @Environment(GitPanelViewModel.self) private var gitPanelViewModel
    @Environment(ChangeReviewProjectionStore.self) private var changeReviewProjectionStore
    @Environment(\.openWindow) private var openWindow

    @Environment(\.modelContext) private var modelContext
    private let launchOptions = TestLaunchOptions.current

    @Query(sort: \Session.updatedAt, order: .reverse)
    private var sessions: [Session]

    private let sceneID: UUID

    init(sceneID: UUID = UUID()) {
        self.sceneID = sceneID
    }

    var body: some View {
        let settings = AppSettings.getOrCreate(in: modelContext)
        let titlePresentation = WorkbenchTitlePresentation.make(
            selectedItem: workbenchState.selectedItem,
            workspaceState: workspaceState,
            globalWorkingDirectory: settings.workingDirectory
        )

        ZStack {
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

            if commandPaletteViewModel.isPresented {
                commandPaletteOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    .zIndex(1)
            }
        }
        .navigationTitle(titlePresentation.title)
        .navigationSubtitle(titlePresentation.subtitle)
        .focusedSceneValue(\.appCommandContext, commandContext)
        .onAppear(perform: configureOnAppear)
        .onChange(of: sessions, initial: false, synchronizeSessionSelection)
        .animation(.snappy(duration: 0.18, extraBounce: 0), value: commandPaletteViewModel.isPresented)
    }

    private var commandPaletteOverlay: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(.black.opacity(0.14))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    commandPaletteViewModel.markDismissed()
                }

            CommandPaletteView()
                .frame(width: 720, height: 520)
                .padding(.top, 56)
                .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
        }
    }

    private func configureOnAppear() {
        claudeService.changeReviewProjectionStore = changeReviewProjectionStore
        workspaceState.contextWindowRouter = WorkbenchContextWindowRouter(
            openWindowWithValue: { windowID, value in
                openWindow(id: windowID, value: value)
            }
        )
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

    private var commandContext: AppCommandContext {
        AppCommandContext(
            sceneID: sceneID,
            workspaceState: workspaceState,
            workbenchState: workbenchState,
            modelContext: modelContext,
            focusedScene: .workbench,
            openWindowByID: { windowID in
                openWindow(id: windowID)
            }
        )
    }
}
import SwiftUI
import SwiftData

struct WorkbenchShellView: View {
    @Environment(ClaudeService.self) private var claudeService
    @State private var workspaceState = WorkspaceState()
    @State private var workbenchState = WorkbenchState(selectedItem: TestLaunchOptions.current.initialWorkbenchItem)
    @State private var gitPanelViewModel = GitPanelViewModel()
    @State private var changeReviewProjectionStore = ChangeReviewProjectionStore()
    @State private var columnVisibility = NavigationSplitViewVisibility.all

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

        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkbenchSidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } content: {
            FileEditorView()
                .accessibilityIdentifier("panel.editor")
                .navigationSplitViewColumnWidth(min: 280, ideal: 400)
        } detail: {
            if let session = workspaceState.selectedSession {
                ChatView(session: session, showsNavigationChrome: false)
                    .accessibilityIdentifier("panel.chat")
            } else {
                emptyDetailState
                    .accessibilityIdentifier("panel.chat.empty")
            }
        }
        .navigationTitle(titlePresentation.title)
        .navigationSubtitle(titlePresentation.subtitle)
        .navigationSplitViewStyle(.balanced)
        .background(WorkbenchWindowConfigurator(presentation: titlePresentation))
        .environment(workspaceState)
        .environment(workbenchState)
        .environment(gitPanelViewModel)
        .environment(changeReviewProjectionStore)
        .onAppear(perform: configureOnAppear)
        .onChange(of: sessions, initial: false, synchronizeSessionSelection)
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
                workspaceState.selectedFile = selectedFileURL
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

    private var emptyDetailState: some View {
        ContentUnavailableView {
            Label("无对话", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("点击左侧会话页或工具栏的 + 开始新对话")
        } actions: {
            Button("新建对话") {
                createNewSession()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("chat.newSessionButton")
        }
    }

    private func createNewSession() {
        let newSession = Session()
        newSession.defaultExecutionProviderID = AppSettings.getOrCreate(in: modelContext).defaultExecutionProviderID
        modelContext.insert(newSession)
        try? modelContext.save()
        workspaceState.selectedSession = newSession
        workbenchState.selectedItem = .sessions
    }
}
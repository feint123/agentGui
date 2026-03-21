import SwiftUI
import SwiftData

struct WorkbenchShellView: View {
    @State private var workspaceState = WorkspaceState()
    @State private var workbenchState = WorkbenchState(selectedItem: TestLaunchOptions.current.initialWorkbenchItem)
    @State private var gitPanelViewModel = GitPanelViewModel()
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    @Environment(\.modelContext) private var modelContext
    private let launchOptions = TestLaunchOptions.current

    @Query(sort: \Session.updatedAt, order: .reverse)
    private var sessions: [Session]

    init() {}

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkbenchSidebarView()
                .navigationTitle(workbenchState.selectedItem.title)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } content: {
            FileEditorView()
                .accessibilityIdentifier("panel.editor")
                .navigationSplitViewColumnWidth(min: 280, ideal: 400)
        } detail: {
            if let session = workspaceState.selectedSession {
                ChatView(session: session)
                    .accessibilityIdentifier("panel.chat")
            } else {
                emptyDetailState
                    .accessibilityIdentifier("panel.chat.empty")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(workspaceState)
        .environment(workbenchState)
        .environment(gitPanelViewModel)
        .onAppear(perform: configureInitialSelection)
        .onChange(of: sessions, initial: false, synchronizeSessionSelection)
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
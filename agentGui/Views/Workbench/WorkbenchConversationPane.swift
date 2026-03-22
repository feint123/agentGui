import SwiftUI
import SwiftData

struct WorkbenchConversationPane: View {
    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(WorkbenchState.self) private var workbenchState
    @Environment(WorkbenchContextWindowState.self) private var contextWindowState
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if let session = workspaceState.selectedSession {
                ChatView(session: session, showsNavigationChrome: false)
                    .accessibilityIdentifier("panel.chat")
            } else {
                emptyState
                    .accessibilityIdentifier("panel.chat.empty")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: openContextWindow) {
                    Image(systemName: contextWindowSystemImage)
                }
                .help(contextWindowHelpText)
                .disabled(!contextWindowState.hasTabs && workspaceState.detailSelection == .none)
                .accessibilityIdentifier("workbench.openContextWindow")
            }
        }
    }

    private var contextWindowSystemImage: String {
        contextWindowState.hasTabs ? "rectangle.stack" : "macwindow.on.rectangle"
    }

    private var contextWindowHelpText: String {
        contextWindowState.hasTabs ? "显示上下文窗口" : "打开当前上下文"
    }

    private var emptyState: some View {
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

    private func openContextWindow() {
        workspaceState.openContextWindow()
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
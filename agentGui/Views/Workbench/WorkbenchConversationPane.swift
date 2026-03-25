import SwiftUI
import SwiftData

struct WorkbenchConversationPane: View {
    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(WorkbenchState.self) private var workbenchState
    @Environment(WorkbenchContextWindowState.self) private var contextWindowState
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ZStack {
            if let session = workspaceState.selectedSession {
                ChatView(session: session, showsNavigationChrome: false)
                    .id(session.sessionId)
                    .accessibilityIdentifier("panel.chat")
            } else {
                emptyState
                    .id("chat-empty-state")
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
        VStack {
            Spacer(minLength: 0)

            WorkbenchConversationEmptyStateCard(
                buttonAccessibilityIdentifier: "chat.newSessionButton"
            ) {
                NewSessionExecutionProviderMenu(onSelect: createNewSession(providerID:)) {
                    Label("新建对话", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: 380)
            .padding(.horizontal, 24)

            Spacer(minLength: 0)
        }
    }

    private func openContextWindow() {
        workspaceState.openContextWindow()
    }

    private func createNewSession(providerID: ConversationExecutionProviderID) {
        let newSession = Session()
        newSession.defaultExecutionProviderID = providerID.rawValue
        modelContext.insert(newSession)
        try? modelContext.save()
        withAnimation(.snappy(duration: 0.24, extraBounce: 0.03)) {
            workspaceState.selectedSession = newSession
            workbenchState.selectedItem = .sessions
        }
    }

    private var chatTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .center)),
            removal: .opacity.combined(with: .move(edge: .bottom))
        )
    }
}
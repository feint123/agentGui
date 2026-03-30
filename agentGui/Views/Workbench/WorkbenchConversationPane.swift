import SwiftUI
import SwiftData

struct WorkbenchConversationPane: View {
    enum Surface: Equatable {
        case chat
        case agentTeam
    }

    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(WorkbenchState.self) private var workbenchState
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ZStack {
            if let session = workspaceState.selectedSession {
                contentView(for: session)
                    .id(session.sessionId)
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
                .disabled(workspaceState.detailSelection == .none)
                .accessibilityIdentifier("workbench.openContextWindow")
            }
        }
    }

    @ViewBuilder
    private func contentView(for session: Session) -> some View {
        switch Self.surface(for: session) {
        case .chat:
            ChatView(session: session, showsNavigationChrome: false)
                .accessibilityIdentifier("panel.chat")
        case .agentTeam:
            AgentTeamSessionView(session: session)
        }
    }

    private var contextWindowSystemImage: String {
        "macwindow.on.rectangle"
    }

    private var contextWindowHelpText: String {
        workspaceState.detailSelection == .none ? "当前没有可打开的上下文" : "打开当前上下文"
    }

    private var emptyState: some View {
        VStack {
            Spacer(minLength: 0)

            WorkbenchConversationEmptyStateCard(
                buttonAccessibilityIdentifier: "chat.newSessionButton"
            ) {
                NewSessionExecutionProviderMenu(
                    sourceSession: workspaceState.selectedSession,
                    onSelect: createNewSession(action:)
                ) {
                    Label("新建对话", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: 380, maxHeight: 240)
            .padding(.horizontal, 24)

            Spacer(minLength: 0)
        }
    }

    private func openContextWindow() {
        workspaceState.openContextWindow()
    }

    private func createNewSession(action: NewSessionMenuAction) {
        do {
            let createdSession: Session
            switch action {
            case .localChat(let providerReference, _):
                let newSession = Session()
                newSession.defaultExecutionProviderReference = providerReference
                modelContext.insert(newSession)
                try modelContext.save()
                createdSession = newSession
            case .agentTeam(let source):
                createdSession = try AgentTeamSessionFactory()
                    .create(fromSourceContext: source, modelContext: modelContext)
                    .session
            }

            withAnimation(.snappy(duration: 0.24, extraBounce: 0.03)) {
                workspaceState.selectedSession = createdSession
                workbenchState.selectedItem = .sessions
            }
        } catch {
        }
    }

    private var chatTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .center)),
            removal: .opacity.combined(with: .move(edge: .bottom))
        )
    }

    static func surface(for session: Session) -> Surface {
        switch session.kind {
        case .agentTeam:
            return .agentTeam
        case .local, .channel, .backgroundTask:
            return .chat
        }
    }
}
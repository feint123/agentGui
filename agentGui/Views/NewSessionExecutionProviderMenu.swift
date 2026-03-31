import SwiftUI
import SwiftData

enum NewSessionMenuAction: Equatable, Identifiable, Sendable {
    struct SourceContext: Equatable, Sendable {
        let sessionID: String
        let title: String
        let defaultExecutionProviderReference: ExecutionProviderReference

        init(
            sessionID: String,
            title: String,
            defaultExecutionProviderReference: ExecutionProviderReference
        ) {
            self.sessionID = sessionID
            self.title = title
            self.defaultExecutionProviderReference = defaultExecutionProviderReference
        }

        init(session: Session) {
            self.sessionID = session.sessionId
            self.title = session.title
            self.defaultExecutionProviderReference = session.defaultExecutionProviderReference
        }
    }

    case localChat(providerReference: ExecutionProviderReference, title: String)
    case agentTeam(source: SourceContext?)

    var id: String {
        switch self {
        case .localChat(let providerReference, _):
            return "localChat:\(providerReference.persistedValue)"
        case .agentTeam(let source):
            return "agentTeam:\(source?.sessionID ?? "standalone")"
        }
    }

    var title: String {
        switch self {
        case .localChat(_, let title):
            return title
        case .agentTeam:
            return "Team Mode"
        }
    }

    var accessibilityIdentifier: String? {
        switch self {
        case .localChat:
            return nil
        case .agentTeam:
            return "sessionList.create.agentTeam"
        }
    }
}

struct NewSessionExecutionProviderMenu<Label: View>: View {
    @Environment(\.modelContext) private var modelContext

    let options: [ExecutionOptionItem]
    let sourceSession: Session?
    let accessibilityIdentifier: String?
    let onSelect: (NewSessionMenuAction) -> Void
    let label: () -> Label

    init(
        options: [ExecutionOptionItem]? = nil,
        sourceSession: Session? = nil,
        accessibilityIdentifier: String? = nil,
        onSelect: @escaping (NewSessionMenuAction) -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.options = options ?? []
        self.sourceSession = sourceSession
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onSelect = onSelect
        self.label = label
    }

    var body: some View {
        Menu {
            ForEach(resolvedActions) { action in
                Button(action.title) {
                    onSelect(action)
                }
                .applyAccessibilityIdentifier(action.accessibilityIdentifier)
                .disabled(isActionEnabled(action) == false)

                if action.id == resolvedActions.first?.id,
                   action.isAgentTeam,
                   resolvedActions.count > 1 {
                    Divider()
                }
            }
        } label: {
            label()
        }
        .applyAccessibilityIdentifier(accessibilityIdentifier)
    }

    private var resolvedOptions: [ExecutionOptionItem] {
        if options.isEmpty == false {
            return options
        }

        let store = SettingsStore(modelContext: modelContext, persistenceCoordinator: nil)
        return store.defaultExecutionProviderOptions()
    }

    private var resolvedActions: [NewSessionMenuAction] {
        Self.buildActions(providerOptions: resolvedOptions, sourceSession: sourceSession)
    }

    private func isActionEnabled(_ action: NewSessionMenuAction) -> Bool {
        switch action {
        case .localChat(let providerReference, _):
            return resolvedOptions.first(where: {
                ExecutionProviderReference.decodePersisted($0.id) == providerReference
            })?.isEnabled ?? true
        case .agentTeam:
            return true
        }
    }

    static func buildActions(
        providerOptions: [ExecutionOptionItem],
        sourceSession: Session?
    ) -> [NewSessionMenuAction] {
        let sourceContext = sourceSession.map(NewSessionMenuAction.SourceContext.init(session:))
        let providerActions = providerOptions.map {
            NewSessionMenuAction.localChat(
                providerReference: ExecutionProviderReference.decodePersisted($0.id),
                title: $0.title
            )
        }
        return [.agentTeam(source: sourceContext)] + providerActions
    }
}

private extension NewSessionMenuAction {
    var isAgentTeam: Bool {
        if case .agentTeam = self {
            return true
        }
        return false
    }
}

import Foundation
import SwiftData

@MainActor
struct AgentTeamSessionFactory {
    struct Result {
        let session: Session
        let state: AgentTeamSessionState
    }

    func create(from source: Session?, modelContext: ModelContext) throws -> Result {
        try create(
            fromSourceContext: source.map(NewSessionMenuAction.SourceContext.init(session:)),
            modelContext: modelContext
        )
    }

    func create(
        fromSourceContext sourceContext: NewSessionMenuAction.SourceContext?,
        modelContext: ModelContext
    ) throws -> Result {
        let sessionTitle = makeSessionTitle(from: sourceContext)
        let session = Session(title: sessionTitle, kind: .agentTeam)
        if let sourceContext {
            session.defaultExecutionProviderReference = sourceContext.defaultExecutionProviderReference
        }

        let state = AgentTeamSessionState(
            session: session,
            sourceSessionID: sourceContext?.sessionID ?? "",
            sourceSessionTitle: sourceContext?.title ?? ""
        )
        session.agentTeamState = state

        modelContext.insert(session)
        modelContext.insert(state)
        try modelContext.save()

        return Result(session: session, state: state)
    }

    private func makeSessionTitle(from sourceContext: NewSessionMenuAction.SourceContext?) -> String {
        guard let sourceContext else {
            return SessionKind.agentTeam.defaultSourceTitle
        }

        let trimmedTitle = sourceContext.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.isEmpty == false else {
            return SessionKind.agentTeam.defaultSourceTitle
        }

        return "\(trimmedTitle) · Team"
    }
}
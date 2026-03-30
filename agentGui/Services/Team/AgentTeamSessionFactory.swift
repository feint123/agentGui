import Foundation
import SwiftData

@MainActor
struct AgentTeamSessionFactory {
    struct Result {
        let session: Session
        let state: AgentTeamSessionState
    }

    func create(from source: Session?, modelContext: ModelContext) throws -> Result {
        let sourceContext = source.map(NewSessionMenuAction.SourceContext.init(session:))
        let fallbackBrief = AgentTeamMissionBriefResolver.fallbackBrief(
            sessionTitle: makeSessionTitle(from: sourceContext),
            sourceTitle: sourceContext?.title,
            mode: .executionDelivery
        )
        return try create(
            fromSourceContext: sourceContext,
            brief: fallbackBrief,
            modelContext: modelContext
        )
    }

    func create(
        from source: Session?,
        draft: AgentTeamMissionBriefDraft,
        modelContext: ModelContext
    ) throws -> Result {
        try create(
            fromSourceContext: source.map(NewSessionMenuAction.SourceContext.init(session:)),
            draft: draft,
            modelContext: modelContext
        )
    }

    func create(
        fromSourceContext sourceContext: NewSessionMenuAction.SourceContext?,
        modelContext: ModelContext
    ) throws -> Result {
        let fallbackBrief = AgentTeamMissionBriefResolver.fallbackBrief(
            sessionTitle: makeSessionTitle(from: sourceContext),
            sourceTitle: sourceContext?.title,
            mode: .executionDelivery
        )
        return try create(
            fromSourceContext: sourceContext,
            brief: fallbackBrief,
            modelContext: modelContext
        )
    }

    func create(
        fromSourceContext sourceContext: NewSessionMenuAction.SourceContext?,
        draft: AgentTeamMissionBriefDraft,
        modelContext: ModelContext
    ) throws -> Result {
        try create(
            fromSourceContext: sourceContext,
            brief: draft.buildBrief(),
            modelContext: modelContext
        )
    }

    func create(
        fromSourceContext sourceContext: NewSessionMenuAction.SourceContext?,
        brief: AgentTeamMissionBrief,
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
            sourceSessionTitle: sourceContext?.title ?? "",
            mode: brief.mode
        )
        state.missionBrief = brief
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
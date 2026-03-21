import Foundation
import SwiftData

struct BackgroundTaskSessionFactory {
    @MainActor
    func ensureSession(
        for task: BackgroundAgentTask,
        desiredTitle: String,
        modelContext: ModelContext
    ) throws -> Session {
        let sessions = try modelContext.fetch(FetchDescriptor<Session>())

        if let session = dedicatedSession(in: sessions, matchingSessionID: task.sessionId, task: task) {
            configure(session: session, for: task, desiredTitle: desiredTitle)
            return session
        }

        if let session = sessions.first(where: {
            $0.kind == .backgroundTask && $0.sourceIdentifier == task.dedicatedSessionSourceIdentifier
        }) {
            configure(session: session, for: task, desiredTitle: desiredTitle)
            return session
        }

        let session = Session(
            title: task.dedicatedSessionTitle(fallbackTitle: desiredTitle),
            kind: .backgroundTask,
            sourceIdentifier: task.dedicatedSessionSourceIdentifier,
            sourceDisplayName: task.dedicatedSessionSourceDisplayName(fallbackTitle: desiredTitle),
            readOnlyReasonOverride: SessionKind.backgroundTask.defaultReadOnlyReason
        )
        configure(session: session, for: task, desiredTitle: desiredTitle)
        modelContext.insert(session)
        return session
    }

    @MainActor
    private func dedicatedSession(
        in sessions: [Session],
        matchingSessionID sessionID: String,
        task: BackgroundAgentTask
    ) -> Session? {
        guard let session = sessions.first(where: { $0.sessionId == sessionID }) else {
            return nil
        }

        guard session.kind == .backgroundTask || session.sourceIdentifier == task.dedicatedSessionSourceIdentifier else {
            return nil
        }

        return session
    }

    @MainActor
    private func configure(session: Session, for task: BackgroundAgentTask, desiredTitle: String) {
        session.kind = .backgroundTask
        session.title = task.dedicatedSessionTitle(fallbackTitle: desiredTitle)
        session.sourceIdentifier = task.dedicatedSessionSourceIdentifier
        session.sourceDisplayName = task.dedicatedSessionSourceDisplayName(fallbackTitle: desiredTitle)
        session.readOnlyReasonOverride = SessionKind.backgroundTask.defaultReadOnlyReason
        session.updatedAt = Date()
    }
}
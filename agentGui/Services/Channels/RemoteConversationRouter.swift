import Foundation
import SwiftData

@MainActor
struct RemoteConversationRouter {
    func resolveSession(for message: InboundChannelMessage, modelContext: ModelContext) throws -> Session {
        let bindings = try modelContext.fetch(FetchDescriptor<RemoteConversationBinding>())
        if let existingBinding = bindings.first(where: {
            $0.channelKind == message.channelKind &&
            $0.externalConversationID == message.externalConversationID
        }) {
            let sessions = try modelContext.fetch(FetchDescriptor<Session>())
            if let session = sessions.first(where: { $0.sessionId == existingBinding.sessionID }) {
                existingBinding.updatedAt = message.receivedAt
                try modelContext.save()
                return session
            }
        }

        let sessionTitle = makeSessionTitle(for: message)
        let session = Session(title: sessionTitle)
        let binding = RemoteConversationBinding(
            channelKind: message.channelKind,
            externalConversationID: message.externalConversationID,
            externalUserID: message.externalUserID,
            sessionID: session.sessionId,
            createdAt: message.receivedAt,
            updatedAt: message.receivedAt
        )
        modelContext.insert(session)
        modelContext.insert(binding)
        try modelContext.save()
        return session
    }

    private func makeSessionTitle(for message: InboundChannelMessage) -> String {
        let peer = message.externalUserID.isEmpty ? message.externalConversationID : message.externalUserID
        return "\(message.channelKind.displayName) · \(peer)"
    }
}
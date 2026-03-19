import Foundation
import SwiftData

@MainActor
struct RemoteConversationRouter {
    func resolveSession(for message: InboundChannelMessage, modelContext: ModelContext) throws -> Session {
        let bindings = try modelContext.fetch(FetchDescriptor<RemoteConversationBinding>())
        let sessions = try modelContext.fetch(FetchDescriptor<Session>())
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })
        let matchingBindings = bindings.filter {
            $0.channelKind == message.channelKind &&
            $0.externalConversationID == message.externalConversationID
        }
        var validBindings: [(binding: RemoteConversationBinding, session: Session)] = []
        var needsSave = false

        for binding in matchingBindings {
            if let session = binding.session {
                if binding.sessionID != session.sessionId {
                    binding.sessionID = session.sessionId
                    needsSave = true
                }
                validBindings.append((binding, session))
                continue
            }

            if let recoveredSession = sessionsByID[binding.sessionID] {
                binding.attach(to: recoveredSession)
                validBindings.append((binding, recoveredSession))
                needsSave = true
            } else {
                modelContext.delete(binding)
                needsSave = true
            }
        }

        if let selected = validBindings.max(by: { $0.binding.updatedAt < $1.binding.updatedAt }) {
            for duplicate in validBindings where duplicate.binding.id != selected.binding.id {
                modelContext.delete(duplicate.binding)
                needsSave = true
            }
            selected.binding.updatedAt = message.receivedAt
            selected.session.updatedAt = message.receivedAt
            try modelContext.save()
            return selected.session
        }

        let sessionTitle = makeSessionTitle(for: message)
        let session = Session(title: sessionTitle)
        let binding = RemoteConversationBinding(
            channelKind: message.channelKind,
            externalConversationID: message.externalConversationID,
            externalUserID: message.externalUserID,
            session: session,
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
import Foundation

struct SessionInteractionPolicy {
    let session: Session

    var canSend: Bool {
        session.isReadOnly == false
    }

    var canRename: Bool {
        switch session.kind {
        case .local, .agentTeam:
            return true
        case .channel, .backgroundTask:
            return false
        }
    }

    var canDelete: Bool {
        switch session.kind {
        case .local, .agentTeam:
            return true
        case .channel, .backgroundTask:
            return false
        }
    }

    var canClearMessages: Bool {
        session.kind == .local
    }

    var canCloneAsLocal: Bool {
        session.isReadOnly
    }

    var readOnlyReason: String {
        guard session.isReadOnly else { return "" }
        return session.readOnlyReason
    }
}
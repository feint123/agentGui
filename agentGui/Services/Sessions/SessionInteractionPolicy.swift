import Foundation

struct SessionInteractionPolicy {
    let session: Session

    var canSend: Bool {
        session.isReadOnly == false
    }

    var canRename: Bool {
        session.kind == .local
    }

    var canDelete: Bool {
        session.kind == .local
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
import Foundation

struct MessageAttachmentSnapshot: Equatable {
    let images: [String]
    let pdfs: [String]
    let others: [String]

    static let empty = MessageAttachmentSnapshot(images: [], pdfs: [], others: [])

    var hasMedia: Bool {
        !images.isEmpty || !pdfs.isEmpty
    }
}

struct UserRowSnapshot: Equatable {
    let bodyText: String
    let presentation: UserMessagePresentation
}

struct AgentRowSnapshot: Equatable {
    let attachments: MessageAttachmentSnapshot
    let execution: AgentExecutionProjection
    let hasAgentRounds: Bool

    var flow: AgentMessageFlowSnapshot {
        execution.audit.flow
    }
}

struct MessageRowSnapshot: Identifiable, Equatable {
    let id: UUID
    let direction: MessageDirection
    let status: MessageStatus
    let timestamp: Date
    let senderName: String
    let editableUserText: String?
    let user: UserRowSnapshot?
    let agent: AgentRowSnapshot?

    nonisolated static func make(for message: Message, workspaceRoot: String) -> MessageRowSnapshot {
        let userSnapshot: UserRowSnapshot?
        if message.direction == .user {
            let parsed = UserMessageTextParser.parse(text: message.textContent ?? "", workspaceRoot: workspaceRoot)
            userSnapshot = UserRowSnapshot(
                bodyText: parsed.bodyText,
                presentation: UserMessagePresentation.make(from: parsed)
            )
        } else {
            userSnapshot = nil
        }

        let agentSnapshot: AgentRowSnapshot?
        if message.direction == .user {
            agentSnapshot = nil
        } else {
            agentSnapshot = AgentRowSnapshot(
                attachments: attachmentSnapshot(from: message.textContent ?? ""),
                execution: AgentMessageFlowPresentation.projection(for: message),
                hasAgentRounds: !message.agentRounds.isEmpty
            )
        }

        return MessageRowSnapshot(
            id: message.id,
            direction: message.direction,
            status: message.status,
            timestamp: message.timestamp,
            senderName: senderName(for: message.direction),
            editableUserText: userSnapshot?.bodyText,
            user: userSnapshot,
            agent: agentSnapshot
        )
    }

    nonisolated private static func senderName(for direction: MessageDirection) -> String {
        switch direction {
        case .user:
            return "你"
        case .agent:
            return "Claude"
        case .system:
            return "系统"
        }
    }

    nonisolated private static func attachmentSnapshot(from raw: String) -> MessageAttachmentSnapshot {
        let separator = "\n\nReferenced files:\n"
        guard let range = raw.range(of: separator) else {
            return .empty
        }

        let paths = raw[range.upperBound...]
            .split(separator: "\n")
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : String($0) }
            .filter { !$0.isEmpty }

        var images: [String] = []
        var pdfs: [String] = []
        var others: [String] = []

        for path in paths {
            if AttachedFile.pathIsImage(path) {
                images.append(path)
            } else if AttachedFile.pathIsPDF(path) {
                pdfs.append(path)
            } else {
                others.append(path)
            }
        }

        return MessageAttachmentSnapshot(images: images, pdfs: pdfs, others: others)
    }
}
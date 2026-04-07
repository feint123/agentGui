import Foundation

struct MessageAttachmentSnapshot: Equatable, @unchecked Sendable {
    let images: [String]
    let pdfs: [String]
    let others: [String]

    static let empty = MessageAttachmentSnapshot(images: [], pdfs: [], others: [])

    var hasMedia: Bool {
        !images.isEmpty || !pdfs.isEmpty
    }

    // 从结构化条目构建
    static func fromStructured(_ entries: [AttachmentSnapshotEntry]) -> MessageAttachmentSnapshot {
        var images: [String] = []
        var pdfs: [String] = []
        var others: [String] = []
        for e in entries {
            switch AttachmentKind(rawValue: e.fileKindRaw) ?? .other {
            case .image:                         images.append(e.filePath)
            case .pdf:                           pdfs.append(e.filePath)
            case .sourceCode, .directory, .other: others.append(e.filePath)
            }
        }
        return MessageAttachmentSnapshot(images: images, pdfs: pdfs, others: others)
    }
}

struct UserRowSnapshot: Equatable, @unchecked Sendable {
    let bodyText: String
    let presentation: UserMessagePresentation
}

struct AgentRowSnapshot: Equatable, @unchecked Sendable {
    let attachments: MessageAttachmentSnapshot
    let execution: AgentExecutionProjection
    let hasAgentRounds: Bool

    var flow: AgentMessageFlowSnapshot {
        execution.audit.flow
    }
}

struct MessageRowSnapshot: Identifiable, Equatable, @unchecked Sendable {
    let id: UUID
    let direction: MessageDirection
    let status: MessageStatus
    let timestamp: Date
    let senderName: String
    let editableUserText: String?
    let user: UserRowSnapshot?
    let agent: AgentRowSnapshot?

    nonisolated static func make(for message: MessageRowBuildInput, workspaceRoot: String) -> MessageRowSnapshot {
        let userSnapshot: UserRowSnapshot?
        if message.direction == .user {
            var parsed = UserMessageTextParser.parse(text: message.textContent ?? "", workspaceRoot: workspaceRoot)
            if !message.structuredAttachments.isEmpty {
                parsed = parsed.replacingAttachments(with: message.structuredAttachments)
            }
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
            let attachments: MessageAttachmentSnapshot = message.structuredAttachments.isEmpty
                ? attachmentSnapshot(from: message.textContent ?? "")
                : MessageAttachmentSnapshot.fromStructured(message.structuredAttachments)
            agentSnapshot = AgentRowSnapshot(
                attachments: attachments,
                execution: AgentMessageFlowPresentation.projection(for: message),
                hasAgentRounds: !message.rounds.isEmpty
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
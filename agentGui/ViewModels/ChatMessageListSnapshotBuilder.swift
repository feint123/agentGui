import Foundation

@MainActor
final class CachedMessageRowSnapshot {
    let fingerprint: MessageRowFingerprint
    let snapshot: MessageRowSnapshot

    init(fingerprint: MessageRowFingerprint, snapshot: MessageRowSnapshot) {
        self.fingerprint = fingerprint
        self.snapshot = snapshot
    }
}

@MainActor
struct ChatMessageListSnapshot {
    let rows: [MessageRowSnapshot]
    let cache: [UUID: CachedMessageRowSnapshot]

    static let empty = ChatMessageListSnapshot(rows: [], cache: [:])

    func cachedEntry(for id: UUID) -> CachedMessageRowSnapshot? {
        cache[id]
    }
}

@MainActor
struct ChatMessageListProjectionTrigger: Equatable {
    let workspaceRoot: String
    let rowFingerprints: [MessageRowFingerprint]

    init(messages: [Message], workspaceRoot: String) {
        self.workspaceRoot = workspaceRoot
        self.rowFingerprints = messages.map { MessageRowFingerprint(message: $0, workspaceRoot: workspaceRoot) }
    }
}

@MainActor
enum ChatMessageListSnapshotBuilder {
    static func build(
        messages: [Message],
        workspaceRoot: String,
        previous: [UUID: CachedMessageRowSnapshot]
    ) -> ChatMessageListSnapshot {
        var rows: [MessageRowSnapshot] = []
        var cache: [UUID: CachedMessageRowSnapshot] = [:]

        for message in messages {
            let fingerprint = MessageRowFingerprint(message: message, workspaceRoot: workspaceRoot)
            if let cached = previous[message.id], cached.fingerprint == fingerprint {
                rows.append(cached.snapshot)
                cache[message.id] = cached
                continue
            }

            let snapshot = MessageRowSnapshot.make(for: message, workspaceRoot: workspaceRoot)
            let cached = CachedMessageRowSnapshot(fingerprint: fingerprint, snapshot: snapshot)
            rows.append(snapshot)
            cache[message.id] = cached
        }

        return ChatMessageListSnapshot(rows: rows, cache: cache)
    }
}

@MainActor
struct MessageRowFingerprint: Hashable {
    let workspaceRoot: String
    let messageID: UUID
    let direction: MessageDirection
    let status: MessageStatus
    let timestamp: Date
    let textContent: String?
    let errorMessage: String?
    let directToolCalls: [ToolCallFingerprint]
    let rounds: [AgentRoundFingerprint]

    init(message: Message, workspaceRoot: String) {
        self.workspaceRoot = workspaceRoot
        self.messageID = message.id
        self.direction = message.direction
        self.status = message.status
        self.timestamp = message.timestamp
        self.textContent = message.textContent
        self.errorMessage = message.errorMessage
        self.directToolCalls = message.toolCalls
            .filter { $0.agentRound == nil }
            .sorted { lhs, rhs in
                (lhs.startTime ?? .distantPast, lhs.id.uuidString) < (rhs.startTime ?? .distantPast, rhs.id.uuidString)
            }
            .map(ToolCallFingerprint.init)
        self.rounds = message.agentRounds
            .sorted { lhs, rhs in
                if lhs.roundIndex != rhs.roundIndex {
                    return lhs.roundIndex < rhs.roundIndex
                }
                return lhs.timestamp < rhs.timestamp
            }
            .map(AgentRoundFingerprint.init)
    }
}

@MainActor
struct AgentRoundFingerprint: Hashable {
    let id: UUID
    let roundIndex: Int
    let text: String?
    let thinkingContent: String?
    let thinkingSignature: String?
    let timestamp: Date
    let stopReason: String?
    let toolCalls: [ToolCallFingerprint]

    init(_ round: AgentRound) {
        self.id = round.id
        self.roundIndex = round.roundIndex
        self.text = round.text
        self.thinkingContent = round.thinkingContent
        self.thinkingSignature = round.thinkingSignature
        self.timestamp = round.timestamp
        self.stopReason = round.stopReason
        self.toolCalls = round.sortedToolCalls.map(ToolCallFingerprint.init)
    }
}

@MainActor
struct ToolCallFingerprint: Hashable {
    let id: UUID
    let toolCallId: String
    let kind: ToolKind
    let title: String?
    let status: ToolStatus
    let filePath: String?
    let diffContent: String?
    let terminalOutput: String?
    let toolResultSummary: String?
    let toolPayloadRef: String?
    let terminalTaskId: String?
    let terminalTaskStatus: String?
    let terminalPromptSummary: String?
    let terminalAgentActionsJSON: String?
    let terminalExecutionMode: String?
    let startTime: Date?
    let endTime: Date?
    let subagentAgentName: String?
    let subagentTask: String?
    let subagentResultKind: String?
    let subagentMessageMetadata: [MetadataPair]
    let memoryRuntimeProfiles: [String]
    let memoryRuntimeLayers: [String]
    let memoryRuntimeWarnings: [String]
    let memoryRuntimeSnapshotID: String?
    let memoryBackgroundConsolidationQueued: Bool?
    let memoryConflictRecordIDs: [String]
    let memoryConfirmationCandidateIDs: [String]
    let subagentRounds: [SubagentRoundFingerprint]

    init(_ toolCall: ToolCall) {
        self.id = toolCall.id
        self.toolCallId = toolCall.toolCallId
        self.kind = toolCall.kind
        self.title = toolCall.title
        self.status = toolCall.status
        self.filePath = toolCall.filePath
        self.diffContent = toolCall.diffContent
        self.terminalOutput = toolCall.terminalOutput
        self.toolResultSummary = toolCall.toolResultSummary
        self.toolPayloadRef = toolCall.toolPayloadRef
        self.terminalTaskId = toolCall.terminalTaskId
        self.terminalTaskStatus = toolCall.terminalTaskStatus
        self.terminalPromptSummary = toolCall.terminalPromptSummary
        self.terminalAgentActionsJSON = toolCall.terminalAgentActionsJSON
        self.terminalExecutionMode = toolCall.terminalExecutionMode
        self.startTime = toolCall.startTime
        self.endTime = toolCall.endTime
        self.subagentAgentName = toolCall.subagentAgentName
        self.subagentTask = toolCall.subagentTask
        self.subagentResultKind = toolCall.subagentResultKind
        self.subagentMessageMetadata = (toolCall.subagentMessageMetadata ?? [:])
            .map { MetadataPair(key: $0.key, value: $0.value) }
            .sorted { lhs, rhs in lhs.key < rhs.key }
        self.memoryRuntimeProfiles = toolCall.memoryRuntimeProfiles ?? []
        self.memoryRuntimeLayers = toolCall.memoryRuntimeLayers ?? []
        self.memoryRuntimeWarnings = toolCall.memoryRuntimeWarnings ?? []
        self.memoryRuntimeSnapshotID = toolCall.memoryRuntimeSnapshotID
        self.memoryBackgroundConsolidationQueued = toolCall.memoryBackgroundConsolidationQueued
        self.memoryConflictRecordIDs = toolCall.memoryConflictRecordIDs ?? []
        self.memoryConfirmationCandidateIDs = toolCall.memoryConfirmationCandidateIDs ?? []
        self.subagentRounds = toolCall.subagentRounds
            .sorted { lhs, rhs in
                if lhs.roundIndex != rhs.roundIndex {
                    return lhs.roundIndex < rhs.roundIndex
                }
                return lhs.timestamp < rhs.timestamp
            }
            .map(SubagentRoundFingerprint.init)
    }
}

@MainActor
struct SubagentRoundFingerprint: Hashable {
    let id: UUID
    let roundIndex: Int
    let text: String?
    let thinkingContent: String?
    let timestamp: Date
    let stopReason: String?

    init(_ round: AgentRound) {
        self.id = round.id
        self.roundIndex = round.roundIndex
        self.text = round.text
        self.thinkingContent = round.thinkingContent
        self.timestamp = round.timestamp
        self.stopReason = round.stopReason
    }
}

@MainActor
struct MetadataPair: Hashable {
    let key: String
    let value: String
}
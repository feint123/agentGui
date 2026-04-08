import Foundation

protocol ChatMessageListProjectionWorking: Sendable {
    func build(request: ChatMessageListBuildRequest) async throws -> ChatMessageListBuildResult
}

struct WorkspaceDependencyFingerprint: Hashable, @unchecked Sendable {
    let workspaceRoot: String
    let requiresWorkspaceRoot: Bool
}

/// 轻量附件摘要，不依赖 SwiftData，跨 Actor 安全传递。
struct AttachmentSnapshotEntry: Hashable, Identifiable, @unchecked Sendable {
    let id: UUID
    let filePath: String
    let displayName: String
    let fileKindRaw: String
    let statusRaw: String
    let lineStart: Int?    // 行范围起始
    let lineEnd: Int?      // 行范围结束

    @MainActor
    init(_ a: MessageAttachment) {
        self.id = a.id
        self.filePath = a.filePath
        self.displayName = a.displayName
        self.fileKindRaw = a.fileKindRaw
        self.statusRaw = a.statusRaw
        self.lineStart = a.lineStart
        self.lineEnd = a.lineEnd
    }

    // 测试用（手动初始化，保持向后兼容）
    init(id: UUID, filePath: String, displayName: String, fileKindRaw: String, statusRaw: String,
         lineStart: Int? = nil, lineEnd: Int? = nil) {
        self.id = id
        self.filePath = filePath
        self.displayName = displayName
        self.fileKindRaw = fileKindRaw
        self.statusRaw = statusRaw
        self.lineStart = lineStart
        self.lineEnd = lineEnd
    }
}

struct SubagentRoundProjectionInput: Identifiable, Hashable, @unchecked Sendable {
    let id: UUID
    let roundIndex: Int
    let text: String?
    let thinkingContent: String?
    let timestamp: Date
    let stopReason: String?
    let toolCalls: [ToolCallProjectionInput]

    @MainActor
    init(_ round: AgentRound) {
        self.id = round.id
        self.roundIndex = round.roundIndex
        self.text = round.text
        self.thinkingContent = round.thinkingContent
        self.timestamp = round.timestamp
        self.stopReason = round.stopReason
        self.toolCalls = round.sortedToolCalls.map(ToolCallProjectionInput.init)
    }
}

struct ToolCallProjectionInput: Identifiable, Hashable, @unchecked Sendable {
    let id: UUID
    let toolCallId: String
    let kind: ToolKind
    let isPermissionRequest: Bool
    let permissionTargetToolCallId: String?
    let title: String?
    let status: ToolStatus
    let filePath: String?
    let diffContent: String?
    let terminalOutput: String?
    let toolResultSummary: String?
    let toolPayloadRef: String?
    let terminalTaskId: String?
    let terminalTaskStatus: String?
    let terminalInteractionPhase: String?
    let terminalPlannerSummary: String?
    let terminalApprovalPending: Bool
    let terminalUserTakeoverActive: Bool
    let terminalPromptSummary: String?
    let terminalAgentActionsJSON: String?
    let terminalExecutionMode: String?
    let terminalTranscriptPath: String?
    let terminalCompletionReason: String?
    let startTime: Date?
    let endTime: Date?
    let localSessionID: String?
    let subagentAgentName: String?
    let subagentTask: String?
    let subagentResultKind: String?
    let subagentMessageMetadata: [MetadataPair]
    let subagentRounds: [SubagentRoundProjectionInput]
    let changeProposalStateRaw: String?
    let memoryRuntimeProfiles: [String]
    let memoryRuntimeLayers: [String]
    let memoryRuntimeWarnings: [String]
    let memoryRuntimeSnapshotID: String?
    let memoryBackgroundConsolidationQueued: Bool?
    let memoryConflictRecordIDs: [String]
    let memoryConfirmationCandidateIDs: [String]

    @MainActor
    init(_ toolCall: ToolCall) {
        self.id = toolCall.id
        self.toolCallId = toolCall.toolCallId
        self.kind = toolCall.kind
        self.isPermissionRequest = toolCall.isPermissionRequest
        self.permissionTargetToolCallId = toolCall.permissionTargetToolCallId
        self.title = toolCall.title
        self.status = toolCall.status
        self.filePath = toolCall.filePath
        self.diffContent = toolCall.diffContent
        self.terminalOutput = toolCall.terminalOutput
        self.toolResultSummary = toolCall.toolResultSummary
        self.toolPayloadRef = toolCall.toolPayloadRef
        self.terminalTaskId = toolCall.terminalTaskId
        self.terminalTaskStatus = toolCall.terminalTaskStatus
        self.terminalInteractionPhase = toolCall.terminalInteractionPhase
        self.terminalPlannerSummary = toolCall.terminalPlannerSummary
        self.terminalApprovalPending = toolCall.terminalApprovalPending
        self.terminalUserTakeoverActive = toolCall.terminalUserTakeoverActive
        self.terminalPromptSummary = toolCall.terminalPromptSummary
        self.terminalAgentActionsJSON = toolCall.terminalAgentActionsJSON
        self.terminalExecutionMode = toolCall.terminalExecutionMode
        self.terminalTranscriptPath = toolCall.terminalTranscriptPath
        self.terminalCompletionReason = toolCall.terminalCompletionReason
        self.startTime = toolCall.startTime
        self.endTime = toolCall.endTime
        self.localSessionID = toolCall.message?.session?.sessionId ?? toolCall.agentRound?.message?.session?.sessionId
        self.subagentAgentName = toolCall.subagentAgentName
        self.subagentTask = toolCall.subagentTask
        self.subagentResultKind = toolCall.subagentResultKind
        self.subagentMessageMetadata = (toolCall.subagentMessageMetadata ?? [:])
            .map { MetadataPair(key: $0.key, value: $0.value) }
            .sorted { lhs, rhs in lhs.key < rhs.key }
        self.subagentRounds = toolCall.subagentRounds
            .sorted { lhs, rhs in
                if lhs.roundIndex != rhs.roundIndex {
                    return lhs.roundIndex < rhs.roundIndex
                }
                return lhs.timestamp < rhs.timestamp
            }
            .map(SubagentRoundProjectionInput.init)
        self.changeProposalStateRaw = toolCall.changeProposalStateRaw
        self.memoryRuntimeProfiles = toolCall.memoryRuntimeProfiles ?? []
        self.memoryRuntimeLayers = toolCall.memoryRuntimeLayers ?? []
        self.memoryRuntimeWarnings = toolCall.memoryRuntimeWarnings ?? []
        self.memoryRuntimeSnapshotID = toolCall.memoryRuntimeSnapshotID
        self.memoryBackgroundConsolidationQueued = toolCall.memoryBackgroundConsolidationQueued
        self.memoryConflictRecordIDs = toolCall.memoryConflictRecordIDs ?? []
        self.memoryConfirmationCandidateIDs = toolCall.memoryConfirmationCandidateIDs ?? []
    }

    init(
        id: UUID,
        toolCallId: String,
        kind: ToolKind,
        isPermissionRequest: Bool = false,
        permissionTargetToolCallId: String? = nil,
        title: String? = nil,
        status: ToolStatus,
        filePath: String? = nil,
        diffContent: String? = nil,
        terminalOutput: String? = nil,
        toolResultSummary: String? = nil,
        toolPayloadRef: String? = nil,
        terminalTaskId: String? = nil,
        terminalTaskStatus: String? = nil,
        terminalInteractionPhase: String? = nil,
        terminalPlannerSummary: String? = nil,
        terminalApprovalPending: Bool = false,
        terminalUserTakeoverActive: Bool = false,
        terminalPromptSummary: String? = nil,
        terminalAgentActionsJSON: String? = nil,
        terminalExecutionMode: String? = nil,
        terminalTranscriptPath: String? = nil,
        terminalCompletionReason: String? = nil,
        startTime: Date? = nil,
        endTime: Date? = nil,
        localSessionID: String? = nil,
        subagentAgentName: String? = nil,
        subagentTask: String? = nil,
        subagentResultKind: String? = nil,
        subagentMessageMetadata: [MetadataPair] = [],
        subagentRounds: [SubagentRoundProjectionInput] = [],
        changeProposalStateRaw: String? = nil,
        memoryRuntimeProfiles: [String] = [],
        memoryRuntimeLayers: [String] = [],
        memoryRuntimeWarnings: [String] = [],
        memoryRuntimeSnapshotID: String? = nil,
        memoryBackgroundConsolidationQueued: Bool? = nil,
        memoryConflictRecordIDs: [String] = [],
        memoryConfirmationCandidateIDs: [String] = []
    ) {
        self.id = id
        self.toolCallId = toolCallId
        self.kind = kind
        self.isPermissionRequest = isPermissionRequest
        self.permissionTargetToolCallId = permissionTargetToolCallId
        self.title = title
        self.status = status
        self.filePath = filePath
        self.diffContent = diffContent
        self.terminalOutput = terminalOutput
        self.toolResultSummary = toolResultSummary
        self.toolPayloadRef = toolPayloadRef
        self.terminalTaskId = terminalTaskId
        self.terminalTaskStatus = terminalTaskStatus
        self.terminalInteractionPhase = terminalInteractionPhase
        self.terminalPlannerSummary = terminalPlannerSummary
        self.terminalApprovalPending = terminalApprovalPending
        self.terminalUserTakeoverActive = terminalUserTakeoverActive
        self.terminalPromptSummary = terminalPromptSummary
        self.terminalAgentActionsJSON = terminalAgentActionsJSON
        self.terminalExecutionMode = terminalExecutionMode
        self.terminalTranscriptPath = terminalTranscriptPath
        self.terminalCompletionReason = terminalCompletionReason
        self.startTime = startTime
        self.endTime = endTime
        self.localSessionID = localSessionID
        self.subagentAgentName = subagentAgentName
        self.subagentTask = subagentTask
        self.subagentResultKind = subagentResultKind
        self.subagentMessageMetadata = subagentMessageMetadata
        self.subagentRounds = subagentRounds
        self.changeProposalStateRaw = changeProposalStateRaw
        self.memoryRuntimeProfiles = memoryRuntimeProfiles
        self.memoryRuntimeLayers = memoryRuntimeLayers
        self.memoryRuntimeWarnings = memoryRuntimeWarnings
        self.memoryRuntimeSnapshotID = memoryRuntimeSnapshotID
        self.memoryBackgroundConsolidationQueued = memoryBackgroundConsolidationQueued
        self.memoryConflictRecordIDs = memoryConflictRecordIDs
        self.memoryConfirmationCandidateIDs = memoryConfirmationCandidateIDs
    }

    nonisolated var duration: TimeInterval? {
        guard let startTime, let endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }

    nonisolated var statusDisplay: String {
        status.displayName
    }

    nonisolated var displayPath: String? {
        guard let filePath else { return nil }
        let components = filePath.components(separatedBy: "/")
        if components.count > 3 {
            return ".../" + components.suffix(2).joined(separator: "/")
        }
        return filePath
    }

    nonisolated var fileName: String? {
        guard let filePath else { return nil }
        return (filePath as NSString).lastPathComponent
    }

    nonisolated var verifierPassed: Bool? {
        guard let raw = subagentMessageMetadata.first(where: { $0.key == "verificationPassed" })?.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return nil
        }

        switch raw {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    nonisolated var verifierSummary: String? {
        let summary = subagentMessageMetadata.first(where: { $0.key == "verificationSummary" })?.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (summary?.isEmpty == false) ? summary : nil
    }

    nonisolated var verifierVerdictText: String? {
        guard let verifierPassed else { return nil }
        return verifierPassed ? "验证通过" : "验证失败"
    }

    nonisolated var permissionLookupToolCallId: String {
        permissionTargetToolCallId ?? toolCallId
    }
}

struct AgentRoundProjectionInput: Identifiable, Hashable, @unchecked Sendable {
    let id: UUID
    let roundIndex: Int
    let text: String?
    let thinkingContent: String?
    let thinkingSignature: String?
    let timestamp: Date
    let stopReason: String?
    let toolCalls: [ToolCallProjectionInput]

    @MainActor
    init(_ round: AgentRound) {
        self.id = round.id
        self.roundIndex = round.roundIndex
        self.text = round.text
        self.thinkingContent = round.thinkingContent
        self.thinkingSignature = round.thinkingSignature
        self.timestamp = round.timestamp
        self.stopReason = round.stopReason
        self.toolCalls = round.sortedToolCalls.map(ToolCallProjectionInput.init)
    }
}

struct MessageRowBuildInput: Identifiable, Hashable, @unchecked Sendable {
    let id: UUID
    let direction: MessageDirection
    let status: MessageStatus
    let timestamp: Date
    let textContent: String?
    let errorMessage: String?
    let directToolCalls: [ToolCallProjectionInput]
    let rounds: [AgentRoundProjectionInput]
    let structuredAttachments: [AttachmentSnapshotEntry]
    let workspaceDependency: WorkspaceDependencyFingerprint?

    @MainActor
    init(message: Message, workspaceRoot: String) {
        let textContent = message.textContent
        self.id = message.id
        self.direction = message.direction
        self.status = message.status
        self.timestamp = message.timestamp
        self.textContent = textContent
        self.errorMessage = message.errorMessage
        self.directToolCalls = message.toolCalls
            .filter { $0.agentRound == nil }
            .sorted { lhs, rhs in
                (lhs.startTime ?? .distantPast, lhs.id.uuidString) < (rhs.startTime ?? .distantPast, rhs.id.uuidString)
            }
            .map(ToolCallProjectionInput.init)
        self.rounds = message.agentRounds
            .sorted { lhs, rhs in
                if lhs.roundIndex != rhs.roundIndex {
                    return lhs.roundIndex < rhs.roundIndex
                }
                return lhs.timestamp < rhs.timestamp
            }
            .map(AgentRoundProjectionInput.init)
        self.structuredAttachments = message.attachments.map(AttachmentSnapshotEntry.init)

        if message.direction == .user,
           let textContent,
           UserMessageTextParser.parse(text: textContent, workspaceRoot: workspaceRoot)
            != UserMessageTextParser.parse(text: textContent, workspaceRoot: "") {
            self.workspaceDependency = WorkspaceDependencyFingerprint(
                workspaceRoot: workspaceRoot,
                requiresWorkspaceRoot: true
            )
        } else {
            self.workspaceDependency = nil
        }
    }

    init(
        id: UUID,
        direction: MessageDirection = .user,
        status: MessageStatus = .completed,
        timestamp: Date = Date(),
        textContent: String? = nil,
        errorMessage: String? = nil,
        directToolCalls: [ToolCallProjectionInput] = [],
        rounds: [AgentRoundProjectionInput] = [],
        structuredAttachments: [AttachmentSnapshotEntry] = [],
        workspaceDependency: WorkspaceDependencyFingerprint? = nil
    ) {
        self.id = id
        self.direction = direction
        self.status = status
        self.timestamp = timestamp
        self.textContent = textContent
        self.errorMessage = errorMessage
        self.directToolCalls = directToolCalls
        self.rounds = rounds
        self.structuredAttachments = structuredAttachments
        self.workspaceDependency = workspaceDependency
    }

    static func fixture(
        id: UUID = UUID(),
        direction: MessageDirection = .user,
        status: MessageStatus = .completed,
        timestamp: Date = Date(),
        textContent: String? = "fixture",
        errorMessage: String? = nil,
        directToolCalls: [ToolCallProjectionInput] = [],
        rounds: [AgentRoundProjectionInput] = [],
        structuredAttachments: [AttachmentSnapshotEntry] = [],
        workspaceDependency: WorkspaceDependencyFingerprint? = nil
    ) -> MessageRowBuildInput {
        MessageRowBuildInput(
            id: id,
            direction: direction,
            status: status,
            timestamp: timestamp,
            textContent: textContent,
            errorMessage: errorMessage,
            directToolCalls: directToolCalls,
            rounds: rounds,
            structuredAttachments: structuredAttachments,
            workspaceDependency: workspaceDependency
        )
    }
}

struct ChatMessageListBuildRequest: @unchecked Sendable {
    let generation: UInt64
    let workspaceRoot: String
    let messages: [MessageRowBuildInput]
    let previousCache: [UUID: CachedMessageRowSnapshot]

    @MainActor
    static func make(
        messages: [Message],
        workspaceRoot: String,
        previousCache: [UUID: CachedMessageRowSnapshot],
        generation: UInt64
    ) -> ChatMessageListBuildRequest {
        ChatMessageListBuildRequest(
            generation: generation,
            workspaceRoot: workspaceRoot,
            messages: messages.map { MessageRowBuildInput(message: $0, workspaceRoot: workspaceRoot) },
            previousCache: previousCache
        )
    }
}

struct CachedMessageRowSnapshot: @unchecked Sendable {
    let semanticFingerprint: MessageRowSemanticFingerprint
    let workspaceDependency: WorkspaceDependencyFingerprint?
    let snapshot: MessageRowSnapshot
}

struct ChatMessageListSnapshot: @unchecked Sendable {
    let rows: [MessageRowSnapshot]
    let cache: [UUID: CachedMessageRowSnapshot]

    static let empty = ChatMessageListSnapshot(rows: [], cache: [:])

    func cachedEntry(for id: UUID) -> CachedMessageRowSnapshot? {
        cache[id]
    }
}

struct ChatMessageListProjectionTrigger: Equatable, @unchecked Sendable {
    let rowFingerprints: [MessageRowSemanticFingerprint]
    let workspaceDependencies: [WorkspaceDependencyFingerprint?]

    @MainActor
    init(messages: [Message], workspaceRoot: String) {
        self.init(
            request: ChatMessageListBuildRequest.make(
                messages: messages,
                workspaceRoot: workspaceRoot,
                previousCache: [:],
                generation: 0
            )
        )
    }

    init(request: ChatMessageListBuildRequest) {
        self.rowFingerprints = request.messages.map(MessageRowSemanticFingerprint.init)
        self.workspaceDependencies = request.messages.map(\.workspaceDependency)
    }
}

struct ChatMessageListRefreshKey: Equatable, @unchecked Sendable {
    /// 每条消息的 ID + 状态 + textContent 哈希（三元组）。
    /// - 不访问 agentRounds / toolCalls，避免 O(N×M) 主线程排序。
    /// - 状态变化（pending → completed）和文本增量都会产生不同的 key，
    ///   保证 ProjectionModel.refresh 在正确时机被触发。
    struct RowDigest: Equatable {
        let id: UUID
        let status: MessageStatus
        /// 用字符数作为文本变化的廉价代理指标；避免拷贝整个字符串进行 Equatable 比较。
        let textLength: Int
        let workspaceDependency: WorkspaceDependencyFingerprint?
    }

    let rows: [RowDigest]

    @MainActor
    init(messages: [Message], workspaceRoot: String) {
        self.rows = messages.map { message in
            // 仅当 user message 的 textContent 依赖 workspaceRoot 时才记录 dependency。
            // 此判断复用 MessageRowBuildInput 里已有的逻辑，但更廉价：只需字符串相等对比。
            let dependency: WorkspaceDependencyFingerprint?
            if message.direction == .user,
               let text = message.textContent,
               !workspaceRoot.isEmpty,
               UserMessageTextParser.parse(text: text, workspaceRoot: workspaceRoot)
                != UserMessageTextParser.parse(text: text, workspaceRoot: "") {
                dependency = WorkspaceDependencyFingerprint(
                    workspaceRoot: workspaceRoot,
                    requiresWorkspaceRoot: true
                )
            } else {
                dependency = nil
            }
            return RowDigest(
                id: message.id,
                status: message.status,
                textLength: message.textContent?.count ?? 0,
                workspaceDependency: dependency
            )
        }
    }
}

enum ChatMessageListProjectionRefreshCoordinator {
    struct Result {
        let snapshot: ChatMessageListSnapshot
        let trigger: ChatMessageListProjectionTrigger
        let didRefresh: Bool
    }

    struct Plan {
        let trigger: ChatMessageListProjectionTrigger
        let requiresRefresh: Bool
    }

    static func plan(
        previousTrigger: ChatMessageListProjectionTrigger?,
        previousSnapshot: ChatMessageListSnapshot,
        request: ChatMessageListBuildRequest
    ) -> Plan {
        let trigger = ChatMessageListProjectionTrigger(request: request)
        let incomingIDs = request.messages.map(\.id)
        let snapshotIDs = previousSnapshot.rows.map(\.id)
        let snapshotConsistentWithMessages = snapshotIDs == incomingIDs

        return Plan(
            trigger: trigger,
            requiresRefresh: !(previousTrigger == trigger && snapshotConsistentWithMessages)
        )
    }

    @MainActor
    static func refresh(
        previousTrigger: ChatMessageListProjectionTrigger?,
        previousSnapshot: ChatMessageListSnapshot,
        messages: [Message],
        workspaceRoot: String
    ) -> Result {
        let request = ChatMessageListBuildRequest.make(
            messages: messages,
            workspaceRoot: workspaceRoot,
            previousCache: previousSnapshot.cache,
            generation: 0
        )
        let refreshPlan = plan(
            previousTrigger: previousTrigger,
            previousSnapshot: previousSnapshot,
            request: request
        )

        guard refreshPlan.requiresRefresh else {
            return Result(snapshot: previousSnapshot, trigger: refreshPlan.trigger, didRefresh: false)
        }

        let rebuiltSnapshot = ChatMessageListSnapshotBuilder.build(request: request)
        return Result(snapshot: rebuiltSnapshot.snapshot, trigger: refreshPlan.trigger, didRefresh: true)
    }
}

struct ChatMessageListBuildResult: @unchecked Sendable {
    let generation: UInt64
    let snapshot: ChatMessageListSnapshot
    let rebuiltRowIDs: [UUID]
    let reusedRowCount: Int
}

@Observable
@MainActor
final class ChatMessageListProjectionModel {
    private(set) var snapshot: ChatMessageListSnapshot = .empty
    private(set) var trigger: ChatMessageListProjectionTrigger?
    private(set) var isInitialLoadInFlight = true

    private let worker: any ChatMessageListProjectionWorking
    private var nextGeneration: UInt64 = 0
    private var activeTask: Task<Void, Never>?

    init(worker: (any ChatMessageListProjectionWorking)? = nil) {
        self.worker = worker ?? ChatMessageListProjectionWorker()
    }

    func refresh(
        messages: [Message],
        workspaceRoot: String,
        showsLoadingPlaceholder: Bool = false
    ) async {
        nextGeneration &+= 1
        let generation = nextGeneration

        let request = ChatMessageListBuildRequest.make(
            messages: messages,
            workspaceRoot: workspaceRoot,
            previousCache: snapshot.cache,
            generation: generation
        )
        let refreshPlan = ChatMessageListProjectionRefreshCoordinator.plan(
            previousTrigger: trigger,
            previousSnapshot: snapshot,
            request: request
        )

        if showsLoadingPlaceholder {
            isInitialLoadInFlight = true
        }

        guard refreshPlan.requiresRefresh else {
            trigger = refreshPlan.trigger
            if showsLoadingPlaceholder {
                isInitialLoadInFlight = false
            }
            return
        }

        activeTask?.cancel()
        let task = Task {
            do {
                let result = try await worker.build(request: request)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard result.generation == self.nextGeneration else { return }
                    self.snapshot = result.snapshot
                    self.trigger = refreshPlan.trigger
                    self.isInitialLoadInFlight = false
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard generation == self.nextGeneration else { return }
                    self.isInitialLoadInFlight = false
                }
            }
        }
        activeTask = task
        await task.value
    }
}

enum ChatMessageListSnapshotBuilder {
    nonisolated static func build(request: ChatMessageListBuildRequest) -> ChatMessageListBuildResult {
        var rows: [MessageRowSnapshot] = []
        var cache: [UUID: CachedMessageRowSnapshot] = [:]
        var rebuiltRowIDs: [UUID] = []
        var reusedRowCount = 0

        for message in request.messages {
            let semanticFingerprint = MessageRowSemanticFingerprint(message)
            if let cached = request.previousCache[message.id],
               cached.semanticFingerprint == semanticFingerprint,
               cached.workspaceDependency == message.workspaceDependency {
                rows.append(cached.snapshot)
                cache[message.id] = cached
                reusedRowCount += 1
                continue
            }

            let snapshot = MessageRowSnapshot.make(for: message, workspaceRoot: request.workspaceRoot)
            let cached = CachedMessageRowSnapshot(
                semanticFingerprint: semanticFingerprint,
                workspaceDependency: message.workspaceDependency,
                snapshot: snapshot
            )
            rows.append(snapshot)
            cache[message.id] = cached
            rebuiltRowIDs.append(message.id)
        }

        return ChatMessageListBuildResult(
            generation: request.generation,
            snapshot: ChatMessageListSnapshot(rows: rows, cache: cache),
            rebuiltRowIDs: rebuiltRowIDs,
            reusedRowCount: reusedRowCount
        )
    }

    @MainActor
    static func build(
        messages: [Message],
        workspaceRoot: String,
        previous: [UUID: CachedMessageRowSnapshot]
    ) -> ChatMessageListSnapshot {
        let request = ChatMessageListBuildRequest.make(
            messages: messages,
            workspaceRoot: workspaceRoot,
            previousCache: previous,
            generation: 0
        )
        return build(request: request).snapshot
    }
}

// Row refresh compares only message semantics plus bounded tool/round summaries.
// Never add raw JSON payloads, unbounded metadata maps, or other opaque large fields here.
// Comparison cost must stay O(message + toolCalls + rounds), independent of payload size.
struct MessageRowSemanticFingerprint: Hashable, @unchecked Sendable {
    let messageID: UUID
    let direction: MessageDirection
    let status: MessageStatus
    let timestamp: Date
    let textContent: String?
    let errorMessage: String?
    let directToolCalls: [ToolCallSummaryFingerprint]
    let rounds: [AgentRoundSummaryFingerprint]
    let attachments: [AttachmentSnapshotEntry]

    init(_ message: MessageRowBuildInput) {
        self.messageID = message.id
        self.direction = message.direction
        self.status = message.status
        self.timestamp = message.timestamp
        self.textContent = message.textContent
        self.errorMessage = message.errorMessage
        self.directToolCalls = message.directToolCalls.map(ToolCallSummaryFingerprint.init)
        self.rounds = message.rounds.map(AgentRoundSummaryFingerprint.init)
        self.attachments = message.structuredAttachments
    }
}

struct AgentRoundSummaryFingerprint: Hashable, @unchecked Sendable {
    let id: UUID
    let roundIndex: Int
    let text: String?
    let thinkingContent: String?
    let timestamp: Date
    let stopReason: String?
    let toolCalls: [ToolCallSummaryFingerprint]

    init(_ round: AgentRoundProjectionInput) {
        self.id = round.id
        self.roundIndex = round.roundIndex
        self.text = round.text
        self.thinkingContent = round.thinkingContent
        self.timestamp = round.timestamp
        self.stopReason = round.stopReason
        self.toolCalls = round.toolCalls.map(ToolCallSummaryFingerprint.init)
    }
}

struct ToolCallSummaryFingerprint: Hashable, @unchecked Sendable {
    let id: UUID
    let toolCallId: String
    let kind: ToolKind
    let isPermissionRequest: Bool
    let permissionLookupToolCallId: String
    let status: ToolStatus
    let localSessionID: String?
    let startTime: Date?
    let endTime: Date?
    let filePath: String?
    let toolPayloadRef: String?
    let terminalExecutionMode: String?
    let terminalTaskStatus: String?
    let terminalApprovalPending: Bool
    let terminalUserTakeoverActive: Bool
    let terminalTranscriptPath: String?
    let terminalCompletionReason: String?
    let subagentTask: String?
    let subagentResultKind: String?
    let subagentMessageMetadata: [MetadataPair]
    let latestAgentActionSummary: String?
    let visiblePrimaryText: String
    let visibleSecondaryText: String?
    let visibleTertiaryText: String?
    let visibleStatusText: String
    let visibleDetailText: String?
    let visibleDurationText: String?
    let subagentRounds: [SubagentRoundSummaryFingerprint]

    init(_ toolCall: ToolCallProjectionInput) {
        let row = ToolCallRowPresentation.make(for: toolCall)
        self.id = toolCall.id
        self.toolCallId = toolCall.toolCallId
        self.kind = toolCall.kind
        self.isPermissionRequest = toolCall.isPermissionRequest
        self.permissionLookupToolCallId = toolCall.permissionLookupToolCallId
        self.status = toolCall.status
        self.localSessionID = toolCall.localSessionID
        self.startTime = toolCall.startTime
        self.endTime = toolCall.endTime
        self.filePath = toolCall.filePath
        self.toolPayloadRef = toolCall.toolPayloadRef
        self.terminalExecutionMode = toolCall.terminalExecutionMode
        self.terminalTaskStatus = toolCall.terminalTaskStatus
        self.terminalApprovalPending = toolCall.terminalApprovalPending
        self.terminalUserTakeoverActive = toolCall.terminalUserTakeoverActive
        self.terminalTranscriptPath = toolCall.terminalTranscriptPath
        self.terminalCompletionReason = toolCall.terminalCompletionReason
        self.subagentTask = toolCall.subagentTask
        self.subagentResultKind = toolCall.subagentResultKind
        self.subagentMessageMetadata = toolCall.subagentMessageMetadata
        self.latestAgentActionSummary = latestTerminalAgentActionSummary(from: toolCall.terminalAgentActionsJSON)
        self.visiblePrimaryText = row.primaryText
        self.visibleSecondaryText = row.secondaryText
        self.visibleTertiaryText = row.tertiaryText
        self.visibleStatusText = row.statusText
        self.visibleDetailText = row.detailText
        self.visibleDurationText = row.durationText
        self.subagentRounds = toolCall.subagentRounds.map(SubagentRoundSummaryFingerprint.init)
    }
}

struct SubagentRoundSummaryFingerprint: Hashable, @unchecked Sendable {
    let id: UUID
    let roundIndex: Int
    let text: String?
    let thinkingContent: String?
    let timestamp: Date
    let stopReason: String?
    let toolCalls: [ToolCallSummaryFingerprint]

    init(_ round: SubagentRoundProjectionInput) {
        self.id = round.id
        self.roundIndex = round.roundIndex
        self.text = round.text
        self.thinkingContent = round.thinkingContent
        self.timestamp = round.timestamp
        self.stopReason = round.stopReason
        self.toolCalls = round.toolCalls.map(ToolCallSummaryFingerprint.init)
    }
}

struct MetadataPair: Hashable, @unchecked Sendable {
    let key: String
    let value: String
}

private func latestTerminalAgentActionSummary(from json: String?) -> String? {
    guard let json, let data = json.data(using: .utf8) else { return nil }
    guard let events = try? JSONDecoder().decode([TerminalTaskEvent].self, from: data) else {
        return nil
    }
    return events.last?.summary.trimmingCharacters(in: .whitespacesAndNewlines)
}
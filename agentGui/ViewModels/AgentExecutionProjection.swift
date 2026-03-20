import Foundation

enum ExecutionPhase: String, Equatable {
    case framing
    case inspecting
    case editing
    case running
    case verifying
    case delivering
    case blocked

    nonisolated var title: String {
        switch self {
        case .framing:
            return "理解任务"
        case .inspecting:
            return "检查代码"
        case .editing:
            return "生成变更"
        case .running:
            return "运行命令"
        case .verifying:
            return "运行验证"
        case .delivering:
            return "整理交付"
        case .blocked:
            return "遇到阻塞"
        }
    }
}

struct ExecutionHeaderPresentation: Equatable {
    let phase: ExecutionPhase
    let isLive: Bool
    let statusText: String
}

enum LiveTaskCardState: Equatable {
    case active
    case recent
}

struct LiveTaskCardPresentation: Equatable, Identifiable {
    let id: String
    let phase: ExecutionPhase
    let title: String
    let subtitle: String?
    let statusText: String
    let isCurrentAction: Bool
    let state: LiveTaskCardState
}

struct ExecutionTheaterPresentation: Equatable {
    let phase: ExecutionPhase
    let phaseTitle: String
    let currentActionID: String?
    let currentActionText: String?
    let cards: [LiveTaskCardPresentation]
}

struct NarrativeTranscriptPresentation: Equatable {
    let answerText: String
    let isError: Bool
}

struct ArtifactChipPresentation: Equatable, Identifiable {
    let id: String
    let displayName: String
    let path: String
}

struct ArtifactSummaryLine: Equatable, Identifiable {
    let id: String
    let text: String
}

struct ArtifactShelfPresentation: Equatable {
    let changedFiles: [ArtifactChipPresentation]
    let referencedFiles: [ArtifactChipPresentation]
    let citations: [ArtifactChipPresentation]
    let commandSummaries: [ArtifactSummaryLine]
    let testSummaries: [ArtifactSummaryLine]

    static let empty = ArtifactShelfPresentation(
        changedFiles: [],
        referencedFiles: [],
        citations: [],
        commandSummaries: [],
        testSummaries: []
    )

    var hasContent: Bool {
        !changedFiles.isEmpty
            || !referencedFiles.isEmpty
            || !citations.isEmpty
            || !commandSummaries.isEmpty
            || !testSummaries.isEmpty
    }
}

struct ExecutionDigestPresentation: Equatable {
    let headline: String
    let inspectedFileCount: Int
    let editedFileCount: Int
    let commandCount: Int
    let verificationSummary: String?
    let subagentContributionSummary: String?
    let outstandingRisk: String?
}

struct AuditTracePresentation: Equatable {
    let flow: AgentMessageFlowSnapshot

    var steps: [AgentMessageFlowStep] {
        flow.steps
    }

    func toolCall(for id: UUID) -> ToolCall? {
        flow.toolCall(for: id)
    }
}

struct AgentExecutionProjection: Equatable {
    let header: ExecutionHeaderPresentation
    let theater: ExecutionTheaterPresentation
    let transcript: NarrativeTranscriptPresentation
    let artifacts: ArtifactShelfPresentation
    let digest: ExecutionDigestPresentation
    let audit: AuditTracePresentation
}

extension AgentExecutionProjection {
    nonisolated static func make(for message: Message) -> AgentExecutionProjection {
        make(for: message, audit: AgentMessageFlowPresentation.snapshot(for: message))
    }

    nonisolated static func make(for message: Message, audit flow: AgentMessageFlowSnapshot) -> AgentExecutionProjection {
        let toolCalls = allToolCalls(in: message)
        let livePhase = phase(for: message, toolCalls: toolCalls)
        let isLive = message.status == .pending || toolCalls.contains(where: { $0.status == .inProgress })
        let theaterCards = makeTheaterCards(for: message, toolCalls: toolCalls, phase: livePhase)
        let currentActionCard = theaterCards.first(where: \LiveTaskCardPresentation.isCurrentAction)
        let transcript = makeTranscript(for: message, flow: flow)
        let artifacts = makeArtifacts(from: toolCalls)
        let digest = makeDigest(from: toolCalls, transcript: transcript)

        return AgentExecutionProjection(
            header: ExecutionHeaderPresentation(
                phase: livePhase,
                isLive: isLive,
                statusText: statusText(for: message)
            ),
            theater: ExecutionTheaterPresentation(
                phase: livePhase,
                phaseTitle: livePhase.title,
                currentActionID: currentActionCard?.id,
                currentActionText: currentActionCard?.title,
                cards: theaterCards
            ),
            transcript: transcript,
            artifacts: artifacts,
            digest: digest,
            audit: AuditTracePresentation(flow: flow)
        )
    }

    nonisolated private static func allToolCalls(in message: Message) -> [ToolCall] {
        let roundCalls = message.agentRounds.flatMap(\.toolCalls)
        let directCalls = message.toolCalls.filter { $0.agentRound == nil }
        return (roundCalls + directCalls).filter { !$0.isPermissionRequest }
    }

    nonisolated private static func phase(for message: Message, toolCalls: [ToolCall]) -> ExecutionPhase {
        if message.status == .failed {
            return .blocked
        }

        if let activeTool = toolCalls
            .filter({ $0.status == .inProgress })
            .sorted(by: { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) })
            .last {
            switch activeTool.kind {
            case .read, .search, .fetch:
                return .inspecting
            case .edit:
                return .editing
            case .execute:
                return .running
            default:
                return .framing
            }
        }

        if message.status == .pending,
           let recentTool = latestCompletedToolCall(in: toolCalls) {
            return phaseForToolKind(recentTool.kind)
        }

        if message.status == .pending {
            return .framing
        }

        return .delivering
    }

    nonisolated private static func makeTheaterCards(
        for message: Message,
        toolCalls: [ToolCall],
        phase: ExecutionPhase
    ) -> [LiveTaskCardPresentation] {
        let activeToolCalls = toolCalls
            .filter { $0.status == .inProgress }
            .sorted { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
        let currentToolID = activeToolCalls.last?.id

        if !activeToolCalls.isEmpty {
            return activeToolCalls.map { toolCall in
                let row = ToolCallRowPresentation.make(for: toolCall)
                return LiveTaskCardPresentation(
                    id: toolCall.id.uuidString,
                    phase: phase,
                    title: liveTitle(for: toolCall),
                    subtitle: row.tertiaryText ?? row.secondaryText,
                    statusText: row.statusText,
                    isCurrentAction: toolCall.id == currentToolID,
                    state: .active
                )
            }
        }

        if message.status == .pending {
            let recentToolCalls = recentCompletedToolCalls(in: toolCalls)
            if !recentToolCalls.isEmpty {
                let currentRecentID = recentToolCalls.first?.id
                return recentToolCalls.map { toolCall in
                    let row = ToolCallRowPresentation.make(for: toolCall)
                    return LiveTaskCardPresentation(
                        id: "recent-\(toolCall.id.uuidString)",
                        phase: phaseForToolKind(toolCall.kind),
                        title: completedLiveTitle(for: toolCall),
                        subtitle: row.secondaryText ?? row.tertiaryText,
                        statusText: recentStatusText(for: toolCall),
                        isCurrentAction: toolCall.id == currentRecentID,
                        state: .recent
                    )
                }
            }
        }

        guard message.status == .pending,
              let round = message.agentRounds.sorted(by: { $0.roundIndex < $1.roundIndex }).last,
              let thinking = round.thinkingContent,
              !thinking.isEmpty else {
            return []
        }

        return [
            LiveTaskCardPresentation(
                id: "thinking-\(round.id.uuidString)",
                phase: phase,
                title: "分析任务",
                subtitle: "推理摘要 · \(thinking.count) 字",
                statusText: "进行中",
                isCurrentAction: true,
                state: .active
            )
        ]
    }

    nonisolated private static func phaseForToolKind(_ kind: ToolKind) -> ExecutionPhase {
        switch kind {
        case .read, .search, .fetch:
            return .inspecting
        case .edit:
            return .editing
        case .execute:
            return .running
        default:
            return .framing
        }
    }

    nonisolated private static func latestCompletedToolCall(in toolCalls: [ToolCall]) -> ToolCall? {
        toolCalls
            .filter { $0.status != .inProgress }
            .sorted {
                let lhsDate = $0.endTime ?? $0.startTime ?? .distantPast
                let rhsDate = $1.endTime ?? $1.startTime ?? .distantPast
                return lhsDate > rhsDate
            }
            .first
    }

    nonisolated private static func recentCompletedToolCalls(in toolCalls: [ToolCall]) -> [ToolCall] {
        Array(
            toolCalls
                .filter { $0.status != .inProgress }
                .sorted {
                    let lhsDate = $0.endTime ?? $0.startTime ?? .distantPast
                    let rhsDate = $1.endTime ?? $1.startTime ?? .distantPast
                    return lhsDate > rhsDate
                }
                .prefix(2)
        )
    }

    nonisolated private static func liveTitle(for toolCall: ToolCall) -> String {
        switch toolCall.kind {
        case .read, .search, .fetch:
            return "检查 \(toolCall.fileName ?? toolCall.title ?? toolCall.kind.displayName)"
        case .edit:
            return "修改 \(toolCall.fileName ?? toolCall.title ?? toolCall.kind.displayName)"
        case .execute:
            return "运行 \(toolCall.title ?? toolCall.kind.displayName)"
        case .subagent:
            return "委派 \(toolCall.subagentAgentName ?? toolCall.title ?? toolCall.kind.displayName)"
        default:
            return toolCall.title ?? toolCall.kind.displayName
        }
    }

    nonisolated private static func completedLiveTitle(for toolCall: ToolCall) -> String {
        switch toolCall.kind {
        case .read, .search, .fetch:
            return "已检查 \(toolCall.fileName ?? toolCall.title ?? toolCall.kind.displayName)"
        case .edit:
            return "已修改 \(toolCall.fileName ?? toolCall.title ?? toolCall.kind.displayName)"
        case .execute:
            return "已运行 \(toolCall.title ?? toolCall.kind.displayName)"
        case .subagent:
            return "已委派 \(toolCall.subagentAgentName ?? toolCall.title ?? toolCall.kind.displayName)"
        default:
            return toolCall.title ?? toolCall.kind.displayName
        }
    }

    nonisolated private static func recentStatusText(for toolCall: ToolCall) -> String {
        switch toolCall.status {
        case .success:
            return "刚完成"
        case .failed:
            return "刚失败"
        case .cancelled:
            return "已取消"
        case .inProgress:
            return "进行中"
        }
    }

    nonisolated private static func makeTranscript(
        for message: Message,
        flow: AgentMessageFlowSnapshot
    ) -> NarrativeTranscriptPresentation {
        if message.status == .failed {
            return NarrativeTranscriptPresentation(
                answerText: message.errorMessage ?? message.textContent ?? "执行失败",
                isError: true
            )
        }

        if let resultText = flow.steps.reversed().compactMap({ step -> String? in
            guard case .result(let presentation) = step, !presentation.isError else { return nil }
            return presentation.text
        }).first {
            return NarrativeTranscriptPresentation(answerText: resultText, isError: false)
        }

        return NarrativeTranscriptPresentation(answerText: message.textContent ?? "", isError: false)
    }

    nonisolated private static func makeArtifacts(from toolCalls: [ToolCall]) -> ArtifactShelfPresentation {
        let changedFiles = makeArtifactChips(from: toolCalls.filter { $0.kind == .edit })
        let referencedFiles = makeArtifactChips(from: toolCalls.filter { $0.kind == .read || $0.kind == .search || $0.kind == .fetch })
        let commandSummaries = toolCalls
            .filter { $0.kind == .execute }
            .map { toolCall in
                ArtifactSummaryLine(
                    id: toolCall.id.uuidString,
                    text: toolCall.title ?? toolCall.kind.displayName
                )
            }

        return ArtifactShelfPresentation(
            changedFiles: changedFiles,
            referencedFiles: referencedFiles,
            citations: [],
            commandSummaries: commandSummaries,
            testSummaries: []
        )
    }

    nonisolated private static func makeArtifactChips(from toolCalls: [ToolCall]) -> [ArtifactChipPresentation] {
        var seen: Set<String> = []
        return toolCalls.compactMap { toolCall in
            guard let path = toolCall.filePath ?? toolCall.toolPayloadRef ?? toolCall.title else {
                return nil
            }
            guard seen.insert(path).inserted else {
                return nil
            }
            return ArtifactChipPresentation(
                id: toolCall.id.uuidString,
                displayName: toolCall.fileName ?? URL(fileURLWithPath: path).lastPathComponent,
                path: path
            )
        }
    }

    nonisolated private static func makeDigest(
        from toolCalls: [ToolCall],
        transcript: NarrativeTranscriptPresentation
    ) -> ExecutionDigestPresentation {
        let inspectedFileCount = toolCalls.filter { $0.kind == .read || $0.kind == .search || $0.kind == .fetch }.count
        let editedFileCount = toolCalls.filter { $0.kind == .edit }.count
        let commandCount = toolCalls.filter { $0.kind == .execute }.count
        let headline = digestHeadline(
            inspectedFileCount: inspectedFileCount,
            editedFileCount: editedFileCount,
            commandCount: commandCount,
            transcript: transcript
        )

        return ExecutionDigestPresentation(
            headline: headline,
            inspectedFileCount: inspectedFileCount,
            editedFileCount: editedFileCount,
            commandCount: commandCount,
            verificationSummary: nil,
            subagentContributionSummary: nil,
            outstandingRisk: transcript.isError ? transcript.answerText : nil
        )
    }

    nonisolated private static func digestHeadline(
        inspectedFileCount: Int,
        editedFileCount: Int,
        commandCount: Int,
        transcript: NarrativeTranscriptPresentation
    ) -> String {
        if transcript.isError {
            return "执行失败"
        }

        var parts: [String] = []
        if inspectedFileCount > 0 {
            parts.append("检查 \(inspectedFileCount) 个文件")
        }
        if editedFileCount > 0 {
            parts.append("修改 \(editedFileCount) 个文件")
        }
        if commandCount > 0 {
            parts.append("运行 \(commandCount) 个命令")
        }

        return parts.isEmpty ? "整理交付结果" : parts.joined(separator: "，")
    }

    nonisolated private static func statusText(for message: Message) -> String {
        switch message.status {
        case .pending:
            return "进行中"
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        case .cancelled:
            return "已取消"
        }
    }
}
import Foundation

struct AgentMessageFlowSnapshot: Equatable {
    let messageID: UUID
    let steps: [AgentMessageFlowStep]
    private let toolCallsByID: [UUID: ToolCall]

    init(messageID: UUID, steps: [AgentMessageFlowStep], toolCallsByID: [UUID: ToolCall] = [:]) {
        self.messageID = messageID
        self.steps = steps
        self.toolCallsByID = toolCallsByID
    }

    func toolCall(for id: UUID) -> ToolCall? {
        toolCallsByID[id]
    }

    static func == (lhs: AgentMessageFlowSnapshot, rhs: AgentMessageFlowSnapshot) -> Bool {
        lhs.messageID == rhs.messageID && lhs.steps == rhs.steps
    }
}

enum AgentMessageFlowStep: Equatable, Identifiable {
    case result(ResultStepPresentation)
    case thinking(ThinkingStepPresentation)
    case tool(ToolStepPresentation)
    case subagent(SubagentStepPresentation)

    var id: String {
        switch self {
        case .result(let value):
            return value.id
        case .thinking(let value):
            return value.id
        case .tool(let value):
            return value.id
        case .subagent(let value):
            return value.id
        }
    }

    var isExpanded: Bool {
        switch self {
        case .result:
            return false
        case .thinking(let value):
            return value.isExpanded
        case .tool(let value):
            return value.row.isExpanded
        case .subagent(let value):
            return value.isExpanded
        }
    }
}

struct ResultStepPresentation: Equatable, Identifiable {
    let id: String
    let text: String
    let isError: Bool
}

struct ThinkingStepPresentation: Equatable, Identifiable {
    let id: String
    let content: String
    let summaryText: String
    let isExpanded: Bool
    let isActive: Bool
}

struct ToolStepPresentation: Equatable, Identifiable {
    let id: String
    let toolCallID: UUID
    let row: ToolCallRowPresentation
}

struct SubagentStepPresentation: Equatable, Identifiable {
    let id: String
    let toolCallID: UUID
    let title: String
    let task: String?
    let summary: String?
    let resultKind: String?
    let durationText: String?
    let roundCount: Int
    let isExpanded: Bool
}

enum AgentMessageFlowPresentation {
    nonisolated static func snapshot(for message: Message) -> AgentMessageFlowSnapshot {
        let activeToolID = activeToolCallID(in: message)
        let activeThinkingRoundID = activeThinkingRoundID(in: message, activeToolID: activeToolID)
        let entries = buildEntries(
            for: message,
            activeToolID: activeToolID,
            activeThinkingRoundID: activeThinkingRoundID
        )

        return AgentMessageFlowSnapshot(
            messageID: message.id,
            steps: entries.sorted { lhs, rhs in
                entrySort(lhs: lhs, rhs: rhs)
            }.map(\.step),
            toolCallsByID: makeToolLookup(for: message)
        )
    }

    nonisolated private static func makeToolLookup(for message: Message) -> [UUID: ToolCall] {
        let roundCalls = message.agentRounds.flatMap(\.toolCalls)
        let directCalls = message.toolCalls.filter { $0.agentRound == nil }

        var lookup: [UUID: ToolCall] = [:]
        for toolCall in roundCalls + directCalls {
            lookup[toolCall.id] = toolCall
        }
        return lookup
    }

    nonisolated private static func buildEntries(
        for message: Message,
        activeToolID: UUID?,
        activeThinkingRoundID: UUID?
    ) -> [FlowEntry] {
        var entries: [FlowEntry] = []
        let rounds = message.agentRounds.sorted { $0.roundIndex < $1.roundIndex }

        for round in rounds {
            let baseTime = round.timestamp

            if let thinking = round.thinkingContent, !thinking.isEmpty {
                let presentation = ThinkingStepPresentation(
                    id: "thinking-\(round.id.uuidString)",
                    content: thinking,
                    summaryText: "推理摘要 · \(thinking.count) 字",
                    isExpanded: activeThinkingRoundID == round.id,
                    isActive: activeThinkingRoundID == round.id
                )
                entries.append(FlowEntry(order: makeOrder(baseTime, round.roundIndex, 0, 0), step: .thinking(presentation)))
            }

            let roundCalls = round.sortedToolCalls
            for (index, toolCall) in roundCalls.enumerated() {
                entries.append(toolEntry(for: toolCall, roundIndex: round.roundIndex, fallbackDate: baseTime, subIndex: 10 + index, activeToolID: activeToolID))
            }

            if let text = round.text, !text.isEmpty {
                let resultDate = roundCalls
                    .compactMap { $0.endTime ?? $0.startTime }
                    .max() ?? baseTime
                let presentation = ResultStepPresentation(
                    id: "result-round-\(round.id.uuidString)",
                    text: text,
                    isError: false
                )
                let textSubIndex = roundCalls.isEmpty ? 5 : 50
                entries.append(FlowEntry(order: makeOrder(resultDate, round.roundIndex, textSubIndex, 0), step: .result(presentation)))
            }
        }

        let directCalls = message.toolCalls
            .filter { $0.agentRound == nil }
            .sorted { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
        for (index, toolCall) in directCalls.enumerated() {
            entries.append(toolEntry(for: toolCall, roundIndex: rounds.count + 1, fallbackDate: toolCall.startTime ?? message.timestamp, subIndex: index, activeToolID: activeToolID))
        }

        if let text = message.textContent,
           !text.isEmpty,
           rounds.isEmpty {
            let presentation = ResultStepPresentation(
                id: "result-message-\(message.id.uuidString)",
                text: text,
                isError: false
            )
            entries.append(FlowEntry(order: makeOrder(message.timestamp, -1, 0, 0), step: .result(presentation)))
        }

        if message.status == .failed {
            let errorText = message.errorMessage ?? message.textContent ?? "执行失败"
            let presentation = ResultStepPresentation(
                id: "result-error-\(message.id.uuidString)",
                text: errorText,
                isError: true
            )
            entries.append(FlowEntry(order: makeOrder(Date.distantFuture, rounds.count + 2, 0, 0), step: .result(presentation)))
        }

        return entries
    }

    nonisolated private static func toolEntry(
        for toolCall: ToolCall,
        roundIndex: Int,
        fallbackDate: Date,
        subIndex: Int,
        activeToolID: UUID?
    ) -> FlowEntry {
        let isExpanded = activeToolID == toolCall.id
        if toolCall.kind == .subagent {
            let rounds = toolCall.subagentRounds.sorted { $0.roundIndex < $1.roundIndex }
            let summary = rounds.last(where: { $0.hasText })?.text
            let presentation = SubagentStepPresentation(
                id: "subagent-\(toolCall.id.uuidString)",
                toolCallID: toolCall.id,
                title: toolCall.subagentAgentName ?? toolCall.title ?? toolCall.kind.displayName,
                task: toolCall.subagentTask,
                summary: summary,
                resultKind: toolCall.subagentResultKind,
                durationText: toolCall.duration.map { String(format: "%.1fs", $0) },
                roundCount: rounds.count,
                isExpanded: isExpanded
            )
            return FlowEntry(order: makeOrder(toolCall.startTime ?? fallbackDate, roundIndex, subIndex, 0), step: .subagent(presentation))
        }

        let row = ToolCallRowPresentation.make(for: toolCall, isExpanded: isExpanded)
        let presentation = ToolStepPresentation(
            id: "tool-\(toolCall.id.uuidString)",
            toolCallID: toolCall.id,
            row: row
        )
        return FlowEntry(order: makeOrder(toolCall.startTime ?? fallbackDate, roundIndex, subIndex, 0), step: .tool(presentation))
    }

    nonisolated private static func activeToolCallID(in message: Message) -> UUID? {
        let roundCalls = message.agentRounds.flatMap(\.toolCalls)
        let directCalls = message.toolCalls.filter { $0.agentRound == nil }
        return (roundCalls + directCalls)
            .filter { $0.status == .inProgress }
            .sorted { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
            .last?
            .id
    }

    nonisolated private static func activeThinkingRoundID(in message: Message, activeToolID: UUID?) -> UUID? {
        guard activeToolID == nil, message.status == .pending else { return nil }
        let rounds = message.agentRounds.sorted { $0.roundIndex < $1.roundIndex }
        return rounds.last(where: { $0.hasThinking })?.id
    }

    nonisolated private static func makeOrder(_ date: Date, _ roundIndex: Int, _ subIndex: Int, _ tiebreaker: Int) -> FlowOrder {
        FlowOrder(date: date, roundIndex: roundIndex, subIndex: subIndex, tiebreaker: tiebreaker)
    }

    nonisolated private static func entrySort(lhs: FlowEntry, rhs: FlowEntry) -> Bool {
        lhs.order < rhs.order
    }
}

private struct FlowEntry {
    let order: FlowOrder
    let step: AgentMessageFlowStep
}

private struct FlowOrder: Comparable {
    let date: Date
    let roundIndex: Int
    let subIndex: Int
    let tiebreaker: Int

    static func < (lhs: FlowOrder, rhs: FlowOrder) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        if lhs.roundIndex != rhs.roundIndex { return lhs.roundIndex < rhs.roundIndex }
        if lhs.subIndex != rhs.subIndex { return lhs.subIndex < rhs.subIndex }
        return lhs.tiebreaker < rhs.tiebreaker
    }
}
import SwiftUI

struct AgentMessageStepFlowView: View {
    let message: Message

    private var snapshot: AgentMessageFlowSnapshot {
        AgentMessageFlowPresentation.snapshot(for: message)
    }

    private var toolLookup: [UUID: ToolCall] {
        Self.makeToolLookup(for: message)
    }

    static func makeToolLookup(for message: Message) -> [UUID: ToolCall] {
        let roundCalls = message.agentRounds.flatMap(\.toolCalls)
        let directCalls = message.toolCalls.filter { $0.agentRound == nil }

        var lookup: [UUID: ToolCall] = [:]
        for toolCall in roundCalls + directCalls {
            lookup[toolCall.id] = toolCall
        }
        return lookup
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(snapshot.steps) { step in
                switch step {
                case .result(let presentation):
                    AgentMessageResultBlockView(presentation: presentation)
                case .thinking(let presentation):
                    ThinkingBubbleView(presentation: presentation)
                case .tool(let presentation):
                    if let toolCall = toolLookup[presentation.toolCallID] {
                        ToolCallBubbleView(toolCall: toolCall, rowPresentation: presentation.row)
                    }
                case .subagent(let presentation):
                    if let toolCall = toolLookup[presentation.toolCallID] {
                        SubagentTaskCardView(toolCall: toolCall, defaultExpanded: presentation.isExpanded)
                    }
                }
            }
        }
    }
}
import SwiftUI

struct AgentMessageStepFlowView: View {
    let snapshot: AgentMessageFlowSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(snapshot.steps) { step in
                switch step {
                case .result(let presentation):
                    AgentMessageResultBlockView(presentation: presentation)
                case .thinking(let presentation):
                    ThinkingBubbleView(presentation: presentation)
                case .reflection(let presentation):
                    ReflectionBubbleView(presentation: presentation)
                case .tool(let presentation):
                    if let toolCall = snapshot.toolCall(for: presentation.toolCallID) {
                        ToolCallBubbleView(toolCall: toolCall, rowPresentation: presentation.row)
                    }
                case .subagent(let presentation):
                    if let toolCall = snapshot.toolCall(for: presentation.toolCallID) {
                        SubagentTaskCardView(toolCall: toolCall, defaultExpanded: presentation.isExpanded)
                    }
                }
            }
        }
    }
}
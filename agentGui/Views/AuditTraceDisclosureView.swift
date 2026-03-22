import SwiftUI

struct AuditTraceDisclosureView: View {
    let presentation: AuditTracePresentation

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("查看执行细节")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }.padding(.horizontal)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.agentMessage.auditDisclosure")

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(presentation.steps) { step in
                        switch step {
                        case .result(let value):
                            AgentMessageResultBlockView(presentation: value)
                        case .thinking(let value):
                            ThinkingBubbleView(presentation: value)
                        case .tool(let value):
                            if let toolCall = presentation.toolCall(for: value.toolCallID) {
                                ToolCallBubbleView(toolCall: toolCall, rowPresentation: value.row)
                            }
                        case .subagent(let value):
                            if let toolCall = presentation.toolCall(for: value.toolCallID) {
                                SubagentTaskCardView(toolCall: toolCall, defaultExpanded: value.isExpanded)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("chat.agentMessage.auditTrace")
            }
        }
    }
}
import SwiftUI

struct AgentMessageStepFlowView: View {
    let projection: AgentExecutionProjection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if projection.header.isLive, !projection.theater.cards.isEmpty {
                ExecutionTheaterView(presentation: projection.theater)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .scale(scale: 0.96, anchor: .top).combined(with: .opacity)
                        )
                    )
            }

            if !projection.transcript.answerText.isEmpty {
                AgentMessageResultBlockView(
                    presentation: ResultStepPresentation(
                        id: "transcript-\(projection.audit.flow.messageID.uuidString)",
                        text: projection.transcript.answerText,
                        isError: projection.transcript.isError
                    )
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("chat.agentMessage.answerBlock")
            }

            if !projection.header.isLive, projection.artifacts.hasContent {
                ArtifactShelfView(presentation: projection.artifacts)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            ExecutionDigestView(presentation: projection.digest)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            AuditTraceDisclosureView(presentation: projection.audit)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.84), value: projection.header.isLive)
        .animation(.easeInOut(duration: 0.24), value: projection.theater.cards.map(\.id))
    }
}
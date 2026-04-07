import SwiftUI

struct AgentMessageStepFlowView: View {
    @Environment(ClaudeService.self) private var claudeService

    let projection: AgentExecutionProjection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if projection.header.isLive, showsExecutionTheater {
                ExecutionTheaterView(
                    presentation: projection.theater,
                    pendingPermissionRequests: pendingPermissionRequests
                )
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
        .animation(ChatMotion.enterSpring, value: projection.header.isLive)
        .animation(ChatMotion.theaterStateChange, value: projection.theater.cards.map(\.id))
        .animation(ChatMotion.theaterStateChange, value: pendingPermissionRequests.map(\.id))
    }

    private var pendingPermissionRequests: [ACPPermissionCenter.PendingRequest] {
        AgentExecutionPermissionLookup.pendingRequests(
            for: projection.audit.flow,
            permissionCenter: claudeService.acpPermissionCenter
        )
    }

    private var showsExecutionTheater: Bool {
        !projection.theater.cards.isEmpty || !pendingPermissionRequests.isEmpty
    }
}
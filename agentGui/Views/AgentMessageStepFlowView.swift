import SwiftUI

struct AgentMessageStepFlowView: View {
    @Environment(ClaudeService.self) private var claudeService

    let projection: AgentExecutionProjection

    @State private var budgetTracker = StreamingCharBudgetTracker()

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
                    ),
                    charBudget: projection.header.isLive ? budgetTracker.displayedCharBudget : nil
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
        .onChange(of: projection.transcript.answerText) { _, newText in
            handleAnswerTextChange(newText: newText)
        }
        .onChange(of: projection.header.isLive) { _, isLive in
            if !isLive {
                budgetTracker.stopTracking(finalLength: projection.transcript.answerText.count)
            }
        }
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

    private func handleAnswerTextChange(newText: String) {
        guard projection.header.isLive else { return }
        if !budgetTracker.isTracking {
            // 第一次有内容：开始追踪
            budgetTracker.startTracking(targetLength: newText.count)
        }
        // 每次文本扩展时更新 target（timer 会自动追赶）
    }
}
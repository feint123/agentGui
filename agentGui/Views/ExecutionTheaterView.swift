import SwiftUI

struct ExecutionTheaterView: View {
    let presentation: ExecutionTheaterPresentation
    let pendingPermissionRequests: [ACPPermissionCenter.PendingRequest]

    @State private var pulseCurrentCard = false
    @State private var actionChangeFlash = false

    init(
        presentation: ExecutionTheaterPresentation,
        pendingPermissionRequests: [ACPPermissionCenter.PendingRequest] = []
    ) {
        self.presentation = presentation
        self.pendingPermissionRequests = pendingPermissionRequests
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(presentation.phaseTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(accentColor.opacity(0.92))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(accentColor.opacity(0.12), in: Capsule())

                    if let currentActionText = presentation.currentActionText, !currentActionText.isEmpty {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(accentColor)
                                .frame(width: 6, height: 6)
                                .scaleEffect(pulseCurrentCard ? 1.15 : 0.72)
                            Text(currentActionText)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(accentColor.opacity(actionChangeFlash ? 0.16 : 0.08), in: Capsule())
                        .accessibilityIdentifier("chat.agentMessage.currentAction")
                    }

                    Spacer(minLength: 0)
                }

                ExecutionPhaseRibbonView(phase: presentation.phase, isAnimated: true)
            }

            ForEach(pendingPermissionRequests) { request in
                ACPPermissionPromptCardView(
                    request: request,
                    emphasis: .theater(accentColor: accentColor)
                )
                .accessibilityIdentifier("chat.agentMessage.permissionCard.\(request.id)")
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                    )
                )
            }

            ForEach(presentation.cards) { card in
                liveTaskCard(card)
                .accessibilityIdentifier("chat.agentMessage.liveTaskCard.\(card.id)")
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                    )
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [
                    accentColor.opacity(0.08),
                    Color.primary.opacity(0.02)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(accentColor.opacity(0.12), lineWidth: 1)
        )
        .onAppear {
            startCurrentActionAnimationCycle()
        }
        .onChange(of: presentation.currentActionID) { _, _ in
            startCurrentActionAnimationCycle()
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.84), value: presentation.cards.map(\.id))
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: pendingPermissionRequests.map(\.id))
        .animation(.easeInOut(duration: 0.2), value: presentation.currentActionID)
        .accessibilityIdentifier("chat.agentMessage.executionTheater")
    }

    private func liveTaskCard(_ card: LiveTaskCardPresentation) -> some View {
        let isCurrent = card.isCurrentAction
        let isRecent = card.state == .recent

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if isCurrent {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 7, height: 7)
                        .scaleEffect(pulseCurrentCard ? 1.12 : 0.82)
                } else if isRecent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(accentColor.opacity(0.9))
                } else {
                    Circle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                }

                Text(card.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(card.statusText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isCurrent || isRecent ? accentColor : .secondary)
            }

            if let subtitle = card.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 15)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(cardBackground(isCurrent: isCurrent))
        .overlay(cardBorder(isCurrent: isCurrent, isRecent: isRecent))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .scaleEffect(isCurrent && pulseCurrentCard ? 1.012 : (isRecent && actionChangeFlash ? 1.01 : 1))
        .opacity(isRecent ? 0.94 : 1)
        .shadow(color: isCurrent ? accentColor.opacity(0.16) : .clear, radius: 12, y: 4)
    }

    private func cardBackground(isCurrent: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(
                LinearGradient(
                    colors: isCurrent
                        ? [accentColor.opacity(0.18), accentColor.opacity(0.06)]
                        : [Color.primary.opacity(0.04), Color.primary.opacity(0.02)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private func cardBorder(isCurrent: Bool, isRecent: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(
                isCurrent
                    ? accentColor.opacity(0.28)
                    : (isRecent ? accentColor.opacity(0.18) : Color.primary.opacity(0.06)),
                lineWidth: 1
            )
    }

    private func startCurrentActionAnimationCycle() {
        guard presentation.currentActionID != nil else {
            pulseCurrentCard = false
            actionChangeFlash = false
            return
        }

        pulseCurrentCard = false
        actionChangeFlash = true
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            pulseCurrentCard = true
        }
        withAnimation(.easeOut(duration: 0.45)) {
            actionChangeFlash = false
        }
    }

    private var accentColor: Color {
        switch presentation.phase {
        case .framing:
            return .indigo
        case .inspecting:
            return .blue
        case .editing:
            return .orange
        case .running:
            return .green
        case .verifying:
            return .mint
        case .delivering:
            return .teal
        case .blocked:
            return .red
        }
    }
}
import SwiftUI

struct ExecutionPhaseRibbonView: View {
    let phase: ExecutionPhase
    var isAnimated: Bool = true

    private let orderedPhases: [ExecutionPhase] = [
        .framing,
        .inspecting,
        .editing,
        .running,
        .verifying,
        .delivering
    ]

    @State private var highlightSweep = false
    @State private var blockedPulse = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(orderedPhases, id: \.self) { item in
                phaseSegment(for: item)
                    .frame(maxWidth: .infinity)
                    .frame(height: 5)
            }
        }
        .onAppear {
            startAnimationsIfNeeded()
        }
        .onChange(of: phase) { _, _ in
            startAnimationsIfNeeded()
        }
        .accessibilityIdentifier("chat.agentMessage.phaseRibbon")
        .accessibilityValue(phase.title)
    }

    private func color(for item: ExecutionPhase) -> Color {
        if phase == .blocked {
            return item == orderedPhases.last ? .red.opacity(0.7) : .primary.opacity(0.08)
        }

        guard let currentIndex = orderedPhases.firstIndex(of: phase),
              let itemIndex = orderedPhases.firstIndex(of: item) else {
            return .primary.opacity(0.08)
        }

        if itemIndex < currentIndex {
            return .secondary.opacity(0.22)
        }

        if itemIndex == currentIndex {
            return .accentColor.opacity(0.85)
        }

        return .primary.opacity(0.08)
    }

    private func phaseSegment(for item: ExecutionPhase) -> some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let sweepWidth = max(width * 0.42, 18)

            ZStack {
                Capsule()
                    .fill(color(for: item))

                if item == phase, phase == .blocked {
                    Capsule()
                        .fill(Color.red.opacity(blockedPulse ? 0.24 : 0.12))
                }

                if item == phase, phase != .blocked, isAnimated {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .clear,
                                    Color.white.opacity(0.0),
                                    Color.white.opacity(0.65),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: sweepWidth)
                        .offset(x: highlightSweep ? width * 0.32 : -width * 0.32)
                        .blendMode(.plusLighter)
                }
            }
        }
    }

    private func startAnimationsIfNeeded() {
        guard isAnimated else { return }

        if phase == .blocked {
            blockedPulse = false
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                blockedPulse = true
            }
            return
        }

        highlightSweep = false
        withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: false)) {
            highlightSweep = true
        }
    }
}
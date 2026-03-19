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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimated)) { timeline in
            HStack(spacing: 6) {
                ForEach(orderedPhases, id: \.self) { item in
                    phaseSegment(for: item, time: timeline.date.timeIntervalSinceReferenceDate)
                        .frame(maxWidth: .infinity)
                        .frame(height: 5)
                }
            }
        }
        .accessibilityIdentifier("chat.agentMessage.phaseRibbon")
        .accessibilityValue(phase.title)
    }

    private func color(for item: ExecutionPhase) -> Color {
        phaseColor(for: item)
    }

    private func inactiveBackgroundColor(for item: ExecutionPhase) -> Color {
        if phase == .blocked {
            return item == .blocked ? .red.opacity(0.18) : .primary.opacity(0.08)
        }

        guard let currentIndex = orderedPhases.firstIndex(of: phase),
              let itemIndex = orderedPhases.firstIndex(of: item) else {
            return .primary.opacity(0.08)
        }

        if itemIndex < currentIndex {
            return phaseColor(for: item).opacity(0.18)
        }

        if itemIndex >= currentIndex {
            return .primary.opacity(0.08)
        }

        return .clear
    }

    private func phaseSegment(for item: ExecutionPhase, time: TimeInterval) -> some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let height = max(geometry.size.height, 1)
            let isCurrent = item == phase

            ZStack {
                Capsule()
                    .fill(inactiveBackgroundColor(for: item))

                if isCurrent {
                    LiquidRibbonOverlay(
                        color: color(for: item),
                        width: width,
                        height: height,
                        time: time,
                        isBlocked: phase == .blocked,
                        isAnimated: isAnimated
                    )
                    .clipShape(Capsule())
                }
            }
        }
    }

    private func phaseColor(for item: ExecutionPhase) -> Color {
        switch item {
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

private struct LiquidRibbonOverlay: View {
    let color: Color
    let width: CGFloat
    let height: CGFloat
    let time: TimeInterval
    let isBlocked: Bool
    let isAnimated: Bool

    var body: some View {
        let droplets = dropletLayout
        let strands = strandLayout

        ZStack {
            Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, _ in
                context.addFilter(.alphaThreshold(min: 0.33, max: 1, color: color))
                context.addFilter(.blur(radius: max(height * 1.08, 1.8)))

                context.drawLayer { layer in
                    for strand in strands {
                        layer.fill(strand.path, with: .color(.white))
                    }

                    for droplet in droplets {
                        let rect = CGRect(
                            x: droplet.center.x - droplet.radius,
                            y: droplet.center.y - droplet.radius,
                            width: droplet.radius * 2,
                            height: droplet.radius * 2
                        )
                        layer.fill(Path(ellipseIn: rect), with: .color(.white))
                    }
                }
            }
        }
        .opacity(isBlocked ? 0.94 : 1)
        .shadow(color: color.opacity(isBlocked ? 0.34 : 0.26), radius: 5)
        .allowsHitTesting(false)
    }

    private var dropletLayout: [RibbonDroplet] {
        let resolvedTime = isAnimated ? time : 0
        let phaseTime = resolvedTime * (isBlocked ? 0.66 : 0.9)
        let centerY = height / 2
        let laneStart = width * 0.08
        let laneSpan = width * 0.84
        let minimumRadius = max(height * 0.34, 1.35)
        let maximumRadius = max(height * 0.98, 2.5)
        let dropletCount = isBlocked ? 6 : 7

        if isBlocked {
            return (0..<dropletCount).map { index in
                let seed = Double(index) * 0.73 + 0.17
                let pulse = (sin(phaseTime * (1.1 + seed * 0.22) + seed * 2.8) + 1) / 2
                let position = laneStart + laneSpan * (0.28 + 0.1 * Double(index) / Double(max(dropletCount - 1, 1)))
                let x = position + width * 0.1 * pulse * sin(phaseTime * 0.34 + seed * 4.2)
                let y = centerY + height * 0.2 * cos(phaseTime * 0.42 + seed * 3.4)
                let radius = minimumRadius + (maximumRadius - minimumRadius) * (0.42 + 0.46 * pulse)
                return RibbonDroplet(center: CGPoint(x: x, y: y), radius: radius)
            }
        }

        return (0..<dropletCount).map { index in
            let seed = Double(index) * 0.61 + 0.21
            let normalized = Double(index) / Double(max(dropletCount - 1, 1))
            let wobble = 0.08 * sin(phaseTime * (0.56 + seed * 0.08) + seed * 5.1)
            let drift = 0.16 * ((sin(phaseTime * (0.72 + seed * 0.06) - normalized * 3.2) + 1) / 2)
            let x = laneStart + laneSpan * min(max(normalized * 0.76 + drift + wobble, 0.02), 0.98)
            let y = centerY + height * 0.32 * sin(phaseTime * (0.88 + seed * 0.12) + normalized * 4.4)
            let sizeNoise = (sin(phaseTime * (1.24 + seed * 0.18) + seed * 3.7) + 1) / 2
            let radius = minimumRadius + (maximumRadius - minimumRadius) * (0.28 + 0.62 * sizeNoise)
            return RibbonDroplet(center: CGPoint(x: x, y: y), radius: radius)
        }
    }

    private var strandLayout: [RibbonStrand] {
        let droplets = dropletLayout.sorted { $0.center.x < $1.center.x }

        return zip(droplets, droplets.dropFirst()).map { lhs, rhs in
            let distance = hypot(rhs.center.x - lhs.center.x, rhs.center.y - lhs.center.y)
            let averageRadius = (lhs.radius + rhs.radius) / 2
            let strandThickness = max(min(averageRadius * (distance < width * 0.22 ? 0.72 : 0.4), height * 1.14), height * 0.32)

            return RibbonStrand(
                from: lhs.center,
                to: rhs.center,
                thickness: strandThickness
            )
        }
    }
}

private struct RibbonDroplet {
    let center: CGPoint
    let radius: CGFloat
}

private struct RibbonStrand {
    let from: CGPoint
    let to: CGPoint
    let thickness: CGFloat

    var path: Path {
        var path = Path()
        path.addRoundedRect(
            in: CGRect(
                x: min(from.x, to.x),
                y: min(from.y, to.y) - thickness / 2,
                width: max(abs(to.x - from.x), 1),
                height: thickness
            ),
            cornerSize: CGSize(width: thickness / 2, height: thickness / 2)
        )

        let angle = atan2(to.y - from.y, to.x - from.x)
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: from.x, y: from.y)
        transform = transform.rotated(by: angle)
        transform = transform.translatedBy(x: -from.x, y: -from.y)
        return path.applying(transform)
    }
}
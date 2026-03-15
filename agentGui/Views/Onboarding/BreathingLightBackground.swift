import SwiftUI

struct BreathingLightBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let palette = BackgroundPalette.forColorScheme(colorScheme)

            GeometryReader { proxy in
                let size = proxy.size

                ZStack {
                    LinearGradient(
                        colors: palette.gradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    BreatheOrb(
                        color: palette.blueOrb,
                        diameter: size.width * 0.52,
                        blurRadius: 95,
                        x: size.width * (0.2 + 0.04 * sin(time * 0.45)),
                        y: size.height * (0.24 + 0.04 * cos(time * 0.4)),
                        opacity: palette.primaryOpacity + 0.05 * sin(time * 0.9)
                    )

                    BreatheOrb(
                        color: palette.goldOrb,
                        diameter: size.width * 0.36,
                        blurRadius: 72,
                        x: size.width * (0.8 + 0.03 * cos(time * 0.36)),
                        y: size.height * (0.24 + 0.04 * sin(time * 0.52)),
                        opacity: palette.secondaryOpacity + 0.04 * cos(time * 0.8)
                    )

                    BreatheOrb(
                        color: palette.greenOrb,
                        diameter: size.width * 0.42,
                        blurRadius: 88,
                        x: size.width * (0.58 + 0.03 * sin(time * 0.31)),
                        y: size.height * (0.86 + 0.03 * cos(time * 0.36)),
                        opacity: palette.tertiaryOpacity + 0.03 * sin(time * 1.02)
                    )

                    VStack(spacing: size.height / 8) {
                        ForEach(0..<7, id: \.self) { _ in
                            Rectangle()
                                .fill(palette.gridColor.opacity(0.03))
                                .frame(height: 1)
                        }
                    }

                    HStack(spacing: size.width / 8) {
                        ForEach(0..<7, id: \.self) { _ in
                            Rectangle()
                                .fill(palette.gridColor.opacity(0.02))
                                .frame(width: 1)
                        }
                    }

                    Rectangle()
                        .fill(.ultraThinMaterial.opacity(palette.materialOpacity))
                }
                .ignoresSafeArea()
            }
        }
    }
}

private struct BackgroundPalette {
    let gradient: [Color]
    let blueOrb: Color
    let goldOrb: Color
    let greenOrb: Color
    let gridColor: Color
    let primaryOpacity: Double
    let secondaryOpacity: Double
    let tertiaryOpacity: Double
    let materialOpacity: Double

    static func forColorScheme(_ colorScheme: ColorScheme) -> BackgroundPalette {
        if colorScheme == .dark {
            return BackgroundPalette(
                gradient: [
                    Color(red: 0.05, green: 0.06, blue: 0.1),
                    Color(red: 0.08, green: 0.1, blue: 0.16),
                    Color(red: 0.12, green: 0.11, blue: 0.12)
                ],
                blueOrb: Color(red: 0.45, green: 0.77, blue: 1.0),
                goldOrb: Color(red: 0.99, green: 0.77, blue: 0.47),
                greenOrb: Color(red: 0.56, green: 0.98, blue: 0.86),
                gridColor: .white,
                primaryOpacity: 0.22,
                secondaryOpacity: 0.14,
                tertiaryOpacity: 0.11,
                materialOpacity: 0.12
            )
        }

        return BackgroundPalette(
            gradient: [
                Color(red: 0.84, green: 0.89, blue: 0.98),
                Color(red: 0.93, green: 0.95, blue: 0.98),
                Color(red: 0.96, green: 0.92, blue: 0.9)
            ],
            blueOrb: Color(red: 0.39, green: 0.67, blue: 0.98),
            goldOrb: Color(red: 0.98, green: 0.74, blue: 0.43),
            greenOrb: Color(red: 0.44, green: 0.84, blue: 0.72),
            gridColor: .black,
            primaryOpacity: 0.18,
            secondaryOpacity: 0.1,
            tertiaryOpacity: 0.08,
            materialOpacity: 0.08
        )
    }
}

private struct BreatheOrb: View {
    let color: Color
    let diameter: CGFloat
    let blurRadius: CGFloat
    let x: CGFloat
    let y: CGFloat
    let opacity: Double

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .blur(radius: blurRadius)
            .opacity(opacity)
            .position(x: x, y: y)
            .blendMode(.screen)
    }
}
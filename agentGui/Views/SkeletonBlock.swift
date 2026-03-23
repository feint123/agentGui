import SwiftUI

struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var cornerRadius: CGFloat = 10

    @State private var shimmerOffset: CGFloat = -1.2

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .overlay {
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .clear,
                                    Color.white.opacity(0.32),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .scaleEffect(x: 1.8, y: 1, anchor: .center)
                        .offset(x: shimmerOffset * proxy.size.width)
                }
                .clipped()
            }
            .frame(width: width, height: height)
            .task {
                guard shimmerOffset < 1.2 else { return }
                withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) {
                    shimmerOffset = 1.2
                }
            }
            .accessibilityHidden(true)
    }
}
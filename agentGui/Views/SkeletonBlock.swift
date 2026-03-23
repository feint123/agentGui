import SwiftUI

struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var cornerRadius: CGFloat = 10

    @State private var shimmerOffset: CGFloat = -1.2

    private var blockShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        blockShape
            .fill(Color.primary.opacity(0.08))
            .overlay {
                GeometryReader { proxy in
                    let shimmerWidth = max(proxy.size.width * 0.72, 36)

                    Rectangle()
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
                        .frame(width: shimmerWidth)
                        .blur(radius: 1.5)
                        .offset(x: shimmerOffset * (proxy.size.width + shimmerWidth))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .mask {
                    blockShape
                }
                .allowsHitTesting(false)
            }
            .frame(width: width, height: height)
            .clipShape(blockShape)
            .task {
                guard shimmerOffset < 1.2 else { return }
                withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) {
                    shimmerOffset = 1.2
                }
            }
            .accessibilityHidden(true)
    }
}
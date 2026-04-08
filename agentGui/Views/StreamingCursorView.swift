// StreamingCursorView.swift
// agentGui

import SwiftUI

/// 流式输出期间，内容末尾的闪烁竖线光标。
/// 宽 1.5pt / 高 14pt，以 0.5 s 周期在 opacity 0.2 ↔ 1 间闪烁。
/// streaming 结束后通过 `.opacity` transition + `ChatMotion.exitDuration` 淡出。
struct StreamingCursorView: View {

    static let width: CGFloat  = 1.5
    static let height: CGFloat = 14.0

    @State private var visible = false

    var body: some View {
        RoundedRectangle(cornerRadius: 0.75)
            .fill(Color.secondary.opacity(0.85))
            .frame(width: Self.width, height: Self.height)
            .opacity(visible ? 1.0 : 0.2)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.5)
                    .repeatForever(autoreverses: true)
                ) {
                    visible = true
                }
            }
    }
}

#Preview {
    HStack(spacing: 4) {
        Text("Hello")
        StreamingCursorView()
    }
    .padding()
}

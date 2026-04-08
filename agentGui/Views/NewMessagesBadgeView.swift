// NewMessagesBadgeView.swift
// agentGui
//
// 当用户回溯阅读、底部有未读消息时，右下角浮现的引导 badge。
// 点击后调用 onTap 回调（由父视图执行 scrollToBottom + 状态重置）。

import SwiftUI

struct NewMessagesBadgeView: View {
    let label: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                Text(label.isEmpty ? "新消息" : "\(label) 条新消息")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.85).combined(with: .opacity)
                    .animation(ChatMotion.enterSpring),
                removal: .scale(scale: 0.85).combined(with: .opacity)
                    .animation(.easeOut(duration: ChatMotion.exitDuration))
            )
        )
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 16) {
        NewMessagesBadgeView(label: "3", onTap: {})
        NewMessagesBadgeView(label: "99+", onTap: {})
        NewMessagesBadgeView(label: "", onTap: {})
    }
    .padding()
}
#endif

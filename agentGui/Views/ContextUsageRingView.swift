//
//  ContextUsageRingView.swift
//  agentGui
//

import SwiftUI

/// 上下文窗口使用率指示器，放置在输入框下方。
/// 显示一个小型环形进度 + 当前 token 数。
/// 鼠标悬停时弹出详细统计面板。
struct ContextUsageRingView: View {

    let service: ClaudeService
    let sessionID: String

    @State private var isHovered = false

    private var ratio: Double { min(service.contextUsageRatio(for: sessionID), 1.0) }

    private var ringColor: Color {
        if ratio < 0.6 { return .green }
        if ratio < 0.8 { return .yellow }
        return .red
    }

    private var statusLabel: String {
        if ratio < 0.6 { return "正常" }
        if ratio < 0.8 { return "较高" }
        return "接近上限"
    }

    private var compactLabel: String {
        let t = service.currentInputTokens(for: sessionID)
        if t >= 1_000 { return "\(t / 1000)k" }
        return "\(t)"
    }

    var body: some View {
        if service.currentInputTokens(for: sessionID) > 0 {
            HStack(spacing: 5) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: ratio)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.4), value: ratio)
                }
                .frame(width: 14, height: 14)

                Text(compactLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .onHover { isHovered = $0 }
            .popover(isPresented: $isHovered, arrowEdge: .bottom) {
                contextDetailPopover
                    .padding(16)
                    .frame(width: 290)
            }
        }
    }

    // MARK: - Detail Popover

    private var contextDetailPopover: some View {
        let modelID = service.currentModelID(for: sessionID)
        let total = service.contextWindowSize(for: modelID)
        let used = service.currentInputTokens(for: sessionID)
        let remaining = max(total - used, 0)
        let pct = Int(ratio * 100)
        let usedStr = formatTokens(used)
        let totalStr = formatTokens(total)
        let remainStr = formatTokens(remaining)

        return VStack(alignment: .leading, spacing: 12) {

            // Header
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .foregroundStyle(ringColor)
                Text("上下文用量")
                    .font(.headline)
                Spacer()
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(ringColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(ringColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            Divider()

            // Model
            detailRow(label: "模型") {
                Text(modelID.isEmpty ? "—" : modelID)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }

            // Tokens used
            detailRow(label: "已用 / 上限") {
                Text("\(usedStr) / \(totalStr)")
                    .font(.caption)
                    .monospacedDigit()
            }

            // Percentage
            detailRow(label: "使用率") {
                Text("\(pct)%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(ringColor)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: progressGradientColors,
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * ratio, height: 6)
                        .animation(.easeInOut(duration: 0.4), value: ratio)
                }
            }
            .frame(height: 6)

            Divider()

            // Remaining
            detailRow(label: "剩余容量") {
                Text("\(remainStr) tokens")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(ratio > 0.8 ? .red : .secondary)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func detailRow<V: View>(label: String, @ViewBuilder value: () -> V) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            value()
        }
    }

    private var progressGradientColors: [Color] {
        if ratio < 0.6 { return [.green.opacity(0.7), .green] }
        if ratio < 0.8 { return [.green, .yellow] }
        return [.yellow, .red]
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

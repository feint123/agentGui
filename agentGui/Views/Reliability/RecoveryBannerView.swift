import SwiftUI

struct RecoveryBannerView: View {
    let snapshot: RecoverySnapshot
    let onView: () -> Void
    let onInterrupt: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("检测到可恢复的\(snapshot.sourceKind.displayName)")
                    .font(.headline)
                Text(snapshot.summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                HStack(spacing: 10) {
                    Button("恢复查看", action: onView)
                    Button("标记为中断", action: onInterrupt)
                    Button("清理现场", role: .destructive, action: onClear)
                }
                .buttonStyle(.bordered)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.orange.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
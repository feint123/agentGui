import SwiftUI

struct RecoveryBannerView: View {
    let titleText: String
    let summaryText: String
    let onView: (() -> Void)?
    let onInterrupt: (() -> Void)?
    let onClear: (() -> Void)?

    init(
        snapshot: RecoverySnapshot,
        onView: @escaping () -> Void,
        onInterrupt: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) {
        self.titleText = "检测到可恢复的\(snapshot.sourceKind.displayName)"
        self.summaryText = snapshot.summaryText
        self.onView = onView
        self.onInterrupt = onInterrupt
        self.onClear = onClear
    }

    init(runtimeItem: RuntimeRecoveryService.RuntimeRecoveryItem) {
        self.titleText = runtimeItem.titleText
        self.summaryText = runtimeItem.summaryText
        self.onView = nil
        self.onInterrupt = nil
        self.onClear = nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(titleText)
                    .font(.headline)
                Text(summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                if let onView {
                    HStack(spacing: 10) {
                        Button("恢复查看", action: onView)
                            .accessibilityIdentifier("recovery.viewButton")

                        if let onInterrupt {
                            Button("标记为中断", action: onInterrupt)
                                .accessibilityIdentifier("recovery.interruptButton")
                        }

                        if let onClear {
                            Button("清理现场", role: .destructive, action: onClear)
                                .accessibilityIdentifier("recovery.clearButton")
                        }
                    }
                    .buttonStyle(.bordered)
                }
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
        .accessibilityIdentifier("recovery.banner")
    }
}
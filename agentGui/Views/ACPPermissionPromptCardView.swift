import SwiftUI

struct ACPPermissionPromptCardView: View {
    enum Emphasis {
        case theater(accentColor: Color)
        case detail
    }

    @Environment(ClaudeService.self) private var claudeService

    let request: ACPPermissionCenter.PendingRequest
    let emphasis: Emphasis

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.contentSpacing) {
            headerSection

            if let reason = request.reason, !reason.isEmpty {
                Text(reason)
                    .font(metrics.reasonFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                ForEach(request.options) { option in
                    permissionActionButton(title: option.name, isPrimary: option.isAllowOption) {
                        claudeService.acpPermissionCenter.selectOption(
                            requestID: request.id,
                            optionID: option.id
                        )
                    }
                }

                if !hasRejectOption {
                    permissionActionButton(title: "取消", isPrimary: false) {
                        claudeService.acpPermissionCenter.cancel(requestID: request.id)
                    }
                }
            }
        }
        .padding(metrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(border)
        .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius))
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange.opacity(0.92))
                .frame(width: 22, height: 22)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text("等待 \(request.source.providerDisplayName) 权限批准")
                    .font(metrics.titleFont)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                Text(request.title)
                    .font(metrics.subtitleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(titleLineLimit)
            }

            Spacer(minLength: 0)

            Text("需处理")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange.opacity(0.92))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.12), in: Capsule())
        }
    }

    @ViewBuilder
    private func permissionActionButton(
        title: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if isPrimary {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Button(title, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var metrics: Metrics {
        switch emphasis {
        case .theater:
            return Metrics(
                padding: 12,
                cornerRadius: 12,
                contentSpacing: 10,
                titleFont: .caption,
                subtitleFont: .caption2,
                reasonFont: .caption2
            )
        case .detail:
            return Metrics(
                padding: 10,
                cornerRadius: 8,
                contentSpacing: 8,
                titleFont: .caption,
                subtitleFont: .caption,
                reasonFont: .caption2
            )
        }
    }

    private var titleLineLimit: Int? {
        switch emphasis {
        case .theater:
            return 2
        case .detail:
            return nil
        }
    }

    private var hasRejectOption: Bool {
        request.options.contains(where: { !$0.isAllowOption })
    }

    @ViewBuilder
    private var background: some View {
        switch emphasis {
        case .theater(let accentColor):
            RoundedRectangle(cornerRadius: metrics.cornerRadius)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.orange.opacity(0.16),
                            accentColor.opacity(0.08),
                            Color.primary.opacity(0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        case .detail:
            RoundedRectangle(cornerRadius: metrics.cornerRadius)
                .fill(Color.orange.opacity(0.08))
        }
    }

    @ViewBuilder
    private var border: some View {
        switch emphasis {
        case .theater(let accentColor):
            RoundedRectangle(cornerRadius: metrics.cornerRadius)
                .stroke(accentColor.opacity(0.18), lineWidth: 1)
        case .detail:
            RoundedRectangle(cornerRadius: metrics.cornerRadius)
                .stroke(Color.orange.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct Metrics {
    let padding: CGFloat
    let cornerRadius: CGFloat
    let contentSpacing: CGFloat
    let titleFont: Font
    let subtitleFont: Font
    let reasonFont: Font
}
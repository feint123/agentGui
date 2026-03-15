import SwiftUI

struct LSPServiceRowView: View {
    let service: LSPServicePresentation
    let isBusy: Bool
    let isExpanded: Bool
    let onToggleDetail: () -> Void
    let onAction: (LSPManagementAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.title)
                        .font(.subheadline.weight(.semibold))

                    Text(service.languagesText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(service.installStatusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(installStatusColor)

                    if let installActivityText = service.installActivityText, !installActivityText.isEmpty {
                        Text(installActivityText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(service.runtimeStatusText)
                        .font(.caption)
                        .foregroundStyle(runtimeColor)
                }
            }

            HStack(spacing: 8) {
                ForEach(service.availableActions, id: \.self) { action in
                    Button(actionTitle(action)) {
                        onAction(action)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isBusy || service.isInstallInProgress)
                }

                Spacer()

                Button(isExpanded ? "收起详情" : "查看详情") {
                    onToggleDetail()
                }
                .buttonStyle(.plain)
                .font(.caption)
            }
        }
        .accessibilityIdentifier("settings.tools.lspService.\(service.id)")
    }

    private var runtimeColor: Color {
        switch service.runtimeStatusText {
        case "运行中":
            return .green
        case "启动失败", "运行崩溃", "未安装":
            return .red
        case "启动中":
            return .orange
        default:
            return .secondary
        }
    }

    private var installStatusColor: Color {
        switch service.installStatusText {
        case "安装中", "准备中", "探测版本":
            return .orange
        case "安装失败":
            return .red
        case "已安装":
            return .green
        default:
            return .secondary
        }
    }

    private func actionTitle(_ action: LSPManagementAction) -> String {
        switch action {
        case .install:
            return "安装"
        case .recheck:
            return "重检"
        case .start:
            return "启动"
        case .stop:
            return "停止"
        case .restart:
            return "重启"
        case .repair:
            return "修复"
        }
    }
}
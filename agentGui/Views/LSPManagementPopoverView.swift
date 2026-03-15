import SwiftUI

struct LSPManagementPopoverView: View {
    let viewModel: LSPManagementViewModel
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .foregroundStyle(Color.accentColor)
                Text("LSP 服务管理")
                    .font(.headline)
                Spacer()
                Button("打开设置") {
                    onOpenSettings()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            Form {
                LSPManagementSectionView(viewModel: viewModel)
            }
            .formStyle(.grouped)
        }
        .padding(16)
        .frame(width: 460, height: 420)
    }
}
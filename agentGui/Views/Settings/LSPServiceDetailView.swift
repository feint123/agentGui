import SwiftUI

struct LSPServiceDetailView: View {
    let service: LSPServicePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow(title: "安装状态", value: service.installStatusText)
            detailRow(title: "运行状态", value: service.runtimeStatusText)
            detailRow(title: "语言", value: service.languagesText)

            if let versionText = service.versionText, !versionText.isEmpty {
                detailRow(title: "版本", value: versionText)
            }

            if let installActivityText = service.installActivityText, !installActivityText.isEmpty {
                detailRow(title: "安装进度", value: installActivityText)
            }

            if let executablePath = service.executablePath, !executablePath.isEmpty {
                detailRow(title: "可执行文件", value: executablePath)
            }

            if let detailText = service.detailText, !detailText.isEmpty {
                detailRow(title: "最近错误", value: detailText)
            }

            if !service.installLogLines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("安装日志")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(Array(service.installLogLines.suffix(6).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)

            Text(value)
                .font(.caption)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
    }
}
import SwiftUI

struct LSPDiagnosticRowPresentation: Equatable {
    let severity: LSPDiagnosticSeverity
    let severityText: String
    let pathText: String
    let messageText: String
    let metadataText: String?

    static func make(_ item: LSPProjectDiagnosticsSummary.DiagnosticItem) -> LSPDiagnosticRowPresentation {
        var metadataParts: [String] = []
        if let source = item.source, !source.isEmpty {
            metadataParts.append(source)
        }
        if let line = item.line, let character = item.character {
            metadataParts.append("L\(line + 1):C\(character + 1)")
        }

        return LSPDiagnosticRowPresentation(
            severity: item.severity,
            severityText: item.severity.rawValue,
            pathText: URL(string: item.uri)?.lastPathComponent ?? item.uri,
            messageText: item.message,
            metadataText: metadataParts.isEmpty ? nil : metadataParts.joined(separator: " · ")
        )
    }
}

struct LSPDiagnosticsPopoverView: View {
    let status: WorkspacePanelLSPStatusPresentation

    private var stateColor: Color {
        let normalized = status.stateText.lowercased()
        if normalized.contains("running") {
            return .green
        }
        if normalized.contains("failed") || normalized.contains("crashed") {
            return .red
        }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble")
                    .foregroundStyle(stateColor)
                Text("LSP 错误详情")
                    .font(.headline)
                Spacer()
                Text(status.stateText)
                    .font(.caption)
                    .foregroundStyle(stateColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(stateColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            Divider()

            detailRow(label: "服务") {
                Text(status.serverID ?? "未绑定")
                    .font(.caption)
            }

            detailRow(label: "错误 / 警告") {
                Text("\(status.errorCount) / \(status.warningCount)")
                    .font(.caption)
                    .monospacedDigit()
            }

            if let summary = status.projectSummary {
                detailRow(label: "受影响文件") {
                    Text("\(summary.filesWithDiagnostics)")
                        .font(.caption)
                        .monospacedDigit()
                }

                detailRow(label: "最近更新") {
                    Text(summary.updatedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                }

                Divider()

                if summary.recentDiagnostics.isEmpty {
                    Text("当前项目没有诊断信息")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(summary.recentDiagnostics.prefix(6).enumerated()), id: \.offset) { _, item in
                            diagnosticRow(item)
                        }
                    }
                }
            } else {
                Text("当前项目没有诊断信息")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

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

    private func diagnosticRow(_ item: LSPProjectDiagnosticsSummary.DiagnosticItem) -> some View {
        let presentation = LSPDiagnosticRowPresentation.make(item)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color(for: presentation.severity))
                    .frame(width: 6, height: 6)
                Text(presentation.severityText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color(for: presentation.severity))
                Spacer()
                Text(presentation.pathText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(presentation.messageText)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            if let metadataText = presentation.metadataText {
                Text(metadataText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 4)
    }

    private func color(for severity: LSPDiagnosticSeverity) -> Color {
        switch severity {
        case .error:
            return .red
        case .warning:
            return .orange
        case .information:
            return .blue
        case .hint:
            return .secondary
        }
    }
}
import SwiftUI
import SwiftData

struct ReliabilityCenterView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RuntimeRecoveryService.self) private var runtimeRecoveryService
    @Environment(ReliabilityCenterViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchSidebarPanelHeader {
                WorkbenchSidebarToolbarHeader {
                    HStack(spacing: 8) {
                        Label("诊断中心", systemImage: "cross.case")
                            .font(.subheadline.weight(.semibold))
                        Text(statusSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } trailing: {
                    Button {
                        viewModel.refresh(using: modelContext)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("reliability.refresh")
                }
            }

            WorkbenchSidebarPanelScrollView {
                WorkbenchSidebarSectionCard(title: "完整性问题", systemImage: "exclamationmark.triangle") {
                    integrityIssuesContent
                }

                WorkbenchSidebarSectionCard(title: "恢复项", systemImage: "arrow.clockwise.circle") {
                    recoveryItemsContent
                }

                WorkbenchSidebarSectionCard(title: "最近保存失败", systemImage: "externaldrive.badge.exclamationmark") {
                    persistenceFailuresContent
                }

                WorkbenchSidebarSectionCard(title: "备份", systemImage: "archivebox") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("导出全量备份") {
                            viewModel.exportAllBackup(using: modelContext)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        if let status = viewModel.lastBackupStatus {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("reliability.root")
        .onAppear {
            viewModel.refresh(using: modelContext)
        }
    }

    private var statusSummary: String {
        if viewModel.issueCount == 0 {
            return "当前没有待处理问题"
        }
        return "共 \(viewModel.issueCount) 项待关注"
    }

    @ViewBuilder
    private var integrityIssuesContent: some View {
        if viewModel.integrityIssues.isEmpty {
            Text("未发现完整性问题")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.integrityIssues.enumerated()), id: \.element.id) { index, issue in
                    if index > 0 {
                        Divider()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.kind.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text(issue.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }

    @ViewBuilder
    private var recoveryItemsContent: some View {
        if viewModel.recoverySnapshots.isEmpty {
            Text("当前没有待处理的恢复项")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.recoverySnapshots.enumerated()), id: \.element.id) { index, snapshot in
                    if index > 0 {
                        Divider()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(snapshot.sourceKind.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text(snapshot.summaryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("查看") {
                                try? runtimeRecoveryService.markViewed(snapshot, in: modelContext)
                                viewModel.refresh(using: modelContext)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("中断") {
                                try? runtimeRecoveryService.markInterrupted(snapshot, in: modelContext)
                                viewModel.refresh(using: modelContext)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("清理", role: .destructive) {
                                try? runtimeRecoveryService.clear(snapshot, in: modelContext)
                                viewModel.refresh(using: modelContext)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }

    @ViewBuilder
    private var persistenceFailuresContent: some View {
        if viewModel.persistenceFailures.isEmpty {
            Text("暂无保存失败记录")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.persistenceFailures.enumerated()), id: \.offset) { index, failure in
                    if index > 0 {
                        Divider()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(failure.userMessage)
                            .font(.subheadline.weight(.semibold))
                        Text(failure.technicalMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }
}
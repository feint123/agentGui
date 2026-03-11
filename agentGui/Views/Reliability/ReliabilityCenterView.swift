import SwiftUI
import SwiftData

struct ReliabilityCenterView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RuntimeRecoveryService.self) private var runtimeRecoveryService
    @Environment(ReliabilityCenterViewModel.self) private var viewModel

    var body: some View {
        NavigationStack {
            List {
                Section("完整性问题") {
                    if viewModel.integrityIssues.isEmpty {
                        Text("未发现完整性问题")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.integrityIssues) { issue in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(issue.kind.displayName)
                                    .font(.headline)
                                Text(issue.summary)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("恢复项") {
                    if viewModel.recoverySnapshots.isEmpty {
                        Text("当前没有待处理的恢复项")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.recoverySnapshots) { snapshot in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(snapshot.sourceKind.displayName)
                                    .font(.headline)
                                Text(snapshot.summaryText)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    Button("查看") {
                                        try? runtimeRecoveryService.markViewed(snapshot, in: modelContext)
                                        viewModel.refresh(using: modelContext)
                                    }
                                    Button("中断") {
                                        try? runtimeRecoveryService.markInterrupted(snapshot, in: modelContext)
                                        viewModel.refresh(using: modelContext)
                                    }
                                    Button("清理", role: .destructive) {
                                        try? runtimeRecoveryService.clear(snapshot, in: modelContext)
                                        viewModel.refresh(using: modelContext)
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("最近保存失败") {
                    if viewModel.persistenceFailures.isEmpty {
                        Text("暂无保存失败记录")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.persistenceFailures, id: \.createdAt) { failure in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(failure.userMessage)
                                    .font(.headline)
                                Text(failure.technicalMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("备份") {
                    Button("导出全量备份") {
                        viewModel.exportAllBackup(using: modelContext)
                    }

                    if let status = viewModel.lastBackupStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("诊断中心")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("刷新") {
                        viewModel.refresh(using: modelContext)
                    }
                }
            }
            .onAppear {
                viewModel.refresh(using: modelContext)
            }
        }
    }
}
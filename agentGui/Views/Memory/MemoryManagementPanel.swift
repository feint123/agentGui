import SwiftUI

struct MemoryManagementPanel: View {
    @State private var viewModel = MemoryManagementViewModel()
    @State private var loadError: String?
    @State private var rejectCandidate: MemoryConfirmationCandidate?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summarySection
                sweepSection
                breakdownSection(title: "Scope 统计", items: viewModel.scopeSummaries)
                breakdownSection(title: "Layer 统计", items: viewModel.layerSummaries)

                GroupBox("待确认写入") {
                    MemoryConfirmationList(
                        candidates: viewModel.pendingConfirmations,
                        onApprove: { candidate in
                            do {
                                try await viewModel.approve(candidateID: candidate.id)
                            } catch {
                                loadError = error.localizedDescription
                            }
                        },
                        onReject: { candidate in
                            rejectCandidate = candidate
                        }
                    )
                }

                GroupBox("冲突 / 替代记录") {
                    MemoryConflictList(records: viewModel.conflictRecords)
                }
            }
            .padding(20)
        }
        .navigationTitle("记忆治理面板")
        .task {
            do {
                try viewModel.reload()
            } catch {
                loadError = error.localizedDescription
            }
        }
        .alert("加载失败", isPresented: Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
            Button("确定") { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
        .confirmationDialog(
            "拒绝这条待确认写入？",
            isPresented: Binding(get: { rejectCandidate != nil }, set: { if !$0 { rejectCandidate = nil } })
        ) {
            if let rejectCandidate {
                Button("拒绝", role: .destructive) {
                    do {
                        try viewModel.reject(candidateID: rejectCandidate.id, reason: "User rejected")
                    } catch {
                        loadError = error.localizedDescription
                    }
                    self.rejectCandidate = nil
                }
            }

            Button("取消", role: .cancel) {
                rejectCandidate = nil
            }
        }
    }

    private var summarySection: some View {
        GroupBox("概览") {
            VStack(alignment: .leading, spacing: 8) {
                summaryRow("总记录数", value: viewModel.totalRecordCount)
                summaryRow("待确认", value: viewModel.pendingConfirmationCount)
                summaryRow("冲突 / 替代", value: viewModel.conflictCount)
                summaryRow("归档", value: viewModel.archivedCount)
            }
        }
    }

    private var sweepSection: some View {
        GroupBox("TTL Sweep") {
            VStack(alignment: .leading, spacing: 8) {
                if let report = viewModel.latestSweepReport {
                    summaryRow("最近归档", value: report.archivedCount)
                    summaryRow("最近待复核", value: report.revalidationCount)
                } else {
                    Text("暂无 sweep 记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("立即执行 Sweep") {
                    do {
                        try viewModel.runSweep()
                    } catch {
                        loadError = error.localizedDescription
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func breakdownSection(title: String, items: [MemoryManagementViewModel.CountSummary]) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                if items.isEmpty {
                    Text("暂无数据")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        summaryRow(item.label, value: item.count)
                    }
                }
            }
        }
    }

    private func summaryRow(_ label: String, value: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(value)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
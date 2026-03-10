import SwiftUI

struct MemoryManagementPanel: View {
    @State private var viewModel = MemoryManagementViewModel()
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summarySection
                breakdownSection(title: "Scope 统计", items: viewModel.scopeSummaries)
                breakdownSection(title: "Layer 统计", items: viewModel.layerSummaries)

                GroupBox("待确认写入") {
                    MemoryConfirmationList(candidates: viewModel.pendingConfirmations)
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
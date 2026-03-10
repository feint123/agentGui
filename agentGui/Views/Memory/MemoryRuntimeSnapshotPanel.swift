import SwiftUI

struct MemoryRuntimeSnapshotPanel: View {
    @State var viewModel: MemoryRuntimeSnapshotViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summarySection
                controlsSection
                MemoryRuntimeSnapshotCharts(viewModel: viewModel)
                budgetTableSection
                MemoryRuntimeSnapshotRecordList(title: "入选记录", records: viewModel.selectedRecords)
                MemoryRuntimeSnapshotRecordList(title: "排除记录", records: viewModel.excludedRecords, showExclusionReason: true)
                promptSection
            }
            .padding(20)
        }
        .navigationTitle("记忆上下文快照")
        .frame(minWidth: 860, minHeight: 720)
    }

    private var summarySection: some View {
        GroupBox("概览") {
            VStack(alignment: .leading, spacing: 8) {
                summaryRow("Task Kind", value: viewModel.snapshot.request.taskKind.rawValue)
                summaryRow("Profiles", value: viewModel.snapshot.plan.profileIDs.joined(separator: ", "))
                summaryRow("Scopes", value: viewModel.snapshot.plan.candidateScopes.joined(separator: ", "))
                summaryRow("Context Budget", value: "\(viewModel.snapshot.request.contextBudget)")
                summaryRow("Candidates", value: "\(viewModel.selectedSummary.candidateCount)")
                summaryRow("Selected", value: "\(viewModel.selectedSummary.selectedCount)")
                summaryRow("Excluded", value: "\(viewModel.selectedSummary.excludedCount)")
                summaryRow("Estimated Chars", value: "\(viewModel.selectedSummary.totalEstimatedPromptChars)")
            }
        }
    }

    private var controlsSection: some View {
        HStack(spacing: 16) {
            Picker("维度", selection: $viewModel.dimension) {
                Text("Layer").tag(MemoryRuntimeSnapshotViewModel.Dimension.layer)
                Text("Kind").tag(MemoryRuntimeSnapshotViewModel.Dimension.kind)
                Text("Scope").tag(MemoryRuntimeSnapshotViewModel.Dimension.scope)
                Text("Verification").tag(MemoryRuntimeSnapshotViewModel.Dimension.verificationStatus)
                Text("Source").tag(MemoryRuntimeSnapshotViewModel.Dimension.source)
            }
            .pickerStyle(.segmented)

            Picker("口径", selection: $viewModel.metric) {
                Text("条目数").tag(MemoryRuntimeSnapshotViewModel.Metric.count)
                Text("字符数").tag(MemoryRuntimeSnapshotViewModel.Metric.estimatedChars)
            }
            .pickerStyle(.segmented)
        }
    }

    private var budgetTableSection: some View {
        GroupBox("Layer 预算明细") {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.layerBudgetItems.isEmpty {
                    Text("暂无预算明细")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.layerBudgetItems) { item in
                        HStack {
                            Text(item.layer.rawValue)
                            Spacer()
                            Text("budget \(item.budget) · candidates \(item.candidates) · selected \(item.selected)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var promptSection: some View {
        GroupBox("Prompt 预览") {
            if viewModel.snapshot.renderedPrompt.isEmpty {
                Text("本轮没有注入记忆文本")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    Text(viewModel.snapshot.renderedPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func summaryRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
            Spacer()
            Text(value.isEmpty ? "-" : value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
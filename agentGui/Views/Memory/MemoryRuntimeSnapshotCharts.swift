import Charts
import SwiftUI

struct MemoryRuntimeSnapshotCharts: View {
    let viewModel: MemoryRuntimeSnapshotViewModel

    private struct BudgetBarItem: Identifiable {
        let id = UUID()
        let layer: String
        let series: String
        let value: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(chartTitle) {
                if viewModel.chartItems.isEmpty {
                    emptyState("暂无可绘制的占比数据")
                } else {
                    Chart(viewModel.chartItems) { item in
                        SectorMark(
                            angle: .value("数值", item.value),
                            innerRadius: .ratio(0.55),
                            angularInset: 2
                        )
                        .foregroundStyle(by: .value("类别", item.label))
                    }
                    .frame(height: 240)
                }
            }

            GroupBox("Layer 预算使用") {
                if viewModel.layerBudgetItems.isEmpty {
                    emptyState("暂无 Layer 预算数据")
                } else {
                    Chart(budgetBars) { item in
                        BarMark(
                            x: .value("数量", item.value),
                            y: .value("Layer", item.layer)
                        )
                        .foregroundStyle(by: .value("系列", item.series))
                        .position(by: .value("系列", item.series))
                    }
                    .frame(height: max(180, CGFloat(viewModel.layerBudgetItems.count) * 38))
                }
            }
        }
    }

    private var chartTitle: String {
        let metricText = switch viewModel.metric {
        case .count:
            "条目数占比"
        case .estimatedChars:
            "字符占比（估算）"
        }
        return "按 \(viewModel.dimension.rawValue) 的 \(metricText)"
    }

    private var budgetBars: [BudgetBarItem] {
        viewModel.layerBudgetItems.flatMap { item in
            [
                BudgetBarItem(layer: item.layer.rawValue, series: "Budget", value: item.budget),
                BudgetBarItem(layer: item.layer.rawValue, series: "Candidates", value: item.candidates),
                BudgetBarItem(layer: item.layer.rawValue, series: "Selected", value: item.selected)
            ]
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }
}
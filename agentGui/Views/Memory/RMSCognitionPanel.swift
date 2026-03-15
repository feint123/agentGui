import SwiftUI
import SwiftData

struct RMSPanel: View {
    @Environment(\.modelContext) private var modelContext
    private let sessionID: String?

    @State private var state: RMSState?
    @State private var loadError: String?

    init(sessionID: String? = nil) {
        self.sessionID = sessionID
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let state {
                    let viewModel = RMSPanelViewModel(state: state)
                    heroSection(viewModel: viewModel)
                    verificationSummarySection(viewModel: viewModel)
                    frontierSection(viewModel: viewModel)
                    counterexampleSection(viewModel: viewModel)
                    constraintSection(viewModel: viewModel)
                    verificationDebtSection(viewModel: viewModel)
                    nextActionsSection(viewModel: viewModel)
                } else if let loadError {
                    ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else {
                    ContentUnavailableView(
                        "暂无 RMS 状态",
                        systemImage: "brain",
                        description: Text("当任务 loop 产生 task-bound RMS state 后，这里会显示 frontiers、反例、约束、验证债务和建议动作。")
                    )
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("RMS 面板")
        .task {
            loadLatestSnapshot()
        }
    }

    private func heroSection(viewModel: RMSPanelViewModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("当前任务认知状态")
                .font(.title2.weight(.semibold))
            Text(heroDescription(viewModel: viewModel))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                cognitionChip(title: "前沿", value: viewModel.frontierItems.count, tint: .orange)
                cognitionChip(title: "反例", value: viewModel.counterexampleItems.count, tint: .red)
                cognitionChip(title: "约束", value: viewModel.constraintItems.count, tint: .blue)
                cognitionChip(title: "验证债务", value: viewModel.verificationDebtItems.count, tint: .yellow)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func frontierSection(viewModel: RMSPanelViewModel) -> some View {
        cognitionSection(title: "Frontiers", subtitle: "系统当前仍未关闭的关键前沿") {
            itemList(items: viewModel.frontierItems) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.goal)
                        .font(.headline)
                    Text(item.openClaim)
                        .font(.subheadline)
                    Text("impact: \(item.impactLevel) · probe: \(item.suggestedProbe)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("stop condition: \(item.stopCondition)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func verificationSummarySection(viewModel: RMSPanelViewModel) -> some View {
        guard let summary = viewModel.verificationSummary else {
            return AnyView(EmptyView())
        }

        return AnyView(
            cognitionSection(title: "Verification Summary", subtitle: "当前未关闭 frontiers 与验证债务") {
                HStack(spacing: 12) {
                    cognitionChip(title: "前沿数", value: "\(summary.frontierCount)", tint: .orange)
                    cognitionChip(title: "债务数", value: "\(summary.debtCount)", tint: .yellow)
                }
            }
        )
    }

    private func counterexampleSection(viewModel: RMSPanelViewModel) -> some View {
        cognitionSection(title: "Counterexamples", subtitle: "当前正在阻止错误路径的反例") {
            itemList(items: viewModel.counterexampleItems) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.summary)
                        .font(.headline)
                    Text("替代动作：\(item.replacementAction)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func constraintSection(viewModel: RMSPanelViewModel) -> some View {
        cognitionSection(title: "Constraints", subtitle: "当前任务的显式边界与约束") {
            itemList(items: viewModel.constraintItems) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.summary)
                        .font(.headline)
                    Text(item.scopeSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func verificationDebtSection(viewModel: RMSPanelViewModel) -> some View {
        cognitionSection(title: "Verification Debt", subtitle: "当前仍缺少直接证据的判断") {
            itemList(items: viewModel.verificationDebtItems) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.claim)
                        .font(.headline)
                    Text(item.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func nextActionsSection(viewModel: RMSPanelViewModel) -> some View {
        cognitionSection(title: "Suggested Next Actions", subtitle: "当前最值得执行的下一步") {
            itemList(items: viewModel.suggestedActionItems) { item in
                Text(item.summary)
                    .font(.headline)
            }
        }
    }

    private func cognitionSection<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func itemList<Item: Identifiable, Content: View>(items: [Item], @ViewBuilder row: @escaping (Item) -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if items.isEmpty {
                Text("暂无数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    row(item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private func cognitionChip(title: String, value: Int, tint: Color) -> some View {
        cognitionChip(title: title, value: "\(value)", tint: tint)
    }

    private func cognitionChip(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func heroDescription(viewModel: RMSPanelViewModel) -> String {
        if viewModel.frontierItems.isEmpty && viewModel.verificationDebtItems.isEmpty {
            return "当前没有显著未决前沿或验证债务，系统处于相对稳定的认知状态。"
        }

        return "当前界面突出显示未决前沿、关键反例、约束与验证债务，帮助你理解系统为什么建议下一步动作。"
    }

    private func loadLatestSnapshot() {
        do {
            guard let sessionID, !sessionID.isEmpty else {
                state = nil
                loadError = nil
                return
            }
            let descriptor = FetchDescriptor<SessionTaskState>(
                predicate: #Predicate { $0.sessionId == sessionID }
            )
            state = try modelContext.fetch(descriptor).first?.rmsState
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
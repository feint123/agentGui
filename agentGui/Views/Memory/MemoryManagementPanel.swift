import SwiftUI

struct MemoryManagementPanel: View {
    @State private var viewModel: MemoryManagementViewModel
    @State private var loadError: String?
    @State private var rejectCandidate: MemoryConfirmationCandidate?

    init(settings: AppSettings? = nil) {
        _viewModel = State(initialValue: MemoryManagementViewModel(settings: settings))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroSection
                metricsSection
                queueSection
                analyticsSection
                rolloutSection
                recordRowsSection
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("RMS 治理")
        .task {
            reload()
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
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("刷新") {
                    reload()
                }

                Button("立即 Sweep") {
                    runSweep()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RMS 治理工作台")
                        .font(.title2.weight(.semibold))
                    Text(heroDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 24)

                VStack(alignment: .trailing, spacing: 8) {
                    statusBadge(
                        title: viewModel.governanceHealth == .healthy ? "治理健康" : "需要处理",
                        symbolName: viewModel.governanceHealth == .healthy ? "checkmark.shield" : "exclamationmark.shield",
                        tint: viewModel.governanceHealth == .healthy ? .green : .orange
                    )

                    if let report = viewModel.latestSweepReport {
                        Text("最近 Sweep: \(relativeDateString(report.runAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 12) {
                if viewModel.reviewQueueCount > 0 {
                    Text("当前有 \(viewModel.reviewQueueCount) 条记录需要人工判断")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var metricsSection: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
            ForEach(viewModel.dashboardMetrics) { metric in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: metric.symbolName)
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Text("\(metric.value)")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    }

                    Text(metric.title)
                        .font(.headline)
                    Text(metric.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                )
            }
        }
    }

    private var queueSection: some View {
        HStack(alignment: .top, spacing: 16) {
            surfaceSection(title: "待确认写入", subtitle: "低置信度或需要人工裁决的候选写入") {
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

            surfaceSection(title: "冲突 / 替代记录", subtitle: "需要判断是否保留旧结论或接受新结论") {
                MemoryConflictList(records: viewModel.conflictRecords)
            }
        }
    }

    private var analyticsSection: some View {
        HStack(alignment: .top, spacing: 16) {
            surfaceSection(title: "Scope 分布", subtitle: "按命名空间观察记忆落点") {
                breakdownContent(items: viewModel.scopeSummaries)
            }

            surfaceSection(title: "Layer 分布", subtitle: "按层级观察工作记忆与语义记忆占比") {
                breakdownContent(items: viewModel.layerSummaries)
            }

            surfaceSection(title: "TTL Sweep", subtitle: "最近一次自动整理输出") {
                VStack(alignment: .leading, spacing: 10) {
                    if let report = viewModel.latestSweepReport {
                        summaryRow("最近归档", value: report.archivedCount)
                        summaryRow("最近待复核", value: report.revalidationCount)
                        summaryRow("跳过", value: report.skippedCount)
                    } else {
                        Text("暂无 sweep 记录")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var rolloutSection: some View {
        guard !viewModel.rolloutFlags.isEmpty else {
            return AnyView(EmptyView())
        }

        return AnyView(
            surfaceSection(title: "RMS Rollout", subtitle: "当前 RMS control plane 的特性开关状态") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.rolloutFlags) { flag in
                        HStack(spacing: 12) {
                            Text(flag.label)
                            Spacer()
                            Text(flag.isEnabled ? "Enabled" : "Disabled")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(flag.isEnabled ? .green : .secondary)
                        }
                        .font(.caption)
                    }
                }
            }
        )
    }

    private var recordRowsSection: some View {
        surfaceSection(title: "最近更新记录", subtitle: "优先暴露最近变化的治理结果，便于快速核对") {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.recentRecordRows.isEmpty {
                    Text("暂无数据")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.recentRecordRows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(row.title)
                                    .font(.headline)
                                Spacer()
                                Text(row.lifecycleTierLabel)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.1), in: Capsule())
                            }
                            Text("\(row.layerLabel) · \(row.scopeLabel) · evidence \(row.evidenceCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !row.admissionExplanationSummary.isEmpty {
                                Text(row.admissionExplanationSummary)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }

    private var heroDescription: String {
        if viewModel.reviewQueueCount == 0 {
            return "当前没有待确认写入或冲突替代记录，治理队列处于稳定状态。"
        }

        return "当前有 \(viewModel.reviewQueueCount) 条记录需要处理，建议先处理待确认写入，再清理反例修订和冲突替代记录。"
    }

    private func breakdownContent(items: [MemoryManagementViewModel.CountSummary]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if items.isEmpty {
                Text("暂无数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    HStack(spacing: 12) {
                        Text(item.label)
                            .lineLimit(1)
                        Spacer()
                        Text("\(item.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func surfaceSection<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private func statusBadge(title: String, symbolName: String, tint: Color) -> some View {
        Label(title, systemImage: symbolName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
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

    private func reload() {
        do {
            try viewModel.reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func runSweep() {
        do {
            try viewModel.runSweep()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func relativeDateString(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}
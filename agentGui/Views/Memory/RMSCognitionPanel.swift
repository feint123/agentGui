import SwiftUI
import SwiftData

enum RMSPopoverLayout {
    static let minimumScrollHeight: CGFloat = 120
    static let maximumScrollHeight: CGFloat = 320

    private static let sectionHeaderHeight: CGFloat = 24
    private static let rowHeight: CGFloat = 44
    private static let overflowHintHeight: CGFloat = 18
    private static let sectionSpacing: CGFloat = 12

    static func scrollAreaHeight(for sections: [RMSPopoverPresentation.Section]) -> CGFloat {
        guard !sections.isEmpty else {
            return minimumScrollHeight
        }

        let contentHeight = sections.reduce(CGFloat(0)) { partialResult, section in
            let visibleRows = min(section.rows.count, 3)
            let rowsHeight = CGFloat(visibleRows) * rowHeight
            let overflowHeight = section.rows.count > 3 ? overflowHintHeight : 0
            return partialResult + sectionHeaderHeight + rowsHeight + overflowHeight
        } + CGFloat(max(0, sections.count - 1)) * sectionSpacing

        return min(max(contentHeight, minimumScrollHeight), maximumScrollHeight)
    }
}

struct RMSPopoverPresentation: Equatable {
    private struct RowSignature: Hashable {
        let title: String
        let detail: String?
        let metadata: String?
    }

    struct Section: Identifiable, Equatable {
        let id: String
        let title: String
        let rowTint: Color
        let rows: [Row]
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String?
        let metadata: String?
    }

    let stateText: String
    let summaryText: String
    let taskIDText: String
    let updatedAtText: String?
    let frontierCount: Int
    let verificationDebtCount: Int
    let counterexampleCount: Int
    let constraintCount: Int
    let suggestedActionCount: Int
    let sections: [Section]

    @MainActor
    static func make(_ state: RMSState) -> RMSPopoverPresentation {
        let viewModel = RMSPanelViewModel(state: state)
        let trimmedSummary = viewModel.state.summary.trimmingCharacters(in: .whitespacesAndNewlines)

        return RMSPopoverPresentation(
            stateText: viewModel.requiresAttention ? "需处理" : "稳定",
            summaryText: trimmedSummary.isEmpty ? "当前没有显著未决前沿或验证债务。" : trimmedSummary,
            taskIDText: viewModel.state.taskID.isEmpty ? "未关联任务" : viewModel.state.taskID,
            updatedAtText: viewModel.state.updatedAt?.formatted(date: .omitted, time: .shortened),
            frontierCount: viewModel.frontierItems.count,
            verificationDebtCount: viewModel.verificationDebtItems.count,
            counterexampleCount: viewModel.counterexampleItems.count,
            constraintCount: viewModel.constraintItems.count,
            suggestedActionCount: viewModel.suggestedActionItems.count,
            sections: sections(for: viewModel)
        )
    }

    @MainActor
    private static func sections(for viewModel: RMSPanelViewModel) -> [Section] {
        var sections: [Section] = []

        if !viewModel.frontierItems.isEmpty {
            sections.append(
                Section(
                    id: "frontiers",
                    title: "前沿",
                    rowTint: .orange,
                    rows: normalizedRows(viewModel.frontierItems.map {
                        Row(
                            id: $0.id,
                            title: $0.goal,
                            detail: $0.openClaim,
                            metadata: compactMetadata(parts: [
                                $0.suggestedProbe.isEmpty ? nil : "probe: \($0.suggestedProbe)",
                                $0.stopCondition.isEmpty ? nil : "stop: \($0.stopCondition)"
                            ])
                        )
                    })
                )
            )
        }

        if !viewModel.verificationDebtItems.isEmpty {
            sections.append(
                Section(
                    id: "verificationDebt",
                    title: "验证债务",
                    rowTint: .yellow,
                    rows: normalizedRows(viewModel.verificationDebtItems.map {
                        Row(id: $0.id, title: $0.claim, detail: $0.reason.isEmpty ? nil : $0.reason, metadata: nil)
                    })
                )
            )
        }

        if !viewModel.counterexampleItems.isEmpty {
            sections.append(
                Section(
                    id: "counterexamples",
                    title: "反例",
                    rowTint: .red,
                    rows: normalizedRows(viewModel.counterexampleItems.map {
                        Row(
                            id: $0.id,
                            title: $0.summary,
                            detail: $0.replacementAction.isEmpty ? nil : $0.replacementAction,
                            metadata: $0.replacementAction.isEmpty ? nil : "替代动作"
                        )
                    })
                )
            )
        }

        if !viewModel.constraintItems.isEmpty {
            sections.append(
                Section(
                    id: "constraints",
                    title: "约束",
                    rowTint: .blue,
                    rows: normalizedRows(viewModel.constraintItems.map {
                        Row(id: $0.id, title: $0.summary, detail: $0.scopeSummary, metadata: nil)
                    })
                )
            )
        }

        if !viewModel.suggestedActionItems.isEmpty {
            sections.append(
                Section(
                    id: "suggestedActions",
                    title: "建议动作",
                    rowTint: .green,
                    rows: normalizedRows(viewModel.suggestedActionItems.map {
                        Row(id: $0.id, title: $0.summary, detail: nil, metadata: nil)
                    })
                )
            )
        }

        return sections
    }

    private static func compactMetadata(parts: [String?]) -> String? {
        let resolved: [String] = parts.compactMap { (value: String?) -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return resolved.isEmpty ? nil : resolved.joined(separator: " · ")
    }

    private static func normalizedRows(_ rows: [Row]) -> [Row] {
        var seenSignatures: Set<RowSignature> = []
        var seenIDCounts: [String: Int] = [:]
        var normalized: [Row] = []

        for row in rows {
            let signature = RowSignature(title: row.title, detail: row.detail, metadata: row.metadata)
            guard seenSignatures.insert(signature).inserted else {
                continue
            }

            let duplicateIndex = seenIDCounts[row.id, default: 0] + 1
            seenIDCounts[row.id] = duplicateIndex

            normalized.append(
                Row(
                    id: duplicateIndex == 1 ? row.id : "\(row.id)-\(duplicateIndex)",
                    title: row.title,
                    detail: row.detail,
                    metadata: row.metadata
                )
            )
        }

        return normalized
    }
}

struct RMSPanel: View {
    @Environment(\.modelContext) private var modelContext
    private let sessionID: String?

    @State private var state: RMSState?
    @State private var loadError: String?

    init(sessionID: String? = nil) {
        self.sessionID = sessionID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .foregroundStyle(stateColor)
                Text("RMS 状态")
                    .font(.headline)
                Spacer()
                Text(stateText)
                    .font(.caption)
                    .foregroundStyle(stateColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(stateColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            Divider()

            if let state {
                let presentation = RMSPopoverPresentation.make(state)
                detailRow(label: "任务") {
                    Text(presentation.taskIDText)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                detailRow(label: "摘要") {
                    Text(presentation.summaryText)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }

                detailRow(label: "前沿 / 债务") {
                    Text("\(presentation.frontierCount) / \(presentation.verificationDebtCount)")
                        .font(.caption)
                        .monospacedDigit()
                }

                detailRow(label: "反例 / 约束") {
                    Text("\(presentation.counterexampleCount) / \(presentation.constraintCount)")
                        .font(.caption)
                        .monospacedDigit()
                }

                if let updatedAtText = presentation.updatedAtText {
                    detailRow(label: "最近更新") {
                        Text(updatedAtText)
                            .font(.caption)
                    }
                }

                Divider()

                if presentation.sections.isEmpty {
                    Text("当前会话没有需要展开的 RMS 项。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let scrollHeight = RMSPopoverLayout.scrollAreaHeight(for: presentation.sections)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(presentation.sections) { section in
                                sectionView(section)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: scrollHeight)
                }
            } else if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("当前会话没有 RMS 状态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 360)
        .task(id: sessionID) {
            loadLatestSnapshot()
        }
    }

    private var stateText: String {
        guard let state else {
            return loadError == nil ? "空闲" : "失败"
        }
        return RMSPopoverPresentation.make(state).stateText
    }

    private var stateColor: Color {
        switch stateText {
        case "需处理":
            return .orange
        case "失败":
            return .red
        case "稳定":
            return .green
        default:
            return .secondary
        }
    }

    @ViewBuilder
    private func detailRow<V: View>(label: String, @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value()
        }
    }

    private func sectionView(_ section: RMSPopoverPresentation.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(section.rowTint)
                    .frame(width: 6, height: 6)
                Text(section.title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(section.rows.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(section.rows.prefix(3)) { row in
                    rowView(row, tint: section.rowTint)
                }

                if section.rows.count > 3 {
                    Text("还有 \(section.rows.count - 3) 项未展开")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func rowView(_ row: RMSPopoverPresentation.Row, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint)
                    .frame(width: 4, height: 16)
                Text(row.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            if let detail = row.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            if let metadata = row.metadata {
                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 4)
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
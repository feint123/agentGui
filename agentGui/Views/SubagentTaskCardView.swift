//
//  SubagentTaskCardView.swift
//  agentGui
//
//  Presents a subagent ToolCall as a "delegated task card" rather than
//  an embedded conversation timeline. Default state shows only the task
//  name, status, and outcome summary. Expand to see the full timeline.
//

import SwiftUI

/// Shows a subagent invocation as a self-contained task card.
struct SubagentTaskCardView: View {
    let toolCall: ToolCall
    let defaultExpanded: Bool

    @State private var isExpanded: Bool
    @State private var isShowingTimeline = false
    @State private var hasManualOverride = false

    init(toolCall: ToolCall, defaultExpanded: Bool = false) {
        self.toolCall = toolCall
        self.defaultExpanded = defaultExpanded
        _isExpanded = State(initialValue: defaultExpanded)
    }

    private var sortedRounds: [AgentRound] {
        toolCall.subagentRounds.sorted { $0.roundIndex < $1.roundIndex }
    }

    /// Last round that produced text output — used as the outcome summary.
    private var conclusionText: String? {
        sortedRounds.last(where: { $0.hasText })?.text
    }

    private var agentLabel: String {
        toolCall.subagentAgentName ?? "子代理"
    }

    private var verifierVerdictText: String? {
        toolCall.verifierVerdictText
    }

    private var verifierSummary: String? {
        toolCall.verifierSummary
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            if isExpanded {
                Divider().opacity(0.15).padding(.horizontal, 10)
                expandedBody
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .onChange(of: toolCall.status) { _, newStatus in
            if !hasManualOverride {
                isExpanded = newStatus == .inProgress
            }
        }
        .onChange(of: defaultExpanded) { _, newValue in
            if !hasManualOverride {
                isExpanded = newValue
            }
        }
    }

    // MARK: - Header Row

    private var headerRow: some View {
        Button {
            withAnimation(.spring(duration: 0.2)) {
                hasManualOverride = true
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                statusIcon
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agentLabel)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    if let task = toolCall.subagentTask, !task.isEmpty {
                        Text(task)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let verdict = verifierVerdictText {
                    Text(verdict)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(toolCall.verifierPassed == true ? .green : .red)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background((toolCall.verifierPassed == true ? Color.green : Color.red).opacity(0.12))
                        .clipShape(Capsule())
                }
                if let kind = toolCall.subagentResultKind, kind == "structured" {
                    Text("JSON")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.12))
                        .clipShape(Capsule())
                }
                if !sortedRounds.isEmpty {
                    Text("\(sortedRounds.count) 轮")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let duration = toolCall.duration {
                    Text(String(format: "%.1fs", duration))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded Body

    @ViewBuilder
    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Task description
            if let task = toolCall.subagentTask, !task.isEmpty {
                labeledBlock(label: "任务") {
                    Text(task)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }

            // Outcome summary from the last text-producing round
            if let conclusion = conclusionText, !conclusion.isEmpty {
                labeledBlock(label: "结论") {
                    Text(conclusion)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(6)
                }
            }

            if let verdict = verifierVerdictText {
                labeledBlock(label: "验证结果") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verdict)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(toolCall.verifierPassed == true ? .green : .red)
                        if let verifierSummary, !verifierSummary.isEmpty {
                            Text(verifierSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(4)
                        }
                    }
                }
            }

            // In-progress placeholder
            if toolCall.status == .inProgress && sortedRounds.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("子代理执行中…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            // AgentMessage metadata (rounds, elapsed, etc.)
            if let meta = toolCall.subagentMessageMetadata, !meta.isEmpty {
                let pairs = meta.sorted { $0.key < $1.key }
                labeledBlock(label: "消息元数据") {
                    HStack(spacing: 8) {
                        ForEach(pairs, id: \.key) { key, value in
                            HStack(spacing: 3) {
                                Text(key)
                                    .foregroundStyle(.tertiary)
                                Text(value)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption2)
                        }
                    }
                }
            }

            // Full timeline
            if !sortedRounds.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isShowingTimeline.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("查看完整执行过程")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: isShowingTimeline ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    if isShowingTimeline {
                        Divider().opacity(0.15)
                        SubagentTimelineView(rounds: sortedRounds)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func labeledBlock<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            content()
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch toolCall.status {
        case .inProgress:
            ProgressView().scaleEffect(0.45).frame(width: 12, height: 12)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

//
//  WorkflowTimelineView.swift
//  agentGui
//
//  Displays the activation timeline for a workflow instance:
//  each agent activation is a row, showing role, trigger, status, and duration.
//

import SwiftUI
import SwiftData

// MARK: - WorkflowTimelineView

struct WorkflowTimelineView: View {

    let instance: WorkflowInstance

    private var activations: [WorkflowActivationRecord] {
        instance.sortedActivations
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if activations.isEmpty {
                Text("暂无激活记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(activations.indices, id: \.self) { idx in
                    ActivationRow(
                        record: activations[idx],
                        isLast: idx == activations.count - 1
                    )
                }
            }
        }
    }
}

// MARK: - ActivationRow

private struct ActivationRow: View {

    let record: WorkflowActivationRecord
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            timelineTrack
            contentArea
                .padding(.leading, 8)
                .padding(.bottom, isLast ? 0 : 12)
        }
    }

    // MARK: Track

    private var timelineTrack: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(nodeColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            if !isLast {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 18)
        .padding(.leading, 6)
    }

    private var nodeColor: Color {
        switch record.resultKind {
        case .success:   return .green
        case .partial:   return .yellow
        case .failed:    return .red
        case .escalated: return .orange
        }
    }

    // MARK: Content

    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(record.roleDisplayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                if let duration = record.duration {
                    Text(String(format: "%.1fs", duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !record.isCompleted {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }
            }

            if !record.triggerReason.isEmpty {
                Text(record.triggerReason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !record.resultSummary.isEmpty {
                Text(record.resultSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - WorkflowStatusBadge

struct WorkflowStatusBadge: View {

    let status: WorkflowStatus

    var body: some View {
        HStack(spacing: 4) {
            if status == .running {
                ProgressView().scaleEffect(0.55).frame(width: 10, height: 10)
            } else {
                Circle().fill(dotColor).frame(width: 6, height: 6)
            }
            Text(status.displayName)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(bgColor, in: Capsule())
        .foregroundStyle(dotColor)
    }

    private var dotColor: Color {
        switch status {
        case .running:   return .blue
        case .completed: return .green
        case .failed:    return .red
        case .cancelled: return .secondary
        case .paused:    return .orange
        case .pending:   return .gray
        }
    }

    private var bgColor: Color {
        dotColor.opacity(0.12)
    }
}

// MARK: - WorkflowMessageListView

struct WorkflowMessageListView: View {

    let instance: WorkflowInstance

    private var messages: [WorkflowMessageRecord] {
        instance.sortedMessages
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if messages.isEmpty {
                Text("暂无消息")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(messages) { record in
                    WorkflowMessageRow(record: record)
                }
            }
        }
    }
}

private struct WorkflowMessageRow: View {

    let record: WorkflowMessageRecord
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    kindBadge
                    Text(record.subject)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(record.sender) → \(record.recipients.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded && !record.body.isEmpty {
                Text(record.body)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var kindBadge: some View {
        Text(record.kind.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(kindColor.opacity(0.12), in: Capsule())
            .foregroundStyle(kindColor)
    }

    private var kindColor: Color {
        switch record.kind {
        case .approval:       return .green
        case .rejection:      return .red
        case .reviewFeedback: return .orange
        case .escalation:     return .red
        case .task, .handoff: return .blue
        case .infoRequest, .infoResponse: return .purple
        default:              return .secondary
        }
    }
}

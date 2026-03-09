//
//  ToolCallBubbleView.swift
//  agentGui
//

import SwiftUI

/// 工具调用卡片视图 — 显示单次工具调用的状态、输入和输出
struct ToolCallBubbleView: View {

    let toolCall: ToolCall
    let rowPresentation: ToolCallRowPresentation

    @State private var isExpanded: Bool
    @State private var hasManualOverride = false

    init(toolCall: ToolCall) {
        let row = ToolCallRowPresentation.make(
            for: toolCall,
            isExpanded: toolCall.kind != .subagent && toolCall.status == .inProgress
        )
        self.init(toolCall: toolCall, rowPresentation: row)
    }

    init(toolCall: ToolCall, rowPresentation: ToolCallRowPresentation) {
        self.toolCall = toolCall
        self.rowPresentation = rowPresentation
        _isExpanded = State(initialValue: rowPresentation.isExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            if shouldShowDetails {
                Divider().opacity(0.12)
                ToolCallDetailContentView(toolCall: toolCall, row: rowPresentation)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .background(Color.primary.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .onChange(of: toolCall.status) { _, newStatus in
            guard !hasManualOverride else { return }
            isExpanded = newStatus == .inProgress && supportsExpansion
        }
        .onChange(of: rowPresentation.isExpanded) { _, newValue in
            guard !hasManualOverride else { return }
            isExpanded = newValue
        }
    }

    private var supportsExpansion: Bool {
        rowPresentation.detailText != nil || rowPresentation.secondaryText != nil || rowPresentation.tertiaryText != nil
    }

    private var shouldShowDetails: Bool {
        supportsExpansion && isExpanded
    }

    private var iconName: String {
        switch rowPresentation.style {
        case .read:
            return "doc.text"
        case .edit:
            return "pencil.line"
        case .execute:
            return "terminal"
        case .search:
            return "magnifyingglass"
        case .fetch:
            return "arrow.down.doc"
        case .askUser:
            return "questionmark.circle"
        case .subagent:
            return "person.badge.plus"
        case .other:
            return toolCall.kind.icon
        }
    }

    private var statusColor: Color {
        switch toolCall.status {
        case .inProgress:
            return .secondary
        case .success:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        }
    }

    private var headerRow: some View {
        Button {
            guard supportsExpansion else { return }
            withAnimation(.spring(duration: 0.2)) {
                hasManualOverride = true
                isExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    statusIcon
                    Image(systemName: iconName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(rowPresentation.primaryText)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    Text(rowPresentation.statusText)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                    if let duration = rowPresentation.durationText {
                        Text(duration)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if supportsExpansion {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let secondary = rowPresentation.secondaryText, !secondary.isEmpty {
                    Text(secondary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.leading, 21)
                }

                if let tertiary = rowPresentation.tertiaryText, !tertiary.isEmpty {
                    Text(tertiary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .padding(.leading, 21)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch toolCall.status {
        case .inProgress:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 14, height: 14)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
//
//  ToolCallBubbleView.swift
//  agentGui
//

import SwiftUI

enum ToolCallBubbleBadgeTone: Equatable {
    case neutral
    case active
    case warning
}

struct ToolCallBubbleBadge: Identifiable, Equatable {
    let id: String
    let text: String
    let tone: ToolCallBubbleBadgeTone

    init(text: String, tone: ToolCallBubbleBadgeTone) {
        self.id = text + "-" + String(describing: tone)
        self.text = text
        self.tone = tone
    }
}

enum ToolCallBubbleHeaderPresentation {
    static func badges(for toolCall: ToolCall, row: ToolCallRowPresentation) -> [ToolCallBubbleBadge] {
        guard row.style == .execute else { return [] }

        var badges: [ToolCallBubbleBadge] = []

        if let mode = TerminalExecutionMode.parse(toolCall.terminalExecutionMode) {
            badges.append(.init(text: executionModeText(mode), tone: .neutral))
        }

        if let status = TerminalTaskStatus.parse(toolCall.terminalTaskStatus) {
            badges.append(.init(text: taskStatusText(status), tone: badgeTone(for: status)))
        }

        if toolCall.terminalApprovalPending {
            badges.append(.init(text: "需要批准", tone: .warning))
        }

        if toolCall.terminalUserTakeoverActive {
            badges.append(.init(text: "手动接管", tone: .active))
        }

        if let actionSummary = latestAgentActionSummary(from: toolCall.terminalAgentActionsJSON) {
            badges.append(.init(text: actionSummary, tone: .active))
        }

        return badges
    }

    static func showsStopButton(for toolCall: ToolCall) -> Bool {
        guard toolCall.kind == .execute,
              toolCall.status == .inProgress,
              let taskId = toolCall.terminalTaskId,
              !taskId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let status = TerminalTaskStatus.parse(toolCall.terminalTaskStatus) else {
            return false
        }

        return !status.isTerminal
    }

    private static func executionModeText(_ mode: TerminalExecutionMode) -> String {
        switch mode {
        case .attached:
            return "附着任务"
        case .detached:
            return "后台任务"
        }
    }

    private static func taskStatusText(_ status: TerminalTaskStatus) -> String {
        switch status {
        case .launching:
            return "启动中"
        case .running:
            return "执行中"
        case .waitingForInput:
            return "等待输入"
        case .planningInteraction:
            return "规划中"
        case .awaitingUserApproval:
            return "用户接管"
        case .userTakeover:
            return "用户接管"
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        case .interrupted:
            return "已中断"
        case .timedOut:
            return "已超时"
        case .terminated:
            return "已终止"
        }
    }

    private static func badgeTone(for status: TerminalTaskStatus) -> ToolCallBubbleBadgeTone {
        switch status {
        case .waitingForInput:
            return .active
        case .planningInteraction, .awaitingUserApproval, .userTakeover:
            return .warning
        case .failed, .timedOut, .terminated:
            return .warning
        default:
            return .neutral
        }
    }

    private static func latestAgentActionSummary(from json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let events = try? JSONDecoder().decode([TerminalTaskEvent].self, from: data) else { return nil }
        return events.last?.summary
    }
}

/// 工具调用卡片视图 — 显示单次工具调用的状态、输入和输出
struct ToolCallBubbleView: View {

    @Environment(ClaudeService.self) private var claudeService
    @Environment(\.modelContext) private var modelContext

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
            .accessibilityIdentifier("toolCall.row")
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
        ToolCallDetailPresentation.showsPrimaryTerminalScreen(for: toolCall, row: rowPresentation)
            || rowPresentation.detailText != nil
            || rowPresentation.secondaryText != nil
            || rowPresentation.tertiaryText != nil
    }

    private var shouldShowDetails: Bool {
        supportsExpansion && isExpanded
    }

    private var headerBadges: [ToolCallBubbleBadge] {
        ToolCallBubbleHeaderPresentation.badges(for: toolCall, row: rowPresentation)
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
                    if ToolCallBubbleHeaderPresentation.showsStopButton(for: toolCall) {
                        Button {
                            Task {
                                await claudeService.stopManagedTerminalTask(toolCall: toolCall, modelContext: modelContext)
                            }
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("toolCall.stopButton")
                        .help("停止当前终端任务")
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

                if !headerBadges.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(headerBadges) { badge in
                            Text(badge.text)
                                .font(.caption2)
                                .foregroundStyle(foregroundColor(for: badge.tone))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .lineLimit(1)
                                .background(backgroundColor(for: badge.tone))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.leading, 21)
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func foregroundColor(for tone: ToolCallBubbleBadgeTone) -> Color {
        switch tone {
        case .neutral:
            return .secondary
        case .active:
            return .blue
        case .warning:
            return .orange
        }
    }

    private func backgroundColor(for tone: ToolCallBubbleBadgeTone) -> Color {
        switch tone {
        case .neutral:
            return Color.secondary.opacity(0.12)
        case .active:
            return Color.blue.opacity(0.12)
        case .warning:
            return Color.orange.opacity(0.14)
        }
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

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 14.0, *) {
            HStack(spacing: spacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: spacing) {
                content
            }
        }
    }
}
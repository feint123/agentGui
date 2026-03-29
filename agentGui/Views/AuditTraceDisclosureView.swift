import SwiftUI

struct AuditTraceDisclosureView: View {
    let presentation: AuditTracePresentation

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("查看执行细节")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }.padding(.horizontal)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.agentMessage.auditDisclosure")

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(presentation.steps) { step in
                        switch step {
                        case .result(let value):
                            AgentMessageResultBlockView(presentation: value)
                        case .thinking(let value):
                            ThinkingBubbleView(presentation: value)
                        case .tool(let value):
                            ProjectedToolCallBubbleView(toolCall: value.toolCall, rowPresentation: value.row)
                        case .subagent(let value):
                            ProjectedSubagentTaskCardView(toolCall: value.toolCall, defaultExpanded: value.isExpanded)
                        }
                    }
                }
                .accessibilityIdentifier("chat.agentMessage.auditTrace")
            }
        }
    }
}

private struct ProjectedToolCallBubbleView: View {
    let toolCall: ToolCallProjectionInput
    let rowPresentation: ToolCallRowPresentation

    @State private var isExpanded: Bool
    @State private var hasManualOverride = false

    init(toolCall: ToolCallProjectionInput, rowPresentation: ToolCallRowPresentation) {
        self.toolCall = toolCall
        self.rowPresentation = rowPresentation
        _isExpanded = State(initialValue: rowPresentation.isExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard supportsExpansion else { return }
                withAnimation(.spring(duration: 0.2)) {
                    hasManualOverride = true
                    isExpanded.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
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

                    if !badges.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(badges) { badge in
                                Text(badge.text)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(badgeColor(badge.tone))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(badgeColor(badge.tone).opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.leading, 21)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if supportsExpansion && isExpanded {
                Divider().opacity(0.12)
                VStack(alignment: .leading, spacing: 6) {
                    if let tertiary = rowPresentation.tertiaryText, !tertiary.isEmpty {
                        detailBlock(label: "补充信息", text: tertiary, monospaced: false)
                    }
                    if let detail = rowPresentation.detailText, !detail.isEmpty {
                        detailBlock(label: detailLabel, text: detail, monospaced: rowPresentation.style == .execute || rowPresentation.style == .edit)
                    }
                    if let transcriptPath = toolCall.terminalTranscriptPath?.trimmingCharacters(in: .whitespacesAndNewlines), !transcriptPath.isEmpty {
                        detailBlock(label: "Transcript", text: transcriptPath, monospaced: true)
                    }
                    if let completionReason = toolCall.terminalCompletionReason?.trimmingCharacters(in: .whitespacesAndNewlines), !completionReason.isEmpty {
                        detailBlock(label: "完成原因", text: completionReason, monospaced: false)
                    }
                }
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
        case .permission:
            return "hand.raised"
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

    private var badges: [ToolCallBubbleBadge] {
        guard rowPresentation.style == .execute else { return [] }

        var result: [ToolCallBubbleBadge] = []
        if let mode = TerminalExecutionMode.parse(toolCall.terminalExecutionMode) {
            result.append(.init(text: mode == .attached ? "附着任务" : "后台任务", tone: .neutral))
        }
        if let status = TerminalTaskStatus.parse(toolCall.terminalTaskStatus) {
            result.append(.init(text: taskStatusText(status), tone: badgeTone(for: status)))
        }
        if toolCall.terminalApprovalPending {
            result.append(.init(text: "需要批准", tone: .warning))
        }
        if toolCall.terminalUserTakeoverActive {
            result.append(.init(text: "手动接管", tone: .active))
        }
        if let actionSummary = latestAgentActionSummary(from: toolCall.terminalAgentActionsJSON) {
            result.append(.init(text: actionSummary, tone: .active))
        }
        return result
    }

    private var detailLabel: String {
        switch rowPresentation.style {
        case .edit:
            return "变更详情"
        case .execute:
            return toolCall.status == .failed ? "错误输出" : "终端输出"
        default:
            return "详情"
        }
    }

    @ViewBuilder
    private func detailBlock(label: String, text: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func taskStatusText(_ status: TerminalTaskStatus) -> String {
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

    private func badgeTone(for status: TerminalTaskStatus) -> ToolCallBubbleBadgeTone {
        switch status {
        case .waitingForInput:
            return .active
        case .planningInteraction, .awaitingUserApproval, .userTakeover, .failed, .timedOut, .terminated:
            return .warning
        default:
            return .neutral
        }
    }

    private func badgeColor(_ tone: ToolCallBubbleBadgeTone) -> Color {
        switch tone {
        case .neutral:
            return .secondary
        case .active:
            return .blue
        case .warning:
            return .orange
        }
    }

    private func latestAgentActionSummary(from json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let events = try? JSONDecoder().decode([TerminalTaskEvent].self, from: data) else { return nil }
        return events.last?.summary
    }
}

private struct ProjectedSubagentTaskCardView: View {
    let toolCall: ToolCallProjectionInput
    let defaultExpanded: Bool

    @State private var isExpanded: Bool
    @State private var isShowingTimeline = false
    @State private var hasManualOverride = false

    init(toolCall: ToolCallProjectionInput, defaultExpanded: Bool = false) {
        self.toolCall = toolCall
        self.defaultExpanded = defaultExpanded
        _isExpanded = State(initialValue: defaultExpanded)
    }

    private var sortedRounds: [SubagentRoundProjectionInput] {
        toolCall.subagentRounds.sorted { $0.roundIndex < $1.roundIndex }
    }

    private var conclusionText: String? {
        sortedRounds.last(where: { $0.text?.isEmpty == false })?.text
    }

    private var agentLabel: String {
        toolCall.subagentAgentName ?? "子代理"
    }

    private var verifierPassed: Bool? {
        guard let raw = toolCall.subagentMessageMetadata.first(where: { $0.key == "verificationPassed" })?.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return nil
        }
        switch raw {
        case "true":
            return true
        case "false":
            return false
        default:
            return nil
        }
    }

    private var verifierVerdictText: String? {
        guard let verifierPassed else { return nil }
        return verifierPassed ? "验证通过" : "验证失败"
    }

    private var verifierSummary: String? {
        guard let summary = toolCall.subagentMessageMetadata.first(where: { $0.key == "verificationSummary" })?.value,
              !summary.isEmpty else {
            return nil
        }
        return summary
    }

    private var durationText: String? {
        guard let start = toolCall.startTime, let end = toolCall.endTime else { return nil }
        return String(format: "%.1fs", end.timeIntervalSince(start))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.2)) {
                    hasManualOverride = true
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
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
                            .foregroundStyle(verifierPassed == true ? .green : .red)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background((verifierPassed == true ? Color.green : Color.red).opacity(0.12))
                            .clipShape(Capsule())
                    }
                    if toolCall.subagentResultKind == "structured" {
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
                    if let durationText {
                        Text(durationText)
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

            if isExpanded {
                Divider().opacity(0.15).padding(.horizontal, 10)
                VStack(alignment: .leading, spacing: 8) {
                    if let task = toolCall.subagentTask, !task.isEmpty {
                        labeledBlock(label: "任务", text: task)
                    }
                    if let conclusion = conclusionText, !conclusion.isEmpty {
                        labeledBlock(label: "结论", text: conclusion)
                    }
                    if let verdict = verifierVerdictText {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("验证结果")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(verdict)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(verifierPassed == true ? .green : .red)
                            if let verifierSummary, !verifierSummary.isEmpty {
                                Text(verifierSummary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(4)
                            }
                        }
                    }
                    if toolCall.status == .inProgress && sortedRounds.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.6)
                            Text("子代理执行中…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    if !toolCall.subagentMessageMetadata.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("消息元数据")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            HStack(spacing: 8) {
                                ForEach(toolCall.subagentMessageMetadata.sorted { $0.key < $1.key }, id: \.key) { pair in
                                    HStack(spacing: 3) {
                                        Text(pair.key)
                                            .foregroundStyle(.tertiary)
                                        Text(pair.value)
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.caption2)
                                }
                            }
                        }
                    }
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
                                ProjectedSubagentTimelineView(rounds: sortedRounds)
                            }
                        }
                    }
                }
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

    @ViewBuilder
    private func labeledBlock(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

private struct ProjectedSubagentTimelineView: View {
    let rounds: [SubagentRoundProjectionInput]

    private var sortedRounds: [SubagentRoundProjectionInput] {
        rounds.sorted { $0.roundIndex < $1.roundIndex }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sortedRounds.enumerated()), id: \.element.id) { index, round in
                VStack(alignment: .leading, spacing: 4) {
                    if let thinking = round.thinkingContent, !thinking.isEmpty {
                        ThinkingBubbleView(content: thinking)
                    }
                    if let text = round.text, !text.isEmpty {
                        MarkdownMessageView(text: text)
                    }
                    if !round.toolCalls.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(round.toolCalls) { toolCall in
                                ProjectedToolCallBubbleView(
                                    toolCall: toolCall,
                                    rowPresentation: ToolCallRowPresentation.make(for: toolCall)
                                )
                            }
                        }
                    }
                }
                .padding(.bottom, index == sortedRounds.count - 1 ? 2 : 12)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: sortedRounds.count)
    }
}
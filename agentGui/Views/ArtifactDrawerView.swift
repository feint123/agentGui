//
//  ArtifactDrawerView.swift
//  agentGui
//
//  The collapsible third layer of an agent message.
//  Groups tool calls by action type (read, edit, execute…) and exposes
//  thinking summaries and subagent task cards behind expandable rows —
//  keeping heavy technical detail hidden until the user asks for it.
//

import SwiftUI

/// Collapsible drawer containing grouped actions, thinking summaries, and subagent cards.
struct ArtifactDrawerView: View {
    let message: Message

    // MARK: - Data

    /// All tool calls from direct message calls and per-round calls, in chronological order.
    private var allToolCalls: [ToolCall] {
        let roundCalls = message.agentRounds.flatMap { $0.toolCalls }
        return (message.toolCalls + roundCalls).sorted {
            ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast)
        }
    }

    private var sortedRounds: [AgentRound] {
        message.agentRounds.sorted { $0.roundIndex < $1.roundIndex }
    }

    private var thinkingRounds: [AgentRound] {
        sortedRounds.filter { $0.hasThinking }
    }

    /// Subagent calls — shown as dedicated task cards, not in action groups.
    private var subagentCalls: [ToolCall] {
        allToolCalls.filter { $0.kind == .subagent }
    }

    /// Non-subagent calls, grouped by tool kind in insertion order.
    private var actionGroups: [ActionGroup] {
        let calls = allToolCalls.filter { $0.kind != .subagent }
        var seen: [String: [ToolCall]] = [:]
        var order: [ToolKind] = []
        for call in calls {
            let key = call.kind.rawValue
            if seen[key] == nil {
                order.append(call.kind)
                seen[key] = []
            }
            seen[key]!.append(call)
        }
        return order.compactMap { kind in
            guard let kindCalls = seen[kind.rawValue], !kindCalls.isEmpty else { return nil }
            return ActionGroup(kind: kind, calls: kindCalls)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !thinkingRounds.isEmpty {
                ThinkingSummaryRow(rounds: thinkingRounds)
            }
            ForEach(actionGroups) { group in
                ActionGroupRow(group: group)
            }
            ForEach(subagentCalls) { call in
                SubagentTaskCardView(toolCall: call)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - ActionGroup Model

private struct ActionGroup: Identifiable {
    var id: String { kind.rawValue }
    let kind: ToolKind
    let calls: [ToolCall]

    var displayTitle: String {
        let n = calls.count
        switch kind {
        case .read:     return "读取了 \(n) 个文件"
        case .edit:     return "修改了 \(n) 个文件"
        case .execute:  return "运行了 \(n) 条命令"
        case .search:   return "搜索了 \(n) 次"
        case .fetch:    return "获取了 \(n) 个 URL"
        case .delete:   return "删除了 \(n) 个文件"
        case .think:    return n == 1 ? "进行了 1 次深度思考" : "进行了 \(n) 次深度思考"
        case .plan:     return n == 1 ? "制定了计划" : "制定了 \(n) 个计划"
        case .todo:     return "更新了待办事项"
        case .askUser:  return n == 1 ? "询问了用户确认" : "询问了 \(n) 次用户确认"
        default:        return "\(kind.displayName) ×\(n)"
        }
    }

    var hasFailure: Bool {
        calls.contains { $0.status == .failed }
    }

    var allComplete: Bool {
        calls.allSatisfy { $0.status != .inProgress }
    }
}

// MARK: - Action Group Row

private struct ActionGroupRow: View {
    let group: ActionGroup
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Summary header — always visible
            Button {
                withAnimation(.spring(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    groupStatusIcon
                    Image(systemName: group.kind.icon)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(group.displayTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded: individual tool call cards
            if isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(group.calls) { call in
                        ToolCallBubbleView(toolCall: call)
                    }
                }
                .padding(.leading, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private var groupStatusIcon: some View {
        if group.hasFailure {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
        } else if !group.allComplete {
            ProgressView().scaleEffect(0.45).frame(width: 12, height: 12)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary.opacity(0.5))
        }
    }
}

// MARK: - Thinking Summary Row

private struct ThinkingSummaryRow: View {
    let rounds: [AgentRound]
    @State private var isExpanded = false

    private var totalChars: Int {
        rounds.compactMap { $0.thinkingContent?.count }.reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.spring(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "brain")
                        .font(.system(size: 10))
                        .foregroundStyle(.purple.opacity(0.65))
                    Text("推理摘要 · \(totalChars) 字")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rounds) { round in
                        if let content = round.thinkingContent, !content.isEmpty {
                            ThinkingBubbleView(content: content)
                        }
                    }
                }
                .padding(.leading, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

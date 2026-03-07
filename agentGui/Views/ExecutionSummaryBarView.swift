//
//  ExecutionSummaryBarView.swift
//  agentGui
//
//  Compact one-line bar that surfaces "what the agent did" (past) or
//  "what the agent is doing" (live). Tapping toggles the artifact drawer below.
//

import SwiftUI

/// A compact summary bar showing aggregated tool-action counts and live status.
/// Acts as both a status anchor and the toggle for the artifact drawer.
struct ExecutionSummaryBarView: View {
    let message: Message
    var isStreaming: Bool = false
    @Binding var isExpanded: Bool

    // MARK: - Derived Data

    /// All tool calls across direct message calls and per-round calls.
    private var allToolCalls: [ToolCall] {
        let roundCalls = message.agentRounds.flatMap { $0.toolCalls }
        return (message.toolCalls + roundCalls).sorted {
            ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast)
        }
    }

    private var hasContent: Bool {
        !allToolCalls.isEmpty || message.status == .failed
    }

    // MARK: - Live Status

    /// Human-readable description of the currently executing action (streaming only).
    private var liveStatus: String? {
        guard isStreaming, message.status == .pending else { return nil }
        guard let active = allToolCalls.last(where: { $0.status == .inProgress }) else {
            return "正在整理答案"
        }
        switch active.kind {
        case .read:
            let name = (active.filePath as NSString?)?.lastPathComponent ?? "文件"
            return "正在读取 \(name)"
        case .edit:
            let name = (active.filePath as NSString?)?.lastPathComponent ?? "文件"
            return "正在修改 \(name)"
        case .execute:
            if let cmd = active.title, !cmd.isEmpty {
                return "正在执行：\(cmd)"
            }
            return "正在执行命令"
        case .search:
            return "正在搜索代码"
        case .fetch:
            return "正在获取内容"
        case .subagent:
            let name = active.subagentAgentName ?? "子代理"
            return "正在调用 \(name)"
        default:
            return "正在处理"
        }
    }

    // MARK: - Completed Summary

    private var completedSummary: String {
        let done = allToolCalls.filter { $0.status != .inProgress }
        var parts: [String] = []
        let reads    = done.filter { $0.kind == .read }.count
        let searches = done.filter { $0.kind == .search }.count
        let fetches  = done.filter { $0.kind == .fetch }.count
        let execs    = done.filter { $0.kind == .execute }.count
        let edits    = done.filter { $0.kind == .edit }.count
        let agents   = done.filter { $0.kind == .subagent }.count
        if reads    > 0 { parts.append("读取 \(reads) 个文件") }
        if searches > 0 { parts.append("搜索 \(searches) 次") }
        if fetches  > 0 { parts.append("获取 \(fetches) 个 URL") }
        if execs    > 0 { parts.append("运行 \(execs) 条命令") }
        if edits    > 0 { parts.append("修改 \(edits) 个文件") }
        if agents   > 0 { parts.append("调用 \(agents) 个子代理") }
        return parts.joined(separator: "，")
    }

    private var displayText: String {
        if message.status == .failed { return "执行失败，点击查看详情" }
        if let live = liveStatus { return live }
        return completedSummary
    }

    // MARK: - Body

    @ViewBuilder
    var body: some View {
        if hasContent {
            Button {
                withAnimation(.spring(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    statusIndicator
                    Text(displayText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.quaternary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if isStreaming && message.status == .pending {
            ProgressView()
                .scaleEffect(0.45)
                .frame(width: 12, height: 12)
        } else if message.status == .failed {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green.opacity(0.7))
        }
    }
}

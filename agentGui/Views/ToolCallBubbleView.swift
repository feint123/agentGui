//
//  ToolCallBubbleView.swift
//  agentGui
//

import SwiftUI

/// 工具调用卡片视图 — 显示单次工具调用的状态、输入和输出
struct ToolCallBubbleView: View {

    let toolCall: ToolCall

    @State private var isExpanded: Bool

    init(toolCall: ToolCall) {
        self.toolCall = toolCall
        // 子代理卡片默认折叠；其他工具执行中时默认展开
        let expanded = toolCall.kind != .subagent && toolCall.status == .inProgress
        _isExpanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            if isExpanded {
                Divider().opacity(0.4)
                detailContent
                    .padding(10)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .onChange(of: toolCall.status) { _, newStatus in
            // 子代理卡片不自动展开
            if newStatus == .inProgress && toolCall.kind != .subagent { isExpanded = true }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        Button {
            withAnimation(.spring(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 7) {
                statusIcon
                Image(systemName: toolCall.kind.icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(toolCall.title ?? toolCall.kind.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                if let duration = toolCall.duration {
                    Text(String(format: "%.1fs", duration))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
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

    @ViewBuilder
    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if toolCall.kind == .subagent {
                subagentDetail
            } else if toolCall.kind == .askUser {
                askUserDetail
            } else {
                standardDetail
            }
        }
    }

    // MARK: - Subagent Detail

    @ViewBuilder
    private var subagentDetail: some View {
        // Task description
        if let task = toolCall.subagentTask, !task.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("任务")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(task)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }

        // Subagent rounds timeline
        let rounds = toolCall.subagentRounds.sorted { $0.roundIndex < $1.roundIndex }
        if !rounds.isEmpty {
            Divider().opacity(0.5)
            SubagentTimelineView(rounds: rounds)
                .padding(.top, 2)
        } else if toolCall.status == .inProgress {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6)
                Text("子代理执行中…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Ask User Detail

    @ViewBuilder
    private var askUserDetail: some View {
        if let output = toolCall.terminalOutput,
           let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let answers = json["answers"] as? [[String: Any]] {
            ForEach(answers.indices, id: \.self) { i in
                let answer = answers[i]
                let question = answer["question"] as? String ?? ""
                let selected = answer["selected"] as? [String] ?? []
                VStack(alignment: .leading, spacing: 3) {
                    Text(question)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if selected.isEmpty {
                        Text("(已取消)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(selected, id: \.self) { label in
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                                Text(label)
                                    .font(.caption2)
                                    .fontWeight(.medium)
                            }
                        }
                    }
                }
                if i < answers.count - 1 { Divider().opacity(0.4) }
            }
        } else if let output = toolCall.terminalOutput, !output.isEmpty {
            outputBlock(output)
        }
    }

    // MARK: - Standard Detail

    @ViewBuilder
    private var standardDetail: some View {
        // 文件路径
        if let path = toolCall.filePath {
            HStack(spacing: 4) {
                Image(systemName: "doc")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
        }

        // bash 命令
        if toolCall.kind == .execute, let cmd = toolCall.title, !cmd.isEmpty {
            codeBlock(label: nil, content: "$ \(cmd)")
        }

        // str_replace diff
        if toolCall.kind == .edit, let diff = toolCall.diffContent {
            codeBlock(label: "Changes", content: diff)
        }

        // 输出/结果
        if let output = toolCall.terminalOutput, !output.isEmpty {
            outputBlock(output)
        }
    }

    private func codeBlock(label: String?, content: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(content)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private func outputBlock(_ output: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Output")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    Text(output)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .id("bottom")
                }
                .frame(maxHeight: 200)
                .onChange(of: output) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

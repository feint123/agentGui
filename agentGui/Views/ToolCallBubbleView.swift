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
        // 执行中时默认展开
        _isExpanded = State(initialValue: toolCall.status == .inProgress)
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
            if newStatus == .inProgress { isExpanded = true }
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

    // MARK: - Detail Content

    @ViewBuilder
    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            ScrollView(.vertical, showsIndicators: true) {
                Text(output)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: 200)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

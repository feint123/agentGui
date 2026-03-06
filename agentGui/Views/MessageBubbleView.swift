//
//  MessageBubbleView.swift
//  agentGui
//

import SwiftUI

struct MessageBubbleView: View {
    let message: Message
    var isStreaming: Bool = false
    var onCopy: () -> Void = {}
    var onEdit: ((String) -> Void)? = nil
    var onDelete: () -> Void = {}
    var onDeleteFrom: () -> Void = {}
    var onRegenerate: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editText = ""

    // 解析消息文本和文件引用
    private var parsedContent: (text: String, files: [String]) {
        let raw = message.textContent ?? ""
        let separator = "\n\nReferenced files:\n"
        if let range = raw.range(of: separator) {
            let text = String(raw[raw.startIndex..<range.lowerBound])
            let filesSection = String(raw[range.upperBound...])
            let files = filesSection
                .split(separator: "\n")
                .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : String($0) }
            return (text, files)
        }
        return (raw, [])
    }

    private var msgAlignment: HorizontalAlignment {
        message.direction == .user ? .trailing : .leading
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.direction == .user { Spacer(minLength: 50) }

            VStack(alignment: msgAlignment, spacing: 4) {
                // Avatar + sender name
                HStack(spacing: 6) {
                    if message.direction != .user { avatarView }
                    Text(senderName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if message.direction == .user { avatarView }
                }

                // Bubble content or inline editor
                if isEditing {
                    editingView
                        .frame(maxWidth: 580, alignment: .trailing)
                } else {
                    bubbleContent
                        .frame(maxWidth: 580, alignment: msgAlignment == .trailing ? .trailing : .leading)
                }

                // Hover action toolbar (shown below the bubble)
                if isHovered && !isEditing && !isStreaming && message.direction != .system {
                    messageActionsRow
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 2)),
                            removal: .opacity
                        ))
                }

                // Retry button for failed agent messages (always visible, no hover needed)
                if message.status == .failed && message.direction == .agent, let retry = onRetry {
                    Button(action: retry) {
                        Label("重新发送", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

                // Timestamp
                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if message.direction != .user { Spacer(minLength: 50) }
        }
        .onHover { hovered in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovered
            }
        }
        .contextMenu {
            contextMenuItems
        }
    }

    // MARK: - Hover Action Toolbar

    private var messageActionsRow: some View {
        HStack(spacing: 2) {
            if message.direction == .user, onEdit != nil {
                actionButton("pencil", tooltip: "编辑") {
                    editText = parsedContent.text
                    isEditing = true
                }
            }
            actionButton("doc.on.doc", tooltip: "复制", action: onCopy)
            if let regen = onRegenerate {
                actionButton("arrow.clockwise", tooltip: "重新生成", action: regen)
            }
            actionButton("arrow.uturn.backward", tooltip: "从此处删除", action: onDeleteFrom)
            actionButton("trash", tooltip: "删除消息", action: onDelete)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }

    private func actionButton(_ icon: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuItems: some View {
        Button { onCopy() } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        if message.direction == .user, onEdit != nil {
            Button {
                editText = parsedContent.text
                isEditing = true
            } label: {
                Label("编辑", systemImage: "pencil")
            }
        }
        if let regen = onRegenerate {
            Button { regen() } label: {
                Label("重新生成", systemImage: "arrow.clockwise")
            }
        }
        Divider()
        Button(role: .destructive) { onDeleteFrom() } label: {
            Label("从此处删除", systemImage: "arrow.uturn.backward")
        }
        Button(role: .destructive) { onDelete() } label: {
            Label("删除消息", systemImage: "trash")
        }
    }

    // MARK: - Inline Editing View

    private var editingView: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $editText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 80, maxHeight: 200)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.accentColor.opacity(0.12))
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                )

            HStack(spacing: 8) {
                Button("取消") {
                    isEditing = false
                    editText = ""
                }
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)

                Button("发送") {
                    let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    onEdit?(text)
                    isEditing = false
                }
                .buttonStyle(.glassProminent)
                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.callout)
        }
    }

    // MARK: - Avatar

    private var avatarView: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 28, height: 28)
            Image(systemName: avatarIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(avatarColor)
        }
        .overlay(
            Circle().stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private var avatarColor: Color {
        switch message.direction {
        case .user: return .blue
        case .agent: return .orange
        case .system: return .secondary
        }
    }

    private var avatarIcon: String {
        switch message.direction {
        case .user: return "person.fill"
        case .agent: return "sparkle"
        case .system: return "info.circle.fill"
        }
    }

    private var senderName: String {
        switch message.direction {
        case .user: return "你"
        case .agent: return "Claude"
        case .system: return "系统"
        }
    }

    // MARK: - Bubble Content

    @ViewBuilder
    private var bubbleContent: some View {
        let content = parsedContent
        let isPending = message.status == .pending && message.direction == .agent

        VStack(alignment: .leading, spacing: 0) {
            if message.status == .failed {
                Label(content.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.body)
                    .foregroundStyle(.red)
                    .padding(14)
            } else if message.direction == .agent {
                if message.agentRounds.isEmpty {
                    // Legacy / streaming-in-progress: flat view
                    VStack(alignment: .leading, spacing: 8) {
                        MarkdownMessageView(text: content.text)
                        if !content.files.isEmpty { fileReferenceBadge(count: content.files.count) }
                        if isPending {
                            ProgressView().scaleEffect(0.5).frame(height: 12)
                        }
                    }
                    .padding(14)

                    let sortedCalls = message.toolCalls.sorted {
                        ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast)
                    }
                    if !sortedCalls.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(sortedCalls) { toolCall in
                                ToolCallBubbleView(toolCall: toolCall)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                    }
                } else {
                    // Timeline view: step-by-step rounds
                    AgentStepTimelineView(message: message)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)

                    if isPending {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.5)
                            Text("正在思考…")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                    }
                }
            } else {
                // User / system messages: plain text
                VStack(alignment: .leading, spacing: 8) {
                    Text(content.text)
                        .font(.body)
                        .textSelection(.enabled)
                    if !content.files.isEmpty { fileReferenceBadge(count: content.files.count) }
                }
                .padding(14)
            }
        }
        .background(bubbleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func fileReferenceBadge(count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "paperclip")
                .font(.caption2)
            Text("引用了 \(count) 个文件")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        switch message.direction {
        case .user:
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.accentColor.opacity(0.12))
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        case .agent:
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        case .system:
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
        }
    }
}

//
//  MessageBubbleView.swift
//  agentGui
//

import SwiftUI

struct MessageBubbleView: View {
    let snapshot: MessageRowSnapshot
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
    @State private var viewingMedia: MediaItem? = nil

    var body: some View {
        Group {
            if snapshot.direction == .user {
                userMessageRow
            } else {
                agentMessageRow
            }
        }
        .sheet(item: $viewingMedia) { item in
            MediaViewerView(item: item)
        }
    }

    // MARK: - User message (compact right-aligned bubble)

    private var userMessageRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                userHeaderRow
                if isEditing {
                    editingView
                        .frame(maxWidth: 560, alignment: .trailing)
                } else {
                    userBubble
                        .frame(maxWidth: 560, alignment: .trailing)
                }
            }
        }
        .onHover { hovered in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovered }
        }
        .contextMenu { contextMenuItems }
    }

    /// Compact header row for user messages: hover actions, timestamp, name (right-aligned).
    private var userHeaderRow: some View {
        HStack(spacing: 5) {
            if isHovered && !isEditing && !isStreaming {
                messageActionsRow
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -2)),
                        removal: .opacity
                    ))
            }
            Text(snapshot.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(senderName)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            Image(systemName: "person.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var userBubble: some View {
        if let user = snapshot.user {
            let content = user.presentation
            VStack(alignment: .trailing, spacing: 8) {
                Group {
                    if content.hasStructuredInlineContent {
                        UserMessageInlineContentView(presentation: content)
                    } else {
                        Text(user.bodyText)
                            .font(.body)
                    }
                }
                .textSelection(.enabled)
                if !content.images.isEmpty || !content.pdfs.isEmpty {
                    mediaGrid(images: content.images, pdfs: content.pdfs)
                }
                if !content.others.isEmpty {
                    fileReferenceBadge(count: content.others.count)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.accentColor.opacity(0.15))
            )
        }
    }

    // MARK: - Agent / system message

    private var agentMessageRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Compact header with hover actions
            agentHeaderRow
            // Three-layer content: answer card → summary bar → artifact drawer
            agentCardContent
            // Retry button always visible on failure
            if snapshot.status == .failed, let retry = onRetry {
                Button(action: retry) {
                    Label("重新发送", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .onHover { hovered in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovered }
        }
        .contextMenu { contextMenuItems }
    }

    /// Compact header row: icon, name, timestamp, hover actions.
    private var agentHeaderRow: some View {
        HStack(spacing: 5) {
            Image(systemName: snapshot.direction == .agent ? "sparkle" : "info.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(snapshot.direction == .agent ? .orange : .secondary)
            Text(senderName)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            Text(snapshot.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if isHovered && !isStreaming {
                messageActionsRow
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -2)),
                        removal: .opacity
                    ))
            }
        }
    }

    @ViewBuilder
    private var agentCardContent: some View {
        if let agent = snapshot.agent {
            VStack(alignment: .leading, spacing: 8) {
                AgentMessageStepFlowView(snapshot: agent.flow)

                if !agent.hasAgentRounds {
                    if agent.attachments.hasMedia {
                        mediaGrid(images: agent.attachments.images, pdfs: agent.attachments.pdfs)
                    }
                    if !agent.attachments.others.isEmpty {
                        fileReferenceBadge(count: agent.attachments.others.count)
                    }
                }
            }
        }
    }

    // MARK: - Hover Action Toolbar

    private var messageActionsRow: some View {
        HStack(spacing: 2) {
            if snapshot.direction == .user, onEdit != nil {
                actionButton("pencil", tooltip: "编辑") {
                    editText = snapshot.editableUserText ?? ""
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
        .frame(height: 12)
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
        if snapshot.direction == .user, onEdit != nil {
            Button {
                editText = snapshot.editableUserText ?? ""
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

    private var senderName: String {
        snapshot.senderName
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

    private func mediaGrid(images: [String], pdfs: [String]) -> some View {
        let all = images.map { ($0, false) } + pdfs.map { ($0, true) }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], spacing: 6) {
            ForEach(all, id: \.0) { path, _ in
                MediaThumbnailCell(path: path) {
                    viewingMedia = MediaItem(url: URL(fileURLWithPath: path))
                }
            }
        }
    }

}

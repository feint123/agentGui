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
    @State private var viewingMedia: MediaItem? = nil
    @State private var isArtifactExpanded = false

    // 解析消息文本和文件引用，将部件分类: 图片/PDF/其他
    private struct ParsedContent {
        let text: String
        let images: [String]
        let pdfs: [String]
        let others: [String]
        var hasMedia: Bool { !images.isEmpty || !pdfs.isEmpty }
    }

    private var parsedContent: ParsedContent {
        let raw = message.textContent ?? ""
        let separator = "\n\nReferenced files:\n"
        guard let range = raw.range(of: separator) else {
            return ParsedContent(text: raw, images: [], pdfs: [], others: [])
        }
        let text = String(raw[raw.startIndex..<range.lowerBound])
        let filesSection = String(raw[range.upperBound...])
        let paths = filesSection
            .split(separator: "\n")
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : String($0) }
            .filter { !$0.isEmpty }
        var images: [String] = []
        var pdfs: [String] = []
        var others: [String] = []
        for path in paths {
            if AttachedFile.pathIsImage(path) { images.append(path) }
            else if AttachedFile.pathIsPDF(path) { pdfs.append(path) }
            else { others.append(path) }
        }
        return ParsedContent(text: text, images: images, pdfs: pdfs, others: others)
    }

    var body: some View {
        Group {
            if message.direction == .user {
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
            Text(message.timestamp.formatted(date: .omitted, time: .shortened))
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

    private var userBubble: some View {
        let content = parsedContent
        return VStack(alignment: .trailing, spacing: 8) {
            Text(content.text)
                .font(.body)
                .textSelection(.enabled)
            if !content.images.isEmpty || !content.pdfs.isEmpty {
                mediaGrid(images: content.images, pdfs: content.pdfs)
            }
            if !content.others.isEmpty { fileReferenceBadge(count: content.others.count) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.accentColor.opacity(0.15))
        )
    }

    // MARK: - Agent / system message

    private var agentMessageRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Compact header with hover actions
            agentHeaderRow
            // Three-layer content: answer card → summary bar → artifact drawer
            agentCardContent
            // Retry button always visible on failure
            if message.status == .failed, let retry = onRetry {
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
            Image(systemName: message.direction == .agent ? "sparkle" : "info.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(message.direction == .agent ? Color.orange : Color.secondary)
            Text(senderName)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            Text(message.timestamp.formatted(date: .omitted, time: .shortened))
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

    /// Consolidated answer text: round texts joined, or plain textContent for simple messages.
    private var agentAnswerText: String {
        let rounds = message.agentRounds.sorted { $0.roundIndex < $1.roundIndex }
        if rounds.isEmpty {
            return parsedContent.text
        }
        return rounds.compactMap { $0.text }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    @ViewBuilder
    private var agentCardContent: some View {
        if message.status == .failed {
            let errText = parsedContent.text.isEmpty
                ? (message.errorMessage ?? "执行失败")
                : parsedContent.text
            Label(errText, systemImage: "exclamationmark.triangle.fill")
                .font(.body)
                .foregroundStyle(.red)
        } else {
            let hasExecutionData = !message.agentRounds.isEmpty || !message.toolCalls.isEmpty
            let content = parsedContent

            VStack(alignment: .leading, spacing: 8) {
                // Layer 1 — Answer card
                AgentAnswerCardView(
                    text: agentAnswerText,
                    isStreaming: isStreaming,
                    isPending: message.status == .pending
                )

                // Media attachments (only for simple messages without rounds)
                if message.agentRounds.isEmpty {
                    if !content.images.isEmpty || !content.pdfs.isEmpty {
                        mediaGrid(images: content.images, pdfs: content.pdfs)
                    }
                    if !content.others.isEmpty {
                        fileReferenceBadge(count: content.others.count)
                    }
                }

                // Layer 2 — Execution summary bar (visible when there is tool activity)
                if hasExecutionData {
                    ExecutionSummaryBarView(
                        message: message,
                        isStreaming: isStreaming,
                        isExpanded: $isArtifactExpanded
                    )

                    // Layer 3 — Artifact drawer (expands on demand)
                    if isArtifactExpanded {
                        ArtifactDrawerView(message: message)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity
                            ))
                    }
                }
            }
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

    private var senderName: String {
        switch message.direction {
        case .user: return "你"
        case .agent: return "Claude"
        case .system: return "系统"
        }
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

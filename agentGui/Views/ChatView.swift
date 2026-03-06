//
//  ChatView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 聊天界面视图 — 使用 SwiftAnthropic 与 Claude 实时对话
struct ChatView: View {

    // MARK: - Environment

    @Environment(\.modelContext) private var modelContext
    @Environment(ClaudeService.self) private var claudeService

    // MARK: - Properties

    let session: Session

    @Query private var allMessages: [Message]

    @State private var inputText = ""
    @State private var errorMessage: String?
    @State private var attachedFiles: [AttachedFile] = []
    @State private var isDropTargeted = false

    @FocusState private var isInputFocused: Bool

    // MARK: - Initializer

    init(session: Session) {
        self.session = session
        let sessionId = session.sessionId
        _allMessages = Query(
            filter: #Predicate<Message> { $0.session?.sessionId == sessionId },
            sort: \.sequence
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            messagesArea
            inputArea
        }
        .navigationTitle(session.title)
        .navigationSubtitle(claudeService.isConfigured ? "" : "⚠️ 请先配置 API Key")
        .toolbar { toolbarContent }
        .alert("错误", isPresented: .constant(errorMessage != nil)) {
            Button("确定") { errorMessage = nil }
        } message: {
            if let error = errorMessage { Text(error) }
        }
        .sheet(item: Binding(
            get: { claudeService.pendingUserQuestion },
            set: { newVal in
                if newVal == nil {
                    // Cancel if not yet resolved (guard inside cancel() is a no-op if already submitted)
                    claudeService.pendingUserQuestion?.cancel()
                    claudeService.pendingUserQuestion = nil
                }
            }
        )) { request in
            AskUserQuestionView(request: request)
        }
    }

    // MARK: - Messages Area

    private var messagesArea: some View {
        Group {
            if allMessages.isEmpty {
                emptyStateView
            } else {
                messageListView
            }
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("开始对话", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("在下方输入您的问题，与 Claude 开始对话")
        }
    }

    private var messageListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(allMessages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }

                    if claudeService.isStreaming {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Claude 正在思考...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                        .id("streaming-indicator")
                    }
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 12)
            }
            .onChange(of: allMessages.last?.textContent) { _, _ in
                if claudeService.isStreaming {
                    scrollToBottom(proxy: proxy)
                }
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if claudeService.isStreaming {
                proxy.scrollTo("streaming-indicator", anchor: .bottom)
            } else if let last = allMessages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Input Area

    private var inputArea: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.5)

            VStack(spacing: 8) {
                // 已附加文件列表
                if !attachedFiles.isEmpty {
                    fileChipsRow
                }

                HStack(alignment: .bottom, spacing: 10) {
                    // 文本输入框
                    TextEditor(text: $inputText)
                        .focused($isInputFocused)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(minHeight: 28, maxHeight: 130)
                        .padding(.horizontal, 4)
                        .disabled(claudeService.isStreaming)

                    sendButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                isDropTargeted
                                    ? Color.accentColor.opacity(0.6)
                                    : Color.primary.opacity(0.08),
                                lineWidth: isDropTargeted ? 2 : 1
                            )
                    )
                    .shadow(color: .black.opacity(0.06), radius: 8, y: -2)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .padding(.top, 8)
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleFileDrop(providers: providers)
            }
        }
        .background(.bar)
    }

    private var fileChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachedFiles) { file in
                    fileChip(file)
                }
            }
        }
    }

    private func fileChip(_ file: AttachedFile) -> some View {
        HStack(spacing: 4) {
            Image(systemName: fileIcon(for: file.name))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(file.name)
                .font(.caption)
                .lineLimit(1)
            Button {
                attachedFiles.removeAll { $0.id == file.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "py": return "doc.text"
        case "js", "ts": return "doc.text"
        case "json": return "curlybraces"
        case "md": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        default: return "doc"
        }
    }

    private var sendButton: some View {
        Button {
            Task { await sendMessage() }
        } label: {
            if claudeService.isStreaming {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 30, height: 30)
            } else {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
            }
        }
        .buttonStyle(.plain)
        .disabled(!canSend || claudeService.isStreaming)
        .keyboardShortcut(.return, modifiers: .command)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && claudeService.isConfigured
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("清除对话") { clearMessages() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - File Drop

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    let file = AttachedFile(name: url.lastPathComponent, url: url)
                    DispatchQueue.main.async {
                        if !attachedFiles.contains(where: { $0.url == url }) {
                            attachedFiles.append(file)
                        }
                    }
                }
                handled = true
            }
        }
        return handled
    }

    // MARK: - Actions

    private func sendMessage() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, claudeService.isConfigured else {
            if !claudeService.isConfigured {
                errorMessage = "请先在「设置」中配置 Anthropic API Key"
            }
            return
        }

        // 拼接文件路径引用
        var fullText = trimmed
        if !attachedFiles.isEmpty {
            let refs = attachedFiles.map { "- \($0.path)" }.joined(separator: "\n")
            fullText += "\n\nReferenced files:\n\(refs)"
        }

        inputText = ""
        attachedFiles = []

        // 保存用户消息
        let userMessage = Message.userMessage(text: fullText, session: session)
        userMessage.status = .completed
        modelContext.insert(userMessage)
        try? modelContext.save()

        // 读取选中的模型
        let settings = AppSettings.getOrCreate(in: modelContext)
        let modelId = settings.selectedModel

        do {
            try await claudeService.sendMessage(
                text: fullText,
                session: session,
                modelId: modelId,
                modelContext: modelContext
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearMessages() {
        for message in allMessages {
            modelContext.delete(message)
        }
        try? modelContext.save()
    }
}

// MARK: - Message Bubble View

private struct MessageBubbleView: View {
    let message: Message

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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.direction == .user { Spacer(minLength: 50) }

            VStack(alignment: message.direction == .user ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if message.direction != .user { avatarView }
                    Text(senderName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if message.direction == .user { avatarView }
                }

                bubbleContent
                    .frame(maxWidth: 580, alignment: message.direction == .user ? .trailing : .leading)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if message.direction != .user { Spacer(minLength: 50) }
        }
    }

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

    @ViewBuilder
    private var bubbleContent: some View {
        let content = parsedContent
        let isStreaming = message.status == .pending && message.direction == .agent

        VStack(alignment: .leading, spacing: 0) {
            if message.status == .failed {
                Label(content.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.body)
                    .foregroundStyle(.red)
                    .padding(14)
            } else if message.direction == .agent {
                // Agent messages: use timeline if rounds are available, fallback for legacy data
                if message.agentRounds.isEmpty {
                    // Legacy / streaming-in-progress: flat view
                    VStack(alignment: .leading, spacing: 8) {
                        MarkdownMessageView(text: content.text)
                        if !content.files.isEmpty { fileReferenceBadge(count: content.files.count) }
                        if isStreaming {
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

                    if isStreaming {
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

// MARK: - Preview

#Preview {
    NavigationStack {
        Text("ChatView Preview")
    }
}

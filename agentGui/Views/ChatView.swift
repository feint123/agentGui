//
//  ChatView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import SwiftData

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
            Divider()
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
                LazyVStack(spacing: 12) {
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
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .id("streaming-indicator")
                    }
                }
                .padding()
            }
            .onChange(of: allMessages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: claudeService.isStreaming) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            // Live scroll as streaming text updates
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
        HStack(alignment: .bottom, spacing: 12) {
            TextEditor(text: $inputText)
                .focused($isInputFocused)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .frame(minHeight: 24, maxHeight: 120)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .disabled(claudeService.isStreaming)
                .onSubmit { }

            sendButton
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sendButton: some View {
        Button {
            Task { await sendMessage() }
        } label: {
            if claudeService.isStreaming {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(canSend ? Color.accentColor : .secondary)
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

    // MARK: - Actions

    private func sendMessage() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, claudeService.isConfigured else {
            if !claudeService.isConfigured {
                errorMessage = "请先在「设置」中配置 Anthropic API Key"
            }
            return
        }

        inputText = ""

        // 保存用户消息
        let userMessage = Message.userMessage(text: trimmed, session: session)
        userMessage.status = .completed
        modelContext.insert(userMessage)
        try? modelContext.save()

        // 读取选中的模型
        let settings = AppSettings.getOrCreate(in: modelContext)
        let modelId = settings.selectedModel

        do {
            try await claudeService.sendMessage(
                text: trimmed,
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.direction == .user { Spacer(minLength: 60) }

            VStack(alignment: message.direction == .user ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if message.direction != .user {
                        avatarView
                    }

                    Text(senderName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if message.direction == .user {
                        avatarView
                    }
                }

                bubbleContent
                    .frame(maxWidth: 560, alignment: message.direction == .user ? .trailing : .leading)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if message.direction != .user { Spacer(minLength: 60) }
        }
    }

    private var avatarView: some View {
        ZStack {
            Circle()
                .fill(avatarColor.gradient)
                .frame(width: 28, height: 28)
            Image(systemName: avatarIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    private var avatarColor: Color {
        switch message.direction {
        case .user: return .blue
        case .agent: return .orange
        case .system: return .gray
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
        let text = message.textContent ?? ""
        let isStreaming = message.status == .pending && message.direction == .agent

        VStack(alignment: .leading, spacing: 0) {
            if message.status == .failed {
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .font(.body)
                    .foregroundStyle(.red)
                    .padding(12)
            } else {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(12)
                    .overlay(alignment: .bottomTrailing) {
                        if isStreaming {
                            ProgressView()
                                .scaleEffect(0.5)
                                .padding(6)
                        }
                    }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(bubbleBackground)
        )
    }

    private var bubbleBackground: Color {
        switch message.direction {
        case .user: return .blue.opacity(0.15)
        case .agent: return Color(nsColor: .controlBackgroundColor)
        case .system: return .gray.opacity(0.1)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        Text("ChatView Preview")
    }
}

//
//  ChatView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import SwiftData

/// 聊天界面视图
/// 显示消息列表并提供发送提示的界面
struct ChatView: View {

    // MARK: - Environment

    @Environment(\.modelContext) private var modelContext

    // MARK: - Properties

    let session: Session

    @State private var messages: [Message] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var scrollToBottom = false

    @FocusState private var isInputFocused: Bool

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // 消息列表
            messagesArea

            Divider()

            // 输入区域
            inputArea
        }
        .navigationTitle(session.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("清除历史") {
                        // TODO: 实现清除历史
                    }
                    Button("导出对话") {
                        // TODO: 实现导出对话
                    }
                    Button("会话设置") {
                        // TODO: 实现会话设置
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("错误", isPresented: .constant(errorMessage != nil)) {
            Button("确定") {
                errorMessage = nil
            }
        } message: {
            if let error = errorMessage {
                Text(error)
            }
        }
        .task {
            await loadMessages()
        }
        .onChange(of: scrollToBottom) { _, _ in
            // 触发滚动到底部
        }
    }

    // MARK: - Messages Area

    private var messagesArea: some View {
        Group {
            if messages.isEmpty {
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
            Text("在下方输入框中输入提示，开始与 Agent 对话")
        }
    }

    private var messageListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(messages) { message in
                        MessageRowView(message: message)
                    }

                    // 加载指示器
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.8)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { _, _ in
                if let lastMessage = messages.last {
                    withAnimation {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input Area

    private var inputArea: some View {
        HStack(alignment: .bottom, spacing: 12) {
            // 文件附件按钮
            Button {
                // TODO: 实现文件附件
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isLoading)

            // 输入框
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
                .disabled(isLoading)

            // 发送按钮
            Button {
                Task {
                    await sendMessage()
                }
            } label: {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : Color.blue)
                }
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Actions

    private func loadMessages() async {
        let repository = MessageRepository(modelContext: modelContext)
        do {
            messages = try await repository.fetch(bySessionId: session.sessionId)
        } catch {
            errorMessage = "加载消息失败: \(error.localizedDescription)"
        }
    }

    private func sendMessage() async {
        let trimmedText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        isLoading = true
        inputText = ""

        // 创建用户消息
        let userMessage = Message.userMessage(
            text: trimmedText,
            session: session
        )

        let repository = MessageRepository(modelContext: modelContext)

        do {
            // 保存用户消息
            try await repository.add(userMessage)
            messages.append(userMessage)

            // TODO: 调用 ACPClientService 发送提示
            // 这里需要注入 ACPClientService 或 SessionService

            // 模拟响应
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5秒

            // 创建助手消息
            let assistantMessage = Message.agentMessage(
                text: "这是模拟的回复。实际实现需要调用 ACPClientService.sendPrompt",
                session: session
            )

            try await repository.add(assistantMessage)
            messages.append(assistantMessage)

        } catch {
            errorMessage = "发送消息失败: \(error.localizedDescription)"

            // 恢复输入文本以便重试
            inputText = trimmedText
        }

        isLoading = false
    }
}

// MARK: - Message Row View

/// 消息行视图
private struct MessageRowView: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // 头像
            avatar

            // 消息内容
            messageContent
        }
        .frame(maxWidth: .infinity, alignment: message.direction == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private var avatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(avatarColor.gradient)
                .frame(width: 32, height: 32)

            Image(systemName: avatarIcon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    private var avatarColor: Color {
        switch message.direction {
        case .user:
            return .blue
        case .agent:
            return .orange
        case .system:
            return .gray
        }
    }

    private var avatarIcon: String {
        switch message.direction {
        case .user:
            return "person.fill"
        case .agent:
            return "brain"
        case .system:
            return "info.circle.fill"
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 发送者名称
            Text(senderName)
                .font(.caption)
                .foregroundStyle(.secondary)

            // 消息文本
            Text(message.textContent ?? "")
                .font(.body)
                .textSelection(.enabled)

            // 工具调用（如果有）
            if !message.toolCalls.isEmpty {
                toolCallsView
            }

            // 时间戳
            Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(message.direction == .user ? Color.blue.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
        )
    }

    private var senderName: String {
        switch message.direction {
        case .user:
            return "你"
        case .agent:
            return "Agent"
        case .system:
            return "系统"
        }
    }

    @ViewBuilder
    private var toolCallsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(message.toolCalls) { toolCall in
                ToolCallBadgeView(toolCall: toolCall)
            }
        }
    }
}

// MARK: - Tool Call Badge View

/// 工具调用徽章视图
private struct ToolCallBadgeView: View {
    let toolCall: ToolCall

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: toolIcon)
                .font(.caption)

            Text(toolCall.title ?? toolCall.kind.displayName)
                .font(.caption)

            Text(toolStatusIcon)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(statusColor.opacity(0.2))
        )
        .foregroundStyle(statusColor)
    }

    private var toolIcon: String {
        switch toolCall.kind {
        case .read:
            return "doc.text"
        case .edit:
            return "pencil"
        case .execute:
            return "terminal"
        case .search:
            return "magnifyingglass"
        case .delete:
            return "trash"
        case .think:
            return "brain"
        case .fetch:
            return "arrow.down.doc"
        case .plan:
            return "list.bullet"
        case .switchMode:
            return "arrow.triangle.2.circlepath"
        case .other:
            return "wrench"
        }
    }

    private var statusColor: Color {
        switch toolCall.status {
        case .inProgress:
            return .blue
        case .success:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        }
    }

    private var toolStatusIcon: String {
        switch toolCall.status {
        case .inProgress:
            return "运行中..."
        case .success:
            return "完成"
        case .failed:
            return "失败"
        case .cancelled:
            return "已取消"
        }
    }
}

// MARK: - Tool Kind Extension

private extension ToolKind {
    var displayName: String {
        switch self {
        case .read:
            return "读取文件"
        case .edit:
            return "写入文件"
        case .execute:
            return "执行命令"
        case .search:
            return "搜索"
        case .delete:
            return "删除"
        case .think:
            return "思考"
        case .fetch:
            return "获取"
        case .plan:
            return "计划"
        case .switchMode:
            return "切换模式"
        case .other:
            return "其他"
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        Text("Chat Preview")
    }
}

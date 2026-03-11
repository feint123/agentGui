//
//  ChatView+MessageList.swift
//  agentGui
//

import SwiftUI

extension ChatView {

    // MARK: - Messages Area

    var messagesArea: some View {
        Group {
            if allMessages.isEmpty || isClearingMessages {
                emptyStateView
            } else {
                messageListView
            }
        }
    }

    var emptyStateView: some View {
        ContentUnavailableView {
            Label("开始对话", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("在下方输入您的问题，与 Claude 开始对话")
        }
    }

    var messageListView: some View {
        let globalWorkingDirectory = AppSettings.getOrCreate(in: modelContext).workingDirectory
        let effectiveWorkspaceRoot = workspaceState.effectiveWorkingDirectory(globalDefault: globalWorkingDirectory)

        return ScrollViewReader { proxy in
            List {
                ForEach(allMessages) { message in
                    MessageBubbleView(
                        message: message,
                        workspaceRoot: effectiveWorkspaceRoot,
                        isStreaming: claudeService.isStreaming,
                        onCopy: { copyMessage(message) },
                        onEdit: message.direction == .user
                            ? { newText in editAndResend(message: message, newText: newText) }
                            : nil,
                        onDelete: { deleteMessage(message) },
                        onDeleteFrom: { deleteFrom(message) },
                        onRegenerate: message.direction == .agent ? { regenerate() } : nil,
                        onRetry: (message.direction == .agent && message.status == .failed)
                            ? { regenerate() }
                            : nil
                    )
                    .id(message.id)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
            .listStyle(.plain)
            .onChange(of: allMessages.last?.textContent) { _, _ in
                if claudeService.isStreaming {
                    scrollToBottom(proxy: proxy)
                }
            }
        }
    }

    func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if let last = allMessages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

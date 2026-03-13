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
        .accessibilityIdentifier("chat.emptyState")
    }

    var messageListView: some View {
        let globalWorkingDirectory = AppSettings.getOrCreate(in: modelContext).workingDirectory
        let effectiveWorkspaceRoot = workspaceState.effectiveWorkingDirectory(globalDefault: globalWorkingDirectory)
        let projectionTrigger = ChatMessageListProjectionTrigger(
            messages: allMessages,
            workspaceRoot: effectiveWorkspaceRoot
        )
        let displaySnapshot = resolvedMessageListSnapshot(for: projectionTrigger)
        let messagesByID = Dictionary(uniqueKeysWithValues: allMessages.map { ($0.id, $0) })

        return ScrollViewReader { proxy in
            List {
                ForEach(displaySnapshot.rows) { row in
                    if let message = messagesByID[row.id] {
                        MessageBubbleView(
                            snapshot: row,
                            isStreaming: claudeService.isStreaming,
                            onCopy: { copyMessage(message) },
                            onEdit: row.direction == .user
                                ? { newText in editAndResend(message: message, newText: newText) }
                                : nil,
                            onDelete: { deleteMessage(message) },
                            onDeleteFrom: { deleteFrom(message) },
                            onRegenerate: row.direction == .agent ? { regenerate() } : nil,
                            onRetry: (row.direction == .agent && row.status == .failed)
                                ? { regenerate() }
                                : nil
                        )
                        .id(row.id)
                        .accessibilityIdentifier("message.row.\(row.id.uuidString)")
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }

                Color.clear
                    .frame(height: 8)
                    .id(ChatMessageListAutoScrollPolicy.bottomAnchorID)
                    .accessibilityHidden(true)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .onAppear {
                        isMessageListPinnedToBottom = true
                    }
                    .onDisappear {
                        if !isProgrammaticMessageListScrollInFlight {
                            isMessageListPinnedToBottom = false
                        }
                    }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("chat.messageList")
            .task(id: projectionTrigger) {
                rebuildMessageListSnapshot(for: projectionTrigger)
            }
            .onChange(of: allMessages.last?.id) { _, _ in
                guard let last = allMessages.last else { return }
                if ChatMessageListAutoScrollPolicy.shouldScrollOnMessageAppend(
                    lastMessageIsUser: last.isUserMessage,
                    isPinnedToBottom: isMessageListPinnedToBottom
                ) {
                    scrollToBottom(proxy: proxy)
                }
            }
            .onChange(of: allMessages.last?.textContent) { _, _ in
                if ChatMessageListAutoScrollPolicy.shouldScrollForStreaming(
                    isStreaming: claudeService.isStreaming,
                    isPinnedToBottom: isMessageListPinnedToBottom
                ) {
                    scrollToBottom(proxy: proxy)
                }
            }
        }
    }

    func scrollToBottom(proxy: ScrollViewProxy) {
        isProgrammaticMessageListScrollInFlight = true
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(ChatMessageListAutoScrollPolicy.bottomAnchorID, anchor: .bottom)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isProgrammaticMessageListScrollInFlight = false
        }
    }

    func resolvedMessageListSnapshot(for projectionTrigger: ChatMessageListProjectionTrigger) -> ChatMessageListSnapshot {
        guard messageListProjectionTrigger != projectionTrigger else {
            return messageListSnapshot
        }

        return ChatMessageListSnapshotBuilder.build(
            messages: allMessages,
            workspaceRoot: projectionTrigger.workspaceRoot,
            previous: messageListSnapshot.cache
        )
    }

    func rebuildMessageListSnapshot(for projectionTrigger: ChatMessageListProjectionTrigger) {
        messageListSnapshot = ChatMessageListSnapshotBuilder.build(
            messages: allMessages,
            workspaceRoot: projectionTrigger.workspaceRoot,
            previous: messageListSnapshot.cache
        )
        messageListProjectionTrigger = projectionTrigger
    }
}

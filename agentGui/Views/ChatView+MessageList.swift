//
//  ChatView+MessageList.swift
//  agentGui
//

import SwiftUI

extension ChatView {

    var currentMessageListProjectionTrigger: ChatMessageListProjectionTrigger {
        let globalWorkingDirectory = AppSettings.getOrCreate(in: modelContext).workingDirectory
        let effectiveWorkspaceRoot = workspaceState.effectiveWorkingDirectory(globalDefault: globalWorkingDirectory)
        return ChatMessageListProjectionTrigger(
            messages: allMessages,
            workspaceRoot: effectiveWorkspaceRoot
        )
    }

    // MARK: - Messages Area

    @ViewBuilder
    var messagesArea: some View {
        switch ChatMessageListPresentationState.resolve(
            isInitialLoadInFlight: isInitialMessageListLoadInFlight,
            isClearingMessages: isClearingMessages,
            snapshot: messageListSnapshot
        ) {
        case .loading:
            messageListLoadingView
        case .empty:
            emptyStateView
        case .content:
            messageListView
        }
    }

    var messageListLoadingView: some View {
        ScrollView {
            VStack(spacing: 18) {
                skeletonAgentMessageRow
                skeletonUserMessageRow
                skeletonAgentMessageRow
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("chat.messageList.loading")
    }

    var skeletonAgentMessageRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                SkeletonBlock(width: 14, height: 14, cornerRadius: 7)
                SkeletonBlock(width: 84, height: 12, cornerRadius: 6)
                SkeletonBlock(width: 44, height: 10, cornerRadius: 5)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                SkeletonBlock(height: 15, cornerRadius: 7)
                SkeletonBlock(width: 240, height: 15, cornerRadius: 7)
                HStack(spacing: 8) {
                    SkeletonBlock(width: 78, height: 26, cornerRadius: 13)
                    SkeletonBlock(width: 112, height: 26, cornerRadius: 13)
                    Spacer(minLength: 0)
                }
            }
            .padding(.leading, 20)
        }
    }

    var skeletonUserMessageRow: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 6) {
                    SkeletonBlock(width: 38, height: 10, cornerRadius: 5)
                    SkeletonBlock(width: 28, height: 10, cornerRadius: 5)
                }
                VStack(alignment: .trailing, spacing: 8) {
                    SkeletonBlock(width: 280, height: 14, cornerRadius: 7)
                    SkeletonBlock(width: 188, height: 14, cornerRadius: 7)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        let projectionTrigger = currentMessageListProjectionTrigger
        let messagesByID = Dictionary(uniqueKeysWithValues: allMessages.map { ($0.id, $0) })

        return ScrollViewReader { proxy in
            List {
                ForEach(messageListSnapshot.rows) { row in
                    if let message = messagesByID[row.id] {
                        MessageBubbleView(
                            snapshot: row,
                            isStreaming: effectiveStreamingState,
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
                await refreshMessageListSnapshot(for: projectionTrigger)
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
                    isStreaming: effectiveStreamingState,
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

    func refreshMessageListSnapshot(
        for projectionTrigger: ChatMessageListProjectionTrigger,
        showsLoadingPlaceholder: Bool = false
    ) async {
        if showsLoadingPlaceholder {
            isInitialMessageListLoadInFlight = true
        }

        defer {
            if showsLoadingPlaceholder {
                isInitialMessageListLoadInFlight = false
            }
        }

        guard messageListProjectionTrigger != projectionTrigger else {
            return
        }

        await Task.yield()
        guard !Task.isCancelled else { return }

        messageListSnapshot = ChatMessageListSnapshotBuilder.build(
            messages: allMessages,
            workspaceRoot: projectionTrigger.workspaceRoot,
            previous: messageListSnapshot.cache
        )
        messageListProjectionTrigger = projectionTrigger
    }
}

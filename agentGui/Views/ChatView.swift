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

    @Environment(\.modelContext) var modelContext
    @Environment(ClaudeService.self) var claudeService
    @Environment(WorkspaceState.self) var workspaceState

    // MARK: - Properties

    let session: Session

    @Query var allMessages: [Message]
    @Query(sort: \Session.updatedAt, order: .reverse) var allSessions: [Session]

    @State var inputText = ""
    @State var errorMessage: String?
    @State var attachedFiles: [AttachedFile] = []
    @State var isDropTargeted = false
    @State var viewingMedia: MediaItem? = nil
    @State var deleteFromConfirmMessage: Message?
    @State var activeTask: Task<Void, Never>?
    /// Prevents ForEach from accessing Message objects that are about to be deleted
    @State var isClearingMessages = false

    // MARK: - Context Chips
    @State var showFileContext = true
    @State var showSelectionContext = true

    // MARK: - @ Mention
    @State var mentionQuery: String? = nil
    @State var mentionCandidates: [URL] = []
    @State var mentionWorkingDir: String = ""

    @FocusState var isInputFocused: Bool

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
                    claudeService.pendingUserQuestion?.cancel()
                    claudeService.pendingUserQuestion = nil
                }
            }
        )) { request in
            AskUserQuestionView(request: request)
        }
        .sheet(item: $viewingMedia) { item in
            MediaViewerView(item: item)
        }
        .confirmationDialog(
            "删除此消息及之后的所有对话？",
            isPresented: Binding(
                get: { deleteFromConfirmMessage != nil },
                set: { if !$0 { deleteFromConfirmMessage = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let msg = deleteFromConfirmMessage {
                Button("删除", role: .destructive) {
                    confirmDeleteFrom(msg)
                    deleteFromConfirmMessage = nil
                }
            }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: workspaceState.selectedFile) { _, _ in
            showFileContext = true
        }
        .onChange(of: workspaceState.editorSelectedText) { _, _ in
            showSelectionContext = true
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        Text("ChatView Preview")
    }
}


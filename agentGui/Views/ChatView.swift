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
    @Environment(SkillService.self) var skillService
    @Environment(WorkspaceState.self) var workspaceState
    @Environment(WorkflowRuntime.self) var workflowRuntime

    // MARK: - Properties

    let session: Session

    @Query var allMessages: [Message]
    @Query(sort: \Session.updatedAt, order: .reverse) var allSessions: [Session]
    @Query(sort: \WritingProject.updatedAt, order: .reverse) var allWritingProjects: [WritingProject]

    @State var inputText = ""
    @State var errorMessage: String?
    @State var attachedFiles: [AttachedFile] = []
    @State var isDropTargeted = false
    @State var viewingMedia: MediaItem? = nil
    @State var deleteFromConfirmMessage: Message?
    @State var activeTask: Task<Void, Never>?
    /// Prevents ForEach from accessing Message objects that are about to be deleted
    @State var isClearingMessages = false

    // MARK: - Workflow
    @State var showWorkflowPanel = false
    @Query var allWorkflows: [WorkflowInstance]

    // MARK: - Context Chips
    @State var showFileContext = true
    @State var showSelectionContext = true

    // MARK: - @ Mention
    @State var mentionQuery: String? = nil
    @State var mentionCandidates: [URL] = []
    @State var mentionWorkingDir: String = ""
    @State var showStoryProjectBrowser = false

    @FocusState var isInputFocused: Bool

    // MARK: - Initializer

    init(session: Session) {
        self.session = session
        let sessionId = session.sessionId
        _allMessages = Query(
            filter: #Predicate<Message> { $0.session?.sessionId == sessionId },
            sort: \.sequence
        )
        _allWorkflows = Query(
            filter: #Predicate<WorkflowInstance> { $0.sessionId == sessionId },
            sort: \.startedAt,
            order: .reverse
        )
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                messagesArea
                inputArea
            }

            // Workflow sidebar panel
            if showWorkflowPanel, let instance = allWorkflows.first {
                Divider()
                WorkflowSidebar(instance: instance)
                    .frame(width: 300)
                    .transition(.move(edge: .trailing))
            }
        }
        .navigationTitle(session.title)
        .navigationSubtitle(navigationSubtitleText)
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
        .onChange(of: workflowRuntime.isRunning) { _, isRunning in
            if isRunning {
                withAnimation(.easeInOut(duration: 0.2)) { showWorkflowPanel = true }
            }
        }
        .onChange(of: allWorkflows.count) { _, _ in
            if !allWorkflows.isEmpty {
                withAnimation(.easeInOut(duration: 0.2)) { showWorkflowPanel = true }
            }
        }
        .sheet(isPresented: $showStoryProjectBrowser) {
            StoryProjectListView(session: session)
                .frame(minWidth: 900, minHeight: 620)
        }
    }

    var storyMemoryEnabled: Bool {
        AppSettings.getOrCreate(in: modelContext).enableStoryMemory
    }

    var activeStoryProject: WritingProject? {
        guard let projectId = UUID(uuidString: session.activeWritingProjectId) else { return nil }
        return allWritingProjects.first(where: { $0.id == projectId })
    }

    var unifiedMemoryRuntimeEnabled: Bool {
        AppSettings.getOrCreate(in: modelContext).enableUnifiedMemoryRuntime
    }

    var navigationSubtitleText: String {
        if !claudeService.isConfigured {
            return "⚠️ 请先配置 API Key"
        }
        if unifiedMemoryRuntimeEnabled {
            let settings = AppSettings.getOrCreate(in: modelContext)
            return settings.enableMemoryGovernance ? "统一记忆运行时已启用 · 治理层开启" : "统一记忆运行时已启用"
        }
        return ""
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        Text("ChatView Preview")
    }
}


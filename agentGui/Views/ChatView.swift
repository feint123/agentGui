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
    @Environment(RuntimeRecoveryService.self) var runtimeRecoveryService
    @Environment(ChangeReviewProjectionStore.self) var changeReviewProjectionStore

    // MARK: - Properties

    let session: Session
    let showsNavigationChrome: Bool

    @Query var allMessages: [Message]
    @Query(sort: \Session.updatedAt, order: .reverse) var allSessions: [Session]

    @State var inputText = ""
    @State var composerHeight = ChatSurfaceLayoutMetrics.composerDefaultHeight
    @State var errorMessage: String?
    @State var attachedFiles: [AttachedFile] = []
    @State var isDropTargeted = false
    @State var viewingMedia: MediaItem? = nil
    @State var deleteFromConfirmMessage: Message?
    @State var activeTask: Task<Void, Never>?
    @State var executionProviderAvailabilityModel = ChatExecutionProviderAvailabilityModel()
    /// Prevents ForEach from accessing Message objects that are about to be deleted
    @State var isClearingMessages = false
    @State var isDeletingAllSessions = false
    @State var messageListSnapshot = ChatMessageListSnapshot.empty
    @State var messageListProjectionTrigger: ChatMessageListProjectionTrigger?
    @State var isInitialMessageListLoadInFlight = true
    @State var isMessageListPinnedToBottom = true
    @State var isProgrammaticMessageListScrollInFlight = false
    @State var isExecutionRuntimeBootstrapInFlight = false
    @State var acpConfigurationRefreshToken = 0

    // MARK: - Context Chips
    @State var showFileContext = true
    @State var showSelectionContext = true

    // MARK: - @ Mention
    @State var mentionQuery: String? = nil
    @State var mentionCandidates: [URL] = []
    @State var mentionWorkingDir: String = ""
    @State var highlightedMentionIndex: Int? = nil

    // MARK: - Slash Command
    @State var slashQuery: String? = nil
    @State var slashCandidates: [ChatSlashCommandItem] = []
    @State var highlightedSlashItemID: String? = nil
    @State var slashStateDebouncer = ChatComposerSlashDebouncer()
    @State var activeInputDirectives: [ChatInputDirective] = []
    @State var didApplyUITestInitialComposerText = false
    @State var showingRMSPanel = false

    @FocusState var isInputFocused: Bool

    // MARK: - Initializer

    init(session: Session, showsNavigationChrome: Bool = true) {
        self.session = session
        self.showsNavigationChrome = showsNavigationChrome
        let sessionId = session.sessionId
        _allMessages = Query(
            filter: #Predicate<Message> { $0.session?.sessionId == sessionId },
            sort: \.sequence
        )
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                readOnlyBanner
                if let recoverySnapshot = runtimeRecoveryService.recoveryItems(for: session.sessionId).first {
                    ChatReadableWidthContainer {
                        RecoveryBannerView(
                            snapshot: recoverySnapshot,
                            onView: {
                                try? runtimeRecoveryService.markViewed(recoverySnapshot, in: modelContext)
                            },
                            onInterrupt: {
                                try? runtimeRecoveryService.markInterrupted(recoverySnapshot, in: modelContext)
                            },
                            onClear: {
                                try? runtimeRecoveryService.clear(recoverySnapshot, in: modelContext)
                            }
                        )
                    }
                }
                ChatReadableWidthContainer {
                    messagesArea
                }
                .task(id: currentMessageListProjectionTrigger) {
                    await refreshMessageListSnapshotForCurrentState()
                }
                ChatReadableWidthContainer {
                    inputArea
                }
            }
        }
        .accessibilityIdentifier("panel.chat")
        .modifier(ChatNavigationChromeModifier(
            title: showsNavigationChrome ? session.title : nil,
            subtitle: showsNavigationChrome ? navigationSubtitleText : nil
        ))
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
        .onChange(of: workspaceState.editorSelection) { _, _ in
            showSelectionContext = true
        }
        .task(id: session.sessionId) {
            await bootstrapSessionViewState()
        }
    }

    var rmsRuntimeEnabled: Bool {
        AppSettings.getOrCreate(in: modelContext).memoryEnabled
    }

    var navigationSubtitleText: String {
        if !claudeService.isConfigured {
            return "⚠️ 请先配置 API Key"
        }
        if rmsRuntimeEnabled {
            return "RMS memory 已启用"
        }
        return ""
    }

    var sessionExecutionProjection: SessionExecutionProjection {
        claudeService.executionProjectionStore.projection(for: session.sessionId)
    }

    var usesExecutionProjectionUI: Bool {
        sessionExecutionProjection.isRunning ||
        sessionExecutionProjection.queuedCount > 0
    }

    var effectiveStreamingState: Bool {
        usesExecutionProjectionUI ? sessionExecutionProjection.isRunning : claudeService.isStreaming
    }

    var sessionInteractionPolicy: SessionInteractionPolicy {
        SessionInteractionPolicy(session: session)
    }
}

extension ChatView {
    func bootstrapSessionViewState() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await refreshMessageListSnapshotForCurrentState(showsLoadingPlaceholder: true)
            }
            group.addTask {
                await refreshRecoverySummary()
            }
            group.addTask {
                await warmExecutionRuntimeIfNeeded()
            }
        }
    }

    private func refreshRecoverySummary() async {
        await Task.yield()
        try? runtimeRecoveryService.refresh(from: modelContext)
    }

    private func warmExecutionRuntimeIfNeeded() async {
        isExecutionRuntimeBootstrapInFlight = true
        defer { isExecutionRuntimeBootstrapInFlight = false }

        await claudeService.handleExecutionProviderSelectionChange(
            session: session,
            selectedProviderID: resolvedExecutionProviderID,
            modelContext: modelContext
            ,
            trigger: .sessionBootstrap
        )

        acpConfigurationRefreshToken &+= 1
        syncSlashState(with: inputText)
    }

    @ViewBuilder
    var readOnlyBanner: some View {
        if sessionInteractionPolicy.readOnlyReason.isEmpty == false {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.displaySourceTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(sessionInteractionPolicy.readOnlyReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if sessionInteractionPolicy.canCloneAsLocal {
                    Button("复制为本地会话") {
                        cloneReadOnlySessionFromBanner()
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("chat.readOnlyBanner")
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }

    private func cloneReadOnlySessionFromBanner() {
        do {
            _ = try SessionToolbarActions(modelContext: modelContext, workspaceState: workspaceState)
                .cloneCurrentSessionAsLocal()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ChatNavigationChromeModifier: ViewModifier {
    let title: String?
    let subtitle: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let title {
            if let subtitle, !subtitle.isEmpty {
                content
                    .navigationTitle(title)
                    .navigationSubtitle(subtitle)
            } else {
                content
                    .navigationTitle(title)
            }
        } else {
            content
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        Text("ChatView Preview")
    }
}


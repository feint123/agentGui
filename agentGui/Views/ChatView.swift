//
//  ChatView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import SwiftData
import Combine
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
    @State var messageListProjectionModel = ChatMessageListProjectionModel()
    @State var scrollState: ChatScrollState = .tracking
    @State var programmaticScrollTask: Task<Void, Never>?
    @State var scrollToBadgeBottom = false
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
    @State var voiceInputController = VoiceInputController()
    @State var pendingAgentTeamComposer: AgentTeamBriefComposerRequest?

    // MARK: - Rewind
    @State var isRewindSelectorPresented = false
    /// R-D4: 从消息上下文菜单触发的待确认回滚数据。
    /// 非 nil 时触发 RewindConfirmationSheet。
    @State var contextMenuPendingConfirmation: MessageRewindSelectorViewModel.PendingConfirmation? = nil
    @State var previousMessageListRefreshKey: ChatMessageListRefreshKey? = nil

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
                if let runtimeRecoveryItem = runtimeRecoveryService.runtimeRecoveryItem(for: session.sessionId) {
                    ChatReadableWidthContainer {
                        RecoveryBannerView(runtimeItem: runtimeRecoveryItem)
                    }
                } else if let recoveryItem = runtimeRecoveryService.recoveryItems(for: session.sessionId).first {
                    ChatReadableWidthContainer {
                        RecoveryBannerView(
                            item: recoveryItem,
                            onView: {
                                Task {
                                    try? await runtimeRecoveryService.markViewed(recoveryItem)
                                }
                            },
                            onInterrupt: {
                                Task {
                                    try? await runtimeRecoveryService.markInterrupted(recoveryItem)
                                }
                            },
                            onClear: {
                                Task {
                                    try? await runtimeRecoveryService.clear(recoveryItem)
                                }
                            }
                        )
                    }
                }
                ChatReadableWidthContainer {
                    messagesArea
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
            get: { claudeService.pendingUserQuestion(for: session.sessionId) },
            set: { newVal in
                if newVal == nil {
                    claudeService.pendingUserQuestion(for: session.sessionId)?.cancel()
                    claudeService.clearPendingUserQuestion(for: session.sessionId)
                }
            }
        )) { request in
            AskUserQuestionView(request: request)
        }
        .sheet(item: $viewingMedia) { item in
            MediaViewerView(item: item)
        }
        .sheet(item: $pendingAgentTeamComposer) { request in
            AgentTeamBriefComposerSheet(
                sourceContext: request.sourceContext,
                initialDraft: request.draft,
                onCancel: {
                    pendingAgentTeamComposer = nil
                },
                onSubmit: { draft in
                    submitAgentTeamComposer(draft: draft, source: request.sourceContext)
                }
            )
        }
        .sheet(isPresented: $isRewindSelectorPresented) {
            makeRewindSelectorView()
        }
        .sheet(item: $contextMenuPendingConfirmation) { pending in
            RewindConfirmationSheet(
                pending: pending,
                onExecute: { option in
                    await executeContextMenuRewind(pending: pending, option: option)
                },
                onCancel: {
                    contextMenuPendingConfirmation = nil
                }
            )
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
        .onChange(of: voiceInputController.displayedText) { _, newValue in
            syncComposerTextFromVoiceControllerIfNeeded(newValue)
        }
        .task(id: session.sessionId) {
            await bootstrapSessionViewState()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .rewindDidComplete)
                .filter { ($0.object as? String) == session.sessionId }
        ) { notification in
            if let text = notification.userInfo?["repopulateText"] as? String {
                inputText = text
            }
        }
    }

    var rmsRuntimeEnabled: Bool {
        AppSettings.getOrCreate(in: modelContext).memoryEnabled
    }

    var navigationSubtitleText: String {
        if !claudeService.isConfigured {
            return "⚠️ 请先配置 API Key"
        }
        return ""
    }

    var sessionExecutionProjection: SessionExecutionProjection {
        claudeService.executionProjectionStore.projection(for: session.sessionId)
    }

    var usesExecutionProjectionUI: Bool {
        ChatComposerExecutionPresentation.shouldUseExecutionProjectionUI(
            for: sessionExecutionProjection
        )
    }

    var effectiveStreamingState: Bool {
        sessionExecutionProjection.isRunning
    }

    var sessionInteractionPolicy: SessionInteractionPolicy {
        SessionInteractionPolicy(session: session)
    }

    var rewindSelectorDisabled: Bool {
        // 无可回滚的用户消息（< 2 条）
        let userMessageCount = allMessages.filter { $0.direction == .user }.count
        guard userMessageCount >= 2 else { return true }
        // session 为只读或 agent loop 正在运行
        guard sessionInteractionPolicy.canSend else { return true }
        return false
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
        await runtimeRecoveryService.scheduleBootstrapRefresh()
    }

    private func warmExecutionRuntimeIfNeeded() async {
        isExecutionRuntimeBootstrapInFlight = true
        defer { isExecutionRuntimeBootstrapInFlight = false }

        // 使用虚拟 probe session 预热 ACP provider（填充 provider 级别 bootstrap 缓存），
        // 不绑定真实会话，避免在用户发送首条消息前在 SwiftData 中写入 binding 记录。
        // 真实会话的 ACP 连接将由 ConversationExecutionOrchestrator 在实际 send 时按需建立。
        let providerReference = resolvedExecutionProviderReference
        let probeSession = Session(title: "__warmup_probe__", kind: .local)
        await claudeService.handleExecutionProviderSelectionChange(
            session: probeSession,
            selectedProviderReference: providerReference,
            modelContext: modelContext,
            trigger: .sessionBootstrap
        )
        // 清理 probe session 的运行时和 binding（provider 级别 bootstrap 缓存不受影响）
        let registry = claudeService.executionProviderRegistry
        let acpProvider = registry?.providerIfAvailable(for: providerReference) as? ACPRemoteSessionConfigurationControlling
        await acpProvider?.discardWarmupState(localSessionID: probeSession.sessionId, modelContext: modelContext)

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
            .transition(ChatMotion.bannerTransition)
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


//
//  agentGuiApp.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import SwiftData
import SwiftAnthropic
import AppKit

enum PersistenceSchema {
    static let currentVersion = 1

    static let sharedModelTypes: [any PersistentModel.Type] = [
        AppSettings.self,
        ACPProviderProfile.self,
        Session.self,
        ChangeProposal.self,
        ProposedFileChange.self,
        ChangeReviewDecision.self,
        ACPExternalSessionBinding.self,
        Message.self,
        ChannelAccountBinding.self,
        RemoteConversationBinding.self,
        SessionProjectionBinding.self,
        ChannelProjectionDelivery.self,
        RemoteMessageReceipt.self,
        ToolCall.self,
        AgentRound.self,
        SessionTaskState.self,
        RecoverySnapshot.self,
        IntegrityIssue.self,
        BackgroundAgentTask.self,
        BackgroundAgentTaskRun.self,
        ExecutionJob.self,
        ExecutionAttempt.self,
    ]

    static let sharedModelTypeNames: [String] = sharedModelTypes.map { String(describing: $0) }
}

@MainActor
enum ChangeReviewBootstrapper {
    static func restorePendingProposals(
        modelContext: ModelContext,
        projectionStore: ChangeReviewProjectionStore,
        persistenceCoordinator: PersistenceCoordinator = .shared
    ) async throws {
        var descriptor = FetchDescriptor<ChangeProposal>()
        descriptor.sortBy = [SortDescriptor(\ChangeProposal.updatedAt, order: .reverse)]

        let proposals = try modelContext.fetch(descriptor)
        let store = ChangeProposalStore(
            modelContext: modelContext,
            persistenceCoordinator: persistenceCoordinator
        )

        for proposal in proposals where proposal.state.isPendingReview {
            let snapshot = try await store.reviewSnapshot(for: proposal.id)
            guard snapshot.fileChanges.contains(where: { $0.state.isPendingReview }) else {
                continue
            }
            projectionStore.set(snapshot)
        }
    }
}

@main
struct agentGuiApp: App {
    static let persistenceSchemaVersion = PersistenceSchema.currentVersion

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
        ProcessInfo.processInfo.arguments.contains("-com.agentgui.test.mode")
    }

    @MainActor
    private static func makeUpdateCoordinator() -> SparkleUpdateCoordinator {
#if canImport(Sparkle) && os(macOS)
        guard !isRunningTests else {
            return SparkleUpdateCoordinator(driver: DisabledSparkleDriver())
        }

        var coordinator: SparkleUpdateCoordinator!
        let delegate = SparkleUpdateDelegate {
            coordinator.updateChannel
        }
        let driver = LiveSparkleDriver(updaterDelegate: delegate)
        coordinator = SparkleUpdateCoordinator(driver: driver)
        return coordinator
#else
        return SparkleUpdateCoordinator(driver: DisabledSparkleDriver())
#endif
    }

    init() {
        ConfigDirectoryManager.shared.setup()
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    private let launchOptions = TestLaunchOptions.current

    @State private var claudeService = ClaudeService()
    @State private var skillService = SkillService()
    @State private var runtimeRecoveryService = RuntimeRecoveryService()
    @State private var reliabilityCenterViewModel = ReliabilityCenterViewModel()
    @State private var backgroundActivityCoordinator: BackgroundActivityCoordinator?
    @State private var channelRegistry = IMChannelRegistry()
    @State private var channelRuntimeBootstrap: ChannelRuntimeBootstrap?
    @State private var workbenchSceneServices = WorkbenchSceneServices()
    @State private var updateCoordinator = agentGuiApp.makeUpdateCoordinator()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema(PersistenceSchema.sharedModelTypes)

        let modelConfiguration: ModelConfiguration
        if Self.isRunningTests {
            modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            let storeDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".agentgui")
            try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
            let storeURL = storeDirectory.appendingPathComponent("default.store")
            modelConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        }

        do {
            return try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(claudeService)
                .environment(skillService)
                .environment(runtimeRecoveryService)
                .environment(reliabilityCenterViewModel)
                .environment(workbenchSceneServices.workspaceState)
                .environment(workbenchSceneServices.workbenchState)
                .environment(workbenchSceneServices.gitPanelViewModel)
                .environment(workbenchSceneServices.changeReviewProjectionStore)
                .onAppear {
                    let context = sharedModelContainer.mainContext
                    seedUITestDataIfNeeded(in: context)

                    // 从持久化设置加载 API Key
                    let settings = AppSettings.getOrCreate(in: context, persistenceCoordinator: .shared)
                    updateCoordinator.updateChannel = settings.sparkleUpdateChannel
                    updateCoordinator.startUpdaterIfNeeded()
                    claudeService.applyConnectionSettings(settings)
                    claudeService.skillService = skillService
                    runtimeRecoveryService.bindRuntimeSnapshotStore(claudeService.executionRuntimeSnapshotStore)
                    reliabilityCenterViewModel.bindRuntimeSnapshotStore(claudeService.executionRuntimeSnapshotStore)
                    Task {
                        await skillService.loadSkills()
                    }
                    let backgroundCoordinator = BackgroundActivityCoordinator(
                        settingsProvider: { settings },
                        registry: BackgroundTaskRegistry(observationService: BackgroundTaskObservationService()),
                        executionCoordinator: BackgroundTaskExecutionCoordinator(
                            evaluator: BackgroundTaskEligibilityEvaluator(),
                            observationService: BackgroundTaskObservationService(),
                            promptComposer: BackgroundPromptComposer(),
                            adapter: BackgroundAgentLoopAdapter(),
                            resultWriter: BackgroundSessionResultWriter()
                        ),
                        observationService: BackgroundTaskObservationService(),
                        serviceProvider: { claudeService.service ?? AnthropicServiceFactory.service(apiKey: settings.apiKey, basePath: settings.baseURL.isEmpty ? "https://api.anthropic.com" : settings.baseURL, betaHeaders: nil) }
                    )
                    backgroundActivityCoordinator = backgroundCoordinator
                    let deliveryCoordinator = OutboundDeliveryCoordinator { kind in
                        channelRegistry.adapter(for: kind)
                    }
                    let remoteDeliveryCoordinator = RemoteTurnDeliveryCoordinator { context in
                        guard let driver = channelRegistry.adapter(for: context.channelKind) as? any ChannelProjectionDriver else {
                            return nil
                        }
                        return try await driver.openSession(context: context)
                    }
                    let remoteOrchestrator = RemoteAgentOrchestrator(
                        router: RemoteConversationRouter(),
                        executor: ClaudeRemoteAgentExecutor(claudeService: claudeService),
                        remoteDeliveryCoordinator: remoteDeliveryCoordinator,
                        deliveryCoordinator: deliveryCoordinator
                    )
                    let channelBootstrap = ChannelRuntimeBootstrap(
                        registry: channelRegistry,
                        orchestrator: remoteOrchestrator,
                        deduplicator: ChannelEventDeduplicator()
                    )
                    channelBootstrap.registerDefaultAdaptersIfNeeded()
                    channelRuntimeBootstrap = channelBootstrap
                    if settings.backgroundAgentEnabled {
                        try? runtimeRecoveryService.normalizeBackgroundTaskRuns(in: context)
                        Task { @MainActor in
                            try? await backgroundCoordinator.bootstrap(modelContext: context)
                        }
                    }
                    Task { @MainActor in
                        await claudeService.bootstrapExecutionRuntime(modelContext: context)
                    }
                    Task { @MainActor in
                        try? await channelBootstrap.startEnabledChannels(modelContext: context)
                        await channelBootstrap.stopDisabledChannels(modelContext: context)
                    }
                    try? runtimeRecoveryService.refresh(from: context)
                    reliabilityCenterViewModel.refresh(using: context)
                }
                .environment(PersistenceCoordinator.shared)
        }
        .modelContainer(sharedModelContainer)
        .commands {
            AppMenuCommands(updateCommandHandler: updateCoordinator)
            WorkspaceCommands()
            RecentCommands()
            NavigationCommands()
            WindowCommands()
        }

        WindowGroup("上下文", id: WorkbenchContextWindowScene.id, for: WorkbenchContextSceneValue.self) { selection in
            WorkbenchContextWindowView(selection: selection)
                .environment(claudeService)
                .environment(workbenchSceneServices.workspaceState)
                .environment(workbenchSceneServices.workbenchState)
                .environment(workbenchSceneServices.gitPanelViewModel)
                .environment(workbenchSceneServices.changeReviewProjectionStore)
                .environment(PersistenceCoordinator.shared)
        }
        .modelContainer(sharedModelContainer)

        Window("设置", id: SettingsWindowScene.id) {
            SettingsWindowView(
                updatePreferencesBridge: SparkleUpdatePreferencesBridge(coordinator: updateCoordinator)
            )
                .environment(claudeService)
                .environment(skillService)
                .environment(runtimeRecoveryService)
                .environment(reliabilityCenterViewModel)
                .environment(PersistenceCoordinator.shared)
        }
        .modelContainer(sharedModelContainer)

        Window("Agent 工作室", id: AgentStudioWindowScene.id) {
            AgentStudioWindowView()
                .environment(claudeService)
                .environment(PersistenceCoordinator.shared)
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 960, height: 540)
    }

    @MainActor
    private func seedUITestDataIfNeeded(in context: ModelContext) {
        guard launchOptions.isUITestMode else { return }

        let persistenceCoordinator = PersistenceCoordinator.shared
        let settings = AppSettings.getOrCreate(in: context, persistenceCoordinator: persistenceCoordinator)
        var settingsChanged = false

        if launchOptions.preloadAPIKey && settings.apiKey.isEmpty {
            settings.apiKey = "sk-ant-ui-test"
            settingsChanged = true
        }

        let sessionId = launchOptions.sessionID ?? "ui-test-session"
        let session = ensureSession(sessionId: sessionId, in: context)

        if let workingDirectoryPath = launchOptions.workingDirectoryPath,
           session.workingDirectory != workingDirectoryPath {
            session.workingDirectory = workingDirectoryPath
            settings.workingDirectory = workingDirectoryPath
            settingsChanged = true
        }

        if launchOptions.preloadMessages {
            ensureCompletedMessages(for: session, in: context)
        }

        if let chatProjectionFixture = launchOptions.chatProjectionFixture {
            ensureChatProjectionFixture(for: session, mode: chatProjectionFixture, in: context)
        }

        if let executionFixtureMode = launchOptions.executionFixtureMode {
            ensureExecutionProjectionFixture(for: session, mode: executionFixtureMode, in: context)
            if settings.apiKey.isEmpty {
                settings.apiKey = "sk-ant-ui-test"
                settingsChanged = true
            }
        }

        if let todoFixtureMode = launchOptions.todoFixtureMode {
            ensureTodoItems(for: session.sessionId, mode: todoFixtureMode, in: context)
        }

        if launchOptions.preloadToolCall {
            ensureCompletedMessages(for: session, in: context)
            ensureToolCall(for: session, in: context)
        }

        if launchOptions.recoveryMode {
            ensurePendingAgentMessage(for: session, in: context)
        }

        if settingsChanged {
            try? persistenceCoordinator.save(
                context,
                domain: .settings,
                userMessage: "UI 测试设置初始化未成功保存"
            )
        }
    }

    @MainActor
    private func ensureSession(sessionId: String, in context: ModelContext) -> Session {
        let existing = (try? context.fetch(FetchDescriptor<Session>()))?.first(where: { $0.sessionId == sessionId })
        if let existing {
            return existing
        }

        let session = Session.fixture(sessionId: sessionId, title: "UI Test Session")
        context.insert(session)
        try? PersistenceCoordinator.shared.save(
            context,
            domain: .sessionMessages,
            userMessage: "UI 测试会话初始化未成功保存"
        )
        return session
    }

    @MainActor
    private func ensureCompletedMessages(for session: Session, in context: ModelContext) {
        guard session.messages.isEmpty else { return }
        let userMessage = Message.userFixture(text: "Run the release checks", session: session)
        let agentMessage = Message.agentFixture(text: "Release checklist prepared.", session: session)
        context.insert(userMessage)
        context.insert(agentMessage)
        try? PersistenceCoordinator.shared.save(
            context,
            domain: .sessionMessages,
            userMessage: "UI 测试消息初始化未成功保存"
        )
    }

    @MainActor
    private func ensurePendingAgentMessage(for session: Session, in context: ModelContext) {
        let hasPendingAgentMessage = session.messages.contains { $0.direction == .agent && $0.status == .pending }
        guard !hasPendingAgentMessage else { return }

        let pendingMessage = Message.agentFixture(
            text: "Partial response that should be recovered",
            session: session,
            status: .pending
        )
        context.insert(pendingMessage)
        try? PersistenceCoordinator.shared.save(
            context,
            domain: .sessionMessages,
            userMessage: "UI 测试恢复消息初始化未成功保存"
        )
    }

    @MainActor
    private func ensureToolCall(for session: Session, in context: ModelContext) {
        let existingToolCall = session.messages
            .flatMap(\.toolCalls)
            .first(where: { $0.kind == .read })
        guard existingToolCall == nil else { return }

        guard let agentMessage = session.messages.first(where: { $0.direction == .agent }) else { return }

        let toolCall = ToolCall.fixture(
            kind: .read,
            message: agentMessage,
            filePath: "/tmp/ReleaseChecklist.md",
            status: .inProgress
        )
        toolCall.title = "读取文件"
        toolCall.terminalOutput = "Release checklist contents"
        context.insert(toolCall)
        try? PersistenceCoordinator.shared.save(
            context,
            domain: .toolCalls,
            userMessage: "UI 测试工具调用初始化未成功保存"
        )
    }

    @MainActor
    private func ensureTodoItems(for sessionId: String, mode: String, in context: ModelContext) {
        guard mode == "basic" else { return }

        let items = [
            TodoItem(id: "todo-1", title: "确认输入区 Todo 卡片位置", status: .inProgress),
            TodoItem(id: "todo-2", title: "验证 slash 浮层优先级", status: .pending),
            TodoItem(id: "todo-3", title: "移除侧栏旧入口", status: .done)
        ]

        let store = SessionTaskStateStore(modelContext: context, persistenceCoordinator: .shared)
        try? store.saveTodoItems(items, for: sessionId)
        claudeService.sessionTodoLists[sessionId] = items
    }

    @MainActor
    private func ensureChatProjectionFixture(for session: Session, mode: String, in context: ModelContext) {
        guard session.messages.isEmpty else { return }

        let userMessage = Message.userFixture(text: "整理 agent message 投影", session: session)
        context.insert(userMessage)

        switch mode {
        case "liveAgentExecution":
            let agentMessage = Message.agentMessage(text: nil, session: session)
            agentMessage.status = .pending
            let round = AgentRound(roundIndex: 0, message: agentMessage)
            round.timestamp = Date(timeIntervalSince1970: 1_710_000_000)
            round.thinkingContent = "准备执行命令"

            let exec = ToolCall(toolCallId: "ui-live-exec", kind: .execute, message: agentMessage, agentRound: round)
            exec.title = "xcodebuild -scheme agentGui"
            exec.status = ToolStatus.inProgress
            exec.startTime = Date(timeIntervalSince1970: 1_710_000_001)
            exec.terminalExecutionMode = "background"
            exec.terminalTaskStatus = "runningBackground"
            exec.terminalPromptSummary = "Compile Swift source..."

            round.toolCalls = [exec]
            agentMessage.agentRounds = [round]

            context.insert(agentMessage)
            context.insert(round)
            context.insert(exec)
        case "settledAgentDelivery":
            let agentMessage = Message.agentMessage(text: nil, session: session)
            agentMessage.status = .completed
            let round = AgentRound(roundIndex: 0, message: agentMessage)
            round.timestamp = Date(timeIntervalSince1970: 1_710_000_000)
            round.thinkingContent = "分析结构"
            round.text = "完成调整"

            let read = ToolCall(toolCallId: "ui-read", kind: .read, message: agentMessage, agentRound: round)
            read.filePath = "/tmp/ChatView.swift"
            read.status = ToolStatus.success
            read.startTime = Date(timeIntervalSince1970: 1_710_000_001)
            read.endTime = Date(timeIntervalSince1970: 1_710_000_002)

            let edit = ToolCall(toolCallId: "ui-edit", kind: .edit, message: agentMessage, agentRound: round)
            edit.filePath = "/tmp/MessageBubbleView.swift"
            edit.diffContent = "--- old\n+++ new\n-old\n+new"
            edit.status = ToolStatus.success
            edit.startTime = Date(timeIntervalSince1970: 1_710_000_003)
            edit.endTime = Date(timeIntervalSince1970: 1_710_000_004)

            round.toolCalls = [read, edit]
            agentMessage.agentRounds = [round]

            context.insert(agentMessage)
            context.insert(round)
            context.insert(read)
            context.insert(edit)
        default:
            return
        }

        try? PersistenceCoordinator.shared.save(
            context,
            domain: .sessionMessages,
            userMessage: "UI 测试聊天投影夹具初始化未成功保存"
        )
    }

    @MainActor
    private func ensureExecutionProjectionFixture(for session: Session, mode: String, in context: ModelContext) {
        switch mode {
        case "runningWithQueueSupport":
            session.defaultExecutionProviderID = ConversationExecutionProviderID.builtInAgent.rawValue
            claudeService.executionProjectionStore.apply(
                runtimeSnapshot: SessionRuntimeSnapshot(
                    sessionID: session.sessionId,
                    queuedJobIDs: [],
                    runningJobID: UUID(),
                    runningProviderReference: .builtIn,
                    requestedCancellationJobIDs: [],
                    lastAction: .started,
                    lastUpdatedAt: .now
                )
            )

            if claudeService.executionOrchestrator == nil {
                claudeService.executionOrchestrator = ConversationExecutionOrchestrator(
                    modelContext: context,
                    persistenceStore: ExecutionPersistenceStore(
                        modelContext: context,
                        persistenceCoordinator: .shared
                    ),
                    projectionStore: claudeService.executionProjectionStore,
                    projectionWriter: SessionExecutionLifecycleFanoutWriter(
                        projectionWriter: claudeService.executionProjectionStore,
                        runtimeBus: claudeService.executionRuntimeBus
                    ),
                    scheduler: ExecutionScheduler(maxConcurrentJobs: 2),
                    runtimePool: ExecutionRuntimePool(),
                    providerRegistry: claudeService.executionProviderRegistry ?? claudeService.buildExecutionProviderRegistry(for: context),
                    runtimeCoordinator: claudeService.executionRuntimeCoordinator,
                    changeReviewProjectionStore: claudeService.changeReviewProjectionStore
                )
            }
        default:
            break
        }
    }
}

@MainActor
private final class DisabledSparkleDriver: SparkleUpdating {
    let canCheckForUpdates = false
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false

    func startUpdaterIfNeeded() {}

    func checkForUpdates() {}

    func resetUpdateCycleAfterShortDelay() {}
}

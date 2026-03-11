//
//  agentGuiApp.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import SwiftData

enum PersistenceSchema {
    static let currentVersion = 1
}

@main
struct agentGuiApp: App {
    static let persistenceSchemaVersion = PersistenceSchema.currentVersion

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
        ProcessInfo.processInfo.arguments.contains("-com.agentgui.test.mode")
    }

    init() {
        ConfigDirectoryManager.shared.setup()
    }

    private let launchOptions = TestLaunchOptions.current

    @State private var claudeService = ClaudeService()
    @State private var skillService = SkillService()
    @State private var workflowRuntime: WorkflowRuntime?
    @State private var memoryBackgroundScheduler: MemoryBackgroundScheduler?
    @State private var runtimeRecoveryService = RuntimeRecoveryService()
    @State private var reliabilityCenterViewModel = ReliabilityCenterViewModel()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            AppSettings.self,
            Session.self,
            Message.self,
            ToolCall.self,
            AgentRound.self,
            WritingProject.self,
            StoryCharacterProfile.self,
            StoryWorldRule.self,
            StoryLocationProfile.self,
            StoryStyleProfile.self,
            StoryChapterRecord.self,
            StorySceneRecord.self,
            StoryTimelineEvent.self,
            StoryForeshadowItem.self,
            StoryContinuityIssue.self,
            SessionTaskState.self,
            RecoverySnapshot.self,
            IntegrityIssue.self,
            // Workflow orchestration models (Phase 1)
            WorkflowInstance.self,
            WorkflowMessageRecord.self,
            WorkflowArtifactRecord.self,
            WorkflowActivationRecord.self,
        ])

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
                .environment(workflowRuntime ?? WorkflowRuntime(claudeService: claudeService))
                .environment(runtimeRecoveryService)
                .environment(reliabilityCenterViewModel)
                .onAppear {
                    let context = sharedModelContainer.mainContext
                    seedUITestDataIfNeeded(in: context)

                    // 从持久化设置加载 API Key
                    let settings = AppSettings.getOrCreate(in: context, persistenceCoordinator: .shared)
                    claudeService.applyConnectionSettings(settings)
                    claudeService.skillService = skillService
                    skillService.loadSkills()
                    let runtime = WorkflowRuntime(claudeService: claudeService)
                    workflowRuntime = runtime
                    claudeService.workflowRuntime = runtime
                    try? runtimeRecoveryService.refresh(from: context)
                    reliabilityCenterViewModel.refresh(using: context)

                    if !launchOptions.isUITestMode && settings.enableUnifiedMemoryRuntime && settings.enableBackgroundMemoryConsolidation {
                        let scheduler = MemoryBackgroundScheduler()
                        scheduler.start(intervalSeconds: settings.memoryBackgroundSchedulerIntervalSeconds)
                        memoryBackgroundScheduler = scheduler

                        if settings.enableMemoryTTLSweep {
                            Task {
                                let jobStore = MemoryBackgroundJobStore()
                                try? jobStore.enqueue(.ttlSweep(ttl: TimeInterval(settings.memoryTTLSweepIntervalSeconds)))
                            }
                        }
                    }
                }
        }
        .modelContainer(sharedModelContainer)
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

        if let workflowState = launchOptions.workflowState {
            ensureWorkflow(for: sessionId, status: workflowState, in: context)
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
    private func ensureWorkflow(for sessionId: String, status: WorkflowStatus, in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<WorkflowInstance>()))?.first(where: { $0.sessionId == sessionId })
        if let existing {
            existing.status = status
            try? PersistenceCoordinator.shared.save(
                context,
                domain: .workflow,
                userMessage: "UI 测试工作流状态未成功保存"
            )
            return
        }

        let workflow = WorkflowInstance.fixture(
            sessionId: sessionId,
            userTask: "Recover interrupted workflow",
            status: status
        )
        context.insert(workflow)
        try? PersistenceCoordinator.shared.save(
            context,
            domain: .workflow,
            userMessage: "UI 测试工作流初始化未成功保存"
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
}

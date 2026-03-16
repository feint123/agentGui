import Foundation
import SwiftData
import Testing
import SwiftAnthropic
@testable import agentGui

@MainActor
struct BackgroundActivityCoordinatorTests {
    @Test func coordinatorBootstrapsEnabledTasksOnAppLaunch() async throws {
        let harness = try BackgroundActivityCoordinatorHarness.make()

        try await harness.coordinator.bootstrap(modelContext: harness.context)

        #expect(harness.schedulerFactory.createdIdentifiers == ["com.agentgui.background.task.repo-daily-summary"])
    }

    @Test func coordinatorTriggerCompletesAndWritesRunRecord() async throws {
        let harness = try BackgroundActivityCoordinatorHarness.make()
        try await harness.coordinator.bootstrap(modelContext: harness.context)
        try await harness.schedulerFactory.fire(identifier: "com.agentgui.background.task.repo-daily-summary")

        let runs = try harness.context.fetch(FetchDescriptor<BackgroundAgentTaskRun>())
        #expect(runs.count == 1)
        #expect(runs.first?.status == .completed)
        #expect(harness.schedulerFactory.completedResults == [.finished])
    }

    @Test func coordinatorReturnsDeferredWhenSchedulerRequestsDefer() async throws {
        let harness = try BackgroundActivityCoordinatorHarness.make()
        try await harness.coordinator.bootstrap(modelContext: harness.context)
        harness.schedulerFactory.scheduler(identifier: "com.agentgui.background.task.repo-daily-summary")?.shouldDefer = true

        try await harness.schedulerFactory.fire(identifier: "com.agentgui.background.task.repo-daily-summary")

        let run = try #require(harness.context.fetch(FetchDescriptor<BackgroundAgentTaskRun>()).first)
        #expect(run.status == .deferred)
        #expect(run.deferReason == "systemRequestedDefer")
        #expect(harness.schedulerFactory.completedResults == [.deferred])
    }

    @Test func coordinatorPersistsFailedRunAndStillFinishesScheduler() async throws {
        let harness = try BackgroundActivityCoordinatorHarness.make(adapter: BackgroundActivityFailingAdapter())
        try await harness.coordinator.bootstrap(modelContext: harness.context)

        try await harness.schedulerFactory.fire(identifier: "com.agentgui.background.task.repo-daily-summary")

        let run = try #require(harness.context.fetch(FetchDescriptor<BackgroundAgentTaskRun>()).first)
        let task = try #require(harness.context.fetch(FetchDescriptor<BackgroundAgentTask>()).first)
        #expect(run.status == .failed)
        #expect(task.consecutiveFailureCount == 1)
        #expect(harness.schedulerFactory.completedResults == [.finished])
    }

    @Test func coordinatorRefreshesRegistrationAfterSchedulingNotification() async throws {
        let notificationCenter = NotificationCenter()
        let harness = try BackgroundActivityCoordinatorHarness.make(notificationCenter: notificationCenter)
        try await harness.coordinator.bootstrap(modelContext: harness.context)

        let secondTask = BackgroundAgentTask.fixture(
            taskKey: "ops-scan",
            title: "巡检",
            sessionId: "session-1",
            taskPrompt: "做一次巡检"
        )
        harness.context.insert(secondTask)
        try harness.context.save()

        notificationCenter.post(name: BackgroundTaskSchedulingNotifications.refreshRequested, object: nil)
        await Task.yield()

        #expect(harness.schedulerFactory.createdIdentifiers.contains("com.agentgui.background.task.ops-scan"))
    }

    @Test func recoveryServiceNormalizesRunningBackgroundRuns() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BackgroundAgentTaskRun.self, configurations: configuration)
        let context = ModelContext(container)
        let run = BackgroundAgentTaskRun(taskID: UUID(), schedulerIdentifier: "bg-1", status: .running, decision: .run)
        context.insert(run)
        try context.save()

        let service = RuntimeRecoveryService()
        try service.normalizeBackgroundTaskRuns(in: context)

        #expect(run.status == .interrupted)
    }
}

@MainActor
private struct BackgroundActivityCoordinatorHarness {
    let container: ModelContainer
    let context: ModelContext
    let coordinator: BackgroundActivityCoordinator
    let schedulerFactory: CoordinatorSchedulerFactory

    static func make(
        adapter: BackgroundAgentLoopAdapting? = nil,
        notificationCenter: NotificationCenter = .default
    ) throws -> BackgroundActivityCoordinatorHarness {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: AppSettings.self,
            Session.self,
            Message.self,
            BackgroundAgentTask.self,
            BackgroundAgentTaskRun.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let settings = AppSettings()
        settings.backgroundAgentEnabled = true
        let session = Session.fixture(sessionId: "session-1", title: "Background")
        let task = BackgroundAgentTask.fixture(taskKey: "repo-daily-summary", title: "日报", sessionId: session.sessionId, taskPrompt: "生成日报")
        context.insert(settings)
        context.insert(session)
        context.insert(task)
        try context.save()

        let schedulerFactory = CoordinatorSchedulerFactory()
        let coordinator = BackgroundActivityCoordinator(
            settingsProvider: { settings },
            registry: BackgroundTaskRegistry(
                policyEngine: BackgroundTaskPolicyEngine(),
                schedulerFactory: schedulerFactory.makeScheduler(identifier:)
            ),
            executionCoordinator: BackgroundTaskExecutionCoordinator(
                evaluator: BackgroundTaskEligibilityEvaluator(),
                observationService: BackgroundTaskObservationService(),
                promptComposer: BackgroundPromptComposer(),
                adapter: adapter ?? BackgroundActivityStubAdapter(),
                resultWriter: BackgroundSessionResultWriter()
            ),
            observationService: BackgroundTaskObservationService(),
            notificationCenter: notificationCenter
        )

        return BackgroundActivityCoordinatorHarness(
            container: container,
            context: context,
            coordinator: coordinator,
            schedulerFactory: schedulerFactory
        )
    }
}

@MainActor
private struct BackgroundActivityStubAdapter: BackgroundAgentLoopAdapting {
    func execute(
        task: BackgroundAgentTask,
        prompt: String,
        service: any AnthropicService,
        modelContext: ModelContext
    ) async throws -> BackgroundExecutionOutcome {
        BackgroundExecutionOutcome(textOutput: "后台执行完成", resultSummary: "success")
    }
}

@MainActor
private struct BackgroundActivityFailingAdapter: BackgroundAgentLoopAdapting {
    func execute(
        task: BackgroundAgentTask,
        prompt: String,
        service: any AnthropicService,
        modelContext: ModelContext
    ) async throws -> BackgroundExecutionOutcome {
        throw Failure.failed
    }

    private enum Failure: Error {
        case failed
    }
}

@MainActor
private final class CoordinatorSchedulerFactory {
    private(set) var createdIdentifiers: [String] = []
    private(set) var completedResults: [BackgroundSystemSchedulerResult] = []
    private var schedulers: [String: FireableBackgroundScheduler] = [:]

    func makeScheduler(identifier: String) -> any BackgroundSystemScheduler {
        createdIdentifiers.append(identifier)
        let scheduler = FireableBackgroundScheduler(identifier: identifier) { [weak self] result in
            self?.completedResults.append(result)
        }
        schedulers[identifier] = scheduler
        return scheduler
    }

    func scheduler(identifier: String) -> FireableBackgroundScheduler? {
        schedulers[identifier]
    }

    func fire(identifier: String) async throws {
        try await schedulers[identifier]?.fire()
    }
}

@MainActor
private final class FireableBackgroundScheduler: BackgroundSystemScheduler {
    let identifier: String
    var interval: TimeInterval = 0
    var tolerance: TimeInterval = 0
    var repeats: Bool = false
    var qualityOfService: BackgroundTaskQualityOfService = .utility
    var shouldDefer: Bool = false

    private var handler: BackgroundSystemSchedulerHandler?
    private let onComplete: (BackgroundSystemSchedulerResult) -> Void

    init(identifier: String, onComplete: @escaping (BackgroundSystemSchedulerResult) -> Void) {
        self.identifier = identifier
        self.onComplete = onComplete
    }

    func setHandler(_ handler: @escaping BackgroundSystemSchedulerHandler) {
        self.handler = handler
    }

    func invalidate() {}

    func fire() async throws {
        guard let handler else { return }
        await withCheckedContinuation { continuation in
            handler(self) { [onComplete] result in
                onComplete(result)
                continuation.resume()
            }
        }
    }
}
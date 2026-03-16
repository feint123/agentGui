import Foundation
import SwiftData
import Testing
import SwiftAnthropic
@testable import agentGui

@MainActor
struct BackgroundTaskExecutionCoordinatorTests {
    @Test func executionCoordinatorRunsTaskAndWritesSessionMessages() async throws {
        let harness = try BackgroundExecutionHarness.make()
        let task = harness.task
        let run = try harness.observation.recordTriggeredRun(
            for: task,
            schedulerIdentifier: BackgroundTaskRegistry.schedulerIdentifier(for: task),
            modelContext: harness.context
        )
        let coordinator = BackgroundTaskExecutionCoordinator(
            evaluator: harness.evaluator,
            observationService: harness.observation,
            promptComposer: harness.promptComposer,
            adapter: harness.adapter,
            resultWriter: harness.resultWriter
        )

        let schedulerResult = try await coordinator.execute(
            task: task,
            run: run,
            service: AnthropicServiceFactory.service(apiKey: "test-key", betaHeaders: nil),
            modelContext: harness.context
        )

        let messages = try harness.context.fetch(FetchDescriptor<Message>())
        #expect(messages.count == 2)
        #expect(run.status == .completed)
        #expect(task.lastCompletedAt != nil)
        #expect(schedulerResult == .finished)
    }

    @Test func executionCoordinatorBuildsDefaultEnvironmentFromExistingWorkspacePath() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let harness = try BackgroundExecutionHarness.make(workspacePath: workspaceURL.path)
        let task = harness.task
        let run = try harness.observation.recordTriggeredRun(
            for: task,
            schedulerIdentifier: BackgroundTaskRegistry.schedulerIdentifier(for: task),
            modelContext: harness.context
        )
        let coordinator = BackgroundTaskExecutionCoordinator(
            evaluator: harness.evaluator,
            observationService: harness.observation,
            promptComposer: harness.promptComposer,
            adapter: harness.adapter,
            resultWriter: harness.resultWriter
        )

        let schedulerResult = try await coordinator.execute(
            task: task,
            run: run,
            service: AnthropicServiceFactory.service(apiKey: "test-key", betaHeaders: nil),
            modelContext: harness.context
        )

        #expect(run.status == .completed)
        #expect(run.skipReason == nil)
        #expect(schedulerResult == .finished)
    }

    @Test func executionCoordinatorMarksFailuresAndAppliesCooldown() async throws {
        let sink = InMemoryBusinessLogSink()
        let harness = try BackgroundExecutionHarness.make(
            observation: BackgroundTaskObservationService(sink: sink),
            adapter: FailingBackgroundAgentLoopAdapter()
        )
        let task = harness.task
        var executionPolicy = task.executionPolicy
        executionPolicy.maxConsecutiveFailures = 1
        task.executionPolicy = executionPolicy
        var schedulePolicy = task.schedulePolicy
        schedulePolicy.baseIntervalSeconds = 3_600
        task.schedulePolicy = schedulePolicy
        let run = try harness.observation.recordTriggeredRun(
            for: task,
            schedulerIdentifier: BackgroundTaskRegistry.schedulerIdentifier(for: task),
            modelContext: harness.context
        )
        let coordinator = BackgroundTaskExecutionCoordinator(
            evaluator: harness.evaluator,
            observationService: harness.observation,
            promptComposer: harness.promptComposer,
            adapter: harness.adapter,
            resultWriter: harness.resultWriter
        )
        let now = Date(timeIntervalSince1970: 5_000)

        let schedulerResult = try await coordinator.execute(
            task: task,
            run: run,
            service: AnthropicServiceFactory.service(apiKey: "test-key", betaHeaders: nil),
            modelContext: harness.context,
            now: now
        )

        #expect(schedulerResult == .finished)
        #expect(run.status == .failed)
        #expect(run.resultSummary == "executionFailed: adapterFailed")
        #expect(run.finishedAt != nil)
        #expect(task.lastTriggeredAt == now)
        #expect(task.lastCompletedAt == nil)
        #expect(task.lastResultSummary == "executionFailed: adapterFailed")
        #expect(task.consecutiveFailureCount == 1)
        #expect(task.cooldownUntil == now.addingTimeInterval(3_600))
        #expect(sink.events.map(\.event).contains(.backgroundTaskFailed))
    }

    @Test func executionCoordinatorReturnsDeferredWhenSystemRequestsDefer() async throws {
        let sink = InMemoryBusinessLogSink()
        let harness = try BackgroundExecutionHarness.make(
            observation: BackgroundTaskObservationService(sink: sink)
        )
        let task = harness.task
        let run = try harness.observation.recordTriggeredRun(
            for: task,
            schedulerIdentifier: BackgroundTaskRegistry.schedulerIdentifier(for: task),
            modelContext: harness.context
        )
        let coordinator = BackgroundTaskExecutionCoordinator(
            evaluator: harness.evaluator,
            observationService: harness.observation,
            promptComposer: harness.promptComposer,
            adapter: harness.adapter,
            resultWriter: harness.resultWriter
        )

        let schedulerResult = try await coordinator.execute(
            task: task,
            run: run,
            service: AnthropicServiceFactory.service(apiKey: "test-key", betaHeaders: nil),
            modelContext: harness.context,
            environment: .fixture(shouldDefer: true)
        )

        #expect(schedulerResult == .deferred)
        #expect(run.status == .deferred)
        #expect(run.deferReason == "systemRequestedDefer")
        #expect(sink.events.map(\.event).contains(.backgroundTaskDeferred))
    }

    @Test func executionCoordinatorUsesLiveEnvironmentSnapshotForPowerRequirement() async throws {
        let sink = InMemoryBusinessLogSink()
        let harness = try BackgroundExecutionHarness.make(
            observation: BackgroundTaskObservationService(sink: sink),
            settingsMutator: { settings in
                settings.backgroundAgentRequiresExternalPower = true
            }
        )
        let task = harness.task
        let run = try harness.observation.recordTriggeredRun(
            for: task,
            schedulerIdentifier: BackgroundTaskRegistry.schedulerIdentifier(for: task),
            modelContext: harness.context
        )
        let coordinator = BackgroundTaskExecutionCoordinator(
            evaluator: harness.evaluator,
            observationService: harness.observation,
            promptComposer: harness.promptComposer,
            adapter: harness.adapter,
            resultWriter: harness.resultWriter,
            environmentSnapshotProvider: StubEnvironmentSnapshotProvider(
                snapshot: .init(networkAvailable: true, externalPowerConnected: false)
            )
        )

        let schedulerResult = try await coordinator.execute(
            task: task,
            run: run,
            service: AnthropicServiceFactory.service(apiKey: "test-key", betaHeaders: nil),
            modelContext: harness.context
        )

        #expect(schedulerResult == .deferred)
        #expect(run.status == .deferred)
        #expect(run.deferReason == "externalPowerRequired")
    }
}

@MainActor
private struct BackgroundExecutionHarness {
    let container: ModelContainer
    let context: ModelContext
    let task: BackgroundAgentTask
    let evaluator: BackgroundTaskEligibilityEvaluator
    let observation: BackgroundTaskObservationService
    let promptComposer: BackgroundPromptComposer
    let adapter: BackgroundAgentLoopAdapting
    let resultWriter: BackgroundSessionResultWriter

    static func make(
        workspacePath: String? = nil,
        observation: BackgroundTaskObservationService? = nil,
        adapter: BackgroundAgentLoopAdapting? = nil,
        settingsMutator: ((AppSettings) -> Void)? = nil
    ) throws -> BackgroundExecutionHarness {
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
        let session = Session.fixture(sessionId: "session-1", title: "Background")
        let task = BackgroundAgentTask.fixture(title: "日报", sessionId: session.sessionId, taskPrompt: "生成日报")
        task.workspacePath = workspacePath
        settingsMutator?(settings)
        context.insert(settings)
        context.insert(session)
        context.insert(task)
        try context.save()

        return BackgroundExecutionHarness(
            container: container,
            context: context,
            task: task,
            evaluator: BackgroundTaskEligibilityEvaluator(),
            observation: observation ?? BackgroundTaskObservationService(),
            promptComposer: BackgroundPromptComposer(),
            adapter: adapter ?? StubBackgroundAgentLoopAdapter(),
            resultWriter: BackgroundSessionResultWriter()
        )
    }
}

@MainActor
private struct StubEnvironmentSnapshotProvider: BackgroundExecutionEnvironmentSnapshotProviding {
    let snapshot: BackgroundExecutionEnvironmentSnapshot

    func currentSnapshot() -> BackgroundExecutionEnvironmentSnapshot {
        snapshot
    }
}

@MainActor
private struct StubBackgroundAgentLoopAdapter: BackgroundAgentLoopAdapting {
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
private struct FailingBackgroundAgentLoopAdapter: BackgroundAgentLoopAdapting {
    func execute(
        task: BackgroundAgentTask,
        prompt: String,
        service: any AnthropicService,
        modelContext: ModelContext
    ) async throws -> BackgroundExecutionOutcome {
        throw Failure.adapterFailed
    }

    private enum Failure: Error {
        case adapterFailed
    }
}
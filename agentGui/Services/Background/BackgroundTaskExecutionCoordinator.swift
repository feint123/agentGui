import Foundation
import SwiftAnthropic
import SwiftData

@MainActor
final class BackgroundTaskExecutionCoordinator {
    private let evaluator: BackgroundTaskEligibilityEvaluator
    private let observationService: BackgroundTaskObservationService
    private let promptComposer: BackgroundPromptComposer
    private let adapter: any BackgroundAgentLoopAdapting
    private let resultWriter: BackgroundSessionResultWriter
    private let persistenceCoordinator: PersistenceCoordinator
    private let fileManager: FileManager
    private let environmentSnapshotProvider: any BackgroundExecutionEnvironmentSnapshotProviding

    @MainActor
    init(
        evaluator: BackgroundTaskEligibilityEvaluator,
        observationService: BackgroundTaskObservationService,
        promptComposer: BackgroundPromptComposer,
        adapter: any BackgroundAgentLoopAdapting,
        resultWriter: BackgroundSessionResultWriter,
        persistenceCoordinator: PersistenceCoordinator = .shared,
        fileManager: FileManager = .default,
        environmentSnapshotProvider: any BackgroundExecutionEnvironmentSnapshotProviding = LiveBackgroundExecutionEnvironmentSnapshotProvider()
    ) {
        self.evaluator = evaluator
        self.observationService = observationService
        self.promptComposer = promptComposer
        self.adapter = adapter
        self.resultWriter = resultWriter
        self.persistenceCoordinator = persistenceCoordinator
        self.fileManager = fileManager
        self.environmentSnapshotProvider = environmentSnapshotProvider
    }

    func execute(
        task: BackgroundAgentTask,
        run: BackgroundAgentTaskRun,
        service: any AnthropicService,
        modelContext: ModelContext,
        environment: BackgroundExecutionEnvironment? = nil,
        now: Date = Date()
    ) async throws -> BackgroundSystemSchedulerResult {
        let resolvedEnvironment = try resolvedEnvironment(
            for: task,
            modelContext: modelContext,
            override: environment
        )
        let eligibility = evaluator.evaluate(task: task, now: now, environment: resolvedEnvironment)
        task.lastTriggeredAt = now

        switch eligibility.decision {
        case .skip:
            run.status = .skipped
            run.decision = .skip
            run.skipReason = eligibility.reason
            run.finishedAt = now
            task.updatedAt = now
            observationService.recordSkipped(task: task, run: run, reason: eligibility.reason)
            try persist(modelContext)
            return .finished
        case .`defer`:
            run.status = .deferred
            run.decision = .`defer`
            run.deferReason = eligibility.reason
            run.finishedAt = now
            task.updatedAt = now
            observationService.recordDeferred(task: task, run: run, reason: eligibility.reason)
            try persist(modelContext)
            return .deferred
        case .run:
            run.status = .running
            run.decision = .run
            run.actualStartAt = now
            task.updatedAt = now
            observationService.recordStarted(task: task, run: run)
            try persist(modelContext)
        case .pending:
            break
        }

        do {
            let prompt = promptComposer.compose(task: task, now: now)
            let outcome = try await adapter.execute(
                task: task,
                prompt: prompt,
                service: service,
                modelContext: modelContext
            )
            let message = try resultWriter.writeSuccessResult(
                task: task,
                output: outcome.textOutput,
                summary: outcome.resultSummary,
                modelContext: modelContext
            )

            run.status = .completed
            run.resultSummary = outcome.resultSummary
            run.finishedAt = Date()
            run.messageID = message?.id.uuidString
            task.lastCompletedAt = run.finishedAt
            task.lastResultSummary = outcome.resultSummary
            task.consecutiveFailureCount = 0
            task.cooldownUntil = nil
            task.updatedAt = run.finishedAt ?? Date()
            observationService.recordCompleted(task: task, run: run, summary: outcome.resultSummary)
            try persist(modelContext)
            return .finished
        } catch {
            let failureSummary = makeFailureSummary(error)
            let finishedAt = Date()
            run.status = .failed
            run.resultSummary = failureSummary
            run.finishedAt = finishedAt
            task.lastResultSummary = failureSummary
            task.consecutiveFailureCount += 1
            task.updatedAt = finishedAt
            if task.consecutiveFailureCount >= max(1, task.executionPolicy.maxConsecutiveFailures) {
                task.cooldownUntil = now.addingTimeInterval(task.schedulePolicy.sanitizedForScheduling.baseIntervalSeconds)
                observationService.recordPolicyAdjusted(task: task, run: run, reason: "failureCooldownApplied")
            }
            let failureMessage = try? resultWriter.writeFailureResult(
                task: task,
                summary: failureSummary,
                modelContext: modelContext
            )
            if let message = failureMessage ?? nil {
                run.messageID = message.id.uuidString
            }
            observationService.recordFailed(task: task, run: run, summary: failureSummary)
            try persist(modelContext)
            return .finished
        }
    }

    private func persist(_ modelContext: ModelContext) throws {
        try persistenceCoordinator.save(
            modelContext,
            domain: .sessionTaskState,
            userMessage: "后台任务执行状态未成功保存"
        )
    }

    private func resolvedEnvironment(
        for task: BackgroundAgentTask,
        modelContext: ModelContext,
        override: BackgroundExecutionEnvironment?
    ) throws -> BackgroundExecutionEnvironment {
        let baseEnvironment = try defaultEnvironment(for: task, modelContext: modelContext)
        guard let override else { return baseEnvironment }

        return BackgroundExecutionEnvironment(
            shouldDefer: baseEnvironment.shouldDefer || override.shouldDefer,
            runningTaskKeys: baseEnvironment.runningTaskKeys.union(override.runningTaskKeys),
            existingWorkspacePaths: baseEnvironment.existingWorkspacePaths.union(override.existingWorkspacePaths),
            runningTaskCount: max(baseEnvironment.runningTaskCount, override.runningTaskCount),
            maximumConcurrentRuns: override.maximumConcurrentRuns ?? baseEnvironment.maximumConcurrentRuns,
            requiresExternalPower: override.requiresExternalPower || baseEnvironment.requiresExternalPower,
            externalPowerConnected: override.externalPowerConnected ?? baseEnvironment.externalPowerConnected,
            networkAvailable: override.networkAvailable ?? baseEnvironment.networkAvailable
        )
    }

    private func defaultEnvironment(
        for task: BackgroundAgentTask,
        modelContext: ModelContext
    ) throws -> BackgroundExecutionEnvironment {
        let settings = AppSettings.getOrCreate(in: modelContext)
        let runningTaskKeys = try runningTaskKeys(modelContext: modelContext)
        let snapshot = environmentSnapshotProvider.currentSnapshot()
        return BackgroundExecutionEnvironment(
            runningTaskKeys: runningTaskKeys,
            existingWorkspacePaths: try existingWorkspacePaths(for: task, modelContext: modelContext),
            runningTaskCount: runningTaskKeys.count,
            maximumConcurrentRuns: settings.backgroundAgentMaximumConcurrentRuns,
            requiresExternalPower: settings.backgroundAgentRequiresExternalPower,
            externalPowerConnected: snapshot.externalPowerConnected,
            networkAvailable: snapshot.networkAvailable
        )
    }

    private func runningTaskKeys(modelContext: ModelContext) throws -> Set<String> {
        let tasks = try modelContext.fetch(FetchDescriptor<BackgroundAgentTask>())
        let taskKeysByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.taskKey) })
        let runs = try modelContext.fetch(FetchDescriptor<BackgroundAgentTaskRun>())

        return Set(
            runs
                .filter { $0.status == .running }
                .compactMap { taskKeysByID[$0.taskID] }
        )
    }

    private func existingWorkspacePaths(
        for task: BackgroundAgentTask,
        modelContext: ModelContext
    ) throws -> Set<String> {
        let tasks = try modelContext.fetch(FetchDescriptor<BackgroundAgentTask>())
        let workspacePaths = tasks.compactMap(\.workspacePath) + [task.workspacePath].compactMap { $0 }

        return Set(workspacePaths.compactMap(existingWorkspacePath(for:)))
    }

    private func existingWorkspacePath(for workspacePath: String) -> String? {
        let normalizedPath = (workspacePath as NSString).standardizingPath
        guard !normalizedPath.isEmpty,
              fileManager.fileExists(atPath: normalizedPath) else {
            return nil
        }

        return normalizedPath
    }

    private func makeFailureSummary(_ error: Error) -> String {
        "executionFailed: \(String(describing: error))"
    }
}
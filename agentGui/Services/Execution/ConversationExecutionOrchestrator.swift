import Foundation
import SwiftData

@MainActor
final class ConversationExecutionOrchestrator {
    private let modelContext: ModelContext
    private let persistenceStore: ExecutionPersistenceStore
    let projectionStore: ExecutionProjectionStore
    private let scheduler: ExecutionScheduler
    private let runtimePool: ExecutionRuntimePool
    private let providerRegistry: ConversationExecutionProviderRegistry
    private let runtimeCoordinator: ConversationExecutionRuntimeCoordinator
    private var mailboxes: [String: SessionExecutionMailbox] = [:]
    private var activeAttemptIDsByJobID: [UUID: UUID] = [:]
    private var hasRestoredPersistedJobs = false

    init(
        modelContext: ModelContext,
        persistenceStore: ExecutionPersistenceStore,
        projectionStore: ExecutionProjectionStore,
        scheduler: ExecutionScheduler,
        runtimePool: ExecutionRuntimePool,
        providerRegistry: ConversationExecutionProviderRegistry,
        runtimeCoordinator: ConversationExecutionRuntimeCoordinator
    ) {
        self.modelContext = modelContext
        self.persistenceStore = persistenceStore
        self.projectionStore = projectionStore
        self.scheduler = scheduler
        self.runtimePool = runtimePool
        self.providerRegistry = providerRegistry
        self.runtimeCoordinator = runtimeCoordinator
    }

    func enqueue(_ command: EnqueueExecutionCommand) async throws -> ExecutionJobHandle {
        await restorePendingJobs()

        let result = try await persistenceStore.enqueue(
            sessionID: command.sessionID,
            providerID: command.providerID,
            payload: command.payload,
            sourceUserMessageID: command.sourceUserMessageID
        )

        let mailbox = mailbox(for: command.sessionID)
        await mailbox.enqueue(jobID: result.job.id)

        let currentProjection = projectionStore.projection(for: command.sessionID)
        let queuedJobIDs = currentProjection.queuedJobIDs + [result.job.id]
        projectionStore.setProjection(
            SessionExecutionProjection(
                sessionID: command.sessionID,
                runningJobID: currentProjection.runningJobID,
                queuedJobIDs: queuedJobIDs,
                queuedCount: queuedJobIDs.count,
                isRunning: currentProjection.isRunning,
                canEditComposer: true,
                canSubmitNewJob: true,
                activeProviderID: command.providerID
            )
        )

        await dispatchReadyJobs()

        return ExecutionJobHandle(jobID: result.job.id, sessionID: command.sessionID)
    }

    func cancelRunning(in sessionID: String) async {
        let currentProjection = projectionStore.projection(for: sessionID)
        guard let runningJobID = currentProjection.runningJobID,
              let job = try? persistenceStore.job(id: runningJobID) else {
            return
        }

        let driver = runtimePool.driver(for: job.providerID, registry: providerRegistry)
        await driver.cancel(jobID: runningJobID, sessionID: sessionID)
    }

    func restorePendingJobs() async {
        guard !hasRestoredPersistedJobs else {
            return
        }

        hasRestoredPersistedJobs = true
        guard let jobs = try? persistenceStore.recoverableJobs(), !jobs.isEmpty else {
            return
        }

        var queuedJobIDsBySessionID: [String: [UUID]] = [:]
        var activeProviderIDsBySessionID: [String: ConversationExecutionProviderID] = [:]

        for job in jobs {
            await mailbox(for: job.sessionID).enqueue(jobID: job.id)
            queuedJobIDsBySessionID[job.sessionID, default: []].append(job.id)
            activeProviderIDsBySessionID[job.sessionID] = activeProviderIDsBySessionID[job.sessionID] ?? job.providerID
        }

        for (sessionID, queuedJobIDs) in queuedJobIDsBySessionID {
            projectionStore.setProjection(
                SessionExecutionProjection(
                    sessionID: sessionID,
                    runningJobID: nil,
                    queuedJobIDs: queuedJobIDs,
                    queuedCount: queuedJobIDs.count,
                    isRunning: false,
                    canEditComposer: true,
                    canSubmitNewJob: true,
                    activeProviderID: activeProviderIDsBySessionID[sessionID]
                )
            )
        }

        await dispatchReadyJobs()
    }

    private func mailbox(for sessionID: String) -> SessionExecutionMailbox {
        if let mailbox = mailboxes[sessionID] {
            return mailbox
        }

        let mailbox = SessionExecutionMailbox(sessionID: sessionID)
        mailboxes[sessionID] = mailbox
        return mailbox
    }

    private func dispatchReadyJobs() async {
        var candidates: [ExecutionSchedulingCandidate] = []
        for (sessionID, mailbox) in mailboxes {
            if let jobID = await mailbox.peekNextJobID(),
               let job = try? persistenceStore.job(id: jobID) {
                candidates.append(
                    ExecutionSchedulingCandidate(
                        sessionID: sessionID,
                        jobID: jobID,
                        runtimeScope: providerRegistry.provider(for: job.providerID).runtimeScope
                    )
                )
            }
        }

        let admitted = await scheduler.admitReadyJobs(candidates)
        for candidate in admitted {
            await dispatch(candidate)
        }
    }

    private func dispatch(_ candidate: ExecutionSchedulingCandidate) async {
        let mailbox = mailbox(for: candidate.sessionID)
        guard await mailbox.markRunning(jobID: candidate.jobID),
              let job = try? persistenceStore.job(id: candidate.jobID),
              let session = try? persistenceStore.session(id: candidate.sessionID) else {
            await scheduler.markFinished(jobID: candidate.jobID, sessionID: candidate.sessionID)
            return
        }

        let provider = providerRegistry.provider(for: job.providerID)
        await runtimeCoordinator.prepareForActivation(
            session: session,
            activeProvider: provider,
            registry: providerRegistry,
            modelContext: modelContext
        )

        guard let attempt = try? persistenceStore.start(jobID: candidate.jobID, runtimeScope: provider.runtimeScope) else {
            _ = await mailbox.finishRunning(jobID: candidate.jobID)
            await scheduler.markFinished(jobID: candidate.jobID, sessionID: candidate.sessionID)
            return
        }

        activeAttemptIDsByJobID[candidate.jobID] = attempt.id
        updateProjectionForRunningJob(jobID: candidate.jobID, sessionID: candidate.sessionID, providerID: job.providerID)

        let driver = runtimePool.driver(for: job.providerID, registry: providerRegistry)
        let stream = driver.execute(
            job,
            context: ExecutionDriverContext(session: session, modelContext: modelContext)
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in stream {
                    switch event {
                    case .started:
                        break
                    case .finished(_, let outcome):
                        await self.finish(job: job, outcome: outcome, errorMessage: nil)
                    }
                }
            } catch is CancellationError {
                await self.finish(job: job, outcome: .cancelled, errorMessage: nil)
            } catch {
                await self.finish(job: job, outcome: .failed, errorMessage: error.localizedDescription)
            }
        }
    }

    private func finish(
        job: ExecutionJob,
        outcome: ExecutionJobState,
        errorMessage: String?
    ) async {
        guard let attemptID = activeAttemptIDsByJobID.removeValue(forKey: job.id) else {
            return
        }

        try? persistenceStore.finish(
            jobID: job.id,
            attemptID: attemptID,
            outcome: outcome,
            errorMessage: errorMessage
        )
        _ = await mailbox(for: job.sessionID).finishRunning(jobID: job.id)
        await scheduler.markFinished(jobID: job.id, sessionID: job.sessionID)

        let currentProjection = projectionStore.projection(for: job.sessionID)
        let activeProviderID: ConversationExecutionProviderID? = currentProjection.queuedJobIDs.isEmpty ? nil : currentProjection.activeProviderID
        projectionStore.setProjection(
            SessionExecutionProjection(
                sessionID: job.sessionID,
                runningJobID: nil,
                queuedJobIDs: currentProjection.queuedJobIDs,
                queuedCount: currentProjection.queuedJobIDs.count,
                isRunning: false,
                canEditComposer: true,
                canSubmitNewJob: true,
                activeProviderID: activeProviderID
            )
        )

        await dispatchReadyJobs()
    }

    private func updateProjectionForRunningJob(
        jobID: UUID,
        sessionID: String,
        providerID: ConversationExecutionProviderID
    ) {
        let currentProjection = projectionStore.projection(for: sessionID)
        let queuedJobIDs = currentProjection.queuedJobIDs.filter { $0 != jobID }
        projectionStore.setProjection(
            SessionExecutionProjection(
                sessionID: sessionID,
                runningJobID: jobID,
                queuedJobIDs: queuedJobIDs,
                queuedCount: queuedJobIDs.count,
                isRunning: true,
                canEditComposer: true,
                canSubmitNewJob: true,
                activeProviderID: providerID
            )
        )
    }
}
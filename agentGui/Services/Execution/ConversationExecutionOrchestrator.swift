import Foundation
import SwiftData

@MainActor
final class ConversationExecutionOrchestrator {
    private struct PreparedDispatchContext {
        let driverContext: ExecutionDriverContext
        let reviewContext: WorkspaceReviewContext?
    }

    private struct WorkspaceReviewContext {
        let baseSnapshot: WorkspaceTextSnapshot
    }

    private let modelContext: ModelContext
    private let persistenceStore: ExecutionPersistenceStore
    let projectionStore: ExecutionProjectionStore
    private let projectionWriter: any SessionExecutionProjectionWriting
    private let scheduler: ExecutionScheduler
    private let runtimePool: ExecutionRuntimePool
    private let providerRegistry: ConversationExecutionProviderRegistry
    private let runtimeCoordinator: ConversationExecutionRuntimeCoordinator
    private let changeReviewProjectionStore: ChangeReviewProjectionStore?
    private let workspaceChangeCaptureExecutor: DetachedWorkspaceChangeCaptureExecutor
    private var mailboxes: [String: SessionExecutionMailbox] = [:]
    private var activeAttemptIDsByJobID: [UUID: UUID] = [:]
    private var activePreparationTasksByJobID: [UUID: Task<PreparedDispatchContext, Error>] = [:]
    private var pendingCancellationJobIDs = Set<UUID>()
    private var hasRestoredPersistedJobs = false

    init(
        modelContext: ModelContext,
        persistenceStore: ExecutionPersistenceStore,
        projectionStore: ExecutionProjectionStore,
        projectionWriter: any SessionExecutionProjectionWriting,
        scheduler: ExecutionScheduler,
        runtimePool: ExecutionRuntimePool,
        providerRegistry: ConversationExecutionProviderRegistry,
        runtimeCoordinator: ConversationExecutionRuntimeCoordinator,
        changeReviewProjectionStore: ChangeReviewProjectionStore? = nil,
        workspaceChangeCaptureService: WorkspaceChangeCaptureService = WorkspaceChangeCaptureService(),
        workspaceChangeCaptureExecutor: DetachedWorkspaceChangeCaptureExecutor? = nil
    ) {
        self.modelContext = modelContext
        self.persistenceStore = persistenceStore
        self.projectionStore = projectionStore
        self.projectionWriter = projectionWriter
        self.scheduler = scheduler
        self.runtimePool = runtimePool
        self.providerRegistry = providerRegistry
        self.runtimeCoordinator = runtimeCoordinator
        self.changeReviewProjectionStore = changeReviewProjectionStore
        self.workspaceChangeCaptureExecutor = workspaceChangeCaptureExecutor
            ?? DetachedWorkspaceChangeCaptureExecutor(service: workspaceChangeCaptureService)
    }

    func enqueue(_ command: EnqueueExecutionCommand) async throws -> ExecutionJobHandle {
        await restorePendingJobs()

        let result = try await persistenceStore.enqueue(
            sessionID: command.sessionID,
            providerReference: command.providerReference,
            payload: command.payload,
            sourceUserMessageID: command.sourceUserMessageID
        )

        let mailbox = mailbox(for: command.sessionID)
        await mailbox.enqueue(jobID: result.job.id)

        projectionWriter.apply(
            .enqueued(
                sessionID: command.sessionID,
                jobID: result.job.id,
                providerReference: command.providerReference
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

        pendingCancellationJobIDs.insert(runningJobID)
        activePreparationTasksByJobID[runningJobID]?.cancel()
        let driver = runtimePool.driver(for: job.providerReference, registry: providerRegistry)
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
        var activeProviderReferencesBySessionID: [String: ExecutionProviderReference] = [:]

        for job in jobs {
            await mailbox(for: job.sessionID).enqueue(jobID: job.id)
            queuedJobIDsBySessionID[job.sessionID, default: []].append(job.id)
            activeProviderReferencesBySessionID[job.sessionID] = activeProviderReferencesBySessionID[job.sessionID] ?? job.providerReference
        }

        for (sessionID, queuedJobIDs) in queuedJobIDsBySessionID {
            projectionWriter.apply(
                .recovered(
                    sessionID: sessionID,
                    queuedJobIDs: queuedJobIDs,
                    runningJobID: nil,
                    providerReference: activeProviderReferencesBySessionID[sessionID]
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
        var prunedInvalidHeadJob = false
        for (sessionID, mailbox) in mailboxes {
            if let jobID = await mailbox.peekNextJobID() {
                if let job = try? persistenceStore.job(id: jobID) {
                    candidates.append(
                        ExecutionSchedulingCandidate(
                            sessionID: sessionID,
                            jobID: jobID,
                            providerReference: job.providerReference,
                            capacityPolicy: providerRegistry.capacityPolicy(for: job.providerReference)
                        )
                    )
                } else if await pruneInvalidQueuedJob(sessionID: sessionID, jobID: jobID, mailbox: mailbox) {
                    prunedInvalidHeadJob = true
                }
            }
        }

        if prunedInvalidHeadJob {
            await dispatchReadyJobs()
            return
        }

        let admitted = await scheduler.admitReadyJobs(candidates)
        let dispatchTasks = admitted.map { candidate in
            Task { @MainActor [weak self] in
                await self?.dispatch(candidate)
            }
        }

        for task in dispatchTasks {
            await task.value
        }
    }

    private func dispatch(_ candidate: ExecutionSchedulingCandidate) async {
        let mailbox = mailbox(for: candidate.sessionID)
        guard await mailbox.markRunning(jobID: candidate.jobID) else {
            await scheduler.markFinished(jobID: candidate.jobID, sessionID: candidate.sessionID)
            return
        }

        guard let job = try? persistenceStore.job(id: candidate.jobID),
              let session = try? persistenceStore.session(id: candidate.sessionID) else {
            _ = await mailbox.finishRunning(jobID: candidate.jobID)
            await scheduler.markFinished(jobID: candidate.jobID, sessionID: candidate.sessionID)
            _ = await pruneInvalidQueuedJob(sessionID: candidate.sessionID, jobID: candidate.jobID, mailbox: mailbox)
            await dispatchReadyJobs()
            return
        }

        let provider = providerRegistry.provider(for: job.providerReference)
        guard let attempt = try? persistenceStore.start(jobID: candidate.jobID, runtimeScope: provider.runtimeScope) else {
            _ = await mailbox.finishRunning(jobID: candidate.jobID)
            await scheduler.markFinished(jobID: candidate.jobID, sessionID: candidate.sessionID)
            return
        }

        activeAttemptIDsByJobID[candidate.jobID] = attempt.id
        updateProjectionForRunningJob(jobID: candidate.jobID, sessionID: candidate.sessionID, providerReference: job.providerReference)

        await runtimeCoordinator.prepareForActivation(
            session: session,
            activeProvider: provider,
            registry: providerRegistry,
            modelContext: modelContext,
            trigger: .executionDispatch
        )

        if pendingCancellationJobIDs.remove(job.id) != nil {
            await finish(job: job, outcome: .cancelled, errorMessage: nil)
            return
        }

        let driver = runtimePool.driver(for: job.providerReference, registry: providerRegistry)
        let preparationTask = Task {
            try await prepareDispatchContext(
                for: job,
                session: session,
                runtimeScope: provider.runtimeScope
            )
        }
        activePreparationTasksByJobID[job.id] = preparationTask
        let preparedContext: PreparedDispatchContext
        do {
            preparedContext = try await preparationTask.value
            activePreparationTasksByJobID.removeValue(forKey: job.id)
        } catch is CancellationError {
            activePreparationTasksByJobID.removeValue(forKey: job.id)
            await finish(job: job, outcome: .cancelled, errorMessage: nil)
            return
        } catch {
            activePreparationTasksByJobID.removeValue(forKey: job.id)
            await finish(job: job, outcome: .failed, errorMessage: error.localizedDescription)
            return
        }

        if pendingCancellationJobIDs.remove(job.id) != nil {
            await finish(job: job, outcome: .cancelled, errorMessage: nil)
            return
        }

        let stream = driver.execute(
            job,
            context: preparedContext.driverContext
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in stream {
                    switch event {
                    case .started:
                        break
                    case .finished(_, let outcome):
                        await self.captureReviewArtifactsIfNeeded(
                            for: job,
                            session: session,
                            reviewContext: preparedContext.reviewContext
                        )
                        await self.finish(job: job, outcome: outcome, errorMessage: nil)
                    }
                }
            } catch is CancellationError {
                await self.captureReviewArtifactsIfNeeded(
                    for: job,
                    session: session,
                    reviewContext: preparedContext.reviewContext
                )
                await self.finish(job: job, outcome: .cancelled, errorMessage: nil)
            } catch {
                await self.captureReviewArtifactsIfNeeded(
                    for: job,
                    session: session,
                    reviewContext: preparedContext.reviewContext
                )
                await self.finish(job: job, outcome: .failed, errorMessage: error.localizedDescription)
            }
        }
    }

    private func prepareDispatchContext(
        for job: ExecutionJob,
        session: Session,
        runtimeScope: ConversationExecutionRuntimeScope?
    ) async throws -> PreparedDispatchContext {
        guard runtimeScope == .externalACP,
              let sourceRoot = resolvedWorkspaceRoot(for: session) else {
            return PreparedDispatchContext(
                driverContext: ExecutionDriverContext(session: session, modelContext: modelContext),
                reviewContext: nil
            )
        }

        let baseSnapshot = try await workspaceChangeCaptureExecutor.captureSnapshot(root: sourceRoot)
        return PreparedDispatchContext(
            driverContext: ExecutionDriverContext(session: session, modelContext: modelContext),
            reviewContext: WorkspaceReviewContext(
                baseSnapshot: WorkspaceTextSnapshot(
                    root: baseSnapshot.root,
                    filesByRelativePath: baseSnapshot.filesByRelativePath
                )
            )
        )
    }

    private func captureReviewArtifactsIfNeeded(
        for job: ExecutionJob,
        session: Session,
        reviewContext: WorkspaceReviewContext?
    ) async {
        guard let reviewContext else {
            return
        }

        guard let proposal = try? await materializeChangeProposal(
            for: job,
            session: session,
            reviewContext: reviewContext
        ) else {
            return
        }

        if let changeReviewProjectionStore,
           let snapshot = try? await ChangeProposalStore(modelContext: modelContext).reviewSnapshot(for: proposal.id) {
            changeReviewProjectionStore.set(snapshot)
        }
    }

    private func materializeChangeProposal(
        for job: ExecutionJob,
        session: Session,
        reviewContext: WorkspaceReviewContext
    ) async throws -> ChangeProposal? {
        let artifacts = try await workspaceChangeCaptureExecutor.collectArtifacts(from: reviewContext.baseSnapshot)
        guard !artifacts.isEmpty else {
            return nil
        }

        let proposalStore = ChangeProposalStore(modelContext: modelContext)
        let latestAgentMessageID = session.messages
            .filter { $0.direction == .agent }
            .sorted { $0.sequence < $1.sequence }
            .last?
            .id
        let proposal = try await proposalStore.createProposal(
            sessionID: session.sessionId,
            jobID: job.id,
            messageID: latestAgentMessageID,
            providerID: job.providerID,
            baseWorkspaceRoot: reviewContext.baseSnapshot.root.path
        )

        for artifact in artifacts {
            try await proposalStore.upsertFileChange(
                proposalID: proposal.id,
                relativePath: artifact.relativePath,
                absolutePath: artifact.absolutePath,
                changeKind: artifact.changeKind,
                unifiedDiff: artifact.unifiedDiff,
                baseContentHash: artifact.baseContentHash,
                stagedContentHash: artifact.stagedContentHash,
                baseContentSnapshot: artifact.baseContentSnapshot,
                stagedContentSnapshot: artifact.stagedContentSnapshot,
                lineAdditions: artifact.lineAdditions,
                lineDeletions: artifact.lineDeletions
            )
        }

        try await proposalStore.updateProposal(
            proposalID: proposal.id,
            state: .readyForReview,
            summary: "待审查变更：\(artifacts.count) 个文件"
        )
        return proposal
    }

    private func resolvedWorkspaceRoot(for session: Session) -> URL? {
        let settings = AppSettings.getOrCreate(in: modelContext)
        let preferredPath = session.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? settings.workingDirectory
            : session.workingDirectory
        let trimmed = preferredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: trimmed).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private func finish(
        job: ExecutionJob,
        outcome: ExecutionJobState,
        errorMessage: String?
    ) async {
        activePreparationTasksByJobID[job.id]?.cancel()
        activePreparationTasksByJobID.removeValue(forKey: job.id)
        pendingCancellationJobIDs.remove(job.id)
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

        projectionWriter.apply(
            .finished(
                sessionID: job.sessionID,
                jobID: job.id,
                outcome: outcome
            )
        )

        await runtimeCoordinator.reconcileRuntimeRetention(
            registry: providerRegistry,
            modelContext: modelContext
        )

        await dispatchReadyJobs()
    }

    private func updateProjectionForRunningJob(
        jobID: UUID,
        sessionID: String,
        providerReference: ExecutionProviderReference
    ) {
        projectionWriter.apply(
            .started(
                sessionID: sessionID,
                jobID: jobID,
                providerReference: providerReference
            )
        )
    }

    private func currentProjection(for sessionID: String) -> SessionExecutionProjection {
        projectionStore.projection(for: sessionID)
    }

    private func pruneInvalidQueuedJob(
        sessionID: String,
        jobID: UUID,
        mailbox: SessionExecutionMailbox
    ) async -> Bool {
        guard await mailbox.discardQueuedJob(jobID: jobID) else {
            let currentProjection = currentProjection(for: sessionID)
            let queuedJobIDs = currentProjection.queuedJobIDs.filter { $0 != jobID }
            guard queuedJobIDs.count != currentProjection.queuedJobIDs.count else {
                return false
            }

            updateProjectionAfterPruningQueuedJob(sessionID: sessionID, jobID: jobID)
            return true
        }

        updateProjectionAfterPruningQueuedJob(sessionID: sessionID, jobID: jobID)
        return true
    }

    private func updateProjectionAfterPruningQueuedJob(
        sessionID: String,
        jobID: UUID
    ) {
        projectionWriter.apply(
            .pruned(
                sessionID: sessionID,
                jobID: jobID
            )
        )
    }
}
import Foundation

@MainActor
final class MemoryBackgroundScheduler {
    private let baseDirectory: URL
    private let jobStore: MemoryBackgroundJobStore
    private let unifiedStore: UnifiedMemoryFileStoreAdapter
    private let governanceService: MemoryGovernanceService
    private let backgroundWriteQueue: MemoryBackgroundWriteQueue
    private let confirmationStore: MemoryConfirmationStore
    private let retentionService: MemoryRetentionService
    private let consolidationEngine: MemoryConsolidationEngine
    private let counterexampleDistiller: CounterexampleDistillationService
    private let tacticKernelDistiller: TacticKernelDistillationService
    private let invalidationService: MemoryInvalidationService
    private let businessLogSink: BusinessLogSink?
    private var loopTask: Task<Void, Never>?

    init(
        baseDirectory: URL = ConfigDirectoryManager.shared.agentGuiDir.appending(path: "unified-memory", directoryHint: .isDirectory),
        governanceService: MemoryGovernanceService = MemoryGovernanceService(),
        retentionService: MemoryRetentionService = MemoryRetentionService(),
        consolidationEngine: MemoryConsolidationEngine = MemoryConsolidationEngine(),
        counterexampleDistiller: CounterexampleDistillationService = CounterexampleDistillationService(),
        tacticKernelDistiller: TacticKernelDistillationService = TacticKernelDistillationService(),
        invalidationService: MemoryInvalidationService = MemoryInvalidationService(),
        businessLogSink: BusinessLogSink? = nil
    ) {
        self.baseDirectory = baseDirectory
        self.jobStore = MemoryBackgroundJobStore(baseDirectory: baseDirectory)
        self.unifiedStore = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        self.governanceService = governanceService
        self.backgroundWriteQueue = MemoryBackgroundWriteQueue(storeBaseDirectory: baseDirectory)
        self.confirmationStore = MemoryConfirmationStore(baseDirectory: baseDirectory)
        self.retentionService = retentionService
        self.consolidationEngine = consolidationEngine
        self.counterexampleDistiller = counterexampleDistiller
        self.tacticKernelDistiller = tacticKernelDistiller
        self.invalidationService = invalidationService
        self.businessLogSink = businessLogSink
    }

    func start(intervalSeconds: Int) {
        stop()
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.runOnce()
                try? await Task.sleep(nanoseconds: UInt64(max(intervalSeconds, 1)) * 1_000_000_000)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func runOnce() async {
        while true {
            let nextJob: MemoryBackgroundJob?
            do {
                nextJob = try jobStore.nextQueuedJob()
            } catch {
                return
            }

            guard let job = nextJob else {
                return
            }

            do {
                MemoryBusinessLogger.emit(.memoryBackgroundJobStarted, job: job, sink: businessLogSink)
                try jobStore.markRunning(jobID: job.id)
                try await process(job)
                try jobStore.markCompleted(jobID: job.id)
            } catch {
                try? jobStore.markFailed(jobID: job.id, summary: error.localizedDescription)
                let failedJob = MemoryBackgroundJob(
                    id: job.id,
                    type: job.type,
                    status: .failed,
                    scopeNamespace: job.scopeNamespace,
                    createdAt: job.createdAt,
                    lastRunAt: job.lastRunAt,
                    completedAt: job.completedAt,
                    failureSummary: error.localizedDescription,
                    attemptCount: job.attemptCount,
                    record: job.record,
                    request: job.request,
                    outcomeRecords: job.outcomeRecords,
                    notes: job.notes,
                    ttlSweepAsOf: job.ttlSweepAsOf,
                    ttlSeconds: job.ttlSeconds
                )
                MemoryBusinessLogger.emit(
                    .memoryBackgroundJobFailed,
                    job: failedJob,
                    metadata: ["error": error.localizedDescription],
                    sink: businessLogSink
                )
                continue
            }

            let completedJob = MemoryBackgroundJob(
                id: job.id,
                type: job.type,
                status: .completed,
                scopeNamespace: job.scopeNamespace,
                createdAt: job.createdAt,
                lastRunAt: job.lastRunAt,
                completedAt: Date(),
                failureSummary: nil,
                attemptCount: job.attemptCount,
                record: job.record,
                request: job.request,
                outcomeRecords: job.outcomeRecords,
                notes: job.notes,
                ttlSweepAsOf: job.ttlSweepAsOf,
                ttlSeconds: job.ttlSeconds
            )
            MemoryBusinessLogger.emit(.memoryBackgroundJobFinished, job: completedJob, sink: businessLogSink)
        }
    }

    private func process(_ job: MemoryBackgroundJob) async throws {
        switch job.type {
        case .backgroundWrite:
            guard let record = job.record else {
                throw MemoryStoreError.serializationFailed("Missing record for background write job \(job.id)")
            }
            _ = try unifiedStore.persist(record: try record.toMemoryRecord())

        case .consolidation:
            let outcome = try job.toOutcome()
            let candidates = try await consolidationEngine.consolidate(outcome)
            for candidate in candidates {
                _ = try await governanceService.route(
                    candidate,
                    store: unifiedStore,
                    backgroundQueue: backgroundWriteQueue,
                    confirmationStore: confirmationStore
                )
            }

        case .counterexampleDistillation:
            let outcome = try job.toOutcome()
            for candidate in counterexampleDistiller.distill(from: outcome) {
                _ = try await governanceService.route(candidate, store: unifiedStore, backgroundQueue: backgroundWriteQueue, confirmationStore: confirmationStore)
            }

        case .tacticKernelDistillation:
            let outcome = try job.toOutcome()
            for candidate in tacticKernelDistiller.distill(from: outcome) {
                _ = try await governanceService.route(candidate, store: unifiedStore, backgroundQueue: backgroundWriteQueue, confirmationStore: confirmationStore)
            }

        case .memoryInvalidation:
            let outcome = try job.toOutcome()
            let analysis = invalidationService.analyze(outcome)
            let invalidatedIDs = Set(analysis.invalidatedRecordIDs)
            guard invalidatedIDs.isEmpty == false else { return }
            let records = try unifiedStore.allRecords(includeArchived: true)
            for record in records where invalidatedIDs.contains(record.id) {
                var archived = record
                archived.retentionPolicy = .archiveOnly
                archived.updatedAt = Date()
                _ = try unifiedStore.persist(record: archived)
            }
            for signal in analysis.generatedSignals {
                _ = try await governanceService.route(signal, store: unifiedStore, backgroundQueue: backgroundWriteQueue, confirmationStore: confirmationStore)
            }

        case .ttlSweep:
            let asOf = job.ttlSweepAsOf ?? Date()
            let ttl = job.ttlSeconds ?? 0
            let report = try retentionService.sweep(store: unifiedStore, asOf: asOf, ttl: ttl)
            try jobStore.saveLatestSweepReport(report)
        }
    }
}
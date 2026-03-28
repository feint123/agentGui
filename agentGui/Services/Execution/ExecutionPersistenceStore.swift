import Foundation
import SwiftData

@MainActor
final class ExecutionPersistenceStore {
    struct EnqueueResult {
        let job: ExecutionJob
        let agentMessageID: UUID?
    }

    private let modelContext: ModelContext
    private let persistenceCoordinator: PersistenceCoordinator

    init(
        modelContext: ModelContext,
        persistenceCoordinator: PersistenceCoordinator
    ) {
        self.modelContext = modelContext
        self.persistenceCoordinator = persistenceCoordinator
    }

    func enqueue(
        sessionID: String,
        providerID: ConversationExecutionProviderID,
        payload: ExecutionPayloadDraft,
        sourceUserMessageID: UUID
    ) async throws -> EnqueueResult {
        try await enqueue(
            sessionID: sessionID,
            providerReference: ExecutionProviderReference.compatibilityReference(for: providerID) ?? .builtIn,
            payload: payload,
            sourceUserMessageID: sourceUserMessageID
        )
    }

    func enqueue(
        sessionID: String,
        providerReference: ExecutionProviderReference,
        payload: ExecutionPayloadDraft,
        sourceUserMessageID: UUID
    ) async throws -> EnqueueResult {
        let session = try resolveSession(id: sessionID)
        let agentMessage = Message.agentMessage(text: nil, session: session)
        agentMessage.status = .pending
        modelContext.insert(agentMessage)

        let job = ExecutionJob(
            sessionID: sessionID,
            providerReference: providerReference,
            payload: payload,
            sourceUserMessageID: sourceUserMessageID,
            targetAgentMessageID: agentMessage.id
        )
        modelContext.insert(job)

        try persistenceCoordinator.save(
            modelContext,
            domain: .execution,
            userMessage: "执行作业入队未成功保存",
            metadata: [
                "sessionId": sessionID,
                "jobId": job.id.uuidString,
                "sourceUserMessageId": sourceUserMessageID.uuidString
            ]
        )

        return EnqueueResult(job: job, agentMessageID: agentMessage.id)
    }

    func job(id: UUID) throws -> ExecutionJob {
        let jobs = try modelContext.fetch(FetchDescriptor<ExecutionJob>())
        guard let job = jobs.first(where: { $0.id == id }) else {
            throw ExecutionPersistenceStoreError.jobNotFound(id)
        }
        return job
    }

    func session(id: String) throws -> Session {
        try resolveSession(id: id)
    }

    func start(jobID: UUID, runtimeScope: ConversationExecutionRuntimeScope?) throws -> ExecutionAttempt {
        let job = try self.job(id: jobID)
        let attempt = ExecutionAttempt(
            jobID: jobID,
            runtimeScopeRaw: runtimeScope?.rawValue,
            runtimeInstanceKey: job.sessionID
        )

        job.state = .running
        if job.startedAt == nil {
            job.startedAt = Date()
        }
        job.latestAttemptID = attempt.id
        modelContext.insert(attempt)

        try persistenceCoordinator.save(
            modelContext,
            domain: .execution,
            userMessage: "执行作业启动未成功保存",
            metadata: [
                "jobId": jobID.uuidString,
                "attemptId": attempt.id.uuidString
            ]
        )

        return attempt
    }

    func finish(
        jobID: UUID,
        attemptID: UUID,
        outcome: ExecutionJobState,
        errorMessage: String? = nil
    ) throws {
        let job = try self.job(id: jobID)
        let attempts = try modelContext.fetch(FetchDescriptor<ExecutionAttempt>())
        guard let attempt = attempts.first(where: { $0.id == attemptID }) else {
            throw ExecutionPersistenceStoreError.attemptNotFound(attemptID)
        }

        let finishedAt = Date()
        job.state = outcome
        job.finishedAt = finishedAt
        if job.startedAt == nil {
            job.startedAt = finishedAt
        }

        attempt.state = switch outcome {
        case .completed:
            .completed
        case .failed:
            .failed
        case .cancelled:
            .cancelled
        default:
            .interrupted
        }
        attempt.endedAt = finishedAt
        attempt.errorMessage = errorMessage
        attempt.stopReason = switch outcome {
        case .completed:
            "completed"
        case .failed:
            "failed"
        case .cancelled:
            "cancelled"
        default:
            nil
        }

        try persistenceCoordinator.save(
            modelContext,
            domain: .execution,
            userMessage: "执行作业收敛未成功保存",
            metadata: [
                "jobId": jobID.uuidString,
                "attemptId": attemptID.uuidString,
                "outcome": outcome.rawValue
            ]
        )
    }

    func recoverableJobs() throws -> [ExecutionJob] {
        let jobs = try modelContext.fetch(FetchDescriptor<ExecutionJob>())
            .filter { $0.state == .queued || $0.state == .running }
            .sorted { lhs, rhs in
                if lhs.enqueuedAt == rhs.enqueuedAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.enqueuedAt < rhs.enqueuedAt
            }

        guard !jobs.isEmpty else {
            return []
        }

        let attempts = try modelContext.fetch(FetchDescriptor<ExecutionAttempt>())
        let recoveredAt = Date()
        var didMutateRunningJob = false

        for job in jobs where job.state == .running {
            job.state = .queued
            if let latestAttemptID = job.latestAttemptID,
               let attempt = attempts.first(where: { $0.id == latestAttemptID }) {
                attempt.state = .interrupted
                attempt.endedAt = recoveredAt
                if attempt.stopReason == nil {
                    attempt.stopReason = "interrupted"
                }
                if attempt.errorMessage == nil {
                    attempt.errorMessage = "Execution interrupted before recovery"
                }
            }
            didMutateRunningJob = true
        }

        if didMutateRunningJob {
            try persistenceCoordinator.save(
                modelContext,
                domain: .execution,
                userMessage: "执行作业恢复未成功保存",
                metadata: [
                    "recoveredJobs": String(jobs.count)
                ]
            )
        }

        return jobs
    }

    private func resolveSession(id: String) throws -> Session {
        let sessions = try modelContext.fetch(FetchDescriptor<Session>())
        guard let session = sessions.first(where: { $0.sessionId == id }) else {
            throw ExecutionPersistenceStoreError.sessionNotFound(id)
        }
        return session
    }
}

enum ExecutionPersistenceStoreError: Error, Equatable {
    case sessionNotFound(String)
    case jobNotFound(UUID)
    case attemptNotFound(UUID)
}
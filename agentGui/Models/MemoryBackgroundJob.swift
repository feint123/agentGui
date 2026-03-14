import Foundation

struct MemoryBackgroundRuntimeRequestSnapshot: Codable, Equatable, Sendable {
    var sessionId: String
    var threadId: String
    var workflowRunId: String?
    var userRequest: String
    var taskKind: MemoryTaskKind
    var projectId: String?
    var workspaceRoot: String?
    var contextBudget: Int

    init(request: MemoryRuntimeRequest) {
        self.sessionId = request.sessionId
        self.threadId = request.threadId
        self.workflowRunId = request.workflowRunId
        self.userRequest = request.userRequest
        self.taskKind = request.taskKind
        self.projectId = request.projectId
        self.workspaceRoot = request.workspaceRoot
        self.contextBudget = request.contextBudget
    }

    func toRequest() -> MemoryRuntimeRequest {
        MemoryRuntimeRequest(
            sessionId: sessionId,
            threadId: threadId,
            workflowRunId: workflowRunId,
            userRequest: userRequest,
            taskKind: taskKind,
            projectId: projectId,
            workspaceRoot: workspaceRoot,
            contextBudget: contextBudget
        )
    }
}

struct MemoryBackgroundJob: Codable, Equatable, Sendable, Identifiable {
    enum JobType: String, Codable, Equatable, Sendable {
        case backgroundWrite
        case consolidation
        case counterexampleDistillation
        case tacticKernelDistillation
        case memoryInvalidation
        case ttlSweep
    }

    enum Status: String, Codable, Equatable, Sendable {
        case queued
        case running
        case completed
        case failed
        case cancelled
    }

    var id: String
    var type: JobType
    var status: Status
    var scopeNamespace: String?
    var createdAt: Date
    var lastRunAt: Date?
    var completedAt: Date?
    var failureSummary: String?
    var attemptCount: Int
    var nextEligibleRunAt: Date?
    var maxAttempts: Int
    var lastFailureAt: Date?
    var record: UnifiedMemoryStoredRecord?
    var request: MemoryBackgroundRuntimeRequestSnapshot?
    var outcomeRecords: [UnifiedMemoryStoredRecord]
    var notes: [String]
    var ttlSweepAsOf: Date?
    var ttlSeconds: TimeInterval?

    init(
        id: String = UUID().uuidString,
        type: JobType,
        status: Status = .queued,
        scopeNamespace: String? = nil,
        createdAt: Date = Date(),
        lastRunAt: Date? = nil,
        completedAt: Date? = nil,
        failureSummary: String? = nil,
        attemptCount: Int = 0,
        nextEligibleRunAt: Date? = nil,
        maxAttempts: Int = 3,
        lastFailureAt: Date? = nil,
        record: UnifiedMemoryStoredRecord? = nil,
        request: MemoryBackgroundRuntimeRequestSnapshot? = nil,
        outcomeRecords: [UnifiedMemoryStoredRecord] = [],
        notes: [String] = [],
        ttlSweepAsOf: Date? = nil,
        ttlSeconds: TimeInterval? = nil
    ) {
        self.id = id
        self.type = type
        self.status = status
        self.scopeNamespace = scopeNamespace
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.completedAt = completedAt
        self.failureSummary = failureSummary
        self.attemptCount = attemptCount
        self.nextEligibleRunAt = nextEligibleRunAt
        self.maxAttempts = maxAttempts
        self.lastFailureAt = lastFailureAt
        self.record = record
        self.request = request
        self.outcomeRecords = outcomeRecords
        self.notes = notes
        self.ttlSweepAsOf = ttlSweepAsOf
        self.ttlSeconds = ttlSeconds
    }
}

extension MemoryBackgroundJob {
    static func backgroundWrite(record: MemoryRecord) -> MemoryBackgroundJob {
        MemoryBackgroundJob(
            type: .backgroundWrite,
            scopeNamespace: record.scope.namespace,
            record: UnifiedMemoryStoredRecord(record: record)
        )
    }

    static func consolidation(outcome: MemoryRuntimeOutcome) -> MemoryBackgroundJob {
        MemoryBackgroundJob(
            type: .consolidation,
            scopeNamespace: MemoryScope.session(id: outcome.request.sessionId).namespace,
            request: MemoryBackgroundRuntimeRequestSnapshot(request: outcome.request),
            outcomeRecords: outcome.records.map(UnifiedMemoryStoredRecord.init(record:)),
            notes: outcome.notes
        )
    }

    static func ttlSweep(asOf: Date = Date(), ttl: TimeInterval) -> MemoryBackgroundJob {
        MemoryBackgroundJob(
            type: .ttlSweep,
            maxAttempts: 1,
            ttlSweepAsOf: asOf,
            ttlSeconds: ttl
        )
    }

    static func counterexampleDistillation(outcome: MemoryRuntimeOutcome) -> MemoryBackgroundJob {
        MemoryBackgroundJob(
            type: .counterexampleDistillation,
            scopeNamespace: MemoryScope.session(id: outcome.request.sessionId).namespace,
            request: MemoryBackgroundRuntimeRequestSnapshot(request: outcome.request),
            outcomeRecords: outcome.records.map(UnifiedMemoryStoredRecord.init(record:)),
            notes: outcome.notes
        )
    }

    static func tacticKernelDistillation(outcome: MemoryRuntimeOutcome) -> MemoryBackgroundJob {
        MemoryBackgroundJob(
            type: .tacticKernelDistillation,
            scopeNamespace: MemoryScope.session(id: outcome.request.sessionId).namespace,
            request: MemoryBackgroundRuntimeRequestSnapshot(request: outcome.request),
            outcomeRecords: outcome.records.map(UnifiedMemoryStoredRecord.init(record:)),
            notes: outcome.notes
        )
    }

    static func memoryInvalidation(outcome: MemoryRuntimeOutcome) -> MemoryBackgroundJob {
        MemoryBackgroundJob(
            type: .memoryInvalidation,
            scopeNamespace: MemoryScope.session(id: outcome.request.sessionId).namespace,
            request: MemoryBackgroundRuntimeRequestSnapshot(request: outcome.request),
            outcomeRecords: outcome.records.map(UnifiedMemoryStoredRecord.init(record:)),
            notes: outcome.notes
        )
    }

    func toOutcome() throws -> MemoryRuntimeOutcome {
        guard let request else {
            throw MemoryStoreError.serializationFailed("Missing consolidation request for job \(id)")
        }

        return MemoryRuntimeOutcome(
            request: request.toRequest(),
            records: try outcomeRecords.map { try $0.toMemoryRecord() },
            notes: notes
        )
    }
}
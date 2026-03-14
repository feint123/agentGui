import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryBackgroundSchedulerTests {
    @Test func backgroundJobFactoriesExposeRMSDistillationAndInvalidationTypes() async throws {
        let outcome = makeOutcome(records: [])
        #expect(MemoryBackgroundJob.counterexampleDistillation(outcome: outcome).type == .counterexampleDistillation)
        #expect(MemoryBackgroundJob.tacticKernelDistillation(outcome: outcome).type == .tacticKernelDistillation)
        #expect(MemoryBackgroundJob.memoryInvalidation(outcome: outcome).type == .memoryInvalidation)
    }

    @Test func backgroundJobStorePersistsQueuedJobsAcrossReload() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = MemoryBackgroundJobStore(baseDirectory: baseDirectory)
        try store.enqueue(.backgroundWrite(record: MemoryRecord.fixture(
            id: "queued-record",
            scope: .session(id: "s1"),
            title: "Queued record"
        )))

        let reloaded = MemoryBackgroundJobStore(baseDirectory: baseDirectory)
        let jobs = try reloaded.allJobs()
        #expect(jobs.count == 1)
        #expect(jobs.first?.status == .queued)
    }

    @Test func schedulerConsumesQueuedConsolidationJobs() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let jobStore = MemoryBackgroundJobStore(baseDirectory: baseDirectory)
        let scheduler = MemoryBackgroundScheduler(baseDirectory: baseDirectory)

        let outcome = MemoryRuntimeOutcome(
            request: MemoryRuntimeRequest(
                sessionId: "s1",
                threadId: "t1",
                workflowRunId: nil,
                userRequest: "Fix build",
                taskKind: .coding,
                projectId: nil,
                workspaceRoot: "/tmp/repo",
                contextBudget: 4000
            ),
            records: [
                MemoryRecord.fixture(
                    id: "build-fact",
                    layer: .working,
                    kind: .working,
                    scope: .session(id: "s1"),
                    title: "Build uses xcodebuild",
                    confidence: 1.0,
                    verificationStatus: .verified,
                    tags: ["confirmed-fact"]
                )
            ]
        )

        try jobStore.enqueue(.consolidation(outcome: outcome))
        await scheduler.runOnce()

        let jobs = try jobStore.allJobs()
        #expect(jobs.allSatisfy { $0.status == .completed })

        let records = try UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
            .records(for: .session(id: "s1"), includeArchived: true)
        #expect(records.contains { $0.title == "Build uses xcodebuild" && $0.layer == .task })
    }

    @Test func schedulerRunsTTLJobsAndStoresLatestSweepReport() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        _ = try store.persist(record: MemoryRecord.fixture(
            id: "expired",
            layer: .task,
            kind: .working,
            scope: .session(id: "s1"),
            retentionPolicy: .sessionBound,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        ))

        let jobStore = MemoryBackgroundJobStore(baseDirectory: baseDirectory)
        try jobStore.enqueue(.ttlSweep(asOf: Date(timeIntervalSince1970: 10_000), ttl: 60))

        let scheduler = MemoryBackgroundScheduler(baseDirectory: baseDirectory)
        await scheduler.runOnce()

        let report = try #require(jobStore.latestSweepReport())
        #expect(report.archivedCount == 1)
        #expect(report.revalidationCount >= 0)
    }

    @Test func schedulerConsumesCounterexampleDistillationJobs() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let jobStore = MemoryBackgroundJobStore(baseDirectory: baseDirectory)
        let scheduler = MemoryBackgroundScheduler(baseDirectory: baseDirectory)

        let outcome = makeOutcome(records: [
            MemoryRecord.fixture(
                id: "failure-1",
                layer: .task,
                kind: .working,
                scope: .session(id: "s1"),
                title: "Attempt 1",
                summary: "Edited before confirming scheme",
                verificationStatus: .failed,
                tags: ["failed-attempt"]
            ),
            MemoryRecord.fixture(
                id: "failure-2",
                layer: .task,
                kind: .working,
                scope: .session(id: "s1"),
                title: "Attempt 2",
                summary: "Edited before confirming scheme",
                verificationStatus: .failed,
                tags: ["failed-attempt"]
            )
        ])

        try jobStore.enqueue(.counterexampleDistillation(outcome: outcome))
        await scheduler.runOnce()

        let jobs = try jobStore.allJobs()
        #expect(jobs.allSatisfy { $0.status == .completed })

        let records = try UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
            .records(for: .session(id: "s1"), includeArchived: true)
        let counterexample = try #require(records.first(where: { $0.tags.contains("counterexample") }))
        #expect(counterexample.tags.contains("anti-pattern"))
        if case let .structured(fields) = counterexample.payload {
            #expect(fields["replacement_action"]?.isEmpty == false)
        } else {
            Issue.record("Expected structured counterexample payload")
        }
    }

    @Test func schedulerConsumesTacticKernelDistillationJobs() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let jobStore = MemoryBackgroundJobStore(baseDirectory: baseDirectory)
        let scheduler = MemoryBackgroundScheduler(baseDirectory: baseDirectory)

        let outcome = makeOutcome(records: [
            MemoryRecord.fixture(
                id: "fact-1",
                layer: .working,
                kind: .working,
                scope: .session(id: "s1"),
                title: "Build uses xcodebuild",
                confidence: 1.0,
                verificationStatus: .verified,
                tags: ["confirmed-fact"]
            )
        ])

        try jobStore.enqueue(.tacticKernelDistillation(outcome: outcome))
        await scheduler.runOnce()

        let jobs = try jobStore.allJobs()
        #expect(jobs.allSatisfy { $0.status == .completed })

        let records = try UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
            .records(for: .session(id: "s1"), includeArchived: true)
        let tacticKernel = try #require(records.first(where: { $0.tags.contains("tactic-kernel") }))
        if case let .structured(fields) = tacticKernel.payload {
            #expect(fields["applicable_precondition"]?.isEmpty == false)
            #expect(fields["exit_condition"]?.isEmpty == false)
        } else {
            Issue.record("Expected structured tactic kernel payload")
        }
    }

    @Test func schedulerConsumesInvalidationJobsAndPersistsSignals() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        _ = try store.persist(record: MemoryRecord.fixture(
            id: "failed-procedure",
            layer: .task,
            kind: .working,
            scope: .session(id: "s1"),
            title: "Old repair path",
            summary: "Edited before confirming scheme",
            verificationStatus: .verified,
            tags: ["tactic-kernel"]
        ))

        let jobStore = MemoryBackgroundJobStore(baseDirectory: baseDirectory)
        let scheduler = MemoryBackgroundScheduler(baseDirectory: baseDirectory)
        let outcome = makeOutcome(records: [
            MemoryRecord.fixture(
                id: "failed-procedure",
                layer: .task,
                kind: .working,
                scope: .session(id: "s1"),
                title: "Old repair path",
                summary: "Edited before confirming scheme",
                verificationStatus: .failed,
                tags: ["tactic-kernel", "failed-attempt"]
            )
        ])

        try jobStore.enqueue(.memoryInvalidation(outcome: outcome))
        await scheduler.runOnce()

        let records = try store.records(for: .session(id: "s1"), includeArchived: true)
        #expect(records.first(where: { $0.id == "failed-procedure" })?.retentionPolicy == .archiveOnly)
        #expect(records.contains { $0.tags.contains("invalidated-procedure") })
    }

    @Test func schedulerEmitsBackgroundJobLifecycleLogs() async throws {
        let sink = InMemoryBusinessLogSink()
        let baseDirectory = try makeTemporaryDirectory()
        let jobStore = MemoryBackgroundJobStore(baseDirectory: baseDirectory)
        let scheduler = MemoryBackgroundScheduler(baseDirectory: baseDirectory, businessLogSink: sink)

        try jobStore.enqueue(.ttlSweep(asOf: Date(timeIntervalSince1970: 10_000), ttl: 60))
        await scheduler.runOnce()

        #expect(sink.events.contains { $0.event == .memoryBackgroundJobStarted })
        #expect(sink.events.contains { entry in
            entry.event == .memoryBackgroundJobFinished &&
            (entry.metadata["jobType"] as? String) == "ttlSweep"
        })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeOutcome(records: [MemoryRecord]) -> MemoryRuntimeOutcome {
        MemoryRuntimeOutcome(
            request: MemoryRuntimeRequest(
                sessionId: "s1",
                threadId: "t1",
                workflowRunId: nil,
                userRequest: "Fix build",
                taskKind: .coding,
                projectId: nil,
                workspaceRoot: "/tmp/repo",
                contextBudget: 4000
            ),
            records: records
        )
    }
}
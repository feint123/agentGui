import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryBackgroundSchedulerTests {
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

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
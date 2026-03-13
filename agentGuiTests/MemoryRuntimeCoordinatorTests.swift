import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryRuntimeCoordinatorTests {
    @Test func coordinatorBuildsUnifiedSliceForCodingRequest() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        _ = try store.persist(record: MemoryRecord.fixture(
            id: "task-1",
            layer: .task,
            kind: .working,
            scope: .session(id: "s1"),
            title: "Known failure",
            source: .taskMemory,
            tags: ["failed-attempt"]
        ))

        let coordinator = MemoryRuntimeCoordinator(
            unifiedRecordsProvider: { request in
                (try? store.records(for: request)) ?? []
            },
            unifiedStoreBaseDirectory: baseDirectory
        )

        let request = MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix build",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 4000
        )

        let context = try await coordinator.prepareContext(for: request)

        #expect(context.records.contains { $0.title == "Known failure" })
        #expect(context.renderedPrompt.contains("Known failure"))
    }

    @Test func coordinatorPersistsRecordedOutcomeIntoUnifiedStore() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let coordinator = MemoryRuntimeCoordinator(
            unifiedRecordsProvider: { _ in [] },
            unifiedStoreBaseDirectory: baseDirectory
        )

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
                    id: "outcome-record",
                    layer: .working,
                    kind: .working,
                    scope: .session(id: "s1"),
                    title: "Observed failure"
                )
            ]
        )

        await coordinator.recordOutcome(outcome)

        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        let records = try store.records(for: .session(id: "s1"), includeArchived: true)
        #expect(records.contains { $0.id == "outcome-record" })
    }

    @Test func coordinatorSchedulesConsolidationAndPersistsCandidates() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let coordinator = MemoryRuntimeCoordinator(
            unifiedRecordsProvider: { _ in [] },
            unifiedStoreBaseDirectory: baseDirectory
        )

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

        await coordinator.scheduleConsolidation(for: outcome)

        let jobStore = MemoryBackgroundJobStore(baseDirectory: baseDirectory)
        #expect(try jobStore.allJobs().contains { $0.type == .consolidation && $0.status == .queued })

        let scheduler = MemoryBackgroundScheduler(baseDirectory: baseDirectory)
        await scheduler.runOnce()

        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        let records = try store.records(for: .session(id: "s1"), includeArchived: true)
        #expect(records.contains { $0.title == "Build uses xcodebuild" && $0.layer == .task })
    }

    @Test func coordinatorBuildsSnapshotTraceWithBudgetAndExclusionReasons() async throws {
        let records = [
            MemoryRecord.fixture(
                id: "task-1",
                layer: .task,
                kind: .working,
                scope: .session(id: "s1"),
                title: "Hot fact",
                verificationStatus: .verified
            ),
            MemoryRecord.fixture(
                id: "task-2",
                layer: .task,
                kind: .working,
                scope: .session(id: "s1"),
                title: "Cold fact",
                verificationStatus: .unverified,
                updatedAt: Date(timeIntervalSince1970: 1)
            ),
            MemoryRecord.fixture(
                id: "semantic-archive",
                layer: .semantic,
                kind: .semantic,
                scope: .user,
                title: "Old pref",
                retentionPolicy: .archiveOnly
            )
        ]

        let coordinator = MemoryRuntimeCoordinator.makeForTests(unifiedRecords: records)
        let request = MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix build",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 1000
        )

        let context = try await coordinator.prepareContext(for: request)

        let snapshot = try #require(context.runtimeSnapshot)
        #expect(snapshot.selectedRecords.contains { $0.layer == .task && $0.recordID == "task-1" })
        #expect(snapshot.selectedRecords.contains { $0.layer == .working && $0.tags.contains("runtime-working") })
        #expect(snapshot.excludedRecords.contains { $0.recordID == "task-2" && $0.exclusionReason == .budgetTrimmed })
        #expect(snapshot.excludedRecords.contains { $0.recordID == "semantic-archive" && $0.exclusionReason == .archived })
        #expect(snapshot.plan.itemBudgetByLayer[.task] == 1)
    }

    @Test func emptyUnifiedMemorySliceStillProducesInspectableSnapshot() async throws {
        let coordinator = MemoryRuntimeCoordinator.makeForTests(unifiedRecords: [])
        let request = MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix build",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 4000
        )

        let context = try await coordinator.prepareContext(for: request)
        let snapshot = try #require(context.runtimeSnapshot)

        #expect(snapshot.metrics.selectedCount == 1)
        #expect(snapshot.selectedRecords.contains { $0.layer == .working && $0.tags.contains("runtime-working") })
        #expect(snapshot.request.contextBudget == 4000)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
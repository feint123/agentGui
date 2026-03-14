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
            source: .system(name: "tests"),
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

    @Test func coordinatorCapturesDereferenceTraceFromSelectedRecords() async throws {
        let records = [
            MemoryRecord.fixture(
                id: "failure-1",
                layer: .task,
                kind: .working,
                scope: .session(id: "s1"),
                title: "xcodebuild scheme failure",
                summary: "Scheme missing",
                verificationStatus: .verified,
                tags: ["failed-attempt"],
                evidenceAnchors: [
                    MemoryEvidenceAnchor(kind: .toolCall, identifier: "tool-1", summary: "Ran xcodebuild test")
                ]
            ),
            MemoryRecord.fixture(
                id: "recovery-1",
                layer: .task,
                kind: .working,
                scope: .session(id: "s1"),
                title: "Re-run with shared scheme",
                summary: "Mark scheme as shared before xcodebuild",
                verificationStatus: .verified,
                tags: ["recovery-tip"]
            )
        ]

        let coordinator = MemoryRuntimeCoordinator.makeForTests(unifiedRecords: records)
        let request = MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix xcodebuild scheme failure",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 4000
        )

        let context = try await coordinator.prepareContext(for: request)
        let snapshot = try #require(context.runtimeSnapshot)

        #expect(snapshot.selectedRecords.contains { $0.recordID == "failure-1" })
        #expect(snapshot.dereferenceCount > 0)
    }

    @Test func coordinatorEmitsStructuredLogsForPrepareContext() async throws {
        let sink = InMemoryBusinessLogSink()
        let coordinator = MemoryRuntimeCoordinator(
            unifiedRecordsProvider: { _ in [
                MemoryRecord.fixture(
                    id: "task-1",
                    layer: .task,
                    kind: .working,
                    scope: .session(id: "s1"),
                    title: "Known failure",
                    verificationStatus: .verified
                )
            ] },
            businessLogSink: sink
        )

        _ = try await coordinator.prepareContext(for: MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix build",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 4000
        ))

        #expect(sink.events.contains { $0.event == .memoryContextPreparationStarted })
        #expect(sink.events.contains { entry in
            entry.event == .memoryContextPrepared &&
            (entry.metadata["selectedCount"] as? Int ?? 0) >= 1 &&
            (entry.metadata["sessionID"] as? String) == "s1"
        })
    }

    @Test func coordinatorCarriesEpistemicStateIntoContextAndSnapshot() async throws {
        let coordinator = MemoryRuntimeCoordinator.makeForTests(unifiedRecords: [
            MemoryRecord.fixture(id: "task-1", layer: .task, kind: .working, scope: .session(id: "s1"), title: "Known failure")
        ])

        let frontier = FrontierMemory(
            frontierId: "f-1",
            goal: "Fix build",
            openClaim: "Need to confirm shared scheme",
            uncertaintyType: .tooling,
            impactLevel: .high,
            suggestedProbe: "Run xcodebuild -list",
            stopCondition: "Scheme confirmed"
        )
        let trace = MemoryInfluenceTrace(activatedMemoryIDs: ["f-1"], rankedActionIDs: ["Run xcodebuild -list"])

        let context = try await coordinator.prepareContext(
            for: MemoryRuntimeRequest(
                sessionId: "s1",
                threadId: "t1",
                workflowRunId: nil,
                userRequest: "Fix build",
                taskKind: .coding,
                projectId: nil,
                workspaceRoot: "/tmp/repo",
                contextBudget: 4000
            ),
            epistemicState: EpistemicState(frontiers: [frontier]),
            influenceTrace: trace
        )

        #expect(context.epistemicState.frontiers.first?.openClaim == "Need to confirm shared scheme")
        #expect(context.influenceTrace.activatedMemoryIDs == ["f-1"])
        #expect(context.renderedPrompt.contains("Need to confirm shared scheme"))
        #expect(context.influenceTrace.frontierBudgetDecisions.first?.frontierID == "f-1")

        let snapshot = try #require(context.runtimeSnapshot)
        #expect(snapshot.epistemicState.frontiers.first?.frontierId == "f-1")
        #expect(snapshot.influenceTrace.rankedActionIDs == ["Run xcodebuild -list"])
        #expect(snapshot.influenceTrace.frontierBudgetDecisions.first?.allocatedBudget ?? 0 >= 1)
    }

    @Test func scheduleConsolidationQueuesRMSDistillationJobs() async throws {
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
                    id: "fact-1",
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

        let jobs = try MemoryBackgroundJobStore(baseDirectory: baseDirectory).allJobs()
        #expect(jobs.contains { $0.type == .counterexampleDistillation })
        #expect(jobs.contains { $0.type == .tacticKernelDistillation })
        #expect(jobs.contains { $0.type == .memoryInvalidation })
        #expect(jobs.contains { $0.type == .consolidation })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
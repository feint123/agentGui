import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryRuntimeCoordinatorTests {
    @Test func coordinatorBuildsUnifiedSliceForCodingRequest() async throws {
        let coordinator = MemoryRuntimeCoordinator.makeForTests(
            taskRecords: [MemoryRecord.fixture(layer: .task, kind: .working, title: "Known failure")],
            storyRecords: []
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
            taskRecordsProvider: { _ in [] },
            storyRecordsProvider: { _ in [] },
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
            taskRecordsProvider: { _ in [] },
            storyRecordsProvider: { _ in [] },
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

        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        let records = try store.records(for: .session(id: "s1"), includeArchived: true)
        #expect(records.contains { $0.title == "Build uses xcodebuild" && $0.layer == .task })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
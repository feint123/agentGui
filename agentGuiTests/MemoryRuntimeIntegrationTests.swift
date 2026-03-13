import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryRuntimeIntegrationTests {
    @Test func codingRequestProducesSingleUnifiedMemorySlice() async throws {
        let coordinator = MemoryRuntimeCoordinator.makeForTests(
            unifiedRecords: [MemoryRecord.fixture(layer: .task, kind: .working, title: "Known task fact")]
        )

        let request = MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix the failing build",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 4000
        )

        let context = try await coordinator.prepareContext(for: request)
        #expect(context.renderedPrompt.contains("Known task fact"))
    }

    @Test func unifiedMemoryBootstrapPersistsSnapshotAndLinksToolCall() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = MemoryRuntimeSnapshotStore(baseDirectory: baseDirectory)
        let coordinator = MemoryRuntimeCoordinator.makeForTests(
            unifiedRecords: [MemoryRecord.fixture(id: "task-1", layer: .task, scope: .session(id: "s1"), title: "Known failure")]
        )

        let context = try await coordinator.prepareContext(for: .init(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix build",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 4000
        ))
        let snapshot = try #require(context.runtimeSnapshot)
        try store.save(snapshot)

        let toolCall = ToolCall(toolCallId: "tool-1", kind: .search)
        toolCall.memoryRuntimeSnapshotID = snapshot.id

        let loadedSnapshot = try store.snapshot(id: snapshot.id)
        #expect(loadedSnapshot?.selectedRecords.contains { $0.layer == .task && $0.title == "Known failure" } == true)
        #expect(loadedSnapshot?.selectedRecords.contains { $0.layer == .working && $0.tags.contains("runtime-working") } == true)
        #expect(toolCall.memoryRuntimeSnapshotID == snapshot.id)
    }

    @Test func prepareContextSynthesizesWorkingMemoryWhenNoWorkingRecordsExist() async throws {
        let coordinator = MemoryRuntimeCoordinator.makeForTests(
            unifiedRecords: [MemoryRecord.fixture(id: "semantic-1", layer: .semantic, kind: .semantic, title: "North tower curfew")]
        )

        let context = try await coordinator.prepareContext(for: .init(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Continue the chapter and keep the night curfew consistent",
            taskKind: .creativeWriting,
            projectId: "project-1",
            workspaceRoot: nil,
            contextBudget: 4000
        ))

        #expect(context.records.contains {
            $0.layer == .working &&
            $0.tags.contains("runtime-working") &&
            $0.summary.contains("Continue the chapter")
        })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryRuntimeSnapshotStoreTests {
    @Test func storeRoundTripsSnapshotWithSelectedAndExcludedRecords() throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = MemoryRuntimeSnapshotStore(baseDirectory: baseDirectory)
        let snapshot = MemoryRuntimeSnapshot.fixture(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            toolCallId: "tool-1",
            candidateCount: 4,
            selectedRecords: [
                .fixture(recordID: "selected-1", title: "Known failure", layer: .task, estimatedPromptChars: 32)
            ],
            excludedRecords: [
                .fixture(recordID: "excluded-1", title: "Old archive", layer: .semantic, exclusionReason: .archived)
            ]
        )

        try store.save(snapshot)
    let persisted = try store.snapshot(id: snapshot.id)
    let loaded = try #require(persisted)

        #expect(loaded.selectedRecords.count == 1)
        #expect(loaded.excludedRecords.first?.exclusionReason == .archived)
        #expect(loaded.metrics.selectedCount == 1)
        #expect(loaded.metrics.countBreakdowns[.layer]?["task"] == 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryManagementViewModelTests {
    @Test func viewModelAggregatesScopeLayerAndGovernanceCounts() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        let confirmationStore = MemoryConfirmationStore(baseDirectory: baseDirectory)

        _ = try store.persist(record: MemoryRecord.fixture(
            id: "active-task",
            layer: .task,
            kind: .working,
            scope: .session(id: "s1"),
            title: "Build failure"
        ))
        _ = try store.persist(record: MemoryRecord.fixture(
            id: "active-semantic",
            layer: .semantic,
            kind: .semantic,
            scope: .user,
            title: "Output preference"
        ))
        _ = try store.persist(record: MemoryRecord.fixture(
            id: "conflict-old",
            layer: .semantic,
            kind: .semantic,
            scope: .project(id: "p1"),
            title: "北塔夜禁",
            supersededBy: "conflict-new"
        ))
        _ = try store.persist(record: MemoryRecord.fixture(
            id: "archived",
            layer: .semantic,
            kind: .semantic,
            scope: .project(id: "p1"),
            title: "Old canon",
            retentionPolicy: .archiveOnly
        ))

        try confirmationStore.append(
            MemoryConfirmationCandidate(
                candidateID: "pending-1",
                domainProfile: "creative-writing",
                scope: .project(id: "p1"),
                title: "Speculative relationship",
                summary: "顾沉可能爱上林澈",
                proposedRecord: UnifiedMemoryStoredRecord(record: MemoryRecord.fixture(id: "pending-1", scope: .project(id: "p1"))),
                reason: "Needs user confirmation"
            )
        )

        let viewModel = MemoryManagementViewModel(store: store, confirmationStore: confirmationStore)
        try viewModel.reload()

        #expect(viewModel.totalRecordCount == 4)
        #expect(viewModel.pendingConfirmationCount == 1)
        #expect(viewModel.archivedCount == 1)
        #expect(viewModel.conflictCount == 1)
        #expect(viewModel.scopeSummaries.contains { $0.label == "project:p1" && $0.count == 2 })
        #expect(viewModel.layerSummaries.contains { $0.label == "semantic" && $0.count == 3 })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
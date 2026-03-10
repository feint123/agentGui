import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryConflictResolverTests {
    @Test func conflictResolverFlagsSameScopeAndTitleConflicts() async throws {
        let existing = [
            MemoryRecord.fixture(
                id: "existing",
                layer: .semantic,
                kind: .semantic,
                scope: .project(id: "p1"),
                title: "北塔夜禁",
                tags: ["world-rule"]
            )
        ]
        let candidate = MemoryCandidate.fixture(
            id: "candidate",
            layer: .semantic,
            kind: .semantic,
            domainProfile: "creative-writing",
            scope: .project(id: "p1"),
            title: "北塔夜禁",
            confidence: 1.0,
            verificationStatus: .verified,
            tags: ["world-rule"]
        )

        let conflicts = MemoryConflictResolver().detectConflicts(for: candidate, existingRecords: existing)

        #expect(conflicts.count == 1)
        #expect(conflicts.first?.existingRecordID == "existing")
    }

    @Test func governedHotPathWriteReplacesConflictingRecord() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        let existing = MemoryRecord.fixture(
            id: "existing",
            layer: .task,
            kind: .working,
            scope: .session(id: "s1"),
            title: "Build entrypoint",
            confidence: 1.0,
            verificationStatus: .verified
        )
        _ = try store.persist(record: existing)

        let candidate = MemoryCandidate.fixture(
            id: "replacement",
            layer: .task,
            kind: .working,
            domainProfile: "coding-task",
            scope: .session(id: "s1"),
            title: "Build entrypoint",
            confidence: 1.0,
            verificationStatus: .verified
        )

        let result = try await MemoryGovernanceService().route(
            candidate,
            store: store,
            backgroundQueue: MemoryBackgroundWriteQueue(storeBaseDirectory: baseDirectory),
            confirmationStore: MemoryConfirmationStore(baseDirectory: baseDirectory)
        )

        guard case let .hotPath(writeResult) = result else {
            Issue.record("Expected hot-path replacement result")
            return
        }

        #expect(writeResult.action == .replaced(replacedRecordID: "existing"))
        let allRecords = try store.records(for: .session(id: "s1"), includeArchived: true)
        let superseded = try #require(allRecords.first(where: { $0.id == "existing" }))
        #expect(superseded.supersededBy == "replacement")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
import Foundation
import Testing
@testable import agentGui

@MainActor
struct UnifiedMemoryFileStoreAdapterTests {
    @Test func fileStorePersistsAndReadsScopedRecords() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        let scope = MemoryScope.session(id: "session-store")
        let record = MemoryRecord.fixture(
            id: "record-a",
            layer: .task,
            kind: .working,
            scope: scope,
            title: "Build failure"
        )

        _ = try store.persist(record: record)

        let records = try store.records(for: scope)
        #expect(records.count == 1)
        #expect(records.first?.id == record.id)
        #expect(records.first?.layer == .task)
    }

    @Test func fileStoreHidesArchivedRecordsByDefaultAndSupportsReplaceAndTouch() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        let scope = MemoryScope.project(id: "project-store")
        let oldRecord = MemoryRecord.fixture(
            id: "record-old",
            layer: .semantic,
            kind: .semantic,
            scope: scope,
            title: "Old rule"
        )
        let newRecord = MemoryRecord.fixture(
            id: "record-new",
            layer: .semantic,
            kind: .semantic,
            scope: scope,
            title: "New rule"
        )

        _ = try store.persist(record: oldRecord)
        _ = try store.replace(recordID: oldRecord.id, with: newRecord)
        let touchedAt = Date(timeIntervalSince1970: 200)
        _ = try store.touch(recordID: newRecord.id, accessedAt: touchedAt)
        _ = try store.archive(recordID: oldRecord.id, reason: .superseded)

        let visible = try store.records(for: scope)
        #expect(visible.count == 1)
        #expect(visible.first?.id == newRecord.id)
        #expect(visible.first?.lastAccessedAt == touchedAt)

        let allRecords = try store.records(for: scope, includeArchived: true)
        let archived = try #require(allRecords.first(where: { $0.id == oldRecord.id }))
        #expect(archived.retentionPolicy == .archiveOnly)
        #expect(archived.supersededBy == newRecord.id)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
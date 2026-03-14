import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryRetentionServiceTests {
    @Test func retentionServiceArchivesExpiredSessionRecords() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        let expired = MemoryRecord.fixture(
            id: "expired",
            layer: .task,
            kind: .working,
            scope: .session(id: "s1"),
            retentionPolicy: .sessionBound,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        _ = try store.persist(record: expired)

        let results = try MemoryRetentionService().sweepExpiredSessionRecords(
            store: store,
            asOf: Date(timeIntervalSince1970: 10_000),
            ttl: 60
        )

        #expect(results.count == 1)
        #expect(try store.records(for: .session(id: "s1")).isEmpty)
        #expect(try store.records(for: .session(id: "s1"), includeArchived: true).first?.retentionPolicy == .archiveOnly)
    }

    @Test func retentionServiceProducesSweepReport() async throws {
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
        _ = try store.persist(record: MemoryRecord.fixture(
            id: "partial",
            layer: .semantic,
            kind: .semantic,
            scope: .user,
            verificationStatus: .partial,
            retentionPolicy: .persistent
        ))

        let report = try MemoryRetentionService().sweep(
            store: store,
            asOf: Date(timeIntervalSince1970: 10_000),
            ttl: 60
        )

        #expect(report.archivedCount == 1)
        #expect(report.revalidationCount == 1)
        #expect(report.totalProcessed == 2)
    }

    @Test func retentionServiceBuildsRevalidationQueueFromUnverifiedRecords() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        _ = try store.persist(record: MemoryRecord.fixture(
            id: "partial",
            layer: .semantic,
            kind: .semantic,
            scope: .user,
            verificationStatus: .partial,
            retentionPolicy: .persistent
        ))
        _ = try store.persist(record: MemoryRecord.fixture(
            id: "unverified",
            layer: .semantic,
            kind: .semantic,
            scope: .user,
            verificationStatus: .unverified,
            retentionPolicy: .persistent
        ))

        let queue = try MemoryRetentionService().revalidationQueue(store: store)

        #expect(queue.map(\.id).sorted() == ["partial", "unverified"])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
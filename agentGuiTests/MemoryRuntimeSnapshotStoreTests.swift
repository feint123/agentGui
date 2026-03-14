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

    @Test func storePersistsEachSnapshotAsSeparateFileUnderSnapshotsDirectory() throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = MemoryRuntimeSnapshotStore(baseDirectory: baseDirectory)
        let snapshot = MemoryRuntimeSnapshot.fixture(id: "snapshot-per-file")

        try store.save(snapshot)

        let snapshotsDirectory = baseDirectory.appending(path: "snapshots", directoryHint: .isDirectory)
        let snapshotFile = snapshotsDirectory.appending(path: "snapshot-per-file.json")

        #expect(FileManager.default.fileExists(atPath: snapshotsDirectory.path))
        #expect(FileManager.default.fileExists(atPath: snapshotFile.path))
        #expect(FileManager.default.fileExists(atPath: baseDirectory.appending(path: "runtime-snapshots.json").path) == false)
    }

    @Test func storeReadsLegacyAggregateSnapshotFileWhenPerFileStoreIsEmpty() throws {
        let baseDirectory = try makeTemporaryDirectory()
        let legacyFile = baseDirectory.appending(path: "runtime-snapshots.json")
        let snapshot = MemoryRuntimeSnapshot.fixture(id: "legacy-snapshot")
        let encoder = JSONEncoder()
        let data = try encoder.encode([snapshot])

        try data.write(to: legacyFile, options: .atomic)

        let store = MemoryRuntimeSnapshotStore(baseDirectory: baseDirectory)

        let loaded = try store.snapshot(id: "legacy-snapshot")
        let snapshots = try store.allSnapshots()

        #expect(loaded?.id == "legacy-snapshot")
        #expect(snapshots.map(\ .id) == ["legacy-snapshot"])
    }

    @Test func latestSnapshotInMostRecentSessionReturnsNewestSnapshotWithoutLoadingAllHistoryIntoUI() throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = MemoryRuntimeSnapshotStore(baseDirectory: baseDirectory)

        try store.save(
            .fixture(
                id: "older-session-a",
                sessionId: "session-a",
                threadId: "thread-a",
                createdAt: Date(timeIntervalSince1970: 10)
            )
        )
        try store.save(
            .fixture(
                id: "newest-session-b",
                sessionId: "session-b",
                threadId: "thread-b",
                createdAt: Date(timeIntervalSince1970: 30)
            )
        )
        try store.save(
            .fixture(
                id: "middle-session-b",
                sessionId: "session-b",
                threadId: "thread-b",
                createdAt: Date(timeIntervalSince1970: 20)
            )
        )

        let snapshot = try store.latestSnapshotInMostRecentSession()

        #expect(snapshot?.id == "newest-session-b")
        #expect(snapshot?.sessionId == "session-b")
    }

    @Test func latestSnapshotInMostRecentSessionFallsBackToLegacyAggregateFile() throws {
        let baseDirectory = try makeTemporaryDirectory()
        let legacyFile = baseDirectory.appending(path: "runtime-snapshots.json")
        let encoder = JSONEncoder()
        let snapshots = [
            MemoryRuntimeSnapshot.fixture(
                id: "legacy-older",
                sessionId: "legacy-session-a",
                threadId: "thread-a",
                createdAt: Date(timeIntervalSince1970: 10)
            ),
            MemoryRuntimeSnapshot.fixture(
                id: "legacy-newest",
                sessionId: "legacy-session-b",
                threadId: "thread-b",
                createdAt: Date(timeIntervalSince1970: 30)
            )
        ]

        try encoder.encode(snapshots).write(to: legacyFile, options: .atomic)

        let store = MemoryRuntimeSnapshotStore(baseDirectory: baseDirectory)

        let snapshot = try store.latestSnapshotInMostRecentSession()

        #expect(snapshot?.id == "legacy-newest")
        #expect(snapshot?.sessionId == "legacy-session-b")
    }

    @Test func preferredSnapshotUsesBoundSnapshotBeforeGlobalLatest() throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = MemoryRuntimeSnapshotStore(baseDirectory: baseDirectory)

        try store.save(.fixture(
            id: "older-current",
            sessionId: "s1",
            toolCallId: "tool-1",
            createdAt: Date(timeIntervalSince1970: 100)
        ))
        try store.save(.fixture(
            id: "newer-other",
            sessionId: "s2",
            toolCallId: "tool-2",
            createdAt: Date(timeIntervalSince1970: 200)
        ))

        let snapshot = try store.preferredSnapshot(snapshotID: "older-current", toolCallID: nil)

        #expect(snapshot?.id == "older-current")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryGovernedWriteRoutingTests {
    @Test func hotPathWritePersistsDirectlyToUnifiedStore() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let coordinator = makeCoordinator(baseDirectory: baseDirectory)
        let candidate = MemoryCandidate.fixture(
            layer: .task,
            kind: .working,
            domainProfile: "coding-task",
            scope: .session(id: "routing-session"),
            confidence: 1.0,
            verificationStatus: .verified
        )

        let result = try await coordinator.applyGovernedWrite(candidate: candidate)

        guard case let .hotPath(writeResult) = result else {
            Issue.record("Expected hot-path persistence result")
            return
        }

        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        let records = try store.records(for: .session(id: "routing-session"), includeArchived: true)
        #expect(writeResult.record.id == candidate.id)
        #expect(records.contains { $0.id == candidate.id })
    }

    @Test func backgroundWriteQueuesAndEventuallyPersists() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let backgroundQueue = MemoryBackgroundWriteQueue(storeBaseDirectory: baseDirectory)
        let coordinator = makeCoordinator(baseDirectory: baseDirectory, backgroundQueue: backgroundQueue)
        let candidate = MemoryCandidate.fixture(
            layer: .semantic,
            kind: .semantic,
            domainProfile: "user-preferences",
            scope: .user,
            confidence: 0.9,
            verificationStatus: .verified
        )

        let result = try await coordinator.applyGovernedWrite(candidate: candidate)
        guard case let .backgroundQueued(recordID) = result else {
            Issue.record("Expected background queue result")
            return
        }

        #expect(recordID == candidate.id)
        await backgroundQueue.waitUntilIdle()

        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        let records = try store.records(for: .user, includeArchived: true)
        #expect(records.contains { $0.id == candidate.id })
    }

    @Test func archiveOnlyWritePersistsArchivedRecord() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let coordinator = makeCoordinator(baseDirectory: baseDirectory)
        let candidate = MemoryCandidate.fixture(
            layer: .semantic,
            kind: .semantic,
            domainProfile: "user-preferences",
            scope: .user,
            confidence: 0.55,
            verificationStatus: .partial
        )

        let result = try await coordinator.applyGovernedWrite(candidate: candidate)
        guard case .archived = result else {
            Issue.record("Expected archive result")
            return
        }

        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        #expect(try store.records(for: .user).isEmpty)
        let archived = try store.records(for: .user, includeArchived: true)
        #expect(archived.first?.retentionPolicy == .archiveOnly)
    }

    @Test func confirmationRequiredWritesCandidateToPendingStore() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let coordinator = makeCoordinator(baseDirectory: baseDirectory)
        let candidate = MemoryCandidate.fixture(
            layer: .semantic,
            kind: .semantic,
            domainProfile: "creative-writing",
            scope: .project(id: "story-project"),
            confidence: 0.45,
            verificationStatus: .unverified
        )

        let result = try await coordinator.applyGovernedWrite(candidate: candidate)
        guard case let .confirmationRequired(confirmation) = result else {
            Issue.record("Expected confirmation-required result")
            return
        }

        let store = MemoryConfirmationStore(baseDirectory: baseDirectory)
        let pending = try store.load()
        #expect(pending.contains { $0.id == confirmation.id })
    }

    private func makeCoordinator(
        baseDirectory: URL,
        backgroundQueue: MemoryBackgroundWriteQueue? = nil
    ) -> MemoryRuntimeCoordinator {
        MemoryRuntimeCoordinator(
            taskRecordsProvider: { _ in [] },
            storyRecordsProvider: { _ in [] },
            unifiedRecordsProvider: { _ in [] },
            unifiedStoreBaseDirectory: baseDirectory,
            backgroundWriteQueue: backgroundQueue,
            confirmationStore: MemoryConfirmationStore(baseDirectory: baseDirectory)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
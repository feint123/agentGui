import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryConfirmationWorkflowServiceTests {
    @Test func confirmationCandidateSupportsPendingApprovedAndRejectedStates() async throws {
        let candidate = MemoryConfirmationCandidate(
            candidateID: "cand-1",
            domainProfile: "creative-writing",
            scope: .project(id: "p1"),
            title: "Possible canon",
            summary: "Speculative summary",
            proposedRecord: UnifiedMemoryStoredRecord(record: MemoryRecord.fixture(id: "r1")),
            reason: "Needs confirmation"
        )

        #expect(candidate.status == .pending)
        #expect(candidate.finalRecordID == nil)
        #expect(candidate.rejectionReason == nil)
    }

    @Test func approvingConfirmationPersistsRecordAndMarksCandidateApproved() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = MemoryConfirmationStore(baseDirectory: baseDirectory)
        let candidate = MemoryConfirmationCandidate(
            candidateID: "cand-approve",
            domainProfile: "coding-task",
            scope: .session(id: "s1"),
            title: "Build uses xcodebuild",
            summary: "Build uses xcodebuild",
            proposedRecord: UnifiedMemoryStoredRecord(
                record: MemoryRecord.fixture(
                    id: "approved-record",
                    layer: .task,
                    kind: .working,
                    scope: .session(id: "s1"),
                    title: "Build uses xcodebuild"
                )
            ),
            reason: "Needs confirmation"
        )
        try store.append(candidate)

        let service = MemoryConfirmationWorkflowService(baseDirectory: baseDirectory)
        let result = try await service.approve(candidateID: candidate.id)

        #expect(result.status == .approved)
        #expect(result.finalRecordID == "approved-record")

        let persisted = try UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
            .records(for: .session(id: "s1"), includeArchived: true)
        #expect(persisted.contains { $0.id == "approved-record" })
    }

    @Test func rejectingConfirmationDoesNotPersistLiveRecord() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = MemoryConfirmationStore(baseDirectory: baseDirectory)
        let candidate = MemoryConfirmationCandidate(
            candidateID: "cand-reject",
            domainProfile: "creative-writing",
            scope: .project(id: "p1"),
            title: "Possible canon",
            summary: "Speculative summary",
            proposedRecord: UnifiedMemoryStoredRecord(record: MemoryRecord.fixture(id: "rejected-record", scope: .project(id: "p1"))),
            reason: "Needs confirmation"
        )
        try store.append(candidate)

        let service = MemoryConfirmationWorkflowService(baseDirectory: baseDirectory)
        let result = try service.reject(candidateID: candidate.id, reason: "User rejected")

        #expect(result.status == .rejected)
        #expect(result.rejectionReason == "User rejected")

        let persisted = try UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
            .records(for: .project(id: "p1"), includeArchived: true)
        #expect(!persisted.contains { $0.id == "rejected-record" })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
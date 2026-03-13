import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryGovernanceServiceTests {
    @Test func verifiedCodingCandidateIsAcceptedForHotPathWrite() async throws {
        let service = MemoryGovernanceService(
            policy: DefaultMemoryAdmissionPolicy(),
            featureExtractor: MemoryAdmissionFeatureExtractor()
        )
        let candidate = MemoryCandidate.fixture(
            layer: .task,
            kind: .working,
            domainProfile: "coding-task",
            confidence: 1.0,
            verificationStatus: .verified
        )

        let evaluation = service.evaluate(candidate)
        #expect(evaluation.route == .acceptHotPath)
        #expect(evaluation.explanation?.score.route == .hotPath)
    }

    @Test func speculativeCreativeSemanticCandidateNeedsConfirmation() async throws {
        let service = MemoryGovernanceService(
            policy: DefaultMemoryAdmissionPolicy(),
            featureExtractor: MemoryAdmissionFeatureExtractor()
        )
        let candidate = MemoryCandidate.fixture(
            layer: .semantic,
            kind: .semantic,
            domainProfile: "creative-writing",
            confidence: 0.45,
            verificationStatus: .unverified
        )

        let evaluation = service.evaluate(candidate)
        #expect(evaluation.route == .needsUserConfirmation)
        #expect(evaluation.explanation?.score.route == .confirmation)
    }

    @Test func lowConfidenceCandidateIsRejected() async throws {
        let service = MemoryGovernanceService(
            policy: DefaultMemoryAdmissionPolicy(),
            featureExtractor: MemoryAdmissionFeatureExtractor()
        )
        let candidate = MemoryCandidate.fixture(
            domainProfile: "user-preferences",
            confidence: 0.2,
            verificationStatus: .unverified
        )

        let evaluation = service.evaluate(candidate)
        #expect(evaluation.route == .reject)
        #expect(evaluation.explanation?.score.route == .reject)
    }

    @Test func governanceServiceUsesPolicyAndPersistsExplanation() async throws {
        let service = MemoryGovernanceService(
            policy: DefaultMemoryAdmissionPolicy(),
            featureExtractor: MemoryAdmissionFeatureExtractor()
        )
        let candidate = MemoryCandidate.fixture(
            layer: .task,
            kind: .working,
            domainProfile: "coding-task",
            confidence: 0.96,
            verificationStatus: .verified
        )

        let evaluation = service.evaluate(candidate)

        #expect(evaluation.explanation != nil)
        #expect(evaluation.route == .acceptHotPath)
        #expect((evaluation.explanation?.featureVector.taskRelevance ?? 0) > 0)
    }

    @Test func governanceRouteEmitsStructuredLogs() async throws {
        let sink = InMemoryBusinessLogSink()
        let service = MemoryGovernanceService(
            policy: DefaultMemoryAdmissionPolicy(),
            featureExtractor: MemoryAdmissionFeatureExtractor(),
            businessLogSink: sink
        )
        let baseDirectory = try makeTemporaryDirectory()
        let candidate = MemoryCandidate.fixture(
            id: "candidate-1",
            layer: .task,
            kind: .working,
            domainProfile: "coding-task",
            scope: .session(id: "s1"),
            confidence: 1.0,
            verificationStatus: .verified
        )

        _ = try await service.route(
            candidate,
            store: UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory),
            backgroundQueue: MemoryBackgroundWriteQueue(storeBaseDirectory: baseDirectory),
            confirmationStore: MemoryConfirmationStore(baseDirectory: baseDirectory)
        )

        #expect(sink.events.contains { $0.event == .memoryWriteEvaluated })
        #expect(sink.events.contains { entry in
            entry.event == .memoryWriteRouted &&
            (entry.metadata["route"] as? String) == "acceptHotPath"
        })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
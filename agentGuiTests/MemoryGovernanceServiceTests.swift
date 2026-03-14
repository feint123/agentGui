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
            title: "Verify shared scheme before editing",
            summary: "Run xcodebuild -list to confirm the shared scheme before changing project files",
            confidence: 1.0,
            verificationStatus: .verified,
            sourceRefs: [.init(kind: "tool", identifier: "tool-1")],
            tags: ["tactic-kernel"]
        )

        let evaluation = service.evaluate(candidate)
        #expect(evaluation.route == .acceptHotPath)
        #expect(evaluation.explanation?.score.route == .hotPath)
        #expect(evaluation.explanation?.assessment.decisionDelta.passes == true)
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
            title: "Preserve north tower curfew",
            summary: "Always verify the north tower curfew before resolving the scene",
            confidence: 0.45,
            verificationStatus: .unverified,
            sourceRefs: [.init(kind: "message", identifier: "user-1")],
            tags: ["constraint"]
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
            title: "README subtitle",
            summary: "README has a subtitle",
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
            title: "Verify shared scheme before editing",
            summary: "Run xcodebuild -list to confirm the shared scheme before changing project files",
            confidence: 0.96,
            verificationStatus: .verified,
            sourceRefs: [.init(kind: "tool", identifier: "tool-1")],
            tags: ["tactic-kernel"]
        )

        let evaluation = service.evaluate(candidate)

        #expect(evaluation.explanation != nil)
        #expect(evaluation.route == .acceptHotPath)
        #expect((evaluation.explanation?.featureVector.decisionDelta ?? 0) > 0)
        #expect(evaluation.explanation?.reasons.contains { $0.contains("decision delta") } == true)
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
            title: "Verify shared scheme before editing",
            summary: "Run xcodebuild -list to confirm the shared scheme before changing project files",
            confidence: 1.0,
            verificationStatus: .verified,
            sourceRefs: [.init(kind: "tool", identifier: "tool-1")],
            tags: ["tactic-kernel"]
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
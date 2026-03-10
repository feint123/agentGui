import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryGovernanceServiceTests {
    @Test func verifiedCodingCandidateIsAcceptedForHotPathWrite() async throws {
        let service = MemoryGovernanceService()
        let candidate = MemoryCandidate.fixture(
            layer: .task,
            kind: .working,
            domainProfile: "coding-task",
            confidence: 1.0,
            verificationStatus: .verified
        )

        #expect(service.evaluate(candidate) == .acceptHotPath)
    }

    @Test func speculativeCreativeSemanticCandidateNeedsConfirmation() async throws {
        let service = MemoryGovernanceService()
        let candidate = MemoryCandidate.fixture(
            layer: .semantic,
            kind: .semantic,
            domainProfile: "creative-writing",
            confidence: 0.45,
            verificationStatus: .unverified
        )

        #expect(service.evaluate(candidate) == .needsUserConfirmation)
    }

    @Test func lowConfidenceCandidateIsRejected() async throws {
        let service = MemoryGovernanceService()
        let candidate = MemoryCandidate.fixture(
            domainProfile: "user-preferences",
            confidence: 0.2,
            verificationStatus: .unverified
        )

        #expect(service.evaluate(candidate) == .reject)
    }
}
import Foundation
import Testing
@testable import agentGui

struct EpistemicStateCoordinatorTests {
    @Test func coordinatorBuildsEpistemicStateFromExtractionOutput() async throws {
        let service = EpistemicExtractionService { _ in
            #"""
            {
              "objects": [
                {
                  "kind": "frontier",
                  "id": "f-1",
                  "summary": "Need to verify shared scheme",
                  "source_refs": ["message:user:0"],
                  "decision_delta": "Run xcodebuild -list",
                  "evidence_level": "partial"
                },
                {
                  "kind": "constraint",
                  "id": "c-1",
                  "summary": "Inspect before editing",
                  "source_refs": ["message:assistant:1"],
                  "decision_delta": "Avoid edit-first path",
                  "evidence_level": "verified"
                }
              ],
              "rejected": [],
              "missingEvidence": ["xcodebuild -list output"],
              "decisionImpactNote": "inspect first"
            }
            """#
        }
        let coordinator = EpistemicStateCoordinator(extractionService: service)

        let result = try await coordinator.buildState(
            from: [
                EpistemicInputEnvelope(
                    sessionID: "s1",
                    roundIndex: 1,
                    userAgentMessages: ["Fix build"],
                    toolObservations: ["scheme not shared"]
                )
            ]
        )

        #expect(result.state.frontiers.count == 1)
        #expect(result.state.frontiers.first?.openClaim == "Need to verify shared scheme")
        #expect(result.state.activeConstraints.count == 1)
        #expect(result.state.verificationDebt.count == 1)
        #expect(result.state.candidateActions == ["Run xcodebuild -list"])
        #expect(result.influenceTrace.activatedMemoryIDs.contains("f-1"))
    }
}
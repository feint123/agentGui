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

    @Test func coordinatorRunsEventFrontierCounterexampleAndConstraintStages() async throws {
      let service = EpistemicExtractionService(
        extractEvents: { _, _ in
          EpistemicExtractionOutput(
            objects: [
              EpistemicObjectCandidate(
                kind: .atomicEvent,
                id: "event-1",
                summary: "Shared scheme may be missing",
                sourceRefs: ["tool:bash:1"],
                decisionDelta: "Inspect scheme configuration",
                evidenceLevel: .partial
              )
            ],
            rejected: [],
            missingEvidence: [],
            decisionImpactNote: "structured event extraction"
          )
        },
        synthesizeFrontiers: { _, _ in
          EpistemicExtractionOutput(
            objects: [
              EpistemicObjectCandidate(
                kind: .frontier,
                id: "frontier-1",
                summary: "Need to verify shared scheme",
                sourceRefs: ["tool:bash:1"],
                decisionDelta: "Run xcodebuild -list",
                evidenceLevel: .partial
              )
            ],
            rejected: [],
            missingEvidence: [],
            decisionImpactNote: "frontier synthesis"
          )
        },
        extractCounterexamples: { _, _ in
          EpistemicExtractionOutput(
            objects: [
              EpistemicObjectCandidate(
                kind: .counterexample,
                id: "counterexample-1",
                summary: "Running the full suite before checking the scheme repeats the failure",
                sourceRefs: ["tool:bash:2"],
                decisionDelta: "Inspect shared scheme before rerunning tests",
                evidenceLevel: .verified
              )
            ],
            rejected: [],
            missingEvidence: [],
            decisionImpactNote: "counterexample extraction"
          )
        },
        extractConstraintsAndDebt: { _, _ in
          EpistemicExtractionOutput(
            objects: [
              EpistemicObjectCandidate(
                kind: .constraint,
                id: "constraint-1",
                summary: "Inspect before editing implementation",
                sourceRefs: ["message:user:0"],
                decisionDelta: "",
                evidenceLevel: .verified
              ),
              EpistemicObjectCandidate(
                kind: .verificationDebt,
                id: "debt-1",
                summary: "Build fix is still unverified",
                sourceRefs: ["message:user:0"],
                decisionDelta: "Run the targeted test after inspection",
                evidenceLevel: .partial
              )
            ],
            rejected: [],
            missingEvidence: [],
            decisionImpactNote: "constraint and debt extraction"
          )
        }
      )

        let result = try await EpistemicStateCoordinator(extractionService: service)
            .buildState(from: [
                EpistemicInputEnvelope(
                    sessionID: "s1",
                    roundIndex: 1,
                    userAgentMessages: ["Fix build before editing implementation"],
                    toolObservations: ["xcodebuild failed because the shared scheme is missing"]
                )
            ])

            let state = await result.state
            let influenceTrace = await result.influenceTrace

            #expect(state.frontiers.first?.openClaim == "Need to verify shared scheme")
            #expect(state.counterexamples.first?.summary == "Running the full suite before checking the scheme repeats the failure")
            #expect(state.activeConstraints.first?.summary == "Inspect before editing implementation")
            #expect(state.verificationDebt.contains { $0.claim == "Build fix is still unverified" })
            #expect(influenceTrace.rankedActionIDs == ["Run xcodebuild -list"])
            #expect(influenceTrace.blockedActionIDs == ["Running the full suite before checking the scheme repeats the failure"])
    }
}
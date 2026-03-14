import Foundation
import Testing
@testable import agentGui

struct EpistemicExtractionPromptBuilderTests {
    @Test func eventExtractionPromptIncludesSchemaAndChainOfThoughtGuard() throws {
        let prompt = EpistemicEventExtractionPromptBuilder().build(
            envelope: EpistemicInputEnvelope(
                sessionID: "s1",
                roundIndex: 2,
                userAgentMessages: ["Fix the failing build", "I will inspect the scheme"],
                toolObservations: ["xcodebuild failed: scheme not shared"]
            ),
            epistemicState: EpistemicState()
        )

        #expect(prompt.contains("objects"))
        #expect(prompt.contains("source_refs"))
        #expect(prompt.contains("decision_delta"))
        #expect(prompt.contains("Example JSON"))
        #expect(prompt.contains("\"objects\": ["))
        #expect(prompt.contains("\"rejected\": ["))
        #expect(prompt.contains("\"missingEvidence\": ["))
        #expect(prompt.contains("All keys must be present"))
        #expect(prompt.contains("Do not output chain-of-thought"))
    }

    @Test func frontierSynthesisPromptReferencesCurrentStateAndEvents() throws {
        let prompt = FrontierSynthesisPromptBuilder().build(
            events: [
                AtomicEpistemicEvent(
                    kind: .claimRaised,
                    summary: "Shared scheme may be missing",
                    sourceRefs: ["message:assistant:1"]
                )
            ],
            epistemicState: EpistemicState(
                candidateActions: ["Run xcodebuild -list"]
            )
        )

        #expect(prompt.contains("Shared scheme may be missing"))
        #expect(prompt.contains("Run xcodebuild -list"))
        #expect(prompt.contains("frontier"))
        #expect(prompt.contains("Return ONLY valid JSON"))
        #expect(prompt.contains("Example JSON"))
        #expect(prompt.contains("\"kind\": \"frontier\""))
    }

    @Test func counterexamplePromptIncludesExplicitJsonContractAndExample() throws {
        let prompt = CounterexampleExtractionPromptBuilder().build(
            events: [
                AtomicEpistemicEvent(
                    kind: .observationReceived,
                    summary: "Running tests before checking the shared scheme failed",
                    sourceRefs: ["tool:bash:1"]
                )
            ],
            epistemicState: EpistemicState(
                counterexamples: [
                    CounterexampleMemory(id: "ce-1", summary: "Do not edit before inspect", replacementAction: "Inspect first")
                ]
            )
        )

        #expect(prompt.contains("Return ONLY valid JSON"))
        #expect(prompt.contains("Example JSON"))
        #expect(prompt.contains("\"kind\": \"counterexample\""))
        #expect(prompt.contains("\"replacementAction\""))
        #expect(prompt.contains("\"evidence_level\""))
    }

    @Test func constraintDebtPromptIncludesSeparateExamplesForConstraintAndDebt() throws {
        let prompt = ConstraintDebtExtractionPromptBuilder().build(
            envelope: EpistemicInputEnvelope(
                sessionID: "s1",
                roundIndex: 2,
                userAgentMessages: ["Run a targeted test before editing implementation"],
                toolObservations: []
            ),
            epistemicState: EpistemicState(
                verificationDebt: [
                    VerificationDebt(id: "d-1", claim: "Build fix works", reason: "No direct test evidence yet")
                ]
            )
        )

        #expect(prompt.contains("Return ONLY valid JSON"))
        #expect(prompt.contains("Example JSON"))
        #expect(prompt.contains("\"kind\": \"constraint\""))
        #expect(prompt.contains("\"kind\": \"verificationDebt\""))
        #expect(prompt.contains("Use empty arrays when there are no items"))
    }

    @Test func promptBuildersUseStableEpistemicSnapshotBeforeRendering() throws {
        let state = EpistemicState(
            frontiers: [
                FrontierMemory(
                    frontierId: " f-1 ",
                    goal: " Fix build ",
                    openClaim: " Need scheme evidence ",
                    uncertaintyType: .tooling,
                    impactLevel: .high,
                    suggestedProbe: " Run xcodebuild -list ",
                    stopCondition: " Scheme confirmed "
                ),
                FrontierMemory(
                    frontierId: "f-blank",
                    goal: "Fix build",
                    openClaim: "   ",
                    uncertaintyType: .tooling,
                    impactLevel: .medium,
                    suggestedProbe: "Ignore",
                    stopCondition: "Ignore"
                )
            ],
            activeConstraints: [
                ConstraintMemory(id: " c-1 ", summary: " Inspect before editing ", scope: .session(id: "s1")),
                ConstraintMemory(id: "c-blank", summary: "   ", scope: .session(id: "s1"))
            ],
            candidateActions: [" Run xcodebuild -list ", "   "],
            verificationDebt: [
                VerificationDebt(id: " d-1 ", claim: " Build fix works ", reason: " No direct evidence yet "),
                VerificationDebt(id: "d-blank", claim: "   ", reason: "ignored")
            ],
            counterexamples: [
                CounterexampleMemory(id: " ce-1 ", summary: " Avoid edit-first loop ", replacementAction: " Inspect first "),
                CounterexampleMemory(id: "ce-blank", summary: "   ", replacementAction: "ignored")
            ]
        )

        let eventPrompt = EpistemicEventExtractionPromptBuilder().build(
            envelope: EpistemicInputEnvelope(sessionID: "s1", roundIndex: 1),
            epistemicState: state
        )
        let frontierPrompt = FrontierSynthesisPromptBuilder().build(events: [], epistemicState: state)
        let counterexamplePrompt = CounterexampleExtractionPromptBuilder().build(events: [], epistemicState: state)
        let debtPrompt = ConstraintDebtExtractionPromptBuilder().build(
            envelope: EpistemicInputEnvelope(sessionID: "s1", roundIndex: 1),
            epistemicState: state
        )

        #expect(eventPrompt.contains("frontiers: Need scheme evidence"))
        #expect(!eventPrompt.contains(" |  | "))
        #expect(frontierPrompt.contains("- Run xcodebuild -list"))
        #expect(!frontierPrompt.contains("-    "))
        #expect(counterexamplePrompt.contains("- Avoid edit-first loop"))
        #expect(!counterexamplePrompt.contains("ignored"))
        #expect(debtPrompt.contains("- Build fix works: No direct evidence yet"))
        #expect(!debtPrompt.contains("ignored"))
    }
}
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
    }
}
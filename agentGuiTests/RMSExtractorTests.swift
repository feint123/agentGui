import Foundation
import Testing
@testable import agentGui

struct RMSExtractorTests {

    @Test func extractorProducesSupportedInsightKindsWithEvidenceRefs() {
        let envelope = EpistemicInputEnvelope(
            sessionID: "session-1",
            roundIndex: 3,
            userAgentMessages: ["Fix the smoke failure"],
            toolObservations: ["xcodebuild failed before the shared scheme was confirmed"],
            events: [
                .init(kind: .constraintDeclared, summary: "Inspect before editing", sourceRefs: ["round:3"]),
                .init(kind: .actionProposed, summary: "Run targeted xcodebuild test", sourceRefs: ["round:3"]),
                .init(kind: .observationReceived, summary: "Prior edit-first attempt regressed the build", sourceRefs: ["round:3", "counterexample"])
            ]
        )

        let result = RMSExtractor().extract(existing: RMSState.fixture(summary: "Fix smoke"), envelope: envelope)

        #expect(result.proposals.map(\.insight.kind) == [.constraint, .tactic, .counterexample])
        #expect(result.proposals.first?.insight.evidenceRefs == ["round:3"])
        #expect(result.proposals.last?.insight.evidenceRefs == ["round:3", "counterexample"])
    }

    @Test func extractorIgnoresNonReusableSignals() {
        let envelope = EpistemicInputEnvelope(
            sessionID: "session-1",
            roundIndex: 1,
            userAgentMessages: ["Fix smoke failure"],
            events: [
                .init(kind: .claimRaised, summary: "Need current build evidence", sourceRefs: ["round:1"]),
                .init(kind: .observationReceived, summary: "Collected direct output", sourceRefs: ["round:1"])
            ]
        )

        let result = RMSExtractor().extract(existing: nil, envelope: envelope)

        #expect(result.proposals.isEmpty)
    }
}
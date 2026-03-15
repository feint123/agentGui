import Foundation
import Testing
@testable import agentGui

struct RMSStateReducerTests {

    @Test func reducerBuildsTaskBoundStateFromEnvelope() {
        let reducer = RMSStateReducer()
        let envelope = EpistemicInputEnvelope(
            sessionID: "session-1",
            roundIndex: 3,
            userAgentMessages: ["Fix smoke failure", "Observed current build output"],
            toolObservations: ["xcodebuild reported missing shared scheme"],
            events: [
                .init(kind: .claimRaised, summary: "Need to confirm shared scheme", sourceRefs: ["round:3"]),
                .init(kind: .actionProposed, summary: "Run xcodebuild -list", sourceRefs: ["round:3"]),
                .init(kind: .constraintDeclared, summary: "Inspect before editing", sourceRefs: ["round:3"]),
                .init(kind: .observationReceived, summary: "Prior edit-first attempt regressed the build", sourceRefs: ["round:3", "counterexample"])
            ]
        )

        let state = reducer.reduce(existing: nil, envelope: envelope)

        #expect(state?.summary == "Fix smoke failure")
        #expect(state?.frontiers.first?.openClaim == "Need to confirm shared scheme")
        #expect(state?.frontiers.first?.suggestedProbe == "Run xcodebuild -list")
        #expect(state?.constraints.first?.summary == "Inspect before editing")
        #expect(state?.counterexamples.first?.summary == "Prior edit-first attempt regressed the build")
        #expect(state?.candidateActions == ["Run xcodebuild -list"])
    }
}
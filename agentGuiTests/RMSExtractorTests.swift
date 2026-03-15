import Foundation
import Testing
@testable import agentGui

struct RMSExtractorTests {

    @Test func extractorProducesStateDeltaForTaskBoundCognition() async throws {
        let envelope = EpistemicInputEnvelope(
            sessionID: "session-1",
            roundIndex: 3,
            userAgentMessages: ["Fix the smoke failure"],
            toolObservations: ["xcodebuild reported missing shared scheme"],
            events: [
                .init(kind: .claimRaised, summary: "Need to confirm shared scheme", sourceRefs: ["round:3"]),
                .init(kind: .actionProposed, summary: "Run xcodebuild -list", sourceRefs: ["round:3"]),
                .init(kind: .constraintDeclared, summary: "Inspect before editing", sourceRefs: ["round:3"]),
                .init(kind: .observationReceived, summary: "Prior edit-first attempt regressed the build", sourceRefs: ["round:3", "counterexample"]),
                .init(kind: .claimResolved, summary: "Shared scheme confirmed", sourceRefs: ["round:3"])
            ]
        )

        let rawContentStore = RMSRawContentStore(baseDirectory: try makeTemporaryDirectory())
        let result = try await RMSExtractor(rawContentStore: rawContentStore).extract(
            existing: nil,
            envelope: envelope,
            generator: StubRMSInsightGenerator(
                generatedStateDelta: RMSStateDelta(
                    summary: "Smoke failure triage",
                    summarySourceFilePath: nil,
                    frontiers: [
                        RMSFrontier(
                            id: "frontier-llm-1",
                            goal: "Stabilize smoke build",
                            openClaim: "Shared scheme still unverified",
                            suggestedProbe: "Run xcodebuild -list",
                            stopCondition: "Scheme confirmed"
                        )
                    ],
                    constraints: [
                        RMSConstraint(
                            id: "constraint-llm-1",
                            summary: "Inspect before editing",
                            scope: .session(id: "session-1")
                        )
                    ],
                    counterexamples: [
                        RMSCounterexample(
                            id: "counterexample-llm-1",
                            summary: "Edit-first caused regression",
                            replacementAction: "Read failure output first"
                        )
                    ],
                    verificationDebts: [
                        RMSVerificationDebt(
                            id: "debt-llm-1",
                            claim: "Shared scheme status is still missing direct evidence",
                            reason: "Need a targeted probe"
                        )
                    ],
                    candidateActions: ["Run xcodebuild -list"],
                    stopSignals: ["Scheme confirmed"]
                ),
                optionalInsightsByContent: [:]
            )
        )

        #expect(result.delta.summary == "Smoke failure triage")
        #expect(result.delta.frontiers.first?.openClaim == "Shared scheme still unverified")
        #expect(result.delta.frontiers.first?.suggestedProbe == "Run xcodebuild -list")
        #expect(result.delta.constraints.first?.summary == "Inspect before editing")
        #expect(result.delta.counterexamples.first?.summary == "Edit-first caused regression")
        #expect(result.delta.verificationDebts.first?.claim == "Shared scheme status is still missing direct evidence")
        #expect(result.delta.candidateActions == ["Run xcodebuild -list"])
        #expect(result.delta.stopSignals == ["Scheme confirmed"])
        #expect(result.delta.summarySourceFilePath != nil)
        let deltaPath = try #require(result.delta.summarySourceFilePath)
        #expect(FileManager.default.fileExists(atPath: deltaPath))
    }

    @Test func extractorFallsBackToHeuristicDeltaWhenGeneratorSkipsStateDelta() async throws {
        let envelope = EpistemicInputEnvelope(
            sessionID: "session-1",
            roundIndex: 3,
            userAgentMessages: ["Fix the smoke failure"],
            toolObservations: ["xcodebuild reported missing shared scheme"],
            events: [
                .init(kind: .claimRaised, summary: "Need to confirm shared scheme", sourceRefs: ["round:3"]),
                .init(kind: .actionProposed, summary: "Run xcodebuild -list", sourceRefs: ["round:3"]),
                .init(kind: .claimResolved, summary: "Shared scheme confirmed", sourceRefs: ["round:3"])
            ]
        )

        let rawContentStore = RMSRawContentStore(baseDirectory: try makeTemporaryDirectory())
        let result = try await RMSExtractor(rawContentStore: rawContentStore).extract(
            existing: nil,
            envelope: envelope,
            generator: StubRMSInsightGenerator(generatedStateDelta: nil, optionalInsightsByContent: [:])
        )

        #expect(result.delta.summary == "Fix the smoke failure")
        #expect(result.delta.frontiers.first?.openClaim == "Need to confirm shared scheme")
        #expect(result.delta.stopSignals == ["Shared scheme confirmed"])
        #expect(result.delta.summarySourceFilePath != nil)
    }

    @Test func extractorProducesGeneratedInsightsWithEvidenceRefs() async throws {
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
        let generator = StubRMSInsightGenerator(optionalInsightsByContent: [
            "Inspect before editing": .constraint(
                id: "constraint-1",
                summary: "Inspect before editing",
                appliesWhen: "coding",
                changesDecision: "block speculative edits",
                evidenceRefs: ["round:3"],
                scope: .session(id: "session-1"),
                confidence: 0.95
            ),
            "Run targeted xcodebuild test": .tactic(
                id: "tactic-1",
                summary: "Run targeted xcodebuild test",
                appliesWhen: "xcodebuild",
                changesDecision: "narrow verification scope",
                evidenceRefs: ["round:3"],
                scope: .session(id: "session-1"),
                confidence: 0.8
            ),
            "Prior edit-first attempt regressed the build": .counterexample(
                id: "counterexample-1",
                summary: "Prior edit-first attempt regressed the build",
                appliesWhen: "coding",
                changesDecision: "avoid repeating the falsified path",
                replacementAction: "Inspect current state before acting",
                evidenceRefs: ["round:3", "counterexample"],
                scope: .session(id: "session-1"),
                confidence: 0.9
            )
        ])

        let rawContentStore = RMSRawContentStore(baseDirectory: try makeTemporaryDirectory())
        let result = try await RMSExtractor(rawContentStore: rawContentStore).extract(
            existing: RMSState.fixture(summary: "Fix smoke"),
            envelope: envelope,
            generator: generator
        )

        #expect(result.proposals.map(\.insight.kind) == [.constraint, .tactic, .counterexample])
        #expect(result.proposals.first?.insight.evidenceRefs == ["round:3"])
        #expect(result.proposals.last?.insight.evidenceRefs == ["round:3", "counterexample"])
        #expect(result.proposals.allSatisfy { $0.insight.rawContentFilePath != nil })
    }

    @Test func extractorIgnoresSignalsDiscardedByGenerator() async throws {
        let envelope = EpistemicInputEnvelope(
            sessionID: "session-1",
            roundIndex: 1,
            userAgentMessages: ["Fix smoke failure"],
            events: [
                .init(kind: .claimRaised, summary: "Need current build evidence", sourceRefs: ["round:1"]),
                .init(kind: .observationReceived, summary: "Collected direct output", sourceRefs: ["round:1"])
            ]
        )
        let generator = StubRMSInsightGenerator(optionalInsightsByContent: [:])

        let result = try await RMSExtractor().extract(existing: nil, envelope: envelope, generator: generator)

        #expect(result.proposals.isEmpty)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private struct StubRMSInsightGenerator: RMSInsightGenerating {
    var generatedStateDelta: RMSStateDelta?
    var optionalInsightsByContent: [String: RMSInsight]

    init(
        generatedStateDelta: RMSStateDelta? = nil,
        optionalInsightsByContent: [String: RMSInsight]
    ) {
        self.generatedStateDelta = generatedStateDelta
        self.optionalInsightsByContent = optionalInsightsByContent
    }

    func generateStateDelta(
        existing: RMSState?,
        envelope: EpistemicInputEnvelope,
        updatedAt: Date
    ) async throws -> RMSStateDelta? {
        _ = existing
        _ = envelope
        _ = updatedAt
        return generatedStateDelta
    }

    func generateRequiredInsight(
        id: String,
        content: String,
        normalizedTitle: String,
        scope: MemoryScope,
        updatedAt: Date
    ) async throws -> RMSInsight {
        RMSInsight.constraint(
            id: id,
            summary: content,
            appliesWhen: normalizedTitle,
            changesDecision: "apply the remembered constraint before taking the next action",
            evidenceRefs: ["tool:memory_write"],
            scope: scope,
            confidence: 0.8
        )
    }

    func generateOptionalInsight(
        id: String,
        content: String,
        envelope: EpistemicInputEnvelope,
        event: AtomicEpistemicEvent,
        scope: MemoryScope,
        updatedAt: Date
    ) async throws -> RMSInsight? {
        _ = envelope
        _ = event
        _ = scope
        _ = updatedAt
        return optionalInsightsByContent[content]
    }
}
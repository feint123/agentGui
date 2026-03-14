import Foundation
import SwiftAnthropic

private actor AnthropicPromptExecutor {
    let service: any AnthropicService
    let modelId: String

    init(service: any AnthropicService, modelId: String) {
        self.service = service
        self.modelId = modelId
    }

    func execute(prompt: String) async throws -> String {
        let response = try await service.createMessage(
            MessageParameter(
                model: .other(modelId),
                messages: [MessageParameter.Message(role: .user, content: .text(prompt))],
                maxTokens: 2048
            )
        )
        return response.content.compactMap { block -> String? in
            if case .text(let text, _) = block { return text }
            return nil
        }.joined()
    }
}

struct EpistemicStateBuildResult {
    var state: EpistemicState
    var influenceTrace: MemoryInfluenceTrace
    var usedFallbackExtraction: Bool
    var fallbackReasons: [String]
}

struct EpistemicStateCoordinator {
    let extractionService: EpistemicExtractionService
    private let reducer = EpistemicStateReducer()

    private struct FallbackExtractionError: Error {}

    init(extractionService: EpistemicExtractionService) {
        self.extractionService = extractionService
    }

    init(service: any AnthropicService, modelId: String) {
        let executor = AnthropicPromptExecutor(service: service, modelId: modelId)
        self.init(extractionService: EpistemicExtractionService { prompt in
            try await executor.execute(prompt: prompt)
        })
    }

    static func fallbackOnly() -> EpistemicStateCoordinator {
        EpistemicStateCoordinator(
            extractionService: EpistemicExtractionService { _ in
                throw FallbackExtractionError()
            }
        )
    }

    func buildState(
        from envelopes: [EpistemicInputEnvelope],
        initialState: EpistemicState = EpistemicState(),
        initialInfluenceTrace: MemoryInfluenceTrace = MemoryInfluenceTrace()
    ) async throws -> EpistemicStateBuildResult {
        var state = initialState.stableSnapshot()
        var trace = initialInfluenceTrace
        var usedFallbackExtraction = false
        var fallbackReasons: [String] = []

        for envelope in envelopes {
            let eventOutput: EpistemicExtractionOutput
            do {
                eventOutput = try await extractionService.extractEvents(from: envelope, state: state.stableSnapshot())
            } catch {
                let reason = fallbackReason(
                    for: "event extraction",
                    roundIndex: envelope.roundIndex,
                    error: error
                )
                usedFallbackExtraction = true
                appendFallbackReason(reason, to: &fallbackReasons)
                eventOutput = fallbackExtractionOutput(from: envelope)
            }

            let eventReduced = reducer.reduce(eventOutput, into: state, influenceTrace: trace)
            state = eventReduced.state.stableSnapshot()
            trace = eventReduced.influenceTrace

            let extractedEvents = envelope.events + atomicEvents(from: eventOutput)

            if !extractedEvents.isEmpty {
                let frontierStage = await stageOutput(
                    stageName: "frontier synthesis",
                    roundIndex: envelope.roundIndex,
                    operation: {
                        try await extractionService.synthesizeFrontiers(from: extractedEvents, state: state.stableSnapshot())
                    },
                    fallback: {
                        scopedFallbackOutput(
                            from: envelope,
                            allowedKinds: [.frontier],
                            note: "Fallback frontier synthesis used because structured model extraction failed"
                        )
                    }
                )
                if let reason = frontierStage.fallbackReason {
                    usedFallbackExtraction = true
                    appendFallbackReason(reason, to: &fallbackReasons)
                }
                let frontierOutput = frontierStage.output
                let frontierReduced = reducer.reduce(frontierOutput, into: state, influenceTrace: trace)
                state = frontierReduced.state.stableSnapshot()
                trace = frontierReduced.influenceTrace

                let counterexampleStage = await stageOutput(
                    stageName: "counterexample extraction",
                    roundIndex: envelope.roundIndex,
                    operation: {
                        try await extractionService.extractCounterexamples(from: extractedEvents, state: state.stableSnapshot())
                    },
                    fallback: {
                        EpistemicExtractionOutput(
                            objects: [],
                            rejected: [],
                            missingEvidence: [],
                            decisionImpactNote: "Counterexample extraction skipped because structured model extraction failed"
                        )
                    }
                )
                if let reason = counterexampleStage.fallbackReason {
                    usedFallbackExtraction = true
                    appendFallbackReason(reason, to: &fallbackReasons)
                }
                let counterexampleOutput = counterexampleStage.output
                let counterexampleReduced = reducer.reduce(counterexampleOutput, into: state, influenceTrace: trace)
                state = counterexampleReduced.state.stableSnapshot()
                trace = counterexampleReduced.influenceTrace
            }

            let constraintDebtStage = await stageOutput(
                stageName: "constraint and debt extraction",
                roundIndex: envelope.roundIndex,
                operation: {
                    try await extractionService.extractConstraintsAndDebt(from: envelope, state: state.stableSnapshot())
                },
                fallback: {
                    EpistemicExtractionOutput(
                        objects: [],
                        rejected: [],
                        missingEvidence: [],
                        decisionImpactNote: "Constraint and debt extraction skipped because structured model extraction failed"
                    )
                }
            )
            if let reason = constraintDebtStage.fallbackReason {
                usedFallbackExtraction = true
                appendFallbackReason(reason, to: &fallbackReasons)
            }
            let constraintDebtOutput = constraintDebtStage.output
            let reduced = reducer.reduce(constraintDebtOutput, into: state, influenceTrace: trace)
            state = reduced.state.stableSnapshot()
            trace = reduced.influenceTrace
        }

        return EpistemicStateBuildResult(
            state: state,
            influenceTrace: trace,
            usedFallbackExtraction: usedFallbackExtraction,
            fallbackReasons: fallbackReasons
        )
    }

    private func fallbackExtractionOutput(from envelope: EpistemicInputEnvelope) -> EpistemicExtractionOutput {
        let primaryObservation = envelope.toolObservations.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryMessage = envelope.userAgentMessages.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (primaryObservation?.isEmpty == false ? primaryObservation : primaryMessage) ?? "Unresolved task uncertainty"

        return EpistemicExtractionOutput(
            objects: [
                EpistemicObjectCandidate(
                    kind: .frontier,
                    id: "frontier-\(envelope.roundIndex)",
                    summary: summary,
                    sourceRefs: ["fallback:round:\(envelope.roundIndex)"],
                    decisionDelta: "Inspect latest evidence",
                    evidenceLevel: .partial
                )
            ],
            rejected: [],
            missingEvidence: primaryObservation == nil ? ["tool observation unavailable"] : [],
            decisionImpactNote: "Fallback extraction used because structured model extraction failed"
        )
    }

    private func atomicEvents(from output: EpistemicExtractionOutput) -> [AtomicEpistemicEvent] {
        output.objects.compactMap { object in
            guard object.kind == .atomicEvent else { return nil }
            return AtomicEpistemicEvent(
                id: object.id,
                kind: .observationReceived,
                summary: object.summary,
                sourceRefs: object.sourceRefs
            )
        }
    }

    private func scopedFallbackOutput(
        from envelope: EpistemicInputEnvelope,
        allowedKinds: Set<EpistemicObjectKind>,
        note: String
    ) -> EpistemicExtractionOutput {
        let fallback = fallbackExtractionOutput(from: envelope)
        return EpistemicExtractionOutput(
            objects: fallback.objects.filter { allowedKinds.contains($0.kind) },
            rejected: fallback.rejected,
            missingEvidence: fallback.missingEvidence,
            decisionImpactNote: note
        )
    }

    private func stageOutput(
        stageName: String,
        roundIndex: Int,
        operation: () async throws -> EpistemicExtractionOutput,
        fallback: () -> EpistemicExtractionOutput
    ) async -> (output: EpistemicExtractionOutput, fallbackReason: String?) {
        do {
            return (try await operation(), nil)
        } catch {
            return (
                fallback(),
                fallbackReason(
                    for: stageName,
                    roundIndex: roundIndex,
                    error: error
                )
            )
        }
    }

    private func fallbackReason(
        for stageName: String,
        roundIndex: Int,
        error: Error
    ) -> String {
        "\(stageName) round \(roundIndex): \(error.localizedDescription)"
    }

    private func appendFallbackReason(_ reason: String, to fallbackReasons: inout [String]) {
        if !fallbackReasons.contains(reason) {
            fallbackReasons.append(reason)
        }
    }
}
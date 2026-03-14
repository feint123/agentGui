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
        var state = initialState
        var trace = initialInfluenceTrace

        for envelope in envelopes {
            let output: EpistemicExtractionOutput
            do {
                output = try await extractionService.extractEvents(from: envelope, state: state)
            } catch {
                output = fallbackExtractionOutput(from: envelope)
            }
            let reduced = reducer.reduce(output, into: state, influenceTrace: trace)
            state = reduced.state
            trace = reduced.influenceTrace
        }

        return EpistemicStateBuildResult(state: state, influenceTrace: trace)
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
}
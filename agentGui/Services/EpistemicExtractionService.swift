import Foundation

struct EpistemicExtractionService {
    typealias ModelExecutor = @Sendable (String) async throws -> String

    let executor: ModelExecutor
    private let parser = EpistemicExtractionResponseParser()
    private let eventPromptBuilder = EpistemicEventExtractionPromptBuilder()
    private let frontierPromptBuilder = FrontierSynthesisPromptBuilder()
    private let counterexamplePromptBuilder = CounterexampleExtractionPromptBuilder()
    private let constraintDebtPromptBuilder = ConstraintDebtExtractionPromptBuilder()

    init(executor: @escaping ModelExecutor) {
        self.executor = executor
    }

    func extractEvents(from envelope: EpistemicInputEnvelope, state: EpistemicState) async throws -> EpistemicExtractionOutput {
        let raw = try await executor(eventPromptBuilder.build(envelope: envelope, epistemicState: state))
        return try parser.parse(raw)
    }

    func synthesizeFrontiers(from events: [AtomicEpistemicEvent], state: EpistemicState) async throws -> EpistemicExtractionOutput {
        let raw = try await executor(frontierPromptBuilder.build(events: events, epistemicState: state))
        return try parser.parse(raw)
    }

    func extractCounterexamples(from events: [AtomicEpistemicEvent], state: EpistemicState) async throws -> EpistemicExtractionOutput {
        let raw = try await executor(counterexamplePromptBuilder.build(events: events, epistemicState: state))
        return try parser.parse(raw)
    }

    func extractConstraintsAndDebt(from envelope: EpistemicInputEnvelope, state: EpistemicState) async throws -> EpistemicExtractionOutput {
        let raw = try await executor(constraintDebtPromptBuilder.build(envelope: envelope, epistemicState: state))
        return try parser.parse(raw)
    }
}
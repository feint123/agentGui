import Foundation

struct EpistemicExtractionService {
    typealias ModelExecutor = @Sendable (String) async throws -> String

    typealias EventExtractor = @Sendable (EpistemicInputEnvelope, EpistemicState) async throws -> EpistemicExtractionOutput
    typealias FrontierSynthesizer = @Sendable ([AtomicEpistemicEvent], EpistemicState) async throws -> EpistemicExtractionOutput
    typealias CounterexampleExtractor = @Sendable ([AtomicEpistemicEvent], EpistemicState) async throws -> EpistemicExtractionOutput
    typealias ConstraintDebtExtractor = @Sendable (EpistemicInputEnvelope, EpistemicState) async throws -> EpistemicExtractionOutput

    private let extractEventsHandler: EventExtractor
    private let synthesizeFrontiersHandler: FrontierSynthesizer
    private let extractCounterexamplesHandler: CounterexampleExtractor
    private let extractConstraintsAndDebtHandler: ConstraintDebtExtractor

    init(executor: @escaping ModelExecutor) {
        let parser = EpistemicExtractionResponseParser()
        let eventPromptBuilder = EpistemicEventExtractionPromptBuilder()
        let frontierPromptBuilder = FrontierSynthesisPromptBuilder()
        let counterexamplePromptBuilder = CounterexampleExtractionPromptBuilder()
        let constraintDebtPromptBuilder = ConstraintDebtExtractionPromptBuilder()

        self.extractEventsHandler = { envelope, state in
            let raw = try await executor(eventPromptBuilder.build(envelope: envelope, epistemicState: state))
            return try parser.parse(raw)
        }
        self.synthesizeFrontiersHandler = { events, state in
            let raw = try await executor(frontierPromptBuilder.build(events: events, epistemicState: state))
            return try parser.parse(raw)
        }
        self.extractCounterexamplesHandler = { events, state in
            let raw = try await executor(counterexamplePromptBuilder.build(events: events, epistemicState: state))
            return try parser.parse(raw)
        }
        self.extractConstraintsAndDebtHandler = { envelope, state in
            let raw = try await executor(constraintDebtPromptBuilder.build(envelope: envelope, epistemicState: state))
            return try parser.parse(raw)
        }
    }

    init(
        extractEvents: @escaping EventExtractor,
        synthesizeFrontiers: @escaping FrontierSynthesizer,
        extractCounterexamples: @escaping CounterexampleExtractor,
        extractConstraintsAndDebt: @escaping ConstraintDebtExtractor
    ) {
        self.extractEventsHandler = extractEvents
        self.synthesizeFrontiersHandler = synthesizeFrontiers
        self.extractCounterexamplesHandler = extractCounterexamples
        self.extractConstraintsAndDebtHandler = extractConstraintsAndDebt
    }

    func extractEvents(from envelope: EpistemicInputEnvelope, state: EpistemicState) async throws -> EpistemicExtractionOutput {
        try await extractEventsHandler(envelope, state)
    }

    func synthesizeFrontiers(from events: [AtomicEpistemicEvent], state: EpistemicState) async throws -> EpistemicExtractionOutput {
        try await synthesizeFrontiersHandler(events, state)
    }

    func extractCounterexamples(from events: [AtomicEpistemicEvent], state: EpistemicState) async throws -> EpistemicExtractionOutput {
        try await extractCounterexamplesHandler(events, state)
    }

    func extractConstraintsAndDebt(from envelope: EpistemicInputEnvelope, state: EpistemicState) async throws -> EpistemicExtractionOutput {
        try await extractConstraintsAndDebtHandler(envelope, state)
    }
}
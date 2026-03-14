import Foundation

struct CounterexampleExtractionPromptBuilder {
    func build(events: [AtomicEpistemicEvent], epistemicState: EpistemicState) -> String {
        let eventLines = events.isEmpty
            ? "- none"
            : events.map { "- [\($0.kind.rawValue)] \($0.summary)" }.joined(separator: "\n")
        let priorCounterexamples = epistemicState.counterexamples.isEmpty
            ? "- none"
            : epistemicState.counterexamples.map { "- \($0.summary)" }.joined(separator: "\n")

        return """
        You are extracting counterexamples from failed or contradicted execution evidence.

        Events:
        \(eventLines)

        Existing counterexamples:
        \(priorCounterexamples)

        Promote only failures that invalidate a prior assumption or procedure.
        Prefer kind="counterexample" for every retained object.
        Include a replacementAction field inside each counterexample object when you keep one.
        \(EpistemicPromptJSONContract.extractionSchema)

        \(EpistemicPromptJSONContract.counterexampleExample)

        Do not output chain-of-thought.
        """
    }
}
import Foundation

struct FrontierSynthesisPromptBuilder {
    func build(events: [AtomicEpistemicEvent], epistemicState: EpistemicState) -> String {
        let eventLines = events.isEmpty
            ? "- none"
            : events.map { "- [\($0.kind.rawValue)] \($0.summary)" }.joined(separator: "\n")
        let actionLines = epistemicState.candidateActions.isEmpty
            ? "- none"
            : epistemicState.candidateActions.map { "- \($0)" }.joined(separator: "\n")

        return """
        You are synthesizing frontier objects from structured epistemic events.

        Events:
        \(eventLines)

        Current candidate actions:
        \(actionLines)

        Identify which unresolved claims qualify as frontier objects because they block action selection.
        Return JSON using the same extraction schema and prefer kind="frontier" when appropriate.
        Do not output chain-of-thought.
        """
    }
}
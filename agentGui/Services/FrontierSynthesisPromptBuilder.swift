import Foundation

struct FrontierSynthesisPromptBuilder {
    func build(events: [AtomicEpistemicEvent], epistemicState: EpistemicState) -> String {
        let stableState = epistemicState.stableSnapshot()
        let eventLines = events.isEmpty
            ? "- none"
            : events.map { "- [\($0.kind.rawValue)] \($0.summary)" }.joined(separator: "\n")
        let actionLines = stableState.candidateActions.isEmpty
            ? "- none"
            : stableState.candidateActions.map { "- \($0)" }.joined(separator: "\n")

        return """
        You are synthesizing frontier objects from structured epistemic events.

        Events:
        \(eventLines)

        Current candidate actions:
        \(actionLines)

        Identify which unresolved claims qualify as frontier objects because they block action selection.
        Prefer kind="frontier" for every retained object.
        \(EpistemicPromptJSONContract.extractionSchema)

        \(EpistemicPromptJSONContract.frontierExample)

        Do not output chain-of-thought.
        """
    }
}
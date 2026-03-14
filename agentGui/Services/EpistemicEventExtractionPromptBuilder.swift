import Foundation

struct EpistemicEventExtractionPromptBuilder {
    func build(envelope: EpistemicInputEnvelope, epistemicState: EpistemicState) -> String {
        """
        You are extracting structured epistemic objects from an agent run.

        Current session: \(envelope.sessionID)
        Round index: \(envelope.roundIndex)

        Current epistemic state summary:
        - frontiers: \(epistemicState.frontiers.map(\ .openClaim).joined(separator: " | "))
        - candidate actions: \(epistemicState.candidateActions.joined(separator: " | "))
        - active constraints: \(epistemicState.activeConstraints.map(\ .summary).joined(separator: " | "))

        User / agent messages:
        \(renderList(envelope.userAgentMessages))

        Tool observations:
        \(renderList(envelope.toolObservations))

        \(EpistemicPromptJSONContract.extractionSchema)

        \(EpistemicPromptJSONContract.genericExample)

        Do not output chain-of-thought. Output only structured residue backed by source_refs.
        """
    }

    private func renderList(_ lines: [String]) -> String {
        if lines.isEmpty {
            return "- none"
        }
        return lines.map { "- \($0)" }.joined(separator: "\n")
    }
}
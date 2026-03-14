import Foundation

struct EpistemicEventExtractionPromptBuilder {
    func build(envelope: EpistemicInputEnvelope, epistemicState: EpistemicState) -> String {
        let stableState = epistemicState.stableSnapshot()
        let frontierSummary = summaryLine(stableState.frontiers.map { $0.openClaim })
        let candidateActionSummary = summaryLine(stableState.candidateActions)
        let constraintSummary = summaryLine(stableState.activeConstraints.map { $0.summary })

        return """
        You are extracting structured epistemic objects from an agent run.

        Current session: \(envelope.sessionID)
        Round index: \(envelope.roundIndex)

        Current epistemic state summary:
        - frontiers: \(frontierSummary)
        - candidate actions: \(candidateActionSummary)
        - active constraints: \(constraintSummary)

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

    private func summaryLine(_ values: [String]) -> String {
        let filteredValues = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if filteredValues.isEmpty {
            return "- none"
        }
        return filteredValues.joined(separator: " | ")
    }
}
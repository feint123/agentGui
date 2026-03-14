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

        Return ONLY valid JSON with this schema:
        {
          "objects": [
            {
              "kind": "frontier|counterexample|constraint|verificationDebt|tacticKernel|atomicEvent",
              "id": "string",
              "summary": "string",
              "source_refs": ["string"],
              "decision_delta": "string",
              "evidence_level": "none|partial|verified"
            }
          ],
          "rejected": [
            {
              "summary": "string",
              "reason": "string"
            }
          ],
          "missingEvidence": ["string"],
          "decisionImpactNote": "string"
        }

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
import Foundation

enum EpistemicPromptJSONContract {
    static let extractionSchema = #"""
Return ONLY valid JSON.
All keys must be present.
Use empty arrays when there are no items.
Use an empty string when a required string field has no value.

JSON structure:
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
"""#

    static let genericExample = #"""
Example JSON:
{
  "objects": [
    {
      "kind": "frontier",
      "id": "frontier-scheme-check",
      "summary": "Need to confirm whether the shared scheme exists before editing build settings",
      "source_refs": ["message:user:0", "tool:bash:1"],
      "decision_delta": "Changes the next step from editing files to inspecting xcodebuild configuration",
      "evidence_level": "partial"
    }
  ],
  "rejected": [
    {
      "summary": "Rename build targets immediately",
      "reason": "No evidence yet that target naming is the blocker"
    }
  ],
  "missingEvidence": ["xcodebuild -list output"],
  "decisionImpactNote": "Inspect the scheme before making code or project edits"
}
"""#

    static let frontierExample = #"""
Example JSON:
{
  "objects": [
    {
      "kind": "frontier",
      "id": "frontier-shared-scheme",
      "summary": "The build cannot proceed until the shared scheme status is confirmed",
      "source_refs": ["event:claimRaised:0", "event:actionProposed:0"],
      "decision_delta": "Prioritizes inspection over implementation edits",
      "evidence_level": "partial"
    }
  ],
  "rejected": [],
  "missingEvidence": ["A direct listing of available shared schemes"],
  "decisionImpactNote": "Close this frontier before selecting a remediation action"
}
"""#

    static let counterexampleExample = #"""
Example JSON:
{
  "objects": [
    {
      "kind": "counterexample",
      "id": "counterexample-edit-before-inspect",
      "summary": "Editing project settings before inspecting the scheme repeats a previously contradicted path",
      "source_refs": ["event:observationReceived:0"],
      "decision_delta": "Blocks premature edits and shifts the next action to inspection",
      "evidence_level": "verified",
      "replacementAction": "Run xcodebuild -list and inspect the shared scheme configuration"
    }
  ],
  "rejected": [],
  "missingEvidence": [],
  "decisionImpactNote": "Keep the agent from repeating a disproven remediation path"
}
"""#

    static let constraintDebtExample = #"""
Example JSON:
{
  "objects": [
    {
      "kind": "constraint",
      "id": "constraint-test-before-edit",
      "summary": "Run a targeted verification step before editing implementation files",
      "source_refs": ["message:user:0"],
      "decision_delta": "Forces verification-first sequencing",
      "evidence_level": "verified"
    },
    {
      "kind": "verificationDebt",
      "id": "debt-build-fix-unverified",
      "summary": "The candidate build fix has not been validated by a direct test run yet",
      "source_refs": ["message:assistant:1"],
      "decision_delta": "Keeps test execution ahead of declaring success",
      "evidence_level": "partial"
    }
  ],
  "rejected": [],
  "missingEvidence": ["A passing targeted build or test command"],
  "decisionImpactNote": "Preserve the constraint and debt until verification closes the gap"
}
"""#
}
import Foundation

struct ConstraintDebtExtractionPromptBuilder {
    func build(envelope: EpistemicInputEnvelope, epistemicState: EpistemicState) -> String {
        let messageLines = envelope.userAgentMessages.isEmpty
            ? "- none"
            : envelope.userAgentMessages.map { "- \($0)" }.joined(separator: "\n")
        let debtLines = epistemicState.verificationDebt.isEmpty
            ? "- none"
            : epistemicState.verificationDebt.map { "- \($0.claim): \($0.reason)" }.joined(separator: "\n")

        return """
        You are extracting constraints and verification debt from the current run.

        Messages:
        \(messageLines)

        Existing verification debt:
        \(debtLines)

        \(EpistemicPromptJSONContract.extractionSchema)

        Use kind="constraint" for stable action-limiting rules and kind="verificationDebt" for evidence gaps that still influence decisions.
        \(EpistemicPromptJSONContract.constraintDebtExample)

        Do not output chain-of-thought.
        """
    }
}
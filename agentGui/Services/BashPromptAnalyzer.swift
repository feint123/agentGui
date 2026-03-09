import Foundation

struct TerminalPromptDecision: Equatable, Sendable {
    var snapshot: TerminalPromptSnapshot
    var shouldAutoReply: Bool
    var autoReplyText: String?
    var escalationReason: String?
}

struct BashPromptAnalyzer {

    func analyze(output: String) -> TerminalPromptDecision? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.lowercased()

        if isSecretPrompt(normalized) {
            let snapshot = TerminalPromptSnapshot(
                kind: .secret,
                promptText: trimmed,
                options: [],
                recommendedReply: nil
            )
            return TerminalPromptDecision(
                snapshot: snapshot,
                shouldAutoReply: false,
                autoReplyText: nil,
                escalationReason: "sensitive-input"
            )
        }

        if isDestructiveConfirmation(normalized) {
            let snapshot = TerminalPromptSnapshot(
                kind: .destructiveConfirmation,
                promptText: trimmed,
                options: ["y", "n"],
                recommendedReply: "n"
            )
            return TerminalPromptDecision(
                snapshot: snapshot,
                shouldAutoReply: false,
                autoReplyText: nil,
                escalationReason: "destructive-confirmation"
            )
        }

        if isYesNoPrompt(normalized) {
            let snapshot = TerminalPromptSnapshot(
                kind: .yesNo,
                promptText: trimmed,
                options: ["y", "n"],
                recommendedReply: "n"
            )
            return TerminalPromptDecision(
                snapshot: snapshot,
                shouldAutoReply: true,
                autoReplyText: snapshot.recommendedReply,
                escalationReason: nil
            )
        }

        if isPressEnterPrompt(normalized) {
            let snapshot = TerminalPromptSnapshot(
                kind: .pressEnter,
                promptText: trimmed,
                options: [],
                recommendedReply: ""
            )
            return TerminalPromptDecision(
                snapshot: snapshot,
                shouldAutoReply: true,
                autoReplyText: "",
                escalationReason: nil
            )
        }

        return nil
    }

    private func isSecretPrompt(_ normalized: String) -> Bool {
        normalized == "password:" || normalized.hasSuffix(" password:") || normalized.contains("enter password")
    }

    private func isDestructiveConfirmation(_ normalized: String) -> Bool {
        (normalized.contains("overwrite") || normalized.contains("replace existing") || normalized.contains("delete"))
            && isYesNoPrompt(normalized)
    }

    private func isYesNoPrompt(_ normalized: String) -> Bool {
        let tokens = [
            "(y/n)",
            "(y/n?)",
            "[y/n]",
            "[y/n?]",
            "(yes/no)",
            "y/n",
            "yes/no"
        ]

        return tokens.contains(where: normalized.contains)
    }

    private func isPressEnterPrompt(_ normalized: String) -> Bool {
        normalized.contains("press enter to continue") || normalized.contains("press return to continue")
    }
}
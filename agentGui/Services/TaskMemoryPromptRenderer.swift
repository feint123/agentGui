import Foundation

struct TaskMemoryPromptRenderer {
    func render(records: [MemoryRecord]) -> String {
        let confirmed = records
            .compactMap(renderedConfirmedFact)

        let attempts = records
            .compactMap(renderedAttempt)

        let failures = records
            .compactMap(renderFailureLine)

        let pending = records
            .compactMap(renderedPendingQuestion)

        let verification = records
            .compactMap(renderedVerificationLine)

        var parts: [String] = []

        if !confirmed.isEmpty {
            parts.append("## Confirmed Facts\n" + confirmed.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !attempts.isEmpty {
            parts.append("## Attempted Actions\n" + attempts.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !failures.isEmpty {
            parts.append("## Failed Attempts\n" + failures.joined(separator: "\n"))
        }
        if !pending.isEmpty {
            parts.append("## Pending Questions\n" + pending.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !verification.isEmpty {
            parts.append("## Verification Status\n" + verification.joined(separator: "\n"))
        }

        return parts.joined(separator: "\n\n")
    }

    private func renderedConfirmedFact(record: MemoryRecord) -> String? {
        guard recordEpisodeType(record) == "confirmed_fact" || record.tags.contains("confirmed-fact") else {
            return nil
        }
        return record.title
    }

    private func renderedAttempt(record: MemoryRecord) -> String? {
        guard recordEpisodeType(record) == "attempted_action" || record.tags.contains("attempt") else {
            return nil
        }
        return record.title
    }

    private func renderedPendingQuestion(record: MemoryRecord) -> String? {
        guard recordEpisodeType(record) == "pending_question" || record.tags.contains("pending") else {
            return nil
        }
        return record.title
    }

    private func renderedVerificationLine(record: MemoryRecord) -> String? {
        guard recordEpisodeType(record) == "verification_entry" || record.tags.contains("verification-entry") else {
            return nil
        }
        return "- \(record.title) [\(record.summary)]"
    }

    private func renderFailureLine(record: MemoryRecord) -> String? {
        guard recordEpisodeType(record) == "failed_attempt" || record.tags.contains("failed-attempt") else {
            return nil
        }
        switch record.payload {
        case let .structured(fields):
            let action = fields["action"] ?? record.title
            let reason = fields["reason"] ?? record.summary
            return "- \(action): \(reason)"
        case let .text(text):
            return "- \(record.title): \(text)"
        }
    }

    private func recordEpisodeType(_ record: MemoryRecord) -> String? {
        guard case let .structured(fields) = record.payload else { return nil }
        return fields["episode_type"]
    }
}
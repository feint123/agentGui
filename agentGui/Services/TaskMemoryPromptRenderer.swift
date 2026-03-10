import Foundation

struct TaskMemoryPromptRenderer {
    func render(records: [MemoryRecord]) -> String {
        let confirmed = records
            .filter { $0.tags.contains("confirmed-fact") }
            .map(\.title)

        let attempts = records
            .filter { $0.tags.contains("attempt") }
            .map(\.title)

        let failures = records
            .filter { $0.tags.contains("failed-attempt") }
            .map(renderFailureLine)

        let pending = records
            .filter { $0.tags.contains("pending") }
            .map(\.title)

        let verification = records
            .filter { $0.tags.contains("verification-entry") }
            .map { "- \($0.title) [\($0.summary)]" }

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

    private func renderFailureLine(record: MemoryRecord) -> String {
        switch record.payload {
        case let .structured(fields):
            let action = fields["action"] ?? record.title
            let reason = fields["reason"] ?? record.summary
            return "- \(action): \(reason)"
        case let .text(text):
            return "- \(record.title): \(text)"
        }
    }
}
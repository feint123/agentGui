import Foundation

enum ExecutionTheaterTextFormatter {
    nonisolated static func clamp(
        _ text: String?,
        maxLines: Int = 5
    ) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.count > maxLines else {
            return trimmed
        }

        var clampedLines = Array(lines.prefix(maxLines))
        let lastIndex = clampedLines.index(before: clampedLines.endIndex)
        clampedLines[lastIndex] = clampedLines[lastIndex].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        return clampedLines.joined(separator: "\n")
    }
}
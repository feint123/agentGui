import Foundation

struct GitCommitDraft: Equatable {
    var summary: String = ""
    var description: String = ""

    var messageFileContents: String {
        let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDescription.isEmpty else { return normalizedSummary + "\n" }
        return normalizedSummary + "\n\n" + normalizedDescription + "\n"
    }
}
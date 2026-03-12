import Foundation

struct ToolBudgetDecision: Equatable, Sendable {
    let mode: ToolResultEnvelope.InjectionMode
    let summary: String
    let preview: String?
    let shouldPersistPayload: Bool
    let retrievalHint: String
    let rawCharCount: Int
    let injectedCharCount: Int
}

struct ToolResultBudgetController {
    var inlineCharLimit: Int = 2_000
    var previewCharLimit: Int = 8_000
    var inlineRoundBudget: Int = 6_000
    var previewRoundBudget: Int = 12_000
    var previewWindow: Int = 1_200

    func decide(
        rawText: String,
        sourceKind: LargeTextPayload.SourceKind,
        roundInjectedChars: Int,
        reservedResponseTokens: Int
    ) -> ToolBudgetDecision {
        let rawCharCount = rawText.count
        let safePreviewWindow = min(previewWindow, max(200, reservedResponseTokens))
        let summary = summarize(rawText: rawText, sourceKind: sourceKind)

        if rawCharCount <= inlineCharLimit, roundInjectedChars < inlineRoundBudget {
            return ToolBudgetDecision(
                mode: .inline,
                summary: summary,
                preview: rawText,
                shouldPersistPayload: false,
                retrievalHint: "",
                rawCharCount: rawCharCount,
                injectedCharCount: rawCharCount
            )
        }

        if rawCharCount <= previewCharLimit, roundInjectedChars < previewRoundBudget {
            let preview = String(rawText.prefix(safePreviewWindow))
            return ToolBudgetDecision(
                mode: .preview,
                summary: summary,
                preview: preview,
                shouldPersistPayload: false,
                retrievalHint: "Inspect summary and preview before asking for more content.",
                rawCharCount: rawCharCount,
                injectedCharCount: summary.count + preview.count
            )
        }

        let preview = String(rawText.prefix(min(800, safePreviewWindow)))
        return ToolBudgetDecision(
            mode: .referenced,
            summary: summary,
            preview: preview,
            shouldPersistPayload: true,
            retrievalHint: "Use read_tool_payload to continue reading this result in chunks.",
            rawCharCount: rawCharCount,
            injectedCharCount: summary.count + preview.count
        )
    }

    private func summarize(rawText: String, sourceKind: LargeTextPayload.SourceKind) -> String {
        let firstNonEmptyLine = rawText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let firstNonEmptyLine, !firstNonEmptyLine.isEmpty {
            return "\(sourceKind.rawValue) result: \(String(firstNonEmptyLine.prefix(160)))"
        }
        return "\(sourceKind.rawValue) result (\(rawText.count) chars)"
    }
}
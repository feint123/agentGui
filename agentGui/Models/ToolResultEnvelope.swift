import Foundation

struct ToolResultEnvelope: Codable, Equatable, Sendable {
    typealias SourceKind = LargeTextPayload.SourceKind

    enum InjectionMode: String, Codable, Sendable {
        case inline
        case preview
        case referenced
    }

    let summary: String
    let preview: String?
    let payloadRef: String?
    let isTruncated: Bool
    let estimatedChars: Int
    let estimatedTokens: Int
    let retrievalHint: String?
    let sourceKind: SourceKind
    let injectionMode: InjectionMode
    let rawCharCount: Int
    let injectedCharCount: Int

    static func estimateTokens(for text: String) -> Int {
        max(1, Int(ceil(Double(text.count) / 4.0)))
    }

    func renderForModel() -> String {
        var lines: [String] = [
            "source_kind: \(sourceKind.rawValue)",
            "injection_mode: \(injectionMode.rawValue)",
            "summary: \(summary)",
            "is_truncated: \(isTruncated)",
            "estimated_chars: \(estimatedChars)",
            "estimated_tokens: \(estimatedTokens)"
        ]

        if let preview, !preview.isEmpty {
            lines.append("preview:")
            lines.append(preview)
        }
        if let payloadRef, !payloadRef.isEmpty {
            lines.append("payload_ref: \(payloadRef)")
        }
        if let retrievalHint, !retrievalHint.isEmpty {
            lines.append("retrieval_hint: \(retrievalHint)")
        }

        return lines.joined(separator: "\n")
    }
}
import Foundation
import Testing
@testable import agentGui

@MainActor
struct ToolResultEnvelopeTests {

    @Test func referencedEnvelopeRequiresPayloadRef() throws {
        let envelope = ToolResultEnvelope(
            summary: "large output",
            preview: "head...",
            payloadRef: "payload_123",
            isTruncated: true,
            estimatedChars: 12_000,
            estimatedTokens: 3_000,
            retrievalHint: "Use read_tool_payload with chunk mode",
            sourceKind: .bash,
            injectionMode: .referenced,
            rawCharCount: 12_000,
            injectedCharCount: 400
        )

        #expect(envelope.payloadRef == "payload_123")
        #expect(envelope.renderForModel().contains("payload_ref: payload_123"))
        #expect(envelope.renderForModel().contains("retrieval_hint: Use read_tool_payload with chunk mode"))
    }

    @Test func inlineEnvelopeKeepsPayloadRefEmpty() throws {
        let envelope = ToolResultEnvelope(
            summary: "short output",
            preview: "short output",
            payloadRef: nil,
            isTruncated: false,
            estimatedChars: 40,
            estimatedTokens: ToolResultEnvelope.estimateTokens(for: "short output"),
            retrievalHint: nil,
            sourceKind: .file,
            injectionMode: .inline,
            rawCharCount: 40,
            injectedCharCount: 40
        )

        #expect(envelope.payloadRef == nil)
        #expect(!envelope.renderForModel().contains("payload_ref:"))
    }

    @Test func previewEnvelopeIncludesPayloadRefWhenAvailable() throws {
        let envelope = ToolResultEnvelope(
            summary: "medium output",
            preview: "truncated preview",
            payloadRef: "payload_preview_123",
            isTruncated: true,
            estimatedChars: 4_000,
            estimatedTokens: 1_000,
            retrievalHint: "Use read_tool_payload to continue reading the remaining content.",
            sourceKind: .webFetch,
            injectionMode: .preview,
            rawCharCount: 4_000,
            injectedCharCount: 1_200
        )

        #expect(envelope.renderForModel().contains("injection_mode: preview"))
        #expect(envelope.renderForModel().contains("payload_ref: payload_preview_123"))
    }
}
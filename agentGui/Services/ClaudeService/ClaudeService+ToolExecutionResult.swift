//
//  ClaudeService+ToolExecutionResult.swift
//  agentGui
//

import Foundation
import SwiftAnthropic

// MARK: - ToolExecutionResult

/// Wraps the result of a tool execution with a semantic status, text output, and optional
/// media objects (e.g. images). The `status` drives both `ToolCall.status` in the UI and
/// the `is_error` flag sent back to the model so it can reason about failures explicitly.
struct ToolExecutionResult {
    let status: ToolResultStatus
    let text: String
    let mediaContent: [MessageParameter.Message.Content.ContentObject]
    let rawOutputText: String?
    let envelope: ToolResultEnvelope?

    /// True when the result represents any kind of failure; maps directly to `is_error` in the
    /// Anthropic tool-result block so the model receives a structured failure signal.
    var isError: Bool { status != .success }

    /// True when the failure is transient and the caller may choose to retry.
    var isRetryable: Bool {
        switch status {
        case .retryableFailure, .timeout: return true
        default: return false
        }
    }

    var isPermissionDenied: Bool {
        status == .permissionDenied
    }

    /// Maps ToolResultStatus to the persistent ToolCall.status stored in SwiftData.
    var toolCallStatus: ToolStatus {
        status == .success ? .success : .failed
    }

    // MARK: Designated initialiser (backward-compatible, defaults to .success)
    init(
        _ text: String,
        status: ToolResultStatus = .success,
        mediaContent: [MessageParameter.Message.Content.ContentObject] = [],
        rawOutputText: String? = nil,
        envelope: ToolResultEnvelope? = nil
    ) {
        self.status = status
        self.text = text
        self.mediaContent = mediaContent
        self.rawOutputText = rawOutputText
        self.envelope = envelope
    }

    // MARK: Named factory methods

    static func success(
        _ text: String,
        mediaContent: [MessageParameter.Message.Content.ContentObject] = []
    ) -> ToolExecutionResult {
        ToolExecutionResult(text, status: .success, mediaContent: mediaContent)
    }

    static func failure(_ text: String) -> ToolExecutionResult {
        ToolExecutionResult(text, status: .failure)
    }

    static func retryableFailure(_ text: String) -> ToolExecutionResult {
        ToolExecutionResult(text, status: .retryableFailure)
    }

    static func timeout(_ text: String) -> ToolExecutionResult {
        ToolExecutionResult(text, status: .timeout)
    }

    static func permissionDenied(_ text: String) -> ToolExecutionResult {
        ToolExecutionResult(text, status: .permissionDenied)
    }

    static func missingParameter(_ name: String) -> ToolExecutionResult {
        ToolExecutionResult("Error: missing required parameter '\(name)'", status: .missingParameter)
    }

    static func parseError(_ text: String) -> ToolExecutionResult {
        ToolExecutionResult(text, status: .parseError)
    }

    static func unknownTool(_ name: String) -> ToolExecutionResult {
        ToolExecutionResult("Error: unknown tool '\(name)'", status: .unknownTool)
    }

    static func fromTerminalOutcome(_ outcome: TerminalExecutionOutcome) -> ToolExecutionResult {
        switch outcome.completionReason {
        case .exitedZero:
            return ToolExecutionResult(outcome.finalOutputSnippet, status: .success)
        case .timedOut:
            return ToolExecutionResult(outcome.finalOutputSnippet, status: .timeout)
        case .exitedNonZero, .terminatedBySignal, .runtimeFailure:
            return ToolExecutionResult(outcome.finalOutputSnippet, status: .failure)
        case .cancelledByAgent, .cancelledByUser:
            return ToolExecutionResult(outcome.finalOutputSnippet, status: .failure)
        }
    }

    // MARK: String-based error detection

    /// Wraps a plain string returned by a tool implementation, automatically inferring the
    /// correct ToolResultStatus from the text content.  Strings not starting with "Error:"
    /// are treated as `.success`.
    static func detect(_ text: String, toolName: String = "") -> ToolExecutionResult {
        let hasErrorPrefix = text.hasPrefix("Error:") || text.hasPrefix("error:")
        guard hasErrorPrefix else { return ToolExecutionResult(text, status: .success) }
        let lower = text.lowercased()
        if lower.contains("[timed out after") || lower.contains("timed out") {
            return ToolExecutionResult(text, status: .timeout)
        }
        if lower.contains("permission denied") || lower.contains("operation not permitted") {
            return ToolExecutionResult(text, status: .permissionDenied)
        }
        if lower.contains("missing") && (lower.contains("parameter") || lower.contains("param")) {
            return ToolExecutionResult(text, status: .missingParameter)
        }
        if lower.contains("parse") || lower.contains("decode") || lower.contains("failed to parse") {
            return ToolExecutionResult(text, status: .parseError)
        }
        // Transient network errors for web tools
        let isWebTool = toolName == "web_fetch" || toolName.contains("web_search")
        if isWebTool && (lower.contains("http") || lower.contains("network") ||
                         lower.contains("connection") || lower.contains("urlerror")) {
            return ToolExecutionResult(text, status: .retryableFailure)
        }
        return ToolExecutionResult(text, status: .failure)
    }
}

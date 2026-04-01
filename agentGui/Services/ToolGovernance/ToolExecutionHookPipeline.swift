import Foundation
import SwiftAnthropic

// MARK: - Context Types

/// Immutable snapshot of a tool call passed to pre-execution hooks.
struct ToolCallPreview: Sendable {
    let toolCallId: String
    let toolName: String
    let input: MessageResponse.Content.Input
    let sessionID: String
    let executionContext: ToolContext
}

/// Immutable record of a completed tool call passed to post-execution hooks.
struct ToolRunRecord: Sendable {
    let toolCallId: String
    let toolName: String
    let input: MessageResponse.Content.Input
    let result: ToolExecutionResult
    let sessionID: String
    let executionContext: ToolContext
}

// MARK: - Decision Enums

/// Decision returned by a single hook's `preExecute`.
enum PreExecuteDecision: Sendable {
    /// Proceed with tool execution.
    case allow
    /// Prevent execution. The reason is returned as a failure result to the model.
    case block(reason: String)
    /// Proceed with execution AND append this context string after the tool result.
    case attachContext(String)
}

/// Action returned by a single hook's `postExecute`.
enum PostExecuteAction: Sendable {
    /// Leave the result unchanged.
    case passthrough
    /// Append this text to the tool result text AND write it to `ToolCall.toolResultSummary`.
    case appendAttachment(String)
    /// Replace the entire `ToolExecutionResult` with the provided value.
    case rewriteResult(ToolExecutionResult)
}

/// Action returned by a single hook's `postFailure`.
enum FailureAction: Sendable {
    /// Let the failure propagate unchanged.
    case propagate
    /// Replace the failure with this successful result.
    case recover(ToolExecutionResult)
    /// Append diagnostic text to the failure message.
    case appendDiagnostic(String)
}

// MARK: - Pre-execute Aggregated Outcome

/// Aggregated output of running all pre-execute hooks through the pipeline.
struct ToolPreExecuteOutcome: Sendable {
    /// Whether any hook requested a block.
    let shouldBlock: Bool
    /// The reason provided by the blocking hook, or `nil` if no block.
    let blockReason: String?
    /// All context strings returned by `.attachContext` hooks (preserved in hook order).
    let additionalContexts: [String]
}

// MARK: - Protocol

/// A governance hook that participates in tool call lifecycle management.
///
/// Hooks must be `Sendable` because the pipeline runs on `@MainActor` and
/// implementations may be shared across async contexts.
protocol ToolExecutionHook: Sendable {
    /// Unique identifier for debugging and logging.
    var hookID: String { get }

    /// Called before the tool executes.
    /// Return `.block` to prevent execution; `.attachContext` to annotate the result;
    /// `.allow` to proceed without modification.
    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision

    /// Called after the tool executes successfully.
    /// Return `.appendAttachment` to annotate the ToolCall timeline;
    /// `.rewriteResult` to replace the result entirely;
    /// `.passthrough` to leave unchanged.
    func postExecute(record: ToolRunRecord) async -> PostExecuteAction

    /// Called after the tool reports `isError == true`.
    /// Return `.recover` to replace the failure with a success result;
    /// `.appendDiagnostic` to add diagnostic information to the error;
    /// `.propagate` to leave unchanged.
    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction
}

// MARK: - Pipeline

/// Runs an ordered sequence of `ToolExecutionHook`s around each tool call.
///
/// Aggregation semantics (mirrors Claude Code `toolHooks.ts`):
///
/// - **preExecute**: First `.block` short-circuits; `.attachContext` values accumulate.
/// - **postExecute**: First `.rewriteResult` short-circuits; `.appendAttachment` values join with newline.
/// - **postFailure**: First `.recover` short-circuits; `.appendDiagnostic` values join with newline.
///
/// Any hook that returns the neutral decision is treated as non-blocking.
struct ToolExecutionHookPipeline: Sendable {
    let hooks: [any ToolExecutionHook]

    // MARK: preExecute

    func runPreExecute(toolCall: ToolCallPreview) async -> ToolPreExecuteOutcome {
        var additionalContexts: [String] = []

        for hook in hooks {
            let decision = await hook.preExecute(toolCall: toolCall)
            switch decision {
            case .block(let reason):
                return ToolPreExecuteOutcome(
                    shouldBlock: true,
                    blockReason: reason,
                    additionalContexts: additionalContexts
                )
            case .attachContext(let ctx):
                additionalContexts.append(ctx)
            case .allow:
                break
            }
        }

        return ToolPreExecuteOutcome(
            shouldBlock: false,
            blockReason: nil,
            additionalContexts: additionalContexts
        )
    }

    // MARK: postExecute

    func runPostExecute(record: ToolRunRecord) async -> PostExecuteAction {
        var attachments: [String] = []

        for hook in hooks {
            let action = await hook.postExecute(record: record)
            switch action {
            case .rewriteResult(let result):
                return .rewriteResult(result)
            case .appendAttachment(let text):
                attachments.append(text)
            case .passthrough:
                break
            }
        }

        if !attachments.isEmpty {
            return .appendAttachment(attachments.joined(separator: "\n"))
        }
        return .passthrough
    }

    // MARK: postFailure

    func runPostFailure(
        toolCall: ToolCallPreview,
        error: any Error
    ) async -> FailureAction {
        var diagnostics: [String] = []

        for hook in hooks {
            let action = await hook.postFailure(toolCall: toolCall, error: error)
            switch action {
            case .recover(let result):
                return .recover(result)
            case .appendDiagnostic(let text):
                diagnostics.append(text)
            case .propagate:
                break
            }
        }

        if !diagnostics.isEmpty {
            return .appendDiagnostic(diagnostics.joined(separator: "\n"))
        }
        return .propagate
    }
}

// MARK: - Pipeline Builder

extension ToolExecutionHookPipeline {
    /// Convenience factory that returns an empty pipeline (no-ops for all calls).
    static let empty = ToolExecutionHookPipeline(hooks: [])
}

// MARK: - Hook Error Helper

/// Lightweight error type that wraps a tool failure text for hook inspection.
struct ToolExecutionHookError: Error, Sendable {
    let message: String
}

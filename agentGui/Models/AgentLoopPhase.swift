//
//  AgentLoopPhase.swift
//  agentGui
//
//  Explicit state machine for the agentic execution loop.
//  Replaces the implicit `continueLoop: Bool` with named, inspectable phases.
//

import Foundation

struct AgentLoopRunResult: Equatable {
    let text: String
    let completedSuccessfully: Bool
    let terminationReason: String?
}

enum VerificationGateResolution: Equatable {
    case clearToFinish
    case needsMoreEvidence(openClaims: [String], suggestedProbe: String?)
}

// MARK: - AgentLoopPhase

/// Every distinct phase the agent loop can occupy.
enum AgentLoopPhase: Equatable {

    /// Loop has not started yet (initial state).
    case idle

    /// A model API call is in progress or about to start.
    case executing

    /// Model returned `tool_use`; tool results are being executed and will be fed back.
    case awaitingToolResults

    /// Model returned `max_tokens`; a continuation turn will be injected so it finishes.
    case continuingTruncatedResponse

    /// Model returned `pause_turn`; resuming server-side sampling.
    case resumingAfterPause

    /// Model returned `end_turn`; loop is completing gracefully.
    case finalizing

    /// Unrecoverable error; loop must stop.
    case failed

    /// Task cancelled by the user.
    case cancelled

    // MARK: Derived

    /// Whether the loop should advance to another iteration.
    var shouldContinue: Bool {
        switch self {
        case .idle, .executing, .awaitingToolResults,
             .continuingTruncatedResponse, .resumingAfterPause:
            return true
        case .finalizing, .failed, .cancelled:
            return false
        }
    }

    var label: String {
        switch self {
        case .idle:
            return "idle"
        case .executing:
            return "executing"
        case .awaitingToolResults:
            return "awaitingToolResults"
        case .continuingTruncatedResponse:
            return "continuingTruncatedResponse"
        case .resumingAfterPause:
            return "resumingAfterPause"
        case .finalizing:
            return "finalizing"
        case .failed:
            return "failed"
        case .cancelled:
            return "cancelled"
        }
    }
}

// MARK: - AgentLoopContext

/// Holds all mutable transient state for a single agentic loop run.
/// Centralises the loop's bookkeeping so `runAgenticLoop` reads as a clean state machine.
struct AgentLoopContext {

    /// Current phase.
    var phase: AgentLoopPhase = .idle

    /// Number of completed rounds (= index that will be assigned to the *next* round).
    var roundIndex: Int = 0

    /// Stop reason returned by the most recent model call.
    var lastStopReason: String? = nil

    /// Human-readable reason why the loop ended abnormally (available for UI / logging).
    var terminationReason: String? = nil

    /// The most recently detected failure event.
    /// The standalone reflection pass has been removed, but failure classification still
    /// records the latest trigger for verification and audit flows.
    var pendingFailureTrigger: FailureTrigger? = nil

    // MARK: Convenience

    /// Whether another loop iteration should run.
    var shouldContinue: Bool { phase.shouldContinue }

    // MARK: Transitions

    /// Drive the next phase based on the model's `stop_reason`.
    mutating func transition(stopReason: String?) {
        lastStopReason = stopReason
        switch stopReason {
        case "tool_use":
            phase = .awaitingToolResults
        case "end_turn":
            phase = .finalizing
        case "max_tokens":
            phase = .continuingTruncatedResponse
        case "pause_turn":
            phase = .resumingAfterPause
        default:
            phase = .failed
            terminationReason = "Unexpected stop_reason: \(stopReason ?? "nil")"
        }
    }

    /// Called after all pending tool results have been appended to the message list.
    mutating func toolResultsAppended() {
        phase = .executing
    }

    /// Called after a continuation or resume turn has been injected.
    mutating func continuationInjected() {
        phase = .executing
    }

    /// Advance the round counter and return the index just assigned.
    mutating func nextRound() -> Int {
        defer { roundIndex += 1 }
        return roundIndex
    }
}

// MARK: - FailureTrigger

/// Describes the class of failure event detected during execution or verification.
enum FailureTrigger: Equatable {

    /// A tool execution returned an error (isError == true).
    case toolFailure(toolName: String, errorText: String)

    /// A reviewer sub-agent returned a "needs_revision" verdict.
    case reviewerRejection(feedback: String)

    /// An executor sub-agent returned a "failed" status for its verification run.
    case executorValidationFailure(detail: String)

    /// A dedicated verifier sub-agent concluded the task is not yet complete.
    case verificationFailure(detail: String)

    // MARK: Derived

    /// Human-readable description for prompt injection and logging.
    var description: String {
        switch self {
        case .toolFailure(let name, let err):
            return "Tool '\(name)' failed: \(String(err.prefix(300)))"
        case .reviewerRejection(let fb):
            return "Reviewer rejected: \(String(fb.prefix(300)))"
        case .executorValidationFailure(let d):
            return "Executor validation failed: \(String(d.prefix(300)))"
        case .verificationFailure(let detail):
            return "Verification failed: \(String(detail.prefix(300)))"
        }
    }

    /// Short label used by failure audit and diagnostics.
    var actionLabel: String {
        switch self {
        case .toolFailure(let name, _):    return "tool:\(name)"
        case .reviewerRejection:           return "reviewer_rejection"
        case .executorValidationFailure:   return "executor_validation_failure"
        case .verificationFailure:         return "verification_failure"
        }
    }
}

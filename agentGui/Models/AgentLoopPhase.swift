//
//  AgentLoopPhase.swift
//  agentGui
//
//  Explicit state machine for the agentic execution loop.
//  Replaces the implicit `continueLoop: Bool` with named, inspectable phases.
//

import Foundation

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

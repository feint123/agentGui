// agentGui/Services/SubagentGovernance/ForkSubagentDefinition.swift
//
// S-F1: Fork subagent type definition.
// Encodes all static properties of a fork child agent — the actual "inherit
// parent context" mechanics are handled by ForkMessageBuilder (S-F2).
//
// Reference: src/tools/AgentTool/forkSubagent.ts → FORK_AGENT
//

import Foundation
import SwiftAnthropic


// MARK: - Constants

/// Synthetic agent type identifier used for analytics when the fork path fires.
/// Matches Claude Code's `FORK_SUBAGENT_TYPE = 'fork'`.
let FORK_SUBAGENT_TYPE = "fork"

/// XML tag injected into the fork child's first user message to signal "this is a fork context".
/// `isInForkChild` scans for this tag to prevent recursive forks.
/// Matches Claude Code's `FORK_BOILERPLATE_TAG`.
let FORK_BOILERPLATE_TAG = "fork-boilerplate"

/// Placeholder text used for all tool_result blocks in the fork prefix message.
/// Must be identical across all fork children to maximise prompt cache sharing.
/// Matches Claude Code's `FORK_PLACEHOLDER_RESULT`.
let FORK_PLACEHOLDER_RESULT = "Fork started — processing in background"

/// Prefix injected before the directive inside the fork child's boilerplate message.
/// Matches Claude Code's `FORK_DIRECTIVE_PREFIX`.
let FORK_DIRECTIVE_PREFIX = "Your directive: "

// MARK: - ForkSubagentDefinition

enum ForkSubagentDefinition {
    /// Synthetic agent type name (matches `FORK_SUBAGENT_TYPE`).
    static let agentType: String = FORK_SUBAGENT_TYPE
    /// Model selection: always inherit the parent agent's model.
    /// Fork children need full context window parity with the parent.
    static let modelPreference: SubagentModelPreference = .inherit
    /// Tool specification: wildcard, resolved to parent's exact tool pool at call time.
    static let tools: [String] = ["*"]
    /// Permission mode: "bubble" surfaces permission prompts to the parent's terminal.
    static let permissionMode: String = "bubble"
    /// Maximum turns for a fork child. Generous budget since forks handle
    /// complete subtasks independently (Claude Code uses 200).
    static let maxTurns: Int = 200
    /// Fork children must not themselves spawn further fork children.
    /// Enforced at call time by `isInForkChild(_:)`.
    static let permitsFork: Bool = false
    /// Human-readable description used in logs and UI hints.
    static let whenToUse: String = """
        Implicit fork — inherits full conversation context. \
        Not selectable via agent_name; triggered by ForkMessageBuilder (S-F2).
        """

    // MARK: - WorkflowRoleDefinition factory

    /// Construct the `WorkflowRoleDefinition` used when running a fork child loop.
    static func makeWorkflowRoleDefinition() -> WorkflowRoleDefinition {
        WorkflowRoleDefinition(
            name: agentType,
            displayName: "Fork",
            description: whenToUse,
            systemPrompt: "",    // Fork child inherits context via initialMessages
            enableTextEditor: true,
            enableBash: true,
            enableWebSearch: true,
            enableWebFetch: true,
            maxTurnsPerActivation: maxTurns,
            modelPreference: modelPreference,
            background: true,    // Fork always runs in background
            isOneShot: false
        )
    }
}

// MARK: - Recursive Fork Guard

/// Returns `true` when the message history contains a fork-boilerplate tag,
/// indicating the current agent is already running as a fork child.
///
/// Fork children keep the full parent tool pool (including `run_subagent`) for
/// cache-identical tool definitions, but must NOT spawn further forks. This
/// guard detects the injected `<fork-boilerplate>` tag that ForkMessageBuilder
/// (S-F2) inserts into the child's first user message.
///
/// Only scans user-role messages (assistant messages may echo the tag innocuously).
///
/// Reference: `isInForkChild()` in `forkSubagent.ts`
///
/// - Parameter messages: The `messages` array from the current agent loop.
/// - Returns: `true` if a fork-boilerplate tag is found in any user message.
func isInForkChild(_ messages: [MessageParameter.Message]) -> Bool {
    let openTag = "<\(FORK_BOILERPLATE_TAG)>"
    for message in messages {
        guard message.role == "user" else { continue }
        if messageContainsForkTag(message.content, openTag: openTag) {
            return true
        }
    }
    return false
}

// MARK: - Private helpers

/// Recursively searches a `MessageParameter.Message.Content` for the fork tag.
private func messageContainsForkTag(
    _ content: MessageParameter.Message.Content,
    openTag: String
) -> Bool {
    switch content {
    case .text(let text):
        return text.contains(openTag)
    case .list(let objects):
        return objects.contains { contentObjectContainsForkTag($0, openTag: openTag) }
    }
}

/// Recursively searches a single `ContentObject` for the fork tag.
private func contentObjectContainsForkTag(
    _ object: MessageParameter.Message.Content.ContentObject,
    openTag: String
) -> Bool {
    switch object {
    case .text(let text):
        return text.contains(openTag)
    case .toolResult(_, let content, _, _):
        return content.contains(openTag)
    default:
        // .toolUse, .thinking, .image, etc. cannot contain fork boilerplate
        return false
    }
}

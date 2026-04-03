// agentGui/Services/SubagentGovernance/ForkMessageBuilder.swift
//
// S-F2: Fork child message construction.
// Builds the byte-identical prefix messages that maximise prompt cache sharing
// across all fork children launched in the same parent round.
//
// Reference: src/tools/AgentTool/forkSubagent.ts
//

import Foundation
import SwiftAnthropic

// MARK: - ForkParentContext

/// Carries the parent context needed to build fork child initial messages.
/// Assembled by `AgentLoopRoundExecutor` and threaded through to the fork launch path.
struct ForkParentContext: Sendable {
    /// Full parent message history (all rounds, up to and including the round that
    /// triggered the fork tool call).
    let parentHistory: [MessageParameter.Message]
    /// The complete assistant message for the current round — contains all `.toolUse`
    /// blocks plus any preceding `.text` / `.thinking` content.
    let assistantMessage: MessageParameter.Message
}

// MARK: - ForkMessageBuilder

/// Constructs the initial message array for a fork child agent.
///
/// **Message structure (when tool_use blocks are present):**
/// ```
/// parentHistory               (0…n messages – shared prefix)
/// + assistantMessage          (all tool_use blocks for the current round)
/// + userMessage               (placeholder tool_results + fork directive)
/// ```
///
/// **Fallback (no tool_use):**
/// ```
/// userMessage only            (just the fork directive)
/// ```
///
/// The placeholder text for every `tool_result` is identical (`FORK_PLACEHOLDER_RESULT`),
/// so each fork child sends a request that shares the maximum possible prompt-cache prefix
/// with the other children dispatched in the same batch.
///
/// Reference: `buildForkedMessages` / `buildChildMessage` in `forkSubagent.ts`.
struct ForkMessageBuilder {

    // MARK: - Public API

    /// Build the initial `messages` array for a fork child.
    ///
    /// - Parameters:
    ///   - directive:        Task-specific instruction for this particular fork child.
    ///   - parentHistory:    All messages preceding the current assistant turn.
    ///   - assistantMessage: The full assistant message containing tool_use blocks.
    /// - Returns: Message array ready to be used as `initialMessages` for the child loop.
    func buildForkedMessages(
        directive: String,
        parentHistory: [MessageParameter.Message],
        assistantMessage: MessageParameter.Message
    ) -> [MessageParameter.Message] {
        let toolUseBlocks = extractToolUseBlocks(from: assistantMessage)

        guard !toolUseBlocks.isEmpty else {
            // Fallback: no tool_use → emit single directive-only user message.
            return [MessageParameter.Message(
                role: .user,
                content: .text(Self.buildChildMessage(directive: directive))
            )]
        }

        // Build the user message: placeholder tool_results + directive text.
        var userBlocks: [MessageParameter.Message.Content.ContentObject] = toolUseBlocks.map { id in
            .toolResult(id, FORK_PLACEHOLDER_RESULT, isError: nil)
        }
        userBlocks.append(.text(Self.buildChildMessage(directive: directive)))

        let userMessage = MessageParameter.Message(
            role: .user,
            content: .list(userBlocks)
        )

        return parentHistory + [assistantMessage, userMessage]
    }

    // MARK: - Static Helpers

    /// Build the directive / boilerplate text injected into the fork child's first user message.
    ///
    /// The text:
    /// - Opens with a `<fork-boilerplate>` XML tag (scanned by `isInForkChild`).
    /// - Includes a "STOP. READ THIS FIRST." preamble.
    /// - Ends with `FORK_DIRECTIVE_PREFIX + directive`.
    ///
    /// Reference: `buildChildMessage` in `forkSubagent.ts`.
    static func buildChildMessage(directive: String) -> String {
        """
        <\(FORK_BOILERPLATE_TAG)>
        STOP. READ THIS FIRST.

        You are running as a fork child agent. You have inherited the full parent \
        conversation context above. The tool-result placeholders above are not real \
        results — they mark the point at which your specific task was forked off.

        Rules:
        - Complete ONLY your assigned directive below.
        - Do NOT spawn another fork (run_subagent without agent_name is forbidden here).
        - When done, output your result directly; do not ask follow-up questions.
        </\(FORK_BOILERPLATE_TAG)>

        \(FORK_DIRECTIVE_PREFIX)\(directive)
        """
    }

    // MARK: - Private

    /// Extracts the tool-use IDs from an assistant message's content list.
    private func extractToolUseBlocks(from message: MessageParameter.Message) -> [String] {
        guard case .list(let objects) = message.content else { return [] }
        return objects.compactMap { object -> String? in
            guard case .toolUse(let id, _, _) = object else { return nil }
            return id
        }
    }
}

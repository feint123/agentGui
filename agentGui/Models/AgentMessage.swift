//
//  AgentMessage.swift
//  agentGui
//
//  Structured inter-agent communication protocol inspired by AutoGen.
//  Subagents return AgentMessage instead of a plain String, enabling typed
//  content (text / structured JSON / error), sender–recipient routing, and
//  an open-ended metadata bag for observability and multi-agent workflows.
//

import Foundation

// MARK: - MessageContent

/// The typed content payload carried by an AgentMessage.
enum MessageContent: Sendable {
    /// Plain-text output — the common case.
    case text(String)

    /// Structured output stored as a valid JSON string (e.g. plans, analysis reports).
    /// The raw JSON is kept as-is so callers can decode it with any schema they need.
    case structured(String)

    /// A failure with a human-readable description.
    case error(String)

    // MARK: Derived

    /// Serialised text for the Anthropic tool-result block.
    var apiString: String {
        switch self {
        case .text(let s):        return s
        case .structured(let j): return j
        case .error(let desc):   return "Error: \(desc)"
        }
    }

    /// Short kind label used for display and persistence.
    var kindLabel: String {
        switch self {
        case .text:       return "text"
        case .structured: return "structured"
        case .error:      return "error"
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    /// Raw underlying string value (without error prefix).
    var rawText: String {
        switch self {
        case .text(let s):        return s
        case .structured(let j): return j
        case .error(let desc):   return desc
        }
    }
}

// MARK: - AgentMessage

/// A structured message passed between the main agent and a subagent.
///
/// ```
/// AgentMessage(
///     sender:    "explorer",
///     recipient: "main",
///     content:   .text("Done — found 3 relevant files."),
///     metadata:  ["rounds": "4", "tokens": "1200"]
/// )
/// ```
struct AgentMessage: Sendable {

    /// Name of the agent that produced this message (e.g. `"explorer"`, `"coder"`).
    let sender: String

    /// Intended recipient — `"main"` for results going back to the orchestrating agent,
    /// or another subagent name when chaining agents.
    let recipient: String

    /// Typed content of the message.
    let content: MessageContent

    /// Arbitrary key-value pairs for observability: round count, token usage, timing, etc.
    let metadata: [String: String]

    // MARK: Derived

    var isError: Bool { content.isError }

    /// Text suitable for use as a Claude API tool-result block.
    var apiText: String { content.apiString }

    /// Converts this message to a `ToolExecutionResult` for the agentic-loop machinery.
    func toExecutionResult() -> ToolExecutionResult {
        isError ? .failure(apiText) : ToolExecutionResult(apiText)
    }
}

// MARK: - Factory

extension AgentMessage {

    /// Build a successful plain-text message.
    static func text(
        _ text: String,
        sender: String,
        recipient: String = "main",
        metadata: [String: String] = [:]
    ) -> AgentMessage {
        AgentMessage(sender: sender, recipient: recipient, content: .text(text), metadata: metadata)
    }

    /// Build a message with structured (JSON) content.
    static func structured(
        _ json: String,
        sender: String,
        recipient: String = "main",
        metadata: [String: String] = [:]
    ) -> AgentMessage {
        AgentMessage(sender: sender, recipient: recipient, content: .structured(json), metadata: metadata)
    }

    /// Build an error message.
    static func error(
        _ description: String,
        sender: String = "system",
        recipient: String = "main",
        metadata: [String: String] = [:]
    ) -> AgentMessage {
        AgentMessage(sender: sender, recipient: recipient, content: .error(description), metadata: metadata)
    }

    /// Wrap a raw result string — automatically promotes to `.structured` when the text
    /// is valid JSON (handles agents like `planner` that always return a JSON object).
    static func detecting(
        text: String,
        sender: String,
        recipient: String = "main",
        metadata: [String: String] = [:]
    ) -> AgentMessage {
        if let structured = ModelResponseJSONExtractor.jsonCandidates(from: text).first,
           ModelResponseJSONExtractor.containsJSONObjectOrArray(in: text) {
            return AgentMessage(
                sender: sender, recipient: recipient,
                content: .structured(structured), metadata: metadata
            )
        }
        return AgentMessage(
            sender: sender, recipient: recipient,
            content: .text(text), metadata: metadata
        )
    }
}

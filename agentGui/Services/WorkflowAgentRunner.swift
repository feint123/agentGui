//
//  WorkflowAgentRunner.swift
//  agentGui
//
//  Executes a single agent role activation within a workflow.
//  Bridges the WorkflowRuntime scheduling layer to the existing
//  ClaudeService.runCoreAgentLoop machinery.
//

import Foundation
import SwiftAnthropic
import SwiftData

// MARK: - WorkflowAgentRunner

/// Runs one agent role activation: builds the prompt, calls runCoreAgentLoop,
/// parses outputs into messages and artifacts, and returns an AgentActivationResult.
struct WorkflowAgentRunner {

    let claudeService: ClaudeService
    let service: any AnthropicService
    let modelId: String
    let settings: AppSettings
    let modelContext: ModelContext

    // MARK: - Run

    func run(
        role: WorkflowRoleDefinition,
        context: WorkflowContext,
        inboxMessages: [WorkflowMessage],
        activationRecord: WorkflowActivationRecord,
        onAction: ((String) -> Void)? = nil
    ) async throws -> AgentActivationResult {

        let task = buildTask(role: role, context: context, inbox: inboxMessages)
        var loopMessages: [MessageParameter.Message] = [.init(role: .user, content: .text(task))]
        let system: MessageParameter.System? = role.systemPrompt.isEmpty
            ? nil
            : .text(role.systemPrompt)

        let tools = buildTools(role: role)

        print("[Workflow] ▶ \(role.displayName) activation | tools=\(tools.count) inbox=\(inboxMessages.count) maxTurns=\(role.maxTurnsPerActivation)")
        print("[Workflow]   task preview: \(task.prefix(200).replacingOccurrences(of: "\n", with: " "))")

        let startTime = Date()
        let outputText = try await claudeService.runCoreAgentLoop(
            messages: &loopMessages,
            service: service,
            modelId: modelId,
            tools: tools,
            system: system,
            settings: settings,
            sessionId: context.sessionId,
            modelContext: modelContext,
            maxRounds: role.maxTurnsPerActivation,
            makeRound: { idx in
                let round = AgentRound(roundIndex: idx)
                round.subagentToolCall = nil
                return round
            },
            parentMessage: nil,
            onTextAccumulated: { text in
                // Surface the last chunk of text as the "current action" for the UI
                let snippet = text.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? ""
                if !snippet.isEmpty {
                    onAction?(String(snippet.prefix(80)))
                }
            }
        )

        let elapsed = Date().timeIntervalSince(startTime)
        let turnsUsed = max(1, loopMessages.count / 2)

        print("[Workflow] ✓ \(role.displayName) loop done | elapsed=\(String(format: "%.1fs", elapsed)) turns=\(turnsUsed) outputLen=\(outputText.count)")

        // Parse the agent output into workflow messages and artifacts
        let (newMessages, newArtifacts) = parseOutput(
            text: outputText,
            role: role,
            context: context
        )

        let resultKind: ActivationResultKind = outputText.isEmpty ? .failed : .success
        let summary = buildSummary(outputText: outputText, role: role, elapsed: elapsed)

        print("[Workflow]   artifacts=\(newArtifacts.map(\.kind.displayName).joined(separator: ",")) msgs=\(newMessages.map(\.kind.displayName).joined(separator: ","))")

        return AgentActivationResult(
            role: role.name,
            outputText: outputText,
            newMessages: newMessages,
            newArtifacts: newArtifacts,
            resultKind: resultKind,
            summary: summary,
            turnsUsed: turnsUsed
        )
    }

    // MARK: - Task Construction

    private func buildTask(
        role: WorkflowRoleDefinition,
        context: WorkflowContext,
        inbox: [WorkflowMessage]
    ) -> String {
        var parts: [String] = []
        parts.append("# Workflow Task")
        parts.append("**Workflow ID**: \(context.workflowId)")
        parts.append("**Your Role**: \(role.displayName) (`\(role.name)`)")
        parts.append("**User Goal**: \(context.userTask)")

        // Workspace context (working dir, active file, selection, skills)
        let ws = context.workspaceContext
        if !ws.workingDirectory.isEmpty {
            parts.append("\n## Workspace")
            parts.append("**Working Directory**: `\(ws.workingDirectory)`")
            if let file = ws.selectedFilePath {
                parts.append("**Active File**: `\(file)`")
            }
            if let text = ws.selectedText, !text.isEmpty {
                let preview = text.count > 2000 ? String(text.prefix(2000)) + "\n…(truncated)" : text
                parts.append("**Editor Selection** (\(text.count) chars):")
                parts.append("```\n\(preview)\n```")
            }
        }
        if !ws.availableSkills.isEmpty {
            parts.append("\n## Available Skills")
            parts.append("The following skills are available on this system:")
            for skill in ws.availableSkills {
                parts.append("- **\(skill.name)**: \(skill.description)")
            }
        }

        // Include artifact context the role can read
        let readableArtifacts = context.artifacts.values.filter {
            role.readableArtifacts.contains($0.kind)
        }
        if !readableArtifacts.isEmpty {
            parts.append("\n## Available Artifacts")
            for artifact in readableArtifacts.sorted(by: { $0.kind.rawValue < $1.kind.rawValue }) {
                parts.append("### \(artifact.kind.displayName) (v\(artifact.version), \(artifact.status.displayName))")
                parts.append(artifact.contentJson)
            }
        }

        // Include inbox messages
        if !inbox.isEmpty {
            parts.append("\n## Inbox Messages")
            for msg in inbox {
                parts.append("**From**: \(msg.sender) | **Kind**: \(msg.kind.displayName) | **Subject**: \(msg.subject)")
                if !msg.body.isEmpty {
                    parts.append(msg.body)
                }
            }
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Tool Construction

    private func buildTools(role: WorkflowRoleDefinition) -> [MessageParameter.Tool] {
        // Delegate to a stub-compatible helper on ClaudeService
        // using the role's tool configuration flags.
        let stub = WorkflowToolStub(
            enableTextEditor: role.enableTextEditor,
            enableBash: role.enableBash,
            enableWebSearch: role.enableWebSearch && settings.enableWebSearchTool,
            enableWebFetch: role.enableWebFetch && settings.enableWebFetchTool
        )
        return stub.buildTools()
    }

    // MARK: - Output Parsing

    /// Attempts to extract structured messages and artifacts from agent output.
    /// Falls back to a generic statusUpdate message if no structured output is found.
    private func parseOutput(
        text: String,
        role: WorkflowRoleDefinition,
        context: WorkflowContext
    ) -> ([WorkflowMessage], [WorkflowArtifact]) {
        var messages: [WorkflowMessage] = []
        var artifacts: [WorkflowArtifact] = []

        // Try to extract a JSON artifact if the role produces one
        if let artifact = tryExtractArtifact(from: text, role: role, context: context) {
            artifacts.append(artifact)
            // Emit a handoff/statusUpdate pointing at the artifact
            let recipients = role.defaultOutputRecipients(context: context)
            if !recipients.isEmpty {
                messages.append(WorkflowMessage(
                    workflowId: context.workflowId,
                    sender: role.name,
                    recipients: recipients,
                    kind: role.defaultOutputMessageKind,
                    subject: "\(role.displayName) produced \(artifact.kind.displayName)",
                    body: "See artifact: \(artifact.id)",
                    artifactRefs: [artifact.id]
                ))
            }
        } else {
            // No structured artifact — emit a plain statusUpdate
            let recipients = role.defaultOutputRecipients(context: context)
            if !recipients.isEmpty {
                messages.append(WorkflowMessage(
                    workflowId: context.workflowId,
                    sender: role.name,
                    recipients: recipients,
                    kind: .statusUpdate,
                    subject: "\(role.displayName) completed activation",
                    body: text.count > 500 ? String(text.prefix(500)) + "…" : text
                ))
            }
        }

        return (messages, artifacts)
    }

    private func tryExtractArtifact(
        from text: String,
        role: WorkflowRoleDefinition,
        context: WorkflowContext
    ) -> WorkflowArtifact? {
        guard let kind = role.primaryOutputArtifactKind else { return nil }

        // Look for a JSON block in the output
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var jsonCandidate: String? = nil

        // Try fenced ```json block first
        if let range = trimmed.range(of: "```json\n"),
           let endRange = trimmed.range(of: "\n```", range: range.upperBound..<trimmed.endIndex) {
            jsonCandidate = String(trimmed[range.upperBound..<endRange.lowerBound])
        }

        // Fall back to bare JSON object
        if jsonCandidate == nil && (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) {
            jsonCandidate = trimmed
        }

        guard let json = jsonCandidate,
              let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else { return nil }

        let artifactId = "\(kind.rawValue)-\(context.workflowId.uuidString.prefix(8))"
        let existing = context.artifacts[artifactId]
        let version = (existing?.version ?? 0) + 1

        return WorkflowArtifact(
            id: artifactId,
            workflowId: context.workflowId,
            kind: kind,
            title: "\(kind.displayName) v\(version)",
            producer: role.name,
            version: version,
            contentJson: json,
            status: .draft
        )
    }

    private func buildSummary(outputText: String, role: WorkflowRoleDefinition, elapsed: TimeInterval) -> String {
        let first = outputText
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let preview = first.count > 120 ? String(first.prefix(120)) + "…" : first
        return "[\(role.displayName)] \(String(format: "%.1fs", elapsed)) — \(preview)"
    }
}

// MARK: - WorkflowToolStub

/// Utility that constructs tool parameter arrays for a given capability set.
/// Mirrors the logic in ClaudeService+Subagent without requiring a ClaudeService reference.
private struct WorkflowToolStub {
    let enableTextEditor: Bool
    let enableBash: Bool
    let enableWebSearch: Bool
    let enableWebFetch: Bool

    func buildTools() -> [MessageParameter.Tool] {
        var tools: [MessageParameter.Tool] = []

        if enableTextEditor {
            tools.append(.function(
                name: "str_replace_based_edit_tool",
                description: """
                A text editor for viewing and modifying files. Supported commands:
                - view: Read file contents, optionally with view_range [start, end] (1-based line numbers)
                - str_replace: Replace an exact string in a file: provide old_str and new_str
                - create: Create or overwrite a file with file_text
                - insert: Insert new_str after insert_line (0 = prepend)
                Always use absolute file paths.
                """,
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "command":    .init(type: .string,  description: "One of: view, str_replace, create, insert"),
                        "path":       .init(type: .string,  description: "Absolute path to the target file"),
                        "old_str":    .init(type: .string,  description: "(str_replace) Exact text to find and replace"),
                        "new_str":    .init(type: .string,  description: "(str_replace/insert) Replacement or inserted text"),
                        "file_text":  .init(type: .string,  description: "(create) Full content of the new file"),
                        "insert_line":.init(type: .integer, description: "(insert) Line number to insert after; 0 = before line 1"),
                        "view_range": .init(type: .array,   description: "(view) Optional [start_line, end_line] to limit output")
                    ],
                    required: ["command", "path"]
                )
            ))
        }

        if enableBash {
            tools.append(.function(
                name: "bash",
                description: """
                Execute shell commands in a persistent bash session. \
                The session preserves working directory and environment variables across calls.
                """,
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "command":    .init(type: .string,  description: "The bash command to execute"),
                        "restart":    .init(type: .boolean, description: "If true, restart the bash session"),
                        "timeout":    .init(type: .integer, description: "Max seconds to wait (default 300)"),
                        "background": .init(type: .boolean, description: "Run in background and return immediately")
                    ],
                    required: []
                )
            ))
        }

        if enableWebSearch {
            tools.append(.function(
                name: "web_search",
                description: "Search the web and return relevant results (title, URL, snippet).",
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "query": .init(type: .string,  description: "The search query"),
                        "count": .init(type: .integer, description: "Number of results (1-10, default 5)")
                    ],
                    required: ["query"]
                )
            ))
        }

        if enableWebFetch {
            tools.append(.function(
                name: "web_fetch",
                description: "Fetch a webpage and return its cleaned text content.",
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "url":       .init(type: .string,  description: "The full URL to fetch"),
                        "max_chars": .init(type: .integer, description: "Maximum characters to return (default 8000)")
                    ],
                    required: ["url"]
                )
            ))
        }

        return tools
    }
}

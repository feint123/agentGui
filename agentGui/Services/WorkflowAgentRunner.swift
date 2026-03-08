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

        // Artifact capture: roles with a primaryOutputArtifactKind MUST call
        // emit_workflow_artifact. If they don't, the activation is marked failed.
        let collector = WorkflowEmitCollector()
        let workflowId = context.workflowId
        let roleName = role.name
        let existingVersion = role.primaryOutputArtifactKind.flatMap { k in
            context.artifacts["\(k.rawValue)-\(workflowId.uuidString.prefix(8))"]?.version
        } ?? 0

        // Build the interceptor only when an artifact output is required for this role
        let artifactInterceptor: ((String, MessageResponse.Content.Input) async -> ToolExecutionResult?)?
        if role.primaryOutputArtifactKind != nil {
            artifactInterceptor = { [collector] toolName, input in
                guard toolName == "emit_workflow_artifact" else { return nil }
                guard let kindRaw = input["kind"]?.stringValue,
                      let kind = WorkflowArtifactKind(rawValue: kindRaw),
                      let contentJson = input["contentJson"]?.stringValue else {
                    return .missingParameter("kind or contentJson")
                }
                guard let data = contentJson.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: data)) != nil else {
                    return .failure("Error: contentJson is not valid JSON")
                }
                let statusRaw = input["status"]?.stringValue ?? ArtifactStatus.draft.rawValue
                let artifactStatus = ArtifactStatus(rawValue: statusRaw) ?? .draft
                let artifactId = "\(kind.rawValue)-\(workflowId.uuidString.prefix(8))"
                let version = existingVersion + 1
                let artifact = WorkflowArtifact(
                    id: artifactId,
                    workflowId: workflowId,
                    kind: kind,
                    title: "\(kind.displayName) v\(version)",
                    producer: roleName,
                    version: version,
                    contentJson: contentJson,
                    status: artifactStatus
                )
                await collector.capture(artifact)
                return .success("Artifact '\(kind.displayName)' v\(version) registered.")
            }
        } else {
            artifactInterceptor = nil
        }

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
                let snippet = text.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? ""
                if !snippet.isEmpty {
                    onAction?(String(snippet.prefix(80)))
                }
            },
            toolInterceptor: artifactInterceptor
        )

        let elapsed = Date().timeIntervalSince(startTime)
        let turnsUsed = max(1, loopMessages.count / 2)
        let capturedArtifact = await collector.capturedArtifact

        print("[Workflow] ✓ \(role.displayName) loop done | elapsed=\(String(format: "%.1fs", elapsed)) turns=\(turnsUsed) outputLen=\(outputText.count) artifact=\(capturedArtifact.map { $0.kind.displayName } ?? "none")")

        let resultKind: ActivationResultKind
        if outputText.isEmpty {
            resultKind = .failed
        } else if role.primaryOutputArtifactKind != nil, capturedArtifact == nil {
            print("[Workflow] ✗ \(role.displayName) rejected — emit_workflow_artifact was not called")
            resultKind = .failed
        } else {
            resultKind = .success
        }

        let (newMessages, newArtifacts) = buildOutputFromCapture(
            capturedArtifact: capturedArtifact,
            role: role,
            context: context
        )
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

        // Mandatory output requirement: remind the agent it must call emit_workflow_artifact
        if let kind = role.primaryOutputArtifactKind {
            parts.append("\n## ⚠ Required: Emit Artifact")
            parts.append("""
            You **must** call the `emit_workflow_artifact` tool exactly once before finishing. \
            Use `kind = "\(kind.rawValue)"`, `schemaVersion = 1`, and put your complete structured \
            output in `contentJson` as a valid JSON string. \
            **Failing to call this tool will mark your activation as failed.**
            """)
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Tool Construction

    private func buildTools(role: WorkflowRoleDefinition) -> [MessageParameter.Tool] {
        let stub = WorkflowToolStub(
            enableTextEditor: role.enableTextEditor,
            enableBash: role.enableBash,
            enableWebSearch: role.enableWebSearch && settings.enableWebSearchTool,
            enableWebFetch: role.enableWebFetch && settings.enableWebFetchTool
        )
        var tools = stub.buildTools()
        if role.primaryOutputArtifactKind != nil {
            tools.append(makeEmitArtifactTool())
        }
        return tools
    }

    private func makeEmitArtifactTool() -> MessageParameter.Tool {
        .function(
            name: "emit_workflow_artifact",
            description: """
            Submit the structured artifact that is the primary output of this activation. \
            You MUST call this tool exactly once before finishing. \
            Not calling it means your activation is rejected.
            """,
            inputSchema: .init(
                type: .object,
                properties: [
                    "kind": .init(type: .string,
                        description: "Artifact kind: plan | explorationReport | codePatchSummary | reviewReport | testReport | decisionLog | finalAnswer"),
                    "schemaVersion": .init(type: .integer,
                        description: "Schema version. Use 1."),
                    "contentJson": .init(type: .string,
                        description: "Full artifact payload serialised as a valid JSON string."),
                    "status": .init(type: .string,
                        description: "Artifact status: draft | approved | rejected | superseded (default: draft)")
                ],
                required: ["kind", "schemaVersion", "contentJson"]
            )
        )
    }

    // MARK: - Output Assembly

    /// Builds output messages and artifacts from the artifact explicitly emitted
    /// via the `emit_workflow_artifact` tool call. If no artifact was captured,
    /// returns empty arrays (caller is responsible for failing the activation).
    private func buildOutputFromCapture(
        capturedArtifact: WorkflowArtifact?,
        role: WorkflowRoleDefinition,
        context: WorkflowContext
    ) -> ([WorkflowMessage], [WorkflowArtifact]) {
        guard let artifact = capturedArtifact else {
            return ([], [])
        }

        var messages: [WorkflowMessage] = []
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
        return (messages, [artifact])
    }

    private func buildSummary(outputText: String, role: WorkflowRoleDefinition, elapsed: TimeInterval) -> String {
        let first = outputText
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let preview = first.count > 120 ? String(first.prefix(120)) + "…" : first
        return "[\(role.displayName)] \(String(format: "%.1fs", elapsed)) — \(preview)"
    }
}

// MARK: - WorkflowEmitCollector

/// Captures the artifact emitted by the `emit_workflow_artifact` tool call
/// during a single agent activation. Thread-safe via actor isolation.
private actor WorkflowEmitCollector {
    private(set) var capturedArtifact: WorkflowArtifact? = nil

    func capture(_ artifact: WorkflowArtifact) {
        capturedArtifact = artifact
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

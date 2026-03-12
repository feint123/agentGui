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

    static func makeToolsForTests(
        role: WorkflowRoleDefinition,
        settings: AppSettings
    ) -> [MessageParameter.Tool] {
        var tools = DefaultToolsetResolver(registry: DefaultToolRegistry()).resolve(
            .init(context: .workflowWorker, role: role, settings: settings)
        ).tools
        if role.primaryOutputArtifactKind != nil {
            tools.append(makeEmitArtifactTool(claudeService: ClaudeService()))
        }
        return tools
    }

    // MARK: - Run

    func run(
        role: WorkflowRoleDefinition,
        context: WorkflowContext,
        inboxMessages: [WorkflowMessage],
        activationRecord: WorkflowActivationRecord,
        onAction: ((String) -> Void)? = nil
    ) async throws -> AgentActivationResult {
        func emitBusinessEvent(_ event: AgentBusinessEvent, metadata: [String: Any] = [:]) {
            let contextMetadata = BusinessLogContext(
                workflowID: context.workflowId.uuidString
            )
            BusinessMonitor.emit(event, context: contextMetadata, metadata: metadata, sink: claudeService.businessLogSink)
        }

        let taskPackage = buildTask(role: role, context: context, inbox: inboxMessages)
        let task = taskPackage.task
        var loopMessages: [MessageParameter.Message] = [.init(role: .user, content: .text(task))]
        let system = claudeService.makeEphemeralSystemPrompt(role.systemPrompt)

        let tools = buildTools(role: role)

        emitBusinessEvent(
            .workflowActivationStarted,
            metadata: [
                "activationID": activationRecord.id.uuidString,
                "roleName": role.name,
                "roleDisplayName": role.displayName,
                "inboxCount": inboxMessages.count,
                "maxTurns": role.maxTurnsPerActivation,
                "toolCount": tools.count,
                "taskPreview": String(task.prefix(200)).replacingOccurrences(of: "\n", with: " ")
            ]
        )

        // Artifact capture: roles with a primaryOutputArtifactKind MUST call
        // emit_workflow_artifact. If they don't, the activation is marked failed.
        let collector = WorkflowEmitCollector()
        let violationCollector = WorkflowContractViolationCollector()
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
                // Contract enforcement: reject writes for kinds outside writableArtifacts.
                guard role.writableArtifacts.contains(kind) else {
                    let violation = WorkflowContractViolation(
                        kind: .unwritableArtifact,
                        roleName: roleName,
                        message: "Rejected emit request for '\(kind.rawValue)'. Permitted writable artifacts: [\(role.writableArtifacts.map(\.rawValue).sorted().joined(separator: ", "))]",
                        artifactKind: kind
                    )
                    await violationCollector.capture(violation)
                    emitBusinessEvent(
                        .workflowContractViolation,
                        metadata: [
                            "roleName": roleName,
                            "violationKind": violation.kind.rawValue,
                            "summary": violation.summary,
                            "artifactKind": kind.rawValue
                        ]
                    )
                    return .failure("Contract violation: role '\(roleName)' cannot write '\(kind.rawValue)'. Permitted kinds: [\(role.writableArtifacts.map(\.rawValue).sorted().joined(separator: ", "))]")
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
        let request = AgentLoopRunRequest(
            service: service,
            modelId: modelId,
            tools: tools,
            system: system,
            maxRounds: role.maxTurnsPerActivation,
            toolExecutionContext: .workflowWorker
        )
        let runtime = AgentLoopRuntime(
            settings: settings,
            session: nil,
            sessionId: context.sessionId,
            modelContext: modelContext,
            makeRound: { idx in
                let round = AgentRound(roundIndex: idx)
                round.subagentToolCall = nil
                return round
            },
            parentMessage: nil,
            streamProjectionTarget: onAction.map { action in
                .workflowAction(action)
            } ?? .none,
            toolInterceptor: artifactInterceptor
        )
        let loopResult = try await claudeService.runCoreAgentLoop(
            messages: &loopMessages,
            request: request,
            runtime: runtime
        )
        let outputText = loopResult.text

        let elapsed = Date().timeIntervalSince(startTime)
        let turnsUsed = max(1, loopMessages.count / 2)
        let capturedArtifact = await collector.capturedArtifact
        let interceptedViolations = await violationCollector.violations
        let contractViolations = taskPackage.contractViolations + interceptedViolations

        let resultKind: ActivationResultKind
        if outputText.isEmpty || !loopResult.completedSuccessfully {
            resultKind = .failed
        } else if role.primaryOutputArtifactKind != nil, capturedArtifact == nil {
            emitBusinessEvent(
                .workflowContractViolation,
                metadata: [
                    "roleName": role.name,
                    "violationKind": "missingPrimaryArtifact",
                    "summary": "emit_workflow_artifact was not called for a role that requires a primary artifact"
                ]
            )
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

        let result = AgentActivationResult(
            role: role.name,
            outputText: outputText,
            newMessages: newMessages,
            newArtifacts: newArtifacts,
            resultKind: resultKind,
            summary: summary,
            turnsUsed: turnsUsed,
            contractViolations: contractViolations
        )
        emitBusinessEvent(
            .workflowActivationFinished,
            metadata: [
                "activationID": activationRecord.id.uuidString,
                "roleName": role.name,
                "resultKind": result.resultKind.rawValue,
                "turnsUsed": result.turnsUsed,
                "artifactCount": result.newArtifacts.count,
                "messageCount": result.newMessages.count,
                "elapsedSeconds": elapsed,
                "outputLength": outputText.count,
                "contractViolationCount": contractViolations.count
            ]
        )
        return result
    }

    // MARK: - Task Construction

    private func buildTask(
        role: WorkflowRoleDefinition,
        context: WorkflowContext,
        inbox: [WorkflowMessage]
    ) -> WorkflowTaskPackage {
        var parts: [String] = []
        var violations: [WorkflowContractViolation] = []
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

        // Include artifact context the role can read.
        // Contract enforcement: artifacts whose kind is not in readableArtifacts are silently
        // withheld from the prompt (hard read-access control).
        let readableArtifacts = context.artifacts.values.filter {
            role.readableArtifacts.contains($0.kind)
        }
        let readableArtifactsById = Dictionary(uniqueKeysWithValues: readableArtifacts.map { ($0.id, $0) })
        // Include inbox messages
        if !inbox.isEmpty {
            parts.append("\n## Inbox Messages")
            for msg in inbox {
                parts.append("**From**: \(msg.sender) | **Kind**: \(msg.kind.displayName) | **Subject**: \(msg.subject)")
                if !msg.body.isEmpty {
                    parts.append(msg.body)
                }
                if !msg.artifactRefs.isEmpty {
                    let readableRefs = msg.artifactRefs.filter { readableArtifactsById[$0] != nil }
                    let unreadableRefs = msg.artifactRefs.filter { readableArtifactsById[$0] == nil }
                    if !readableRefs.isEmpty {
                        parts.append("**Referenced Artifacts**: \(readableRefs.joined(separator: ", "))")
                    }
                    for artifactId in msg.artifactRefs {
                        guard let artifact = readableArtifactsById[artifactId] else {
                            let violation = WorkflowContractViolation(
                                kind: .unreadableArtifact,
                                roleName: role.name,
                                message: "Artifact reference was withheld because its kind is outside readableArtifacts.",
                                messageKind: msg.kind,
                                artifactId: artifactId,
                                sender: msg.sender
                            )
                            violations.append(violation)
                            continue
                        }
                        parts.append(renderArtifact(artifact, headingPrefix: "####"))
                    }
                    if !unreadableRefs.isEmpty {
                        parts.append("- One or more referenced artifacts were withheld by workflow contract.")
                    }
                }
            }
        }

        if role.name == "worker",
           let evaluatorEntry = renderEvaluatorLoopEntry(in: context, inbox: inbox) {
            parts.append(evaluatorEntry)
        }

        let referencedArtifactIds = Set(inbox.flatMap(\.artifactRefs))
        let additionalArtifacts = readableArtifacts
            .filter { !referencedArtifactIds.contains($0.id) }
            .sorted(by: { $0.kind.rawValue < $1.kind.rawValue })
        if !additionalArtifacts.isEmpty {
            parts.append("\n## Additional Available Artifacts")
            for artifact in additionalArtifacts {
                parts.append(renderArtifact(artifact, headingPrefix: "###"))
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

        return WorkflowTaskPackage(
            task: parts.joined(separator: "\n"),
            contractViolations: violations
        )
    }

    private func renderArtifact(_ artifact: WorkflowArtifact, headingPrefix: String) -> String {
        [
            "\(headingPrefix) \(artifact.kind.displayName) (id: \(artifact.id), v\(artifact.version), \(artifact.status.displayName))",
            artifact.contentJson,
        ].joined(separator: "\n")
    }

    private func renderEvaluatorLoopEntry(
        in context: WorkflowContext,
        inbox: [WorkflowMessage]
    ) -> String? {
        guard inbox.contains(where: { $0.kind == .reviewFeedback || $0.kind == .rejection }),
              let failure = context.evaluatorLoop.latestFailure else {
            return nil
        }

        return [
            "\n## Evaluator Loop Entry",
            "You are re-entering the worker because the previous candidate failed evaluator checks.",
            "Carry every item in the structured payload below into the next patch and address them explicitly.",
            "```json",
            serializeEvaluatorFailure(failure, historyCount: context.evaluatorLoop.failureHistory.count),
            "```"
        ].joined(separator: "\n")
    }

    private func serializeEvaluatorFailure(
        _ failure: WorkflowEvaluatorFailureRecord,
        historyCount: Int
    ) -> String {
        let jsonObject: [String: Any] = [
            "evaluator_iteration": failure.iteration,
            "failed_patch": [
                "artifact_id": failure.patchArtifactId,
                "version": failure.patchVersion
            ],
            "trigger_kind": failure.triggerKind.rawValue,
            "must_address": failure.outcomes.map { outcome in
                [
                    "source": outcome.source.rawValue,
                    "summary": outcome.summary,
                    "reasons": outcome.reasons,
                    "artifact_id": outcome.artifactId,
                    "artifact_version": outcome.artifactVersion
                ]
            },
            "failure_history_count": historyCount
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else {
            return "{ \"evaluator_iteration\": \(failure.iteration) }"
        }
        return text
    }

    // MARK: - Tool Construction

    private func buildTools(role: WorkflowRoleDefinition) -> [MessageParameter.Tool] {
        var tools = DefaultToolsetResolver(registry: DefaultToolRegistry()).resolve(
            .init(context: .workflowWorker, role: role, settings: settings)
        ).tools
        if role.primaryOutputArtifactKind != nil {
            tools.append(Self.makeEmitArtifactTool(claudeService: claudeService))
        }
        return tools
    }

    private static func makeEmitArtifactTool(claudeService: ClaudeService) -> MessageParameter.Tool {
        if let definition = DefaultToolRegistry().definition(for: "emit_workflow_artifact") {
            return definition.makeAnthropicTool(context: .default)
        }
        return claudeService.makeEphemeralTool(name: "emit_workflow_artifact")
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

private actor WorkflowContractViolationCollector {
    private(set) var violations: [WorkflowContractViolation] = []

    func capture(_ violation: WorkflowContractViolation) {
        violations.append(violation)
    }
}

private struct WorkflowTaskPackage {
    let task: String
    let contractViolations: [WorkflowContractViolation]
}

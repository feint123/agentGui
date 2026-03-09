//
//  ClaudeService+WorkflowTool.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

extension ClaudeService {

    // MARK: - Start Workflow

    /// Launches a named workflow synchronously and returns a result summary.
    func executeStartWorkflowTool(
        input: MessageResponse.Content.Input,
        modelContext: ModelContext
    ) async -> ToolExecutionResult {
        guard let workflowId = input["workflow_id"]?.stringValue else {
            return .missingParameter("workflow_id")
        }
        guard let task = input["task"]?.stringValue else {
            return .missingParameter("task")
        }
        guard let definition = ClaudeService.makeWorkflowDefinition(id: workflowId) else {
            let available = ClaudeService.availableWorkflows.map(\.id).joined(separator: ", ")
            return .failure("Error: unknown workflow_id '\(workflowId)'. Available: \(available)")
        }
        guard let runtime = workflowRuntime else {
            return .failure("Error: workflow runtime is not available")
        }
        guard let session = currentSession else {
            return .failure("Error: no active session for workflow")
        }

        if runtime.isRunning {
            return .failure("Error: a workflow is already running. Wait for it to complete before launching another.")
        }

        do {
            let handle = try await runtime.startWorkflow(
                definition: definition,
                session: session,
                initialTask: task,
                workspaceContext: currentWorkspaceContext,
                modelContext: modelContext
            )
            // Fetch the persisted instance for status/artifact info
            let wfId = handle.workflowId
            let descriptor = FetchDescriptor<WorkflowInstance>(
                predicate: #Predicate { $0.id == wfId }
            )
            let instance = (try? modelContext.fetch(descriptor))?.first
            let statusName = instance?.status.displayName ?? "完成"
            let artifactSummary = instance?.latestArtifacts
                .map { "\($0.kind.displayName) (v\($0.version))" }
                .joined(separator: ", ") ?? "无"
            return .success("""
            Workflow '\(definition.displayName)' completed. Status: \(statusName)
            Artifacts: \(artifactSummary)
            Workflow ID: \(handle.workflowId)

            The workflow sidebar in the UI shows the full execution timeline, inter-agent messages, and artifacts.
            Summarize the outcome for the user based on this information.
            """)
        } catch {
            return .failure("Error: workflow failed — \(error.localizedDescription)")
        }
    }
}

//
//  WorkflowRuntime.swift
//  agentGui
//
//  The orchestration engine for multi-agent workflows. Manages scheduling,
//  mailbox delivery, artifact versioning, checkpointing, and budget enforcement.
//
//  Architecture diagram:
//
//  WorkflowRuntime
//    ├─ WorkflowContext (shared mutable state)
//    ├─ WorkflowScheduler (which role runs next)
//    ├─ WorkflowAgentRunner (executes a role activation)
//    ├─ WorkflowReducer (applies result to context)
//    └─ SwiftData (persists WorkflowInstance + records)
//

import Foundation
import SwiftData

// MARK: - WorkflowHandle

/// Lightweight reference to a running or completed workflow, returned by startWorkflow().
struct WorkflowHandle: Sendable {
    let workflowId: UUID
    let definitionId: String
}

// MARK: - WorkflowRuntime

@Observable
@MainActor
final class WorkflowRuntime {

    // MARK: - Observable State

    /// Currently active workflow context, if any.
    private(set) var activeContext: WorkflowContext?
    /// Whether a workflow is currently running.
    var isRunning: Bool = false
    /// Last error message from a workflow run.
    var lastError: String?
    /// The name of the role currently executing, if any.
    private(set) var activeRoleName: String? = nil
    /// Latest action/status text per role (role name → description).
    private(set) var currentActionByRole: [String: String] = [:]

    // MARK: - Dependencies

    private let claudeService: ClaudeService

    // MARK: - Init

    init(claudeService: ClaudeService) {
        self.claudeService = claudeService
    }

    // MARK: - Public API

    // MARK: - Logging

    private func log(_ msg: String) {
        print("[Workflow] \(msg)")
    }

    // MARK: - Public API

    /// Starts a new workflow and runs the scheduling loop until completion.
    @discardableResult
    func startWorkflow(
        definition: any WorkflowDefinition,
        session: any SessionProtocol,
        initialTask: String,
        workspaceContext: WorkflowWorkspaceContext = .empty,
        modelContext: ModelContext
    ) async throws -> WorkflowHandle {
        guard !isRunning else {
            throw WorkflowError.alreadyRunning
        }
        guard let anthropicService = claudeService.service else {
            throw WorkflowError.notConfigured
        }
        let settings = AppSettings.getOrCreate(in: modelContext)

        isRunning = true
        lastError = nil
        defer {
            isRunning = false
            activeRoleName = nil
        }

        log("━━━ Workflow START ━━━")
        log("  definition : \(definition.id) (\(definition.displayName))")
        log("  session    : \(session.sessionId)")
        log("  task       : \(initialTask.prefix(120))")
        log("  workingDir : \(workspaceContext.workingDirectory.isEmpty ? "(none)" : workspaceContext.workingDirectory)")
        if let file = workspaceContext.selectedFilePath { log("  activeFile : \(file)") }
        if let sel = workspaceContext.selectedText { log("  selection  : \(sel.count) chars") }
        log("  skills     : \(workspaceContext.availableSkills.map(\.name).joined(separator: ", "))")

        // Build initial context
        var context = definition.makeInitialContext(task: initialTask, sessionId: session.sessionId)
        context.workspaceContext = workspaceContext

        // Persist the WorkflowInstance
        let instance = WorkflowInstance(
            id: context.workflowId,
            sessionId: context.sessionId,
            definitionId: definition.id,
            userTask: initialTask,
            budget: context.budget,
            policies: context.policies
        )
        modelContext.insert(instance)
        try? modelContext.save()

        let scheduler = definition.makeScheduler()
        var reducer = definition.makeReducer()
        let runner = WorkflowAgentRunner(
            claudeService: claudeService,
            service: anthropicService,
            modelId: settings.selectedModel,
            settings: settings,
            modelContext: modelContext
        )

        context.status = .running
        instance.status = .running
        self.activeContext = context
        log("  roles      : \(context.roles.map(\.name).joined(separator: " → "))")
        log("  budget     : rounds=\(context.budget.maxTotalRounds) activations/role=\(context.budget.maxActivationsPerRole) turns/activation=\(context.budget.maxTurnsPerActivation)")

        // MARK: Main Scheduling Loop

        while context.isActive {
            try Task.checkCancellation()

            // Budget check
            if context.totalActivations >= context.budget.maxTotalRounds {
                log("⛔ Budget exceeded: totalActivations=\(context.totalActivations) >= max=\(context.budget.maxTotalRounds)")
                context.status = .failed
                break
            }

            // Stall detection
            if context.policies.stallTimeoutSeconds > 0 {
                let idle = Date().timeIntervalSince(context.lastProgressAt)
                if idle > context.policies.stallTimeoutSeconds {
                    log("⏸ Stall detected: no progress for \(Int(idle))s (threshold=\(Int(context.policies.stallTimeoutSeconds))s)")
                    context.status = .paused  // surface to user
                    if context.policies.escalateOnStall {
                        deliverEscalation(context: &context, reason: "Stalled: no progress for \(Int(idle))s")
                    }
                    break
                }
            }

            // Log mailbox snapshot before scheduling
            let runnableRoles = scheduler.runnableRoles(in: context)
            log("── Tick \(context.totalTicks + 1) | runnable=\(runnableRoles.isEmpty ? "(none)" : runnableRoles.joined(separator: ", ")) | totalActivations=\(context.totalActivations)")

            // Pick next role
            guard let roleName = scheduler.chooseNextRole(in: context),
                  let role = context.roles.first(where: { $0.name == roleName })
            else {
                // No runnable role — workflow is complete or paused
                if scheduler.runnableRoles(in: context).isEmpty {
                    log("✅ No runnable roles remaining — marking completed")
                    context.status = .completed
                } else {
                    log("⏸ Scheduler returned nil despite runnable roles — pausing")
                }
                break
            }

            log("▶ Scheduler chose: \(roleName)")

            // Per-role activation budget
            let activationCount = context.activationCount(for: roleName)
            if activationCount >= role.maxActivations {
                log("⛔ \(roleName) exhausted: activations=\(activationCount) >= max=\(role.maxActivations) — blocking")
                // Mark role as exhausted and continue to next
                context.agentStates[roleName]?.isBlocked = true
                context.agentStates[roleName]?.blockReason = "Max activations (\(role.maxActivations)) reached"
                continue
            }

            // Create activation record
            let inbox = context.drainInbox(for: roleName)
            let activationRecord = WorkflowActivationRecord(
                workflowId: context.workflowId,
                role: roleName,
                roleDisplayName: role.displayName,
                triggerReason: inbox.first?.subject ?? "scheduled"
            )
            modelContext.insert(activationRecord)
            instance.activations.append(activationRecord)
            try? modelContext.save()

            context.recordActivation(for: roleName)
            context.totalTicks += 1
            self.activeContext = context

            let inboxSummary = inbox.map { "\($0.kind.displayName): \($0.subject)" }.joined(separator: "; ")
            log("  activation #\(activationCount + 1) | inbox=\(inbox.count) msg(s): \(inboxSummary.isEmpty ? "(none)" : inboxSummary)")

            // Mark this role as currently running
            activeRoleName = roleName
            currentActionByRole[roleName] = inbox.first?.subject.isEmpty == false
                ? inbox.first!.subject
                : "正在处理任务..."

            // Run the agent
            let result: AgentActivationResult
            do {
                result = try await runner.run(
                    role: role,
                    context: context,
                    inboxMessages: inbox,
                    activationRecord: activationRecord,
                    onAction: { [weak self] action in
                        self?.currentActionByRole[roleName] = action
                    }
                )
            } catch {
                log("❌ \(roleName) activation FAILED: \(error.localizedDescription)")
                activationRecord.markCompleted(turnsUsed: 0, result: .failed, summary: error.localizedDescription)
                activeRoleName = nil
                currentActionByRole[roleName] = "失败：\(error.localizedDescription)"
                try? modelContext.save()
                // Decide whether to abort or continue
                if context.policies.maxRetries == 0 {
                    context.status = .failed
                    break
                }
                continue
            }

            // Role finished — clear active state
            activeRoleName = nil
            currentActionByRole[roleName] = result.summary.isEmpty ? "完成" : String(result.summary.prefix(80))

            // Log activation result
            let artifactKinds = result.newArtifacts.map(\.kind.displayName).joined(separator: ", ")
            let msgKinds = result.newMessages.map(\.kind.displayName).joined(separator: ", ")
            log("  ✓ \(roleName) done | result=\(result.resultKind) turns=\(result.turnsUsed) artifacts=[\(artifactKinds.isEmpty ? "none" : artifactKinds)] msgs=[\(msgKinds.isEmpty ? "none" : msgKinds)]")

            // Persist activation result
            activationRecord.markCompleted(
                turnsUsed: result.turnsUsed,
                result: result.resultKind,
                summary: result.summary
            )

            // Persist new messages
            for msg in result.newMessages {
                let record = WorkflowMessageRecord(
                    workflowId: context.workflowId,
                    sender: msg.sender,
                    recipients: msg.recipients,
                    kind: msg.kind,
                    subject: msg.subject,
                    body: msg.body,
                    artifactRefs: msg.artifactRefs
                )
                modelContext.insert(record)
                instance.messages.append(record)
            }

            // Persist new/updated artifacts
            for artifact in result.newArtifacts {
                let record = WorkflowArtifactRecord(
                    artifactId: artifact.id,
                    workflowId: context.workflowId,
                    kind: artifact.kind,
                    title: artifact.title,
                    producer: artifact.producer,
                    version: artifact.version,
                    contentJson: artifact.contentJson,
                    status: artifact.status
                )
                modelContext.insert(record)
                instance.artifacts.append(record)
            }

            try? modelContext.save()

            // Apply result to shared context via reducer
            try reducer.apply(activationResult: result, to: &context)
            self.activeContext = context

            // Log post-reducer state
            let pendingBoxes = context.mailboxes.filter { $0.value.hasMessages }.map { "\($0.key)(\($0.value.inbox.count))" }.joined(separator: " ")
            log("  context status=\(context.status.displayName) | pending mailboxes: \(pendingBoxes.isEmpty ? "(none)" : pendingBoxes) | artifacts=\(context.artifacts.count)")
        }

        // Final status sync
        instance.status = context.status
        try? modelContext.save()

        log("━━━ Workflow DONE  ━━━")
        log("  id     : \(context.workflowId)")
        log("  status : \(context.status.displayName)")
        log("  ticks  : \(context.totalTicks) | activations: \(context.totalActivations)")
        log("  artifacts produced: \(context.artifacts.values.map(\.kind.displayName).joined(separator: ", "))")
        return WorkflowHandle(workflowId: context.workflowId, definitionId: definition.id)
    }

    /// Cancels the currently active workflow.
    func cancelWorkflow() {
        activeContext?.status = .cancelled
    }

    // MARK: - Helpers

    private func deliverEscalation(context: inout WorkflowContext, reason: String) {
        let msg = WorkflowMessage(
            workflowId: context.workflowId,
            sender: "runtime",
            recipients: ["planner"],
            kind: .escalation,
            subject: "Workflow stalled",
            body: reason
        )
        context.deliver(msg)
    }
}

// MARK: - WorkflowError

enum WorkflowError: LocalizedError {
    case alreadyRunning
    case notConfigured
    case budgetExceeded
    case noRunnableRole

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:  return "A workflow is already running"
        case .notConfigured:   return "ClaudeService is not configured"
        case .budgetExceeded:  return "Workflow budget exceeded"
        case .noRunnableRole:  return "No runnable role found"
        }
    }
}

// MARK: - SessionProtocol

/// Minimal protocol so WorkflowRuntime doesn't import SwiftData's Session directly.
protocol SessionProtocol {
    var sessionId: String { get }
}

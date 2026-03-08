//
//  CodeChangeWorkflow.swift
//  agentGui
//
//  The first concrete WorkflowDefinition: a multi-agent coding workflow that
//  orchestrates planner → explorer → coder → reviewer → executor, with
//  support for review feedback loops and context request loops.
//
//  Default execution path:
//
//    start → planner → explorer (if needed) → coder → reviewer ─┐
//                          ↑                    ↑   ↓ approved   │
//                          └── infoRequest ─────┘ rejection     │
//                                                   ↓            │
//                                               executor ────────┘ (done)
//

import Foundation

// MARK: - CodeChangeWorkflow

struct CodeChangeWorkflow: WorkflowDefinition {
    let id = "code_change"
    let displayName = "代码变更流程"
    let description = "多代理协作完成代码修改：规划 → 探索 → 编码 → 审查 → 验证"

    func makeInitialContext(task: String, sessionId: String) -> WorkflowContext {
        var ctx = WorkflowContext(
            sessionId: sessionId,
            definitionId: id,
            userTask: task,
            budget: WorkflowBudget(
                maxTotalRounds: 80,
                maxActivationsPerRole: 5,
                maxTurnsPerActivation: 16,
                timeoutSeconds: 0
            ),
            policies: WorkflowPolicies(
                stallTimeoutSeconds: 180,
                maxRetries: 2,
                repeatFindingThreshold: 2,
                allowParallelActivations: false,
                escalateOnStall: true
            )
        )

        ctx.roles = [
            .planner,
            .explorer,
            .coder,
            .reviewer,
            .executor,
        ]

        // Seed mailboxes
        for role in ctx.roles {
            ctx.mailboxes[role.name] = AgentMailbox(roleName: role.name)
        }

        // Bootstrap: deliver the initial task to planner
        ctx.deliver(WorkflowMessage(
            workflowId: ctx.workflowId,
            sender: "user",
            recipients: ["planner"],
            kind: .task,
            subject: "New coding task",
            body: task
        ))

        return ctx
    }

    func makeScheduler() -> any WorkflowScheduler {
        CodeChangeScheduler()
    }

    func makeReducer() -> any WorkflowReducer {
        CodeChangeReducer()
    }
}

// MARK: - CodeChangeScheduler

struct CodeChangeScheduler: WorkflowScheduler {

    func runnableRoles(in context: WorkflowContext) -> [String] {
        context.mailboxes.compactMap { roleName, mailbox in
            mailbox.hasMessages ? roleName : nil
        }
    }

    func chooseNextRole(in context: WorkflowContext) -> String? {
        let runnable = runnableRoles(in: context)
        guard !runnable.isEmpty else { return nil }

        // Priority ordering based on message kinds in inbox
        let ordered = ["planner", "explorer", "coder", "reviewer", "executor"]

        // Pick by highest-priority pending message kind first
        var best: (role: String, priority: Int)? = nil
        for roleName in runnable {
            let inbox = context.inbox(for: roleName)
            let maxPriority = inbox.map(\.kind.schedulingPriority).max() ?? 0
            if best == nil || maxPriority > best!.priority {
                best = (roleName, maxPriority)
            }
        }

        // If tied, use canonical order
        if let winner = best {
            let tied = runnable.filter { roleName in
                let priority = context.inbox(for: roleName).map(\.kind.schedulingPriority).max() ?? 0
                return priority == winner.priority
            }
            return tied.sorted { a, b in
                (ordered.firstIndex(of: a) ?? 99) < (ordered.firstIndex(of: b) ?? 99)
            }.first
        }

        return best?.role
    }
}

// MARK: - CodeChangeReducer

struct CodeChangeReducer: WorkflowReducer {

    mutating func apply(
        activationResult: AgentActivationResult,
        to context: inout WorkflowContext
    ) throws {
        let role = activationResult.role

        // Update artifacts
        for artifact in activationResult.newArtifacts {
            context.upsertArtifact(artifact)
        }

        // Deliver messages into recipients' mailboxes
        for message in activationResult.newMessages {
            context.deliver(message)
        }

        // Role-specific routing logic
        switch role {

        case "planner":
            try handlePlannerResult(activationResult, context: &context)

        case "explorer":
            handleExplorerResult(activationResult, context: &context)

        case "coder":
            try handleCoderResult(activationResult, context: &context)

        case "reviewer":
            try handleReviewerResult(activationResult, context: &context)

        case "executor":
            try handleExecutorResult(activationResult, context: &context)

        default:
            break
        }
    }

    // MARK: - Role Handlers

    private func handlePlannerResult(
        _ result: AgentActivationResult,
        context: inout WorkflowContext
    ) throws {
        guard let planArtifact = result.newArtifacts.first(where: { $0.kind == .plan }) else {
            // No plan produced — send to explorer with raw task
            context.deliver(WorkflowMessage(
                workflowId: context.workflowId,
                sender: "planner",
                recipients: ["coder"],
                kind: .task,
                subject: "Proceed without formal plan",
                body: result.outputText
            ))
            return
        }

        // Check if plan requires exploration
        let requiresExploration = extractBool(from: planArtifact.contentJson, key: "requires_exploration")

        if requiresExploration {
            context.deliver(WorkflowMessage(
                workflowId: context.workflowId,
                sender: "planner",
                recipients: ["explorer"],
                kind: .task,
                subject: "Explore codebase according to plan",
                body: "Plan: \(planArtifact.contentJson)\n\nTask: \(context.userTask)",
                artifactRefs: [planArtifact.id]
            ))
        } else {
            // Skip exploration — go straight to coder
            context.deliver(WorkflowMessage(
                workflowId: context.workflowId,
                sender: "planner",
                recipients: ["coder"],
                kind: .task,
                subject: "Implement according to plan",
                body: "Plan is ready. Proceed with implementation.\n\nTask: \(context.userTask)",
                artifactRefs: [planArtifact.id]
            ))
        }
    }

    private func handleExplorerResult(
        _ result: AgentActivationResult,
        context: inout WorkflowContext
    ) {
        // Route to whoever sent the infoRequest, or fall back to coder
        let explorationArtifactId = result.newArtifacts.first?.id

        // Check if there's a pending coder infoRequest waiting for this
        let coderPendingInfo = context.agentStates["coder"]?.isBlocked == true
        let nextRecipient = coderPendingInfo ? "coder" : "coder"  // default routing

        context.agentStates["coder"]?.isBlocked = false
        context.agentStates["coder"]?.blockReason = nil

        context.deliver(WorkflowMessage(
            workflowId: context.workflowId,
            sender: "explorer",
            recipients: [nextRecipient],
            kind: .infoResponse,
            subject: "Exploration complete",
            body: result.outputText,
            artifactRefs: explorationArtifactId.map { [$0] } ?? []
        ))
    }

    private func handleCoderResult(
        _ result: AgentActivationResult,
        context: inout WorkflowContext
    ) throws {
        guard let patchArtifact = result.newArtifacts.first(where: { $0.kind == .codePatchSummary }) else {
            // Coder didn't produce a patch — check if it needs more context
            if extractBool(from: result.outputText, key: "needs_more_context") {
                // Mark coder as blocked and send infoRequest to explorer
                context.agentStates["coder"]?.isBlocked = true
                context.agentStates["coder"]?.blockReason = "Waiting for explorer"
                context.deliver(WorkflowMessage(
                    workflowId: context.workflowId,
                    sender: "coder",
                    recipients: ["explorer"],
                    kind: .infoRequest,
                    subject: "Need more context to proceed",
                    body: result.outputText
                ))
            }
            return
        }

        // Deliver patch to both reviewer and executor
        context.deliver(WorkflowMessage(
            workflowId: context.workflowId,
            sender: "coder",
            recipients: ["reviewer"],
            kind: .handoff,
            subject: "Code changes ready for review",
            body: "Patch summary available.",
            artifactRefs: [patchArtifact.id]
        ))
        context.deliver(WorkflowMessage(
            workflowId: context.workflowId,
            sender: "coder",
            recipients: ["executor"],
            kind: .handoff,
            subject: "Run verification",
            body: "Please run the verification command from the patch summary.",
            artifactRefs: [patchArtifact.id]
        ))
    }

    private func handleReviewerResult(
        _ result: AgentActivationResult,
        context: inout WorkflowContext
    ) throws {
        guard let reviewArtifact = result.newArtifacts.first(where: { $0.kind == .reviewReport }) else {
            return
        }

        let verdict = extractString(from: reviewArtifact.contentJson, key: "verdict") ?? "needs_revision"

        if verdict == "approved" {
            var updatedArtifact = reviewArtifact
            updatedArtifact.status = .approved
            context.upsertArtifact(updatedArtifact)
            // Reviewer approved — check if executor is done
            checkCompletion(context: &context)
        } else {
            // Send review feedback back to coder
            context.deliver(WorkflowMessage(
                workflowId: context.workflowId,
                sender: "reviewer",
                recipients: ["coder"],
                kind: .reviewFeedback,
                subject: "Review: revision required",
                body: result.outputText,
                artifactRefs: [reviewArtifact.id]
            ))
        }
    }

    private func handleExecutorResult(
        _ result: AgentActivationResult,
        context: inout WorkflowContext
    ) throws {
        guard let testReport = result.newArtifacts.first(where: { $0.kind == .testReport }) else {
            return
        }

        let status = extractString(from: testReport.contentJson, key: "status") ?? "failed"

        if status == "passed" {
            var updatedReport = testReport
            updatedReport.status = .approved
            context.upsertArtifact(updatedReport)
            checkCompletion(context: &context)
        } else {
            // Send failure back to coder
            context.deliver(WorkflowMessage(
                workflowId: context.workflowId,
                sender: "executor",
                recipients: ["coder"],
                kind: .rejection,
                subject: "Verification failed",
                body: result.outputText,
                artifactRefs: [testReport.id]
            ))
        }
    }

    // MARK: - Completion Check

    private func checkCompletion(context: inout WorkflowContext) {
        let reviewApproved = context.artifacts.values
            .filter { $0.kind == .reviewReport }
            .contains { $0.status == .approved }

        let testPassed = context.artifacts.values
            .filter { $0.kind == .testReport }
            .contains { $0.status == .approved }

        if reviewApproved && testPassed {
            // Produce final answer artifact
            let finalArtifact = WorkflowArtifact(
                id: "finalAnswer-\(context.workflowId.uuidString.prefix(8))",
                workflowId: context.workflowId,
                kind: .finalAnswer,
                title: "Workflow Complete",
                producer: "runtime",
                version: 1,
                contentJson: """
                {
                  "conclusion": "Code change workflow completed successfully.",
                  "review_verdict": "approved",
                  "test_status": "passed"
                }
                """,
                status: .approved
            )
            context.upsertArtifact(finalArtifact)
            context.status = .completed
        }
    }

    // MARK: - JSON Helpers

    private func extractBool(from json: String, key: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = obj[key] as? Bool
        else { return false }
        return value
    }

    private func extractString(from json: String, key: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = obj[key] as? String
        else { return nil }
        return value
    }
}

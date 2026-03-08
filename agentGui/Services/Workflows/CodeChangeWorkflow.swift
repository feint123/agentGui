//
//  CodeChangeWorkflow.swift
//  agentGui
//
//  The first concrete WorkflowDefinition: a multi-agent coding workflow that
//  orchestrates planner → explorer → coder → reviewer/executor evaluator loop,
//  with support for structured revision feedback and context request loops.
//
//  Default execution path:
//
//    start → planner → explorer (if needed) → coder → reviewer ─┐
//                          ↑                    │                │
//                          └── infoRequest ─────┘                │
//                                               executor ────────┤
//                                                      │         │
//                                    combined evaluator feedback │
//                                                      └────→ coder (next iteration)
//

import Foundation

// MARK: - CodeChangeWorkflow

struct CodeChangeWorkflow: WorkflowDefinition {
    let id = "code_change"
    let displayName = "代码变更流程"
    let description = "多代理协作完成代码修改：规划 → 探索 → 编码 → evaluator loop(审查+验证)"

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

    // MARK: - Completion Checklist

    func evaluateCompletion(in context: WorkflowContext) -> CompletionEvaluation {
        let artifacts = context.artifacts.values

        // 1. 用户目标：登记了任务且生成了执行计划
        let hasGoal = !context.userTask.isEmpty
            && artifacts.contains { $0.kind == .plan }

        // 2. 变更摘要：存在代码变更摘要 artifact
        let hasPatchSummary = artifacts.contains { $0.kind == .codePatchSummary }

        // 3. 验证结果：测试报告已通过；明确被拓绝为关键失败
        let testApproved = artifacts.contains {
            $0.kind == .testReport && $0.status == .approved
        }
        let testRejected = artifacts.contains {
            $0.kind == .testReport && $0.status == .rejected
        }

        // 4. 审查结果：审查报告已通过
        let reviewApproved = artifacts.contains {
            $0.kind == .reviewReport && $0.status == .approved
        }

        // 5. 无未完成项：无被锁定角色
        let hasNoBlockers = !context.agentStates.values.contains { $0.isBlocked }

        return CompletionEvaluation(items: [
            CompletionCheckItem(id: "userGoal",            label: "用户目标",   passed: hasGoal),
            CompletionCheckItem(id: "changeSummary",       label: "变更摘要",   passed: hasPatchSummary),
            CompletionCheckItem(id: "verificationResults", label: "验证结果",
                                passed: testApproved,
                                isCritical: testRejected),
            CompletionCheckItem(id: "reviewResults",       label: "审查结果",   passed: reviewApproved),
            CompletionCheckItem(id: "noBlockers",          label: "无未完成项", passed: hasNoBlockers),
        ])
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

        context.evaluatorLoop.beginCycle(for: patchArtifact.id, version: patchArtifact.version)

        // Deliver patch to both reviewer and executor
        context.deliver(WorkflowMessage(
            workflowId: context.workflowId,
            sender: "coder",
            recipients: ["reviewer"],
            kind: .handoff,
            subject: "Evaluate patch iteration \(context.evaluatorLoop.activeCycle?.iteration ?? patchArtifact.version)",
            body: "Review the latest patch candidate and produce structured optimizer feedback.",
            artifactRefs: [patchArtifact.id]
        ))
        context.deliver(WorkflowMessage(
            workflowId: context.workflowId,
            sender: "coder",
            recipients: ["executor"],
            kind: .handoff,
            subject: "Verify patch iteration \(context.evaluatorLoop.activeCycle?.iteration ?? patchArtifact.version)",
            body: "Run verification for the latest patch candidate and capture actionable failure details.",
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
        let approved = verdict == "approved"

        var updatedArtifact = reviewArtifact
        updatedArtifact.status = approved ? .approved : .rejected
        context.upsertArtifact(updatedArtifact)

        context.evaluatorLoop.record(makeReviewerOutcome(from: updatedArtifact, fallbackText: result.outputText))
        finalizeEvaluatorLoopIfReady(context: &context)
    }

    private func handleExecutorResult(
        _ result: AgentActivationResult,
        context: inout WorkflowContext
    ) throws {
        guard let testReport = result.newArtifacts.first(where: { $0.kind == .testReport }) else {
            return
        }

        let status = extractString(from: testReport.contentJson, key: "status") ?? "failed"
        let approved = status == "passed"

        var updatedReport = testReport
        updatedReport.status = approved ? .approved : .rejected
        context.upsertArtifact(updatedReport)

        context.evaluatorLoop.record(makeExecutorOutcome(from: updatedReport, fallbackText: result.outputText))
        finalizeEvaluatorLoopIfReady(context: &context)
    }

    private func finalizeEvaluatorLoopIfReady(context: inout WorkflowContext) {
        if context.evaluatorLoop.completeSuccessIfReady() {
            checkCompletion(context: &context)
            return
        }

        guard let failure = context.evaluatorLoop.completeFailureIfReady() else {
            return
        }

        context.deliver(WorkflowMessage(
            workflowId: context.workflowId,
            sender: "evaluator",
            recipients: ["coder"],
            kind: failure.triggerKind,
            subject: "Evaluator loop iteration \(failure.iteration): revision required",
            body: buildEvaluatorFeedbackBody(from: failure),
            artifactRefs: failure.outcomes.map(\.artifactId)
        ))
    }

    // MARK: - Completion Signal

    /// Produces the final-answer artifact when both review and tests pass.
    /// Status resolution is deferred to the runtime via `evaluateCompletion(in:)`.
    private func checkCompletion(context: inout WorkflowContext) {
        let reviewApproved = context.artifacts.values
            .filter { $0.kind == .reviewReport }
            .contains { $0.status == .approved }

        let testPassed = context.artifacts.values
            .filter { $0.kind == .testReport }
            .contains { $0.status == .approved }

        if reviewApproved && testPassed {
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
            // Status is resolved by the runtime's completion checklist;
            // no direct assignment here.
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

    private func extractStringArray(from json: String, key: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = obj[key] as? [Any]
        else { return [] }

        return values.compactMap(stringifyJSONValue)
    }

    private func stringifyJSONValue(_ value: Any) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    private func makeReviewerOutcome(
        from artifact: WorkflowArtifact,
        fallbackText: String
    ) -> WorkflowEvaluatorOutcome {
        let summary = extractString(from: artifact.contentJson, key: "summary")
            ?? condensedSummary(from: fallbackText)
        let reasons = extractStringArray(from: artifact.contentJson, key: "blocking_findings")

        return WorkflowEvaluatorOutcome(
            source: .reviewer,
            approved: artifact.status == .approved,
            summary: summary,
            reasons: reasons.isEmpty && artifact.status != .approved ? [summary] : reasons,
            artifactId: artifact.id,
            artifactVersion: artifact.version
        )
    }

    private func makeExecutorOutcome(
        from artifact: WorkflowArtifact,
        fallbackText: String
    ) -> WorkflowEvaluatorOutcome {
        let summary = extractString(from: artifact.contentJson, key: "output_summary")
            ?? condensedSummary(from: fallbackText)
        let reasons = extractStringArray(from: artifact.contentJson, key: "failures")

        return WorkflowEvaluatorOutcome(
            source: .executor,
            approved: artifact.status == .approved,
            summary: summary,
            reasons: reasons.isEmpty && artifact.status != .approved ? [summary] : reasons,
            artifactId: artifact.id,
            artifactVersion: artifact.version
        )
    }

    private func condensedSummary(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No summary provided." }
        return String(trimmed.prefix(240))
    }

    private func buildEvaluatorFeedbackBody(from failure: WorkflowEvaluatorFailureRecord) -> String {
        let payload: [String: Any] = [
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
            }
        ]

        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            json = text
        } else {
            json = "{ \"evaluator_iteration\": \(failure.iteration) }"
        }

        return """
        Evaluator loop requires a new coder iteration. Treat the structured payload below as mandatory input for the next patch.

        \(json)
        """
    }
}

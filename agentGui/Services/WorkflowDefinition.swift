//
//  WorkflowDefinition.swift
//  agentGui
//
//  Protocol layer and in-memory value types for the workflow orchestration runtime.
//
//  Architecture:
//  ┌─────────────────┐   defines   ┌───────────────────────┐
//  │ WorkflowDefinition│ ─────────► │ WorkflowScheduler     │
//  │  (template)      │            │ WorkflowReducer        │
//  └─────────────────┘            └───────────────────────┘
//         │ creates                       │ used by
//         ▼                               ▼
//  ┌─────────────────┐           ┌────────────────────┐
//  │ WorkflowContext  │◄──────── │ WorkflowRuntime     │
//  │  (shared state)  │           │  (orchestrator)     │
//  └─────────────────┘           └────────────────────┘
//

import Foundation

// MARK: - WorkflowWorkspaceContext

/// Snapshot of the IDE workspace state captured when a workflow is launched.
struct WorkflowSkillInfo: Sendable {
    var name: String
    var description: String
}

struct WorkflowWorkspaceContext: Sendable {
    var workingDirectory: String = ""
    var selectedFilePath: String? = nil
    var selectedText: String? = nil
    var availableSkills: [WorkflowSkillInfo] = []

    static let empty = WorkflowWorkspaceContext()
}

// MARK: - WorkflowDefinition Protocol

/// Defines a class of tasks: roles, routing rules, budget, and completion policy.
/// The definition does NOT contain execution logic — that lives in WorkflowRuntime.
protocol WorkflowDefinition: Sendable {
    /// Machine-readable identifier used to look up this template (e.g. "code_change").
    var id: String { get }
    var displayName: String { get }
    var description: String { get }

    /// Create the initial WorkflowContext from a user task string.
    func makeInitialContext(task: String, sessionId: String) -> WorkflowContext

    /// Create the scheduler that decides which role runs next.
    func makeScheduler() -> any WorkflowScheduler

    /// Create the reducer that applies activation results to the context.
    func makeReducer() -> any WorkflowReducer

    /// Evaluate whether the workflow has satisfactorily completed.
    /// Called by the runtime when no runnable roles remain.
    /// Returns a `CompletionEvaluation` whose `resolvedStatus` maps to
    /// `.completed`, `.partial`, or `.failed`.
    func evaluateCompletion(in context: WorkflowContext) -> CompletionEvaluation
}

extension WorkflowDefinition {
    /// Default five-item completion checklist used by all workflows that don't
    /// provide their own implementation.
    ///
    /// Items checked:
    ///   1. **用户目标** — `userTask` non-empty and a `.plan` artifact exists
    ///   2. **变更摘要** — a `.codePatchSummary` or `.finalAnswer` artifact exists
    ///   3. **验证结果** — a `.testReport` with `.approved` status exists; critical if rejected
    ///   4. **审查结果** — a `.reviewReport` artifact exists
    ///   5. **无未完成项** — no role is in a blocked state
    func evaluateCompletion(in context: WorkflowContext) -> CompletionEvaluation {
        let artifacts = context.artifacts.values

        let hasGoal = !context.userTask.isEmpty
            && artifacts.contains { $0.kind == .plan }

        let hasChangeSummary = artifacts.contains {
            $0.kind == .codePatchSummary || $0.kind == .finalAnswer
        }

        let verificationApproved = artifacts.contains {
            $0.kind == .testReport && $0.status == .approved
        }
        let verificationRejected = artifacts.contains {
            $0.kind == .testReport && $0.status == .rejected
        }

        let hasReview = artifacts.contains { $0.kind == .reviewReport }

        let hasNoBlockers = !context.agentStates.values.contains { $0.isBlocked }

        return CompletionEvaluation(items: [
            CompletionCheckItem(id: "userGoal",            label: "用户目标",   passed: hasGoal),
            CompletionCheckItem(id: "changeSummary",       label: "变更摘要",   passed: hasChangeSummary),
            CompletionCheckItem(id: "verificationResults", label: "验证结果",
                                passed: verificationApproved,
                                isCritical: verificationRejected),
            CompletionCheckItem(id: "reviewResults",       label: "审查结果",   passed: hasReview),
            CompletionCheckItem(id: "noBlockers",          label: "无未完成项", passed: hasNoBlockers),
        ])
    }
}

// MARK: - WorkflowScheduler Protocol

/// Decides which role should be activated next given the current context.
protocol WorkflowScheduler: Sendable {
    /// Returns the names of roles that currently have pending inbox messages or tasks.
    func runnableRoles(in context: WorkflowContext) -> [String]

    /// Picks the single next role to activate; returns nil when the workflow
    /// should pause and wait (e.g. awaiting human input).
    func chooseNextRole(in context: WorkflowContext) -> String?
}

// MARK: - WorkflowReducer Protocol

/// Applies the result of an agent activation to the shared workflow context.
protocol WorkflowReducer: Sendable {
    mutating func apply(
        activationResult: AgentActivationResult,
        to context: inout WorkflowContext
    ) throws
}

// MARK: - WorkflowContext

/// The shared mutable state of a running workflow instance.
/// Passed by value (copy-on-write semantics via struct).
struct WorkflowContext: Sendable {
    var workflowId: UUID
    var sessionId: String
    var definitionId: String
    var userTask: String

    var status: WorkflowStatus = .pending
    var roles: [WorkflowRoleDefinition] = []

    /// Messages in each agent's mailbox.
    var mailboxes: [String: AgentMailbox] = [:]

    /// Per-role activation state summaries.
    var agentStates: [String: AgentWorkerState] = [:]

    /// Accumulated artifacts produced during the workflow.
    var artifacts: [String: WorkflowArtifact] = [:]

    /// Structured evaluator loop state shared across coder / reviewer / executor.
    var evaluatorLoop = WorkflowEvaluatorLoopState()

    /// Hard runtime contract violations recorded during delivery and activation.
    var contractViolations: [WorkflowContractViolation] = []

    var budget: WorkflowBudget = .default
    var policies: WorkflowPolicies = .default

    /// Workspace snapshot injected at launch time.
    var workspaceContext: WorkflowWorkspaceContext = .empty

    /// Number of scheduler ticks so far.
    var totalTicks: Int = 0

    /// Time of last state-changing event (for stall detection).
    var lastProgressAt: Date = Date()

    init(
        workflowId: UUID = UUID(),
        sessionId: String,
        definitionId: String,
        userTask: String,
        budget: WorkflowBudget = .default,
        policies: WorkflowPolicies = .default
    ) {
        self.workflowId = workflowId
        self.sessionId = sessionId
        self.definitionId = definitionId
        self.userTask = userTask
        self.budget = budget
        self.policies = policies
    }
}

extension WorkflowContext {
    var isActive: Bool { !status.isTerminal }

    /// Returns all messages currently in the given role's inbox.
    func inbox(for role: String) -> [WorkflowMessage] {
        mailboxes[role]?.inbox ?? []
    }

    /// Delivers a message into the recipient's inbox.
    /// Contract enforcement: messages whose `kind` is not in the recipient's
    /// `subscribesTo` set are silently dropped and a warning is logged.
    mutating func deliver(_ message: WorkflowMessage) {
        for recipient in message.recipients {
            // Hard subscription check — look up the role definition registered in this context.
            if let role = roles.first(where: { $0.name == recipient }),
               !role.subscribesTo.contains(message.kind) {
                let violation = WorkflowContractViolation(
                    kind: .unsubscribedMessage,
                    roleName: recipient,
                    message: "Dropped '\(message.kind.rawValue)' because recipient does not subscribe to it. Allowed: [\(role.subscribesTo.map(\.rawValue).sorted().joined(separator: ", "))]",
                    messageKind: message.kind,
                    sender: message.sender
                )
                contractViolations.append(violation)
                print("[Workflow] ⚠ Contract[subscribesTo]: \(violation.summary)")
                continue
            }
            if mailboxes[recipient] == nil {
                mailboxes[recipient] = AgentMailbox(roleName: recipient)
            }
            mailboxes[recipient]?.inbox.append(message)
        }
    }

    /// Consumes (removes) all messages from the given role's inbox and returns them.
    mutating func drainInbox(for role: String) -> [WorkflowMessage] {
        let msgs = mailboxes[role]?.inbox ?? []
        mailboxes[role]?.inbox = []
        return msgs
    }

    /// Total activation count across all roles.
    var totalActivations: Int {
        agentStates.values.reduce(0) { $0 + $1.activationCount }
    }

    /// Activation count for a specific role.
    func activationCount(for role: String) -> Int {
        agentStates[role]?.activationCount ?? 0
    }

    mutating func recordActivation(for role: String) {
        if agentStates[role] == nil {
            agentStates[role] = AgentWorkerState(roleName: role)
        }
        agentStates[role]?.activationCount += 1
        agentStates[role]?.lastActivatedAt = Date()
        lastProgressAt = Date()
    }

    mutating func upsertArtifact(_ artifact: WorkflowArtifact) {
        artifacts[artifact.id] = artifact
        lastProgressAt = Date()
    }

    mutating func recordContractViolations(_ violations: [WorkflowContractViolation]) {
        guard !violations.isEmpty else { return }
        contractViolations.append(contentsOf: violations)
        lastProgressAt = Date()
    }
}

// MARK: - AgentMailbox

struct AgentMailbox: Sendable {
    var roleName: String
    var inbox: [WorkflowMessage] = []
    var outbox: [WorkflowMessage] = []

    var hasMessages: Bool { !inbox.isEmpty }
}

// MARK: - AgentWorkerState

struct AgentWorkerState: Sendable {
    var roleName: String
    var activationCount: Int = 0
    var lastActivatedAt: Date? = nil
    var isBlocked: Bool = false
    var blockReason: String? = nil

    init(roleName: String) {
        self.roleName = roleName
    }
}

// MARK: - WorkflowMessage (in-memory)

/// The in-memory representation of an inter-agent message. Converted to
/// WorkflowMessageRecord for persistence.
struct WorkflowMessage: Identifiable, Sendable {
    var id: UUID = UUID()
    var workflowId: UUID
    var sender: String
    var recipients: [String]
    var kind: WorkflowMessageKind
    var subject: String
    var body: String
    var artifactRefs: [String] = []
    var replyTo: UUID? = nil
    var createdAt: Date = Date()

    init(
        workflowId: UUID,
        sender: String,
        recipients: [String],
        kind: WorkflowMessageKind,
        subject: String,
        body: String,
        artifactRefs: [String] = [],
        replyTo: UUID? = nil
    ) {
        self.workflowId = workflowId
        self.sender = sender
        self.recipients = recipients
        self.kind = kind
        self.subject = subject
        self.body = body
        self.artifactRefs = artifactRefs
        self.replyTo = replyTo
    }
}

// MARK: - WorkflowArtifact (in-memory)

/// The in-memory representation of a workflow artifact. Converted to
/// WorkflowArtifactRecord for persistence.
struct WorkflowArtifact: Identifiable, Sendable {
    var id: String
    var workflowId: UUID
    var kind: WorkflowArtifactKind
    var title: String
    var producer: String
    var version: Int
    var contentJson: String
    var status: ArtifactStatus = .draft
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// Returns a new artifact with version incremented and status reset to draft.
    func nextVersion(contentJson: String, producer: String) -> WorkflowArtifact {
        WorkflowArtifact(
            id: id,
            workflowId: workflowId,
            kind: kind,
            title: title,
            producer: producer,
            version: version + 1,
            contentJson: contentJson,
            status: .draft
        )
    }
}

// MARK: - AgentActivationResult

/// The output of a single agent role activation, returned by WorkflowAgentRunner.
struct AgentActivationResult: Sendable {
    /// The role name that produced this result.
    let role: String
    /// Full text output from the agent's loop.
    let outputText: String
    /// Messages to be delivered to other roles' mailboxes.
    let newMessages: [WorkflowMessage]
    /// Artifacts created or updated during this activation.
    let newArtifacts: [WorkflowArtifact]
    /// How the activation terminated.
    let resultKind: ActivationResultKind
    /// Short summary for the activation record.
    let summary: String
    /// Number of inner-loop rounds consumed.
    let turnsUsed: Int
    /// Contract violations observed during prompt construction or tool interception.
    let contractViolations: [WorkflowContractViolation]
}

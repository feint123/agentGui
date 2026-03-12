//
//  WorkflowRoleDefinition.swift
//  agentGui
//
//  Single source of truth for all agent-role configuration: system prompt,
//  tool permissions, artifact contracts, and turn budgets.
//
//  Both the workflow orchestration path (WorkflowAgentRunner) and the
//  ad-hoc delegation path (run_subagent tool / ClaudeService+Subagent)
//  read from this type. SubagentDefinition.swift has been removed.
//

import Foundation

// MARK: - WorkflowRoleDefinition

struct WorkflowRoleDefinition: Sendable {

    // MARK: Identity

    let name: String
    let displayName: String
    let description: String

    // MARK: Execution Configuration

    let systemPrompt: String
    let enableTextEditor: Bool
    let enableBash: Bool
    let enableWebSearch: Bool
    let enableWebFetch: Bool
    let enableStoryMemoryTools: Bool
    let toolGrants: [ToolGrant]

    // MARK: Artifact Permissions

    /// Artifact kinds this role may read from the shared context.
    let readableArtifacts: Set<WorkflowArtifactKind>

    /// Artifact kinds this role may produce or update.
    let writableArtifacts: Set<WorkflowArtifactKind>

    // MARK: Communication Contract

    /// Message kinds this role listens for.
    let subscribesTo: Set<WorkflowMessageKind>

    /// The default kind of output messages this role emits.
    let defaultOutputMessageKind: WorkflowMessageKind

    /// The kind of artifact this role primarily produces (nil = no artifact by default).
    let primaryOutputArtifactKind: WorkflowArtifactKind?

    // MARK: Activation Budget

    let maxTurnsPerActivation: Int
    let maxActivations: Int

    // MARK: Adapter

    /// Alias used by the run_subagent path (maps to maxTurnsPerActivation).
    var maxRounds: Int { maxTurnsPerActivation }

    // MARK: Init

    init(
        name: String,
        displayName: String,
        description: String = "",
        systemPrompt: String,
        enableTextEditor: Bool = true,
        enableBash: Bool = false,
        enableWebSearch: Bool = false,
        enableWebFetch: Bool = false,
        enableStoryMemoryTools: Bool = false,
        toolGrants: [ToolGrant] = [],
        readableArtifacts: Set<WorkflowArtifactKind> = [],
        writableArtifacts: Set<WorkflowArtifactKind> = [],
        subscribesTo: Set<WorkflowMessageKind> = [.task],
        defaultOutputMessageKind: WorkflowMessageKind = .statusUpdate,
        primaryOutputArtifactKind: WorkflowArtifactKind? = nil,
        maxTurnsPerActivation: Int = 10,
        maxActivations: Int = 5
    ) {
        self.name = name
        self.displayName = displayName
        self.description = description
        self.systemPrompt = systemPrompt
        self.enableTextEditor = enableTextEditor
        self.enableBash = enableBash
        self.enableWebSearch = enableWebSearch
        self.enableWebFetch = enableWebFetch
        self.enableStoryMemoryTools = enableStoryMemoryTools
        self.toolGrants = toolGrants
        self.readableArtifacts = readableArtifacts
        self.writableArtifacts = writableArtifacts
        self.subscribesTo = subscribesTo
        self.defaultOutputMessageKind = defaultOutputMessageKind
        self.primaryOutputArtifactKind = primaryOutputArtifactKind
        self.maxTurnsPerActivation = maxTurnsPerActivation
        self.maxActivations = maxActivations
    }

    /// Returns the default list of recipients for this role's output messages
    /// given the current workflow context (used by WorkflowAgentRunner).
    func defaultOutputRecipients(context: WorkflowContext) -> [String] {
        switch defaultOutputMessageKind {
        case .approval, .rejection, .reviewFeedback:
            // Reducers are responsible for routing evaluator feedback so they can
            // aggregate verification results before waking the worker.
            return []
        case .infoResponse:
            // Respond to whoever sent us an infoRequest
            return context.mailboxes[name]?.inbox
                .filter { $0.kind == .infoRequest }
                .flatMap { [$0.sender] } ?? []
        case .completion:
            return []
        default:
            // Primary consumer is whoever's next in the default chain
            return []
        }
    }
}

// MARK: - Built-in Workflow Roles

extension WorkflowRoleDefinition {

    /// All built-in roles — loaded from the structured built-in agent catalog.
    static var all: [WorkflowRoleDefinition] {
        AgentCatalog.shared.workflowRoleDefinitions
    }

    static func find(named name: String) -> WorkflowRoleDefinition? {
        all.first { $0.name == name }
    }

    // Legacy internal workflow aliases retained only to keep older workflow
    // templates compiling during the three-role migration.
    static var planner: WorkflowRoleDefinition { explore }
    static var explorer: WorkflowRoleDefinition { explore }
    static var coder: WorkflowRoleDefinition { worker }
    static var reviewer: WorkflowRoleDefinition { verifier }
    static var executor: WorkflowRoleDefinition { verifier }

    static var explore: WorkflowRoleDefinition {
        AgentCatalog.shared.find(named: "explore")!.workflowRoleDefinition
    }

    static var worker: WorkflowRoleDefinition {
        AgentCatalog.shared.find(named: "worker")!.workflowRoleDefinition
    }

    static var verifier: WorkflowRoleDefinition {
        AgentCatalog.shared.find(named: "verifier")!.workflowRoleDefinition
    }
}

//
//  WorkflowRoleDefinition.swift
//  agentGui
//
//  Defines the contract for an agent role within a workflow: tools, artifact
//  permissions, communication subscriptions, and activation limits.
//
//  WorkflowRoleDefinition is the successor to SubagentDefinition. The original
//  SubagentDefinition structs are kept as-is for backward compatibility with
//  the existing run_subagent tool path.
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
            // Find the role that produced the primary writable artifact
            return context.agentStates.keys
                .filter { $0 != name }
                .filter { roleName in
                    context.roles.first { $0.name == roleName }?
                        .writableArtifacts.contains(.codePatchSummary) == true
                }
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

    /// All built-in roles (mirrors SubagentDefinition.all).
    static let all: [WorkflowRoleDefinition] = [
        planner, explorer, coder, reviewer, executor
    ]

    static func find(named name: String) -> WorkflowRoleDefinition? {
        all.first { $0.name == name }
    }

    // MARK: Planner

    static let planner = WorkflowRoleDefinition(
        name: "planner",
        displayName: "规划师",
        description: "分析任务需求，输出结构化执行计划。只读，不执行操作。",
        systemPrompt: """
        You are a strategic planning assistant. Your ONLY job is to analyze the task and produce \
        a detailed, structured execution plan. Do NOT execute any actions or make any changes.

        Required output — return a JSON object with this exact structure:
        {
          "goal": "one-sentence description of what needs to be achieved",
          "steps": [
            { "id": "1", "title": "action-oriented step title" }
          ],
          "assumptions": ["assumption 1"],
          "success_criteria": ["criterion 1"],
          "requires_exploration": true
        }

        Planning rules:
        - Read relevant files (view only) to understand context before planning.
        - Break complex tasks into 5–15 small, concrete, verifiable steps.
        - Set "requires_exploration" to true if code locations or dependencies are unclear.
        - Return ONLY the JSON object — no prose before or after.
        """,
        enableTextEditor: true,
        enableBash: false,
        readableArtifacts: [],
        writableArtifacts: [.plan],
        subscribesTo: [.task],
        defaultOutputMessageKind: .handoff,
        primaryOutputArtifactKind: .plan,
        maxTurnsPerActivation: 6,
        maxActivations: 3
    )

    // MARK: Explorer

    static let explorer = WorkflowRoleDefinition(
        name: "explorer",
        displayName: "探索者",
        description: "阅读代码库、文档或网页，搜集并整合信息。只读，不修改文件。",
        systemPrompt: """
        You are a versatile research and exploration assistant. Your job is to gather information \
        from local files or the web and deliver a clear, structured answer.

        Rules:
        - Use the text editor ONLY with the "view" command — do NOT create, edit, or delete files.
        - Be concise: summarize findings rather than quoting verbatim at length.
        - Cite sources (file paths or URLs) for key facts.
        - Return a structured exploration report as JSON:
        {
          "relevant_files": ["path/to/file.swift"],
          "key_symbols": ["ClassName", "methodName"],
          "findings": "summary of what was found",
          "open_questions": ["question 1"],
          "risk_areas": ["risk 1"]
        }
        """,
        enableTextEditor: true,
        enableBash: false,
        enableWebSearch: true,
        enableWebFetch: true,
        readableArtifacts: [.plan],
        writableArtifacts: [.explorationReport],
        subscribesTo: [.task, .infoRequest],
        defaultOutputMessageKind: .infoResponse,
        primaryOutputArtifactKind: .explorationReport,
        maxTurnsPerActivation: 12,
        maxActivations: 5
    )

    // MARK: Coder

    static let coder = WorkflowRoleDefinition(
        name: "coder",
        displayName: "编写者",
        description: "实现代码变更：编写新文件或修改现有文件，可运行命令验证。",
        systemPrompt: """
        You are a focused coding assistant. Your job is to implement the exact changes described \
        in the task using the text editor and bash tools.

        Rules:
        - Read relevant files first before making changes.
        - Make minimal, targeted edits. Do not refactor code beyond what is asked.
        - Use bash to run build or test commands only when needed to verify changes.
        - After completing all changes, return a patch summary as JSON:
        {
          "changed_files": ["path/to/file.swift"],
          "summary": "brief description of what was changed",
          "verification_command": "swift build",
          "needs_more_context": false,
          "context_questions": []
        }
        """,
        enableTextEditor: true,
        enableBash: true,
        readableArtifacts: [.plan, .explorationReport, .reviewReport],
        writableArtifacts: [.codePatchSummary],
        subscribesTo: [.task, .reviewFeedback, .rejection, .infoResponse],
        defaultOutputMessageKind: .handoff,
        primaryOutputArtifactKind: .codePatchSummary,
        maxTurnsPerActivation: 16,
        maxActivations: 5
    )

    // MARK: Reviewer

    static let reviewer = WorkflowRoleDefinition(
        name: "reviewer",
        displayName: "审查者",
        description: "审查代码质量、安全性、规范性，返回结构化审查报告。只读，不修改文件。",
        systemPrompt: """
        You are a careful code reviewer. Your job is to read the specified code and produce a \
        structured review covering correctness, security, performance, and code style.

        Rules:
        - Use the text editor ONLY with the "view" command — do NOT modify any files.
        - Organize findings by severity: Critical / Warning / Suggestion.
        - Be specific: point to file paths and line numbers where relevant.
        - Return a structured review report as JSON:
        {
          "blocking_findings": [],
          "warnings": [],
          "suggestions": [],
          "verdict": "approved",
          "summary": "brief verdict explanation"
        }
        Note: "verdict" must be "approved" or "needs_revision".
        """,
        enableTextEditor: true,
        enableBash: false,
        readableArtifacts: [.plan, .explorationReport, .codePatchSummary],
        writableArtifacts: [.reviewReport],
        subscribesTo: [.task, .handoff],
        defaultOutputMessageKind: .reviewFeedback,
        primaryOutputArtifactKind: .reviewReport,
        maxTurnsPerActivation: 8,
        maxActivations: 5
    )

    // MARK: Executor

    static let executor = WorkflowRoleDefinition(
        name: "executor",
        displayName: "执行者",
        description: "运行 bash 命令（构建、测试、脚本等），返回结果摘要。",
        systemPrompt: """
        You are a focused command executor. Your job is to run the bash commands described in \
        the task and return a concise summary of the results.

        Rules:
        - Run only the commands described in the task.
        - If a command fails, diagnose the error and attempt to fix it (max 2 retries).
        - Return a structured test report as JSON:
        {
          "command": "swift build",
          "status": "passed",
          "output_summary": "Build succeeded with 0 errors",
          "failures": [],
          "reproducible": true
        }
        Note: "status" must be "passed" or "failed".
        """,
        enableTextEditor: false,
        enableBash: true,
        readableArtifacts: [.codePatchSummary],
        writableArtifacts: [.testReport],
        subscribesTo: [.task, .handoff],
        defaultOutputMessageKind: .statusUpdate,
        primaryOutputArtifactKind: .testReport,
        maxTurnsPerActivation: 8,
        maxActivations: 5
    )
}

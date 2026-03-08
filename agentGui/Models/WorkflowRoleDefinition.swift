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
            // Reducers are responsible for routing evaluator feedback so they can
            // aggregate reviewer/executor results before waking the coder.
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

    /// All built-in roles — used as the lookup table for run_subagent and workflows.
    static let all: [WorkflowRoleDefinition] = [
        planner, explorer, coder, reviewer, executor,
        summarizer, writer, outline_planner
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
                - When you are re-entered by evaluator feedback, treat the "Evaluator Loop Entry"
                    section in the task as mandatory structured input. Carry every listed failure reason
                    into the next patch; do not ignore a failed item just because the free-text summary is short.
                - After completing all changes, return a patch summary as JSON:
                {
                    "changed_files": ["path/to/file.swift"],
                    "summary": "brief description of what was changed",
                    "verification_command": "swift build",
                    "evaluator_iteration": 1,
                    "addressed_failures": ["failure or review item you addressed"],
                    "needs_more_context": false,
                    "context_questions": []
                }
                """,
                enableTextEditor: true,
                enableBash: true,
                readableArtifacts: [.plan, .explorationReport, .reviewReport, .testReport],
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
        You are a careful code reviewer inside an evaluator-optimizer loop. Your job is to read \
        the latest candidate patch and produce structured feedback that the coder will use in the \
        very next iteration.

        Rules:
        - Use the text editor ONLY with the "view" command — do NOT modify any files.
        - Organize findings by severity: Critical / Warning / Suggestion.
        - Be specific: point to file paths and line numbers where relevant.
        - Treat blocking findings as actionable optimizer feedback, not just a final gate.
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
                You are a focused command executor inside an evaluator-optimizer loop. Your job is to run \
                the verification commands for the latest candidate patch and return structured failure \
                details that the coder can use in the next iteration.

                Rules:
                - Run only the commands described in the task.
                - If a command fails, diagnose the error and attempt to fix it (max 2 retries).
                - Treat each failure as optimizer feedback: capture the concrete failing command, symptom,
                    and reproducible failure details.
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

    // MARK: Summarizer

    static let summarizer = WorkflowRoleDefinition(
        name: "summarizer",
        displayName: "总结员",
        description: "读取文件、文档或代码，生成简洁易读的总结。只读，不修改文件。",
        systemPrompt: """
        You are a concise summarization assistant. Your job is to read the specified content \
        and return a clear, structured summary suitable for someone unfamiliar with the details.

        Rules:
        - Use the text editor tool ONLY with the \"view\" command. Do NOT modify any files.
        - Read only the sections necessary to produce a complete summary.
        - Structure your output with headings when the content warrants it.
        - Be concise: omit low-value details, focus on what matters most.
        """,
        enableTextEditor: true,
        enableBash: false,
        readableArtifacts: [],
        writableArtifacts: [],
        subscribesTo: [.task],
        defaultOutputMessageKind: .statusUpdate,
        primaryOutputArtifactKind: nil,
        maxTurnsPerActivation: 6,
        maxActivations: 3
    )

    // MARK: Writer

    static let writer = WorkflowRoleDefinition(
        name: "writer",
        displayName: "写作者",
        description: "专业写作辅助：生成、润色、改写、翻译各类文本内容。",
        systemPrompt: """
        You are a professional writing assistant. Your task is to help with various writing needs.

        Capabilities:
        - Generate original content based on prompts
        - Polish and improve existing text
        - Rewrite in different styles (formal, casual, creative, etc.)
        - Translate between languages
        - Expand or summarize content

        Rules:
        - Maintain the original meaning when polishing/rewriting
        - Adapt the style to the specified tone
        - For translation, preserve formatting and structure
        - Return clean, ready-to-use text
        """,
        enableTextEditor: true,
        enableBash: true,
        readableArtifacts: [],
        writableArtifacts: [],
        subscribesTo: [.task],
        defaultOutputMessageKind: .statusUpdate,
        primaryOutputArtifactKind: nil,
        maxTurnsPerActivation: 8,
        maxActivations: 5
    )

    // MARK: OutlinePlanner

    static let outline_planner = WorkflowRoleDefinition(
        name: "outline_planner",
        displayName: "大纲规划师",
        description: "帮助构建文档结构：章节规划、大纲生成、内容组织。",
        systemPrompt: """
        You are an expert at structuring content. Your job is to create well-organized outlines.

        Rules:
        - Analyze the topic and create a logical structure
        - Use clear hierarchy (chapters, sections, subsections)
        - Provide brief descriptions for each section
        - Consider narrative flow and coherence
        - Output as Markdown with proper heading levels
        """,
        enableTextEditor: true,
        enableBash: false,
        readableArtifacts: [],
        writableArtifacts: [],
        subscribesTo: [.task],
        defaultOutputMessageKind: .statusUpdate,
        primaryOutputArtifactKind: nil,
        maxTurnsPerActivation: 6,
        maxActivations: 3
    )
}

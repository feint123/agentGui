//
//  WorkflowRoleDefinition.swift
//  agentGui
//
//  Single source of truth for all agent-role configuration: system prompt,
//  tool permissions, artifact contracts, and turn budgets used by subagents.
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

    // MARK: - S-A1 Execution Traits

    /// 子代理优先使用的模型。`.inherit` 表示沿用父代理的模型。
    let modelPreference: SubagentModelPreference

    /// Thinking budget 偏好（`nil` 表示使用服务默认值）。
    let effort: SubagentEffort?

    /// `true` 时此代理总应以后台任务方式产生（不阻塞父代理 loop）。
    let background: Bool

    /// `true` 时对此代理构建系统提示时跳过 CLAUDE.md 层级、git status
    /// 和 workspace 状态描述（节省只读代理的 token 开销）。
    let omitMainContext: Bool

    /// 子代理第一轮 user-message 前额外注入的文本（nil = 不注入）。
    let initialPrompt: String?

    /// 每轮 user-message 前重新注入的短提醒（≤200 字；nil = 不注入）。
    let criticalReminder: String?

    /// UI 标注颜色名称（nil = 使用默认）。
    let color: String?

    /// 从代理可用工具集中排除的工具名称列表（空 = 不排除）。
    let disallowedToolNames: [String]

    // MARK: - S-A2 One-Shot Trailer Skip
    /// `true` 时子代理结果不附加执行元数据 trailer。
    let isOneShot: Bool

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
        toolGrants: [ToolGrant] = [],
        readableArtifacts: Set<WorkflowArtifactKind> = [],
        writableArtifacts: Set<WorkflowArtifactKind> = [],
        subscribesTo: Set<WorkflowMessageKind> = [.task],
        defaultOutputMessageKind: WorkflowMessageKind = .statusUpdate,
        primaryOutputArtifactKind: WorkflowArtifactKind? = nil,
        maxTurnsPerActivation: Int = 10,
        maxActivations: Int = 5,
        // S-A1 新增（全部有默认值，向后兼容）
        modelPreference: SubagentModelPreference = .inherit,
        effort: SubagentEffort? = nil,
        background: Bool = false,
        omitMainContext: Bool = false,
        initialPrompt: String? = nil,
        criticalReminder: String? = nil,
        color: String? = nil,
        disallowedToolNames: [String] = [],
        // S-A2 新增
        isOneShot: Bool = false
    ) {
        self.name = name
        self.displayName = displayName
        self.description = description
        self.systemPrompt = systemPrompt
        self.enableTextEditor = enableTextEditor
        self.enableBash = enableBash
        self.enableWebSearch = enableWebSearch
        self.enableWebFetch = enableWebFetch
        self.toolGrants = toolGrants
        self.readableArtifacts = readableArtifacts
        self.writableArtifacts = writableArtifacts
        self.subscribesTo = subscribesTo
        self.defaultOutputMessageKind = defaultOutputMessageKind
        self.primaryOutputArtifactKind = primaryOutputArtifactKind
        self.maxTurnsPerActivation = maxTurnsPerActivation
        self.maxActivations = maxActivations
        self.modelPreference = modelPreference
        self.effort = effort
        self.background = background
        self.omitMainContext = omitMainContext
        self.initialPrompt = initialPrompt
        self.criticalReminder = criticalReminder
        self.color = color
        self.disallowedToolNames = disallowedToolNames
        self.isOneShot = isOneShot
    }

}

// MARK: - Built-in Roles

extension WorkflowRoleDefinition {

    /// All built-in roles — loaded from the structured built-in agent catalog.
    static var all: [WorkflowRoleDefinition] {
        AgentCatalog.shared.workflowRoleDefinitions
    }

    static func find(named name: String) -> WorkflowRoleDefinition? {
        all.first { $0.name == name }
    }

    static var plan: WorkflowRoleDefinition {
        AgentCatalog.shared.find(named: "plan")!.workflowRoleDefinition
    }

    static var planner: WorkflowRoleDefinition { plan }
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

    // MARK: - M-06 Consolidation Daemon

    /// 记忆整合 Daemon 专用角色。
    ///
    /// 工具权限：只允许文件读取（无 Bash，无写 Web）。
    /// `enableTextEditor: true` 赋予写文件能力（写入 memory 话题文件）。
    /// `omitMainContext: true`：不注入 CLAUDE.md / git status（整合任务不需要项目上下文）。
    static var consolidationDaemon: WorkflowRoleDefinition {
        WorkflowRoleDefinition(
            name: "consolidation_daemon",
            displayName: "Memory Consolidation Daemon",
            description: "后台整合近期 session 的记忆，将多个 session 的知识蒸馏到持久话题文件。",
            systemPrompt: """
            You are a memory consolidation daemon. \
            Your sole purpose is to read recent session activity and organize long-term memory files.

            Rules:
            - Only operate inside the memory directory you are given.
            - Do not modify any files outside the memory directory.
            - Prefer updating existing topic files over creating new ones.
            - Use the file formats and type conventions specified in the user message.
            - When done, output a concise summary of changes.
            """,
            enableTextEditor: true,
            enableBash: false,
            enableWebSearch: false,
            enableWebFetch: false,
            maxTurnsPerActivation: 30,
            maxActivations: 1,
            modelPreference: .sonnet,
            omitMainContext: true,
            isOneShot: false
        )
    }
}

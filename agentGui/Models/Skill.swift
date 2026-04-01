//
//  Skill.swift
//  agentGui
//

import Foundation

/// A locally installed skill discovered from the skills directory.
struct Skill: Identifiable, Hashable, Sendable {

    // MARK: - 基础字段

    /// 目录名 — 用作稳定唯一标识符
    var id: String { directoryName }
    let directoryName: String
    /// frontmatter `name:` 的展示名称；缺失时退回 directoryName
    let name: String
    /// frontmatter `description:` 的简短描述
    let description: String
    /// skill 目录的 URL
    let path: URL
    /// skill 目录内 SKILL.md 的 URL
    let contentURL: URL

    // MARK: - 执行控制字段（S-A1）

    /// frontmatter `when_to_use:` — 模型路由提示，帮助 model 决策何时主动调用该 skill
    let whenToUse: String?
    /// frontmatter `argument-hint:` — 在 SkillsView 和 SkillInvocationTool 中展示的参数说明
    let argumentHint: String?
    /// frontmatter `arguments:` — 命名参数列表，用于 S-D2 命名参数替换
    let argumentNames: [String]
    /// frontmatter `allowed-tools:` — skill 执行期间可用的工具白名单
    let allowedTools: [String]
    /// frontmatter `model:` — 覆盖 main loop 模型；nil 表示继承当前模型
    let model: String?
    /// frontmatter `effort:` — 覆盖 thinking budget；nil 表示继承当前设置
    let effort: EffortLevel?
    /// frontmatter `context:` — 执行上下文（inline 或 fork）；默认 inline
    let executionContext: SkillExecutionContext
    /// frontmatter `agent:` — 指定执行该 skill 的 agent 类型
    let agent: String?
    /// frontmatter `user-invocable:` — 用户是否可手动调用；默认 true
    let userInvocable: Bool
    /// frontmatter `disable-model-invocation:` — 禁止模型通过 SkillInvocationTool 主动调用；默认 false
    let disableModelInvocation: Bool
    /// frontmatter `version:` — 版本标签，用于 SkillsView 显示和冲突检测（S-G2）
    let version: String?
    /// frontmatter `paths:` — 条件激活 glob 模式列表；nil 表示始终可用（S-A4）
    let paths: [String]?

    // MARK: - 运行时元数据（S-A1）

    /// skill 目录内除 SKILL.md 之外是否有其他参考文件（S-E2 懒加载用）
    let hasReferenceFiles: Bool
    /// 该技能的加载来源（user / project / managed / bundled）
    let loadedFrom: SkillSource

    // MARK: - init with defaults for new fields

    init(
        directoryName: String,
        name: String,
        description: String,
        path: URL,
        contentURL: URL,
        whenToUse: String? = nil,
        argumentHint: String? = nil,
        argumentNames: [String] = [],
        allowedTools: [String] = [],
        model: String? = nil,
        effort: EffortLevel? = nil,
        executionContext: SkillExecutionContext = .inline,
        agent: String? = nil,
        userInvocable: Bool = true,
        disableModelInvocation: Bool = false,
        version: String? = nil,
        paths: [String]? = nil,
        hasReferenceFiles: Bool = false,
        loadedFrom: SkillSource = .user
    ) {
        self.directoryName = directoryName
        self.name = name
        self.description = description
        self.path = path
        self.contentURL = contentURL
        self.whenToUse = whenToUse
        self.argumentHint = argumentHint
        self.argumentNames = argumentNames
        self.allowedTools = allowedTools
        self.model = model
        self.effort = effort
        self.executionContext = executionContext
        self.agent = agent
        self.userInvocable = userInvocable
        self.disableModelInvocation = disableModelInvocation
        self.version = version
        self.paths = paths
        self.hasReferenceFiles = hasReferenceFiles
        self.loadedFrom = loadedFrom
    }
}

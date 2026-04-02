//
//  SkillInvocationProcessor.swift
//  agentGui
//

import Foundation

// MARK: - Protocol

/// Skill 内容访问协议，使 SkillInvocationProcessor 可脱离 SkillService 单独测试。
protocol SkillContentProviding: Sendable {
    func skillsList() async -> [Skill]
    func readSkillContent(name: String) async -> String?
}

// MARK: - SkillService conformance

extension SkillService: SkillContentProviding {
    func skillsList() async -> [Skill] { availableSkills }
}

// MARK: - Result types

/// `skill_invoke` 工具的调用结果。
enum SkillInvocationOutcome: Sendable {
    /// 成功：已加载并替换完毕，可直接返回给模型。
    case success(SkillInvocationSuccess)
    /// Skill 不存在。
    case notFound(String)
    /// Skill 设置了 disableModelInvocation = true，禁止模型主动调用。
    case disabled(String)
    /// Skill 存在但内容无法读取（文件缺失或读写权限问题）。
    case unreadable(String)
}

struct SkillInvocationSuccess: Sendable {
    /// Skill 的规范目录名，用于日志和工具结果展示。
    let commandName: String
    /// 经过 $ARGUMENTS 等变量替换后的 skill 全文。
    let content: String
    /// Skill 声明的工具白名单（空表示不限制）。
    let allowedTools: [String]
    /// Skill 声明的模型覆盖（nil 表示继承当前模型）。
    let modelOverride: String?
}

// MARK: - Processor

/// 封装 `skill_invoke` 工具的业务逻辑。纯计算，无副作用（除了 async 内容读取）。
///
/// 对应 Claude Code `SkillTool.ts` → `call()` inline 分支。
struct SkillInvocationProcessor: Sendable {
    private let provider: any SkillContentProviding
    private let sessionId: String

    init(provider: any SkillContentProviding, sessionId: String) {
        self.provider = provider
        self.sessionId = sessionId
    }

    /// 执行 skill 调用的完整流程：查找 → 校验 → 读取内容 → 变量替换 → 组装结果。
    ///
    /// - Parameters:
    ///   - skillName: 用户/模型传入的技能名称（支持前导斜杠，会自动规范化）。
    ///   - args:      调用参数字符串（用于 $ARGUMENTS 替换）。
    func invoke(skillName: String, args: String?) async -> SkillInvocationOutcome {
        // 规范化：移除前导斜杠
        let normalizedName = skillName.hasPrefix("/") ? String(skillName.dropFirst()) : skillName

        // 查找 skill（先按 name 后按 directoryName）
        let skills = await provider.skillsList()
        guard let skill = skills.first(where: { $0.name == normalizedName || $0.directoryName == normalizedName }) else {
            return .notFound(normalizedName)
        }

        // disableModelInvocation 检查
        guard !skill.disableModelInvocation else {
            return .disabled(skill.directoryName)
        }

        // 读取内容
        guard let rawContent = await provider.readSkillContent(name: skill.directoryName) else {
            return .unreadable(skill.directoryName)
        }

        // 变量替换（$ARGUMENTS + 内置变量）
        let processedContent = SkillArgumentSubstitution.substitute(
            content: rawContent,
            args: args,
            skillDirectory: skill.path,
            sessionId: sessionId
        )

        return .success(SkillInvocationSuccess(
            commandName: skill.directoryName,
            content: processedContent,
            allowedTools: skill.allowedTools,
            modelOverride: skill.model
        ))
    }
}

// MARK: - Null Object

/// SkillService 不可用时的 fallback，保证 SkillInvocationProcessor 不需要处理可选类型。
struct NullSkillContentProvider: SkillContentProviding {
    func skillsList() async -> [Skill] { [] }
    func readSkillContent(name: String) async -> String? { nil }
}

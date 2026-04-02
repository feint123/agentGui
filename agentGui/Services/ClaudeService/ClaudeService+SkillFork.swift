//
//  ClaudeService+SkillFork.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

// MARK: - SkillSubagentRunning Protocol

/// Fork skill 执行的子代理调用接口。
/// 抽象层让 SkillForkExecutor 在测试中可与 ClaudeService 解耦。
protocol SkillSubagentRunning: Sendable {
    /// 在独立子代理中执行 task，返回子代理的最终文本输出。
    /// - Parameters:
    ///   - task: 经过变量替换后的 skill prompt 全文（作为子代理的初始 user message）。
    ///   - allowedTools: 子代理可用的工具 ID 列表；空数组表示不限制。
    ///   - modelId: 子代理使用的模型 ID（已按 skill.model > parentModel 优先级解析）。
    func runSkillSubagent(
        task: String,
        allowedTools: [String],
        modelId: String
    ) async throws -> String
}

// MARK: - SkillForkExecutor

/// 封装 fork skill 的执行流程：内容传入 → 工具集构建 → 模型解析 → 子代理运行 → 结果封装。
///
/// 对应 Claude Code `executeForkedSkill()` (SkillTool.ts) 的 agentGui 移植。
/// 注意：不迁移遥测（logEvent）和 ANT-only 实验特性。
struct SkillForkExecutor {
    let runner: any SkillSubagentRunning
    let defaultModelId: String

    /// 执行 fork skill。
    /// - Parameters:
    ///   - skill: 已查找到的 Skill，`executionContext` 必须为 `.fork`。
    ///   - processedContent: 经过 SkillArgumentSubstitution 处理后的 skill 内容。
    ///   - parentModelId: 调用方（主 agent）当前模型 ID，当 skill 未指定 model 时继承。
    /// - Returns: 封装有子代理输出文本的 `ToolExecutionResult`；失败时 `isError = true`。
    func execute(
        skill: Skill,
        processedContent: String,
        parentModelId: String
    ) async throws -> ToolExecutionResult {
        // 解析实际使用的模型：skill.model > parentModelId
        let resolvedModelId = skill.model ?? parentModelId

        do {
            let resultText = try await runner.runSkillSubagent(
                task: processedContent,
                allowedTools: skill.allowedTools,
                modelId: resolvedModelId
            )
            let header = "[Skill fork result: \(skill.directoryName)]\n"
            return ToolExecutionResult(header + resultText)
        } catch {
            return .failure("Error executing forked skill '\(skill.directoryName)': \(error.localizedDescription)")
        }
    }
}

// MARK: - SkillForkContext

/// ClaudeService 在 tool dispatch 执行期间存储的上下文，
/// 供 `runSkillSubagent` 获取当前运行环境参数。
struct SkillForkContext: Sendable {
    let service: any AnthropicService
    let modelId: String
    let settings: AppSettings
    let sessionId: String
    let modelContext: ModelContext
}

// MARK: - SkillForkError

enum SkillForkError: Error, LocalizedError {
    case missingRunContext
    case serviceNotConfigured

    var errorDescription: String? {
        switch self {
        case .missingRunContext:
            return "SkillFork: ClaudeService 缺少运行上下文。skill_invoke 必须在 agent loop 内调用。"
        case .serviceNotConfigured:
            return "SkillFork: ClaudeService 尚未配置 AnthropicService，请先设置 API key。"
        }
    }
}

// MARK: - ClaudeService as SkillSubagentRunning

extension ClaudeService: SkillSubagentRunning {

    /// ClaudeService 的 SkillSubagentRunning 实现：构造子代理所需的完整参数，
    /// 复用 `runSubagentLoop` 路径（已有 subagent 执行基础设施）。
    ///
    /// - 工具集：若 `allowedTools` 非空，只开放列表内的工具；否则使用空 toolGrants（走默认工具集）。
    /// - 该方法通过 `currentSkillForkContext` 获取当前会话的运行参数。
    func runSkillSubagent(
        task: String,
        allowedTools: [String],
        modelId: String
    ) async throws -> String {
        guard let ctx = currentSkillForkContext else {
            throw SkillForkError.missingRunContext
        }

        let toolGrants = buildSkillForkToolGrants(from: allowedTools)

        let definition = WorkflowRoleDefinition(
            name: "skill-fork",
            displayName: "Skill Fork",
            description: "Fork execution agent for skill invocation",
            systemPrompt: "",
            toolGrants: toolGrants,
            maxTurnsPerActivation: 20
        )

        // 创建一个占位 ToolCall 记录（fork skill 对应的 SwiftData 状态追踪）
        let dummyToolCall = ToolCall(toolCallId: "skill-fork-\(UUID().uuidString)", kind: .execute)

        let agentMsg = try await runSubagentLoop(
            task: task,
            definition: definition,
            toolCallRecord: dummyToolCall,
            service: ctx.service,
            modelId: modelId,
            overrideModelId: nil,
            settings: ctx.settings,
            sessionId: ctx.sessionId,
            modelContext: ctx.modelContext
        )

        return agentMsg.apiText.isEmpty ? "(fork skill produced no output)" : agentMsg.apiText
    }

    /// 构造工具授权列表。
    /// - 若 allowedTools 为空：返回空数组（子代理将使用 WorkflowRoleDefinition 默认工具集）。
    /// - 若 allowedTools 非空：每个 toolID 构造一条 ToolGrant。
    private func buildSkillForkToolGrants(from allowedTools: [String]) -> [ToolGrant] {
        guard !allowedTools.isEmpty else { return [] }
        return allowedTools.map { toolID in
            ToolGrant(
                toolID: toolID,
                accessMode: .unrestricted,
                allowedContexts: [.subagent]
            )
        }
    }
}

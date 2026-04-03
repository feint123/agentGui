//
//  ClaudeService+Subagent.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

// MARK: - S-F3 Fork Override

/// S-F3: fork 子代理执行参数，用于覆盖 runSubagentLoop 的默认消息构建和系统提示。
struct ForkSubagentOverride {
    /// 已由 ForkMessageBuilder 构建好的初始消息列表：[...parentHistory, assistantMsg, userMsg]
    /// 替代默认的单条 task user 消息。
    let initialMessages: [MessageParameter.Message]
    /// 父代理已渲染的系统提示文本（byte-identical 确保 cache 命中）。
    /// 替代 WorkflowRoleDefinition.systemPrompt。
    let parentSystemPromptText: String?
}

// MARK: - Subagent Support

extension ClaudeService {

    func makeSubagentToolsForTests(
        modelId: String,
        definition: WorkflowRoleDefinition,
        settings: AppSettings
    ) -> [MessageParameter.Tool] {
        buildSubagentTools(definition: definition, settings: settings)
    }

    /// 解析子代理实际使用的模型 ID（测试可见辅助桥接方法）。
    /// 将 WorkflowRoleDefinition.modelPreference 传递给 SubagentModelResolver。
    nonisolated static func resolvedModelId(
        for definition: WorkflowRoleDefinition,
        parentModelId: String,
        overrideModelId: String? = nil
    ) -> String {
        SubagentModelResolver.resolve(
            preference: definition.modelPreference,
            parentModelId: parentModelId,
            overrideModelId: overrideModelId
        )
    }

    /// 执行 run_subagent 工具调用：解析参数、查找定义、运行嵌套 loop
    /// 返回 AgentMessage（带发送方、接收方、内容类型和元数据）而非纯字符串。
    func executeRunSubagentTool(
        input: MessageResponse.Content.Input,
        toolCallRecord: ToolCall,
        service: any AnthropicService,
        modelId: String,
        settings: AppSettings,
        sessionId: String,
        modelContext: ModelContext
    ) async -> AgentMessage {
        guard let agentName = input["agent_name"]?.stringValue else {
            return .error("missing 'agent_name' parameter", sender: "system")
        }
        guard let task = input["task"]?.stringValue else {
            return .error("missing 'task' parameter", sender: "system")
        }

        // S-A3: 解析调用方可选的 model override
        let overrideModelId = input["model"]?.stringValue.flatMap {
            $0.isEmpty ? nil : $0
        }

        do {
            return try await runNamedSubagent(
                name: agentName,
                task: task,
                toolCallRecord: toolCallRecord,
                service: service,
                modelId: modelId,
                overrideModelId: overrideModelId,
                settings: settings,
                sessionId: sessionId,
                modelContext: modelContext
            )
        } catch {
            return .error(error.localizedDescription, sender: agentName)
        }
    }

    func runNamedSubagent(
        name: String,
        task: String,
        toolCallRecord: ToolCall,
        service: any AnthropicService,
        modelId: String,
        overrideModelId: String? = nil,
        settings: AppSettings,
        sessionId: String,
        modelContext: ModelContext
    ) async throws -> AgentMessage {
        let catalog = AgentCatalog.shared
        guard let definition = catalog.find(named: name) else {
            let available = catalog.subagentInvocableAgents.map(\.name).joined(separator: ", ")
            return .error("unknown agent '\(name)'. Available: \(available)", sender: "system")
        }

        return try await runSubagentLoop(
            task: task,
            definition: definition.workflowRoleDefinition,
            toolCallRecord: toolCallRecord,
            service: service,
            modelId: modelId,
            overrideModelId: overrideModelId,
            settings: settings,
            sessionId: sessionId,
            modelContext: modelContext
        )
    }

    /// 子代理的嵌套 agentic loop — 通过 runCoreAgentLoop 复用主代理的核心流程。
    /// 返回 AgentMessage：自动检测 JSON 结构化输出，并附带执行轮次等元数据。
    func runSubagentLoop(
        task: String,
        definition: WorkflowRoleDefinition,
        toolCallRecord: ToolCall,
        service: any AnthropicService,
        modelId: String,
        overrideModelId: String? = nil,
        settings: AppSettings,
        sessionId: String,
        modelContext: ModelContext,
        onProgressUpdate: (@MainActor @Sendable (SubagentProgress) -> Void)? = nil,
        /// S-F2: 当提供此参数时，跳过默认首轮消息构造，直接使用指定消息列表（用于 fork child）。
        initialMessagesOverride: [MessageParameter.Message]? = nil,
        /// S-F3: fork 子代理覆盖参数（含预构建消息 + 父代理系统提示）；优先于 initialMessagesOverride。
        forkOverride: ForkSubagentOverride? = nil
    ) async throws -> AgentMessage {
        let startTime = Date()

        // S-A3: 按三层优先级解析实际使用的模型 ID
        let resolvedModelId = SubagentModelResolver.resolve(
            preference: definition.modelPreference,
            parentModelId: modelId,
            overrideModelId: overrideModelId
        )

        // S-F3 > S-F2 > default: 按优先级选择初始消息和系统提示
        var loopMessages: [MessageParameter.Message]
        let systemText: String
        if let fork = forkOverride {
            // S-F3: 使用预构建的 fork 消息和父代理系统提示
            loopMessages = fork.initialMessages
            systemText = fork.parentSystemPromptText ?? definition.systemPrompt
        } else if let override = initialMessagesOverride {
            // S-F2: 使用 implicit fork 构建的消息列表
            loopMessages = override
            systemText = definition.systemPrompt
        } else {
            let firstTurnContent = ClaudeService.buildSubagentFirstTurnMessage(
                task: task,
                criticalReminder: definition.criticalReminder
            )
            loopMessages = [.init(role: .user, content: .text(firstTurnContent))]
            systemText = definition.systemPrompt
        }
        let system = makeEphemeralSystemPrompt(systemText)
        let request = AgentLoopRunRequest(
            service: service,
            modelId: resolvedModelId,
            tools: buildSubagentTools(definition: definition, settings: settings),
            system: system,
            maxRounds: definition.maxRounds,
            toolExecutionContext: .subagent,
            toolApprovalMode: .bypassApprovals,
            runSource: "subagent",
            runLabel: definition.name,
            requestedBudgetSeconds: nil,
            criticalReminder: definition.criticalReminder
        )
        let runtime = AgentLoopRuntime(
            settings: settings,
            session: nil,
            sessionId: sessionId,
            modelContext: modelContext,
            makeRound: { idx in
                let round = AgentRound(roundIndex: idx)
                round.subagentToolCall = toolCallRecord
                return round
            },
            parentMessage: nil,
            streamProjectionTarget: .none,
            toolInterceptor: nil,
            subagentProgressUpdate: onProgressUpdate  // S-C3
        )
        let result = try await runCoreAgentLoop(
            messages: &loopMessages,
            request: request,
            runtime: runtime
        )
        let rawOutput = result.text.isEmpty ? "(subagent produced no output)" : result.text
        let elapsed = Date().timeIntervalSince(startTime)
        let rounds = min(loopMessages.count / 2, definition.maxRounds)
        let trailer = ClaudeService.buildSubagentTrailer(
            agentName: definition.name,
            rounds: rounds,
            elapsed: elapsed,
            isOneShot: definition.isOneShot
        )
        let output = ClaudeService.applyTrailerToOutput(output: rawOutput, trailer: trailer)
        let metadata: [String: String] = [
            "agent":    definition.name,
            "rounds":   String(rounds),
            "elapsed":  String(format: "%.2fs", elapsed)
        ]
        return .detecting(text: output, sender: definition.name, metadata: metadata)
    }

    /// 为子代理构建工具列表（根据定义配置，不添加 run_subagent / ask_user_question）
    private func buildSubagentTools(definition: WorkflowRoleDefinition, settings: AppSettings) -> [MessageParameter.Tool] {
        DefaultToolsetResolver(registry: DefaultToolRegistry()).resolve(
            .init(context: .subagent, role: definition, settings: settings)
        ).tools
    }

    private func toolName(from tool: MessageParameter.Tool) -> String? {
        extractString(labeled: "name", from: Mirror(reflecting: tool))
    }

    private func extractString(labeled target: String, from mirror: Mirror) -> String? {
        for child in mirror.children {
            if child.label == target, let value = child.value as? String {
                return value
            }

            let childMirror = Mirror(reflecting: child.value)
            if let value = extractString(labeled: target, from: childMirror) {
                return value
            }
        }

        return nil
    }

    // MARK: - S-A2 One-Shot Trailer

    /// 根据 isOneShot 标记生成执行元数据 trailer。
    /// - Returns: 追加在输出末尾的字符串（以 `\n` 开头），或 `nil`（one-shot 代理跳过）。
    nonisolated static func buildSubagentTrailer(
        agentName: String,
        rounds: Int,
        elapsed: TimeInterval,
        isOneShot: Bool
    ) -> String? {
        guard !isOneShot else { return nil }
        let elapsedStr = String(format: "%.2fs", elapsed)
        return "\n<agent_execution>agent: \(agentName) | rounds: \(rounds) | elapsed: \(elapsedStr)</agent_execution>"
    }

    /// 将 trailer（可为 nil）追加到输出文本末尾。
    nonisolated static func applyTrailerToOutput(output: String, trailer: String?) -> String {
        guard let trailer else { return output }
        return output + trailer
    }

    // MARK: - S-A5 CriticalReminder first-turn injection

    /// 根据 criticalReminder 构建首轮 task 消息文本。
    /// - Parameters:
    ///   - task: 子代理的原始任务描述
    ///   - criticalReminder: 每轮提醒文本（nil = 不注入）
    /// - Returns: 若 reminder 非空，返回 "reminder\n\n task"；否则原样返回 task。
    nonisolated static func buildSubagentFirstTurnMessage(
        task: String,
        criticalReminder: String?
    ) -> String {
        guard let reminder = criticalReminder, !reminder.isEmpty else { return task }
        return "\(reminder)\n\n\(task)"
    }
}

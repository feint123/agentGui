//
//  ClaudeService+Subagent.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

// MARK: - Subagent Support

extension ClaudeService {

    func makeSubagentToolsForTests(
        modelId: String,
        definition: WorkflowRoleDefinition,
        settings: AppSettings
    ) -> [MessageParameter.Tool] {
        buildSubagentTools(definition: definition, settings: settings)
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

        do {
            return try await runNamedSubagent(
                name: agentName,
                task: task,
                toolCallRecord: toolCallRecord,
                service: service,
                modelId: modelId,
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
            settings: settings,
            sessionId: sessionId,
            modelContext: modelContext
        )
    }

    /// 子代理的嵌套 agentic loop — 通过 runCoreAgentLoop 复用主代理的核心流程。
    /// 返回 AgentMessage：自动检测 JSON 结构化输出，并附带执行轮次等元数据。
    private func runSubagentLoop(
        task: String,
        definition: WorkflowRoleDefinition,
        toolCallRecord: ToolCall,
        service: any AnthropicService,
        modelId: String,
        settings: AppSettings,
        sessionId: String,
        modelContext: ModelContext
    ) async throws -> AgentMessage {
        let startTime = Date()
        var loopMessages: [MessageParameter.Message] = [.init(role: .user, content: .text(task))]
        let system = makeEphemeralSystemPrompt(definition.systemPrompt)
        let request = AgentLoopRunRequest(
            service: service,
            modelId: modelId,
            tools: buildSubagentTools(definition: definition, settings: settings),
            system: system,
            maxRounds: definition.maxRounds,
            toolExecutionContext: .subagent,
            toolApprovalMode: .bypassApprovals,
            runSource: "subagent",
            runLabel: definition.name,
            requestedBudgetSeconds: nil
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
            toolInterceptor: nil
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
}

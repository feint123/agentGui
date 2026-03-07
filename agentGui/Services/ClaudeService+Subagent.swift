//
//  ClaudeService+Subagent.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

// MARK: - Subagent Support

extension ClaudeService {

    /// 执行 run_subagent 工具调用：解析参数、查找定义、运行嵌套 loop
    func executeRunSubagentTool(
        input: MessageResponse.Content.Input,
        toolCallRecord: ToolCall,
        service: any AnthropicService,
        modelId: String,
        settings: AppSettings,
        sessionId: String,
        modelContext: ModelContext
    ) async -> String {
        guard let agentName = input["agent_name"]?.stringValue else {
            return "Error: missing 'agent_name' parameter"
        }
        guard let task = input["task"]?.stringValue else {
            return "Error: missing 'task' parameter"
        }
        guard let definition = SubagentDefinition.find(named: agentName) else {
            let available = SubagentDefinition.all.map(\.name).joined(separator: ", ")
            return "Error: unknown agent '\(agentName)'. Available: \(available)"
        }

        do {
            return try await runSubagentLoop(
                task: task,
                definition: definition,
                toolCallRecord: toolCallRecord,
                service: service,
                modelId: modelId,
                settings: settings,
                sessionId: sessionId,
                modelContext: modelContext
            )
        } catch {
            return "Subagent error: \(error.localizedDescription)"
        }
    }

    /// 子代理的嵌套 agentic loop：不允许递归调用 run_subagent / ask_user_question
    private func runSubagentLoop(
        task: String,
        definition: SubagentDefinition,
        toolCallRecord: ToolCall,
        service: any AnthropicService,
        modelId: String,
        settings: AppSettings,
        sessionId: String,
        modelContext: ModelContext
    ) async throws -> String {
        var loopMessages: [MessageParameter.Message] = [
            .init(role: .user, content: .text(task))
        ]
        var accumulatedText = ""
        var continueLoop = true
        var roundIndex = 0

        let subagentTools = buildSubagentTools(modelId: modelId, definition: definition)
        let systemValue: MessageParameter.System? = definition.systemPrompt.isEmpty
            ? nil
            : .text(definition.systemPrompt)

        while continueLoop && roundIndex < definition.maxRounds {
            let useThinking = settings.enableExtendedThinking && isThinkingCapable(modelId: modelId)
            let budget = settings.extendedThinkingBudget
            let maxTokens = useThinking ? max(budget + 4096, 16000) : 8192

            let params = MessageParameter(
                model: .other(modelId),
                messages: loopMessages,
                maxTokens: maxTokens,
                system: systemValue,
                tools: subagentTools.isEmpty ? nil : subagentTools,
                thinking: useThinking ? .init(budgetTokens: budget) : nil
            )
            let stream = try await service.streamMessage(params)

            // Create a round linked to the parent ToolCall (not a Message)
            let round = AgentRound(roundIndex: roundIndex)
            round.subagentToolCall = toolCallRecord
            modelContext.insert(round)
            try? modelContext.save()
            roundIndex += 1

            var currentRoundText = ""
            var currentRoundThinking = PendingThinking()
            var pendingTools: [Int: PendingToolUse] = [:]
            var currentBlockIndex: Int? = nil
            var stopReason: String? = nil

            for try await event in stream {
                if let block = event.contentBlock {
                    if block.type == "tool_use", let id = block.id, let name = block.name {
                        let idx = event.index ?? pendingTools.count
                        pendingTools[idx] = PendingToolUse(id: id, name: name)
                        currentBlockIndex = idx
                    } else {
                        currentBlockIndex = nil
                    }
                }

                if let delta = event.delta {
                    switch delta.type {
                    case "text_delta":
                        if let text = delta.text {
                            currentRoundText += text
                            round.text = currentRoundText
                        }
                    case "thinking_delta":
                        if let thinking = delta.thinking {
                            currentRoundThinking.content += thinking
                            round.thinkingContent = currentRoundThinking.content
                        }
                    case "signature_delta":
                        if let sig = delta.signature {
                            currentRoundThinking.signature = sig
                            round.thinkingSignature = sig
                        }
                    default:
                        if let text = delta.text {
                            currentRoundText += text
                            round.text = currentRoundText
                        }
                        if let json = delta.partialJson, let idx = currentBlockIndex {
                            pendingTools[idx]?.partialJson += json
                        }
                    }
                    if let reason = delta.stopReason { stopReason = reason }
                }
            }

            if !currentRoundText.isEmpty {
                if !accumulatedText.isEmpty { accumulatedText += "\n\n" }
                accumulatedText += currentRoundText
                round.text = currentRoundText
            }
            try? modelContext.save()

            var assistantObjects: [MessageParameter.Message.Content.ContentObject] = []
            if useThinking && !currentRoundThinking.content.isEmpty,
               let sig = currentRoundThinking.signature {
                assistantObjects.append(.thinking(currentRoundThinking.content, sig))
            }

            if stopReason == "tool_use" && !pendingTools.isEmpty {
                let sorted = pendingTools.sorted { $0.key < $1.key }.map { $0.value }
                if !currentRoundText.isEmpty { assistantObjects.append(.text(currentRoundText)) }
                var toolResultObjects: [MessageParameter.Message.Content.ContentObject] = []

                for pending in sorted {
                    let toolInput = pending.parsedInput
                    assistantObjects.append(.toolUse(pending.id, pending.name, toolInput))

                    let toolRecord = makeToolCallRecord(
                        toolUseId: pending.id,
                        toolName: pending.name,
                        input: toolInput,
                        message: nil,
                        agentRound: round
                    )
                    modelContext.insert(toolRecord)
                    try? modelContext.save()

                    let toolResult = await executeTool(
                        name: pending.name,
                        input: toolInput,
                        settings: settings,
                        sessionId: sessionId
                    )
                    toolRecord.terminalOutput = toolResult
                    toolRecord.status = .success
                    toolRecord.endTime = Date()
                    try? modelContext.save()

                    toolResultObjects.append(.toolResult(pending.id, toolResult))
                }

                loopMessages.append(.init(role: .assistant, content: .list(assistantObjects)))
                loopMessages.append(.init(role: .user, content: .list(toolResultObjects)))
            } else {
                continueLoop = false
            }
        }

        return accumulatedText.isEmpty ? "(subagent produced no output)" : accumulatedText
    }

    /// 为子代理构建工具列表（根据定义配置，不添加 run_subagent / ask_user_question）
    private func buildSubagentTools(modelId: String, definition: SubagentDefinition) -> [MessageParameter.Tool] {
        var tools: [MessageParameter.Tool] = []
        if definition.enableTextEditor {
            let isClaude3 = modelId.contains("3-") || modelId.contains("3.")
            let type = isClaude3 ? "text_editor_20250124" : "text_editor_20250728"
            let name = isClaude3 ? "str_replace_editor" : "str_replace_based_edit_tool"
            tools.append(.hosted(type: type, name: name))
        }
        if definition.enableBash {
            tools.append(.hosted(type: "bash_20250124", name: "bash"))
        }
        return tools
    }
}

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
        var loopMemory = ContextMemory()

        let subagentTools = buildSubagentTools(modelId: modelId, definition: definition, settings: settings)
        let systemValue: MessageParameter.System? = definition.systemPrompt.isEmpty
            ? nil
            : .text(definition.systemPrompt)

        while continueLoop && roundIndex < definition.maxRounds {
            // Count tokens and compress into hierarchical memory if context is getting large
            if let tokenCount = try? await service.countTokens(
                parameter: MessageTokenCountParameter(
                    model: .other(modelId),
                    messages: loopMessages,
                    system: systemValue,
                    tools: subagentTools.isEmpty ? nil : subagentTools
                )
            ) {
                currentInputTokens = tokenCount.inputTokens
                currentModelId = modelId
                print("Subagent input tokens: \(tokenCount.inputTokens) (\(Int(contextUsageRatio * 100))%)")
            }
            await compressIfNeeded(
                messages: &loopMessages,
                memory: &loopMemory,
                service: service,
                modelId: modelId
            )

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

            // Accumulate round text
            if !currentRoundText.isEmpty {
                if !accumulatedText.isEmpty { accumulatedText += "\n\n" }
                accumulatedText += currentRoundText
                round.text = currentRoundText
            }

            // Persist stop reason on this round
            round.stopReason = stopReason
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
                    toolRecord.terminalOutput = toolResult.text
                    toolRecord.status = toolResult.toolCallStatus
                    toolRecord.endTime = Date()
                    try? modelContext.save()

                    toolResultObjects.append(.toolResult(pending.id, toolResult.text, isError: toolResult.isError ? true : nil))
                    toolResultObjects.append(contentsOf: toolResult.mediaContent)
                }

                loopMessages.append(.init(role: .assistant, content: .list(assistantObjects)))
                loopMessages.append(.init(role: .user, content: .list(toolResultObjects)))

            } else if stopReason == "end_turn" {
                continueLoop = false

            } else if stopReason == "max_tokens" {
                print("Subagent max_tokens at round \(roundIndex - 1), appending continuation turn")
                if !currentRoundText.isEmpty { assistantObjects.append(.text(currentRoundText)) }
                if !assistantObjects.isEmpty {
                    loopMessages.append(.init(role: .assistant, content: .list(assistantObjects)))
                }
                loopMessages.append(.init(
                    role: .user,
                    content: .text("Please continue your previous response exactly where you left off. Do not repeat what you already wrote and do not re-plan — just continue.")
                ))

            } else if stopReason == "pause_turn" {
                print("Subagent pause_turn at round \(roundIndex - 1), resuming")
                if !currentRoundText.isEmpty { assistantObjects.append(.text(currentRoundText)) }
                if !assistantObjects.isEmpty {
                    loopMessages.append(.init(role: .assistant, content: .list(assistantObjects)))
                }
                loopMessages.append(.init(role: .user, content: .text("Continue.")))

            } else {
                let reason = stopReason ?? "nil"
                print("Subagent unexpected stop reason '\(reason)' at round \(roundIndex - 1), terminating")
                if !accumulatedText.isEmpty {
                    accumulatedText += "\n\n⚠️ Subagent loop ended unexpectedly (stop_reason: \(reason))."
                }
                continueLoop = false
            }
        }

        // Safety: maxRounds guard
        if roundIndex >= definition.maxRounds && continueLoop {
            print("Subagent reached maxRounds (\(definition.maxRounds)), terminating")
            if !accumulatedText.isEmpty {
                accumulatedText += "\n\n⚠️ Subagent stopped after reaching the maximum of \(definition.maxRounds) rounds."
            }
        }

        return accumulatedText.isEmpty ? "(subagent produced no output)" : accumulatedText
    }

    /// 为子代理构建工具列表（根据定义配置，不添加 run_subagent / ask_user_question）
    private func buildSubagentTools(modelId: String, definition: SubagentDefinition, settings: AppSettings) -> [MessageParameter.Tool] {
        var tools: [MessageParameter.Tool] = []
        if definition.enableTextEditor {
            tools.append(.function(
                name: "str_replace_based_edit_tool",
                description: """
                A text editor for viewing and modifying files. Supported commands:
                - view: Read file contents, optionally with view_range [start, end] (1-based line numbers)
                - str_replace: Replace an exact string in a file: provide old_str and new_str
                - create: Create or overwrite a file with file_text
                - insert: Insert new_str after insert_line (0 = prepend)
                Always use absolute file paths.
                """,
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "command": .init(type: .string, description: "One of: view, str_replace, create, insert"),
                        "path": .init(type: .string, description: "Absolute path to the target file"),
                        "old_str": .init(type: .string, description: "(str_replace) Exact text to find and replace"),
                        "new_str": .init(type: .string, description: "(str_replace/insert) Replacement or inserted text"),
                        "file_text": .init(type: .string, description: "(create) Full content of the new file"),
                        "insert_line": .init(type: .integer, description: "(insert) Line number to insert after; 0 = before line 1"),
                        "view_range": .init(type: .array, description: "(view) Optional [start_line, end_line] to limit output")
                    ],
                    required: ["command", "path"]
                )
            ))
        }
        if definition.enableBash {
            tools.append(.function(
                name: "bash",
                description: """
                Execute shell commands in a persistent bash session. \
                The session preserves working directory and environment variables across calls. \
                Use restart: true to reset the session.
                """,
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "command": .init(type: .string, description: "The bash command to execute"),
                        "restart": .init(type: .boolean, description: "If true, restart the bash session and ignore command")
                    ],
                    required: []
                )
            ))
        }
        if settings.enableWebSearchTool {
            tools.append(.function(
                name: "web_search",
                description: """
                Search the web using Bing and return a list of relevant results (title, URL, snippet). \
                Use when you need up-to-date information, facts, or references not in your training data.
                """,
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "query": .init(type: .string, description: "The search query string"),
                        "count": .init(type: .integer, description: "Number of results to return (1-10, default 5)")
                    ],
                    required: ["query"]
                )
            ))
        }
        if settings.enableWebFetchTool {
            tools.append(.function(
                name: "web_fetch",
                description: """
                Fetch a webpage and return its cleaned text content. \
                HTML boilerplate, scripts, styles, and navigation are stripped. \
                Use after web_search to read the full content of a specific page.
                """,
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "url": .init(type: .string, description: "The full URL to fetch (http or https)"),
                        "max_chars": .init(type: .integer, description: "Maximum characters to return (default 8000, max 32000)")
                    ],
                    required: ["url"]
                )
            ))
        }
        return tools
    }
}

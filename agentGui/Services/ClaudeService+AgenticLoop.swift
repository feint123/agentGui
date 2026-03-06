//
//  ClaudeService+AgenticLoop.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

// MARK: - Pending Tool Use

struct PendingToolUse {
    let id: String
    let name: String
    var partialJson: String = ""

    var parsedInput: MessageResponse.Content.Input {
        guard let data = partialJson.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: MessageResponse.Content.DynamicContent].self, from: data)) ?? [:]
    }
}

// MARK: - Agentic Loop

extension ClaudeService {

    func runAgenticLoop(
        apiMessages: [MessageParameter.Message],
        assistantMessage: Message,
        service: any AnthropicService,
        modelId: String,
        tools: [MessageParameter.Tool],
        session: Session,
        settings: AppSettings,
        modelContext: ModelContext
    ) async throws {
        var loopMessages = apiMessages
        var accumulatedText = ""
        var continueLoop = true

        while continueLoop {
            let params = MessageParameter(
                model: .other(modelId),
                messages: loopMessages,
                maxTokens: 8192,
                tools: tools.isEmpty ? nil : tools
            )
            let stream = try await service.streamMessage(params)

            var currentRoundText = ""
            var pendingTools: [Int: PendingToolUse] = [:]
            var currentBlockIndex: Int? = nil
            var stopReason: String? = nil

            for try await event in stream {
                // content_block_start — register new tool_use block
                if let block = event.contentBlock {
                    if block.type == "tool_use", let id = block.id, let name = block.name {
                        let idx = event.index ?? pendingTools.count
                        pendingTools[idx] = PendingToolUse(id: id, name: name)
                        currentBlockIndex = idx
                    } else if block.type == "text" {
                        currentBlockIndex = nil
                    }
                }

                // content_block_delta — accumulate text or partial JSON
                if let delta = event.delta {
                    if let text = delta.text {
                        currentRoundText += text
                        let joined = accumulatedText.isEmpty
                            ? currentRoundText
                            : accumulatedText + "\n\n" + currentRoundText
                        assistantMessage.textContent = joined
                    } else if let json = delta.partialJson, let idx = currentBlockIndex {
                        pendingTools[idx]?.partialJson += json
                    }
                    if let reason = delta.stopReason {
                        stopReason = reason
                    }
                }
            }

            // Persist this round's text
            if !currentRoundText.isEmpty {
                if !accumulatedText.isEmpty { accumulatedText += "\n\n" }
                accumulatedText += currentRoundText
                assistantMessage.textContent = accumulatedText
            }

            // Execute tools and continue loop, or stop
            if stopReason == "tool_use" && !pendingTools.isEmpty {
                let sorted = pendingTools.sorted { $0.key < $1.key }.map { $0.value }

                var assistantObjects: [MessageParameter.Message.Content.ContentObject] = []
                if !currentRoundText.isEmpty {
                    assistantObjects.append(.text(currentRoundText))
                }
                var toolResultObjects: [MessageParameter.Message.Content.ContentObject] = []

                for pending in sorted {
                    let input = pending.parsedInput
                    assistantObjects.append(.toolUse(pending.id, pending.name, input))

                    let record = makeToolCallRecord(
                        toolUseId: pending.id,
                        toolName: pending.name,
                        input: input,
                        message: assistantMessage
                    )
                    modelContext.insert(record)
                    try? modelContext.save()

                    let result = await executeTool(
                        name: pending.name,
                        input: input,
                        settings: settings,
                        sessionId: session.sessionId
                    )
                    record.terminalOutput = result
                    record.status = .success
                    record.endTime = Date()
                    try? modelContext.save()

                    toolResultObjects.append(.toolResult(pending.id, result))
                }

                loopMessages.append(MessageParameter.Message(role: .assistant, content: .list(assistantObjects)))
                loopMessages.append(MessageParameter.Message(role: .user, content: .list(toolResultObjects)))
            } else {
                continueLoop = false
            }
        }
    }

    // MARK: - Tool List Builder

    func buildTools(modelId: String, settings: AppSettings) -> [MessageParameter.Tool] {
        var tools: [MessageParameter.Tool] = []

        if settings.enableTextEditorTool {
            let isClaude3 = modelId.contains("3-") || modelId.contains("3.")
            let type = isClaude3 ? "text_editor_20250124" : "text_editor_20250728"
            let name = isClaude3 ? "str_replace_editor" : "str_replace_based_edit_tool"
            tools.append(.hosted(type: type, name: name))
        }

        if settings.enableBashTool {
            tools.append(.hosted(type: "bash_20250124", name: "bash"))
        }

        return tools
    }
}

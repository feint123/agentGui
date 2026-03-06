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

// MARK: - Pending Thinking Block

struct PendingThinking {
    var content: String = ""
    var signature: String? = nil
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
        var roundIndex = 0

        while continueLoop {
            let useThinking = settings.enableExtendedThinking && isThinkingCapable(modelId: modelId)
            let budget = settings.extendedThinkingBudget
            // thinking budget must be < maxTokens; give at least 4096 for response
            let maxTokens = useThinking ? max(budget + 4096, 16000) : 8192

            let params = MessageParameter(
                model: .other(modelId),
                messages: loopMessages,
                maxTokens: maxTokens,
                tools: tools.isEmpty ? nil : tools,
                thinking: useThinking ? .init(budgetTokens: budget) : nil
            )
            let stream = try await service.streamMessage(params)

            // Create a round record for this iteration
            let round = AgentRound(roundIndex: roundIndex, message: assistantMessage)
            modelContext.insert(round)
            try? modelContext.save()
            roundIndex += 1

            var currentRoundText = ""
            var currentRoundThinking = PendingThinking()
            var pendingTools: [Int: PendingToolUse] = [:]
            var currentBlockIndex: Int? = nil
            var stopReason: String? = nil

            for try await event in stream {
                // content_block_start — register new block
                if let block = event.contentBlock {
                    if block.type == "tool_use", let id = block.id, let name = block.name {
                        let idx = event.index ?? pendingTools.count
                        pendingTools[idx] = PendingToolUse(id: id, name: name)
                        currentBlockIndex = idx
                    } else {
                        currentBlockIndex = nil
                    }
                }

                // content_block_delta — accumulate text / thinking / partial JSON
                if let delta = event.delta {
                    switch delta.type {
                    case "text_delta":
                        if let text = delta.text {
                            currentRoundText += text
                            round.text = currentRoundText
                            let joined = accumulatedText.isEmpty
                                ? currentRoundText
                                : accumulatedText + "\n\n" + currentRoundText
                            assistantMessage.textContent = joined
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
                        // legacy text delta (non-streaming thinking models)
                        if let text = delta.text {
                            currentRoundText += text
                            round.text = currentRoundText
                            let joined = accumulatedText.isEmpty
                                ? currentRoundText
                                : accumulatedText + "\n\n" + currentRoundText
                            assistantMessage.textContent = joined
                        }
                        if let json = delta.partialJson, let idx = currentBlockIndex {
                            pendingTools[idx]?.partialJson += json
                        }
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
                round.text = currentRoundText
            }
            try? modelContext.save()

            // Build assistant content objects for this round (for next API call)
            var assistantObjects: [MessageParameter.Message.Content.ContentObject] = []

            // Include thinking blocks from this round (required for multi-turn)
            if useThinking && !currentRoundThinking.content.isEmpty,
               let sig = currentRoundThinking.signature {
                assistantObjects.append(.thinking(currentRoundThinking.content, sig))
            }

            // Execute tools and continue loop, or stop
            if stopReason == "tool_use" && !pendingTools.isEmpty {
                let sorted = pendingTools.sorted { $0.key < $1.key }.map { $0.value }

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
                        message: assistantMessage,
                        agentRound: round
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

    // MARK: - Helpers

    /// Returns true if the model supports Extended Thinking (3.7 Sonnet and all later models)
    private func isThinkingCapable(modelId: String) -> Bool {
        // Claude 3.7+ and all Claude 4 series support Extended Thinking
        let thinkingModels = ["claude-3-7", "claude-3.7", "claude-opus-4", "claude-sonnet-4", "claude-haiku-4"]
        return thinkingModels.contains { modelId.contains($0) }
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

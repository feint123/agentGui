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

    // MARK: Public Entry Point

    func runAgenticLoop(
        apiMessages: [MessageParameter.Message],
        assistantMessage: Message,
        service: any AnthropicService,
        modelId: String,
        tools: [MessageParameter.Tool],
        systemPrompt: String = "",
        session: Session,
        settings: AppSettings,
        modelContext: ModelContext,
        maxRounds: Int = 16
    ) async throws {
        var loopMessages = apiMessages
        let system: MessageParameter.System? = systemPrompt.isEmpty ? nil : .text(systemPrompt)
        try await runCoreAgentLoop(
            messages: &loopMessages,
            service: service,
            modelId: modelId,
            tools: tools,
            system: system,
            settings: settings,
            sessionId: session.sessionId,
            modelContext: modelContext,
            maxRounds: maxRounds,
            makeRound: { AgentRound(roundIndex: $0, message: assistantMessage) },
            parentMessage: assistantMessage,
            onTextAccumulated: { assistantMessage.textContent = $0 }
        )
        try? modelContext.save()
    }

    // MARK: - Core Loop

    /// Shared agentic loop used by both the main agent and sub-agents.
    ///
    /// Callers parameterise per-call behaviour via:
    /// - `makeRound`: constructs the `AgentRound` for each iteration; the main agent
    ///   attaches it to a `Message`, sub-agents attach it to a `ToolCall`.
    /// - `parentMessage`: the `Message` to update on error/truncation; `nil` for
    ///   sub-agents (they use the return value instead).
    /// - `onTextAccumulated`: called each text delta with the full accumulated text,
    ///   driving real-time UI for the main agent; sub-agents pass `{ _ in }`.
    ///
    /// Returns the full accumulated text produced across all rounds.
    @discardableResult
    func runCoreAgentLoop(
        messages: inout [MessageParameter.Message],
        service: any AnthropicService,
        modelId: String,
        tools: [MessageParameter.Tool],
        system: MessageParameter.System?,
        settings: AppSettings,
        sessionId: String,
        modelContext: ModelContext,
        maxRounds: Int,
        makeRound: (Int) -> AgentRound,
        parentMessage: Message?,
        onTextAccumulated: (String) -> Void
    ) async throws -> String {
        var accumulatedText = ""
        var loopCtx = AgentLoopContext(phase: .executing)
        var loopMemory = ContextMemory()

        while loopCtx.shouldContinue && loopCtx.roundIndex < maxRounds {
            try Task.checkCancellation()
            print("[\(loopCtx.phase)] Starting round \(loopCtx.roundIndex) with \(messages.count) messages")

            await compressIfNeeded(
                messages: &messages,
                memory: &loopMemory,
                service: service,
                modelId: modelId
            )

            currentModelId = modelId
            let useThinking = settings.enableExtendedThinking && isThinkingCapable(modelId: modelId)
            let budget = settings.extendedThinkingBudget
            // thinking budget must be < maxTokens; give at least 4096 for response
            let maxTokens = useThinking ? max(budget + 4096, 16000) : 8192
            print("Using model \(modelId) with maxTokens \(maxTokens)")

            let params = MessageParameter(
                model: .other(modelId),
                messages: messages,
                maxTokens: maxTokens,
                system: system,
                tools: tools.isEmpty ? nil : tools,
                thinking: useThinking ? .init(budgetTokens: budget) : nil
            )
            print("Sending message with \(params.messages.count) messages, system: \(system == nil ? "none" : "present")")

            // Count input tokens before streaming (reliable: countTokens API always returns input_tokens)
            if let tokenCount = try? await service.countTokens(
                parameter: MessageTokenCountParameter(
                    model: .other(modelId),
                    messages: messages,
                    system: system,
                    tools: tools.isEmpty ? nil : tools
                )
            ) {
                currentInputTokens = tokenCount.inputTokens
                print("Input tokens: \(tokenCount.inputTokens) (\(Int(contextUsageRatio * 100))%)")
            }

            let stream = try await service.streamMessage(params)
            let roundIdx = loopCtx.nextRound()
            print("Received stream for round \(roundIdx)")

            let round = makeRound(roundIdx)
            modelContext.insert(round)
            try? modelContext.save()

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
                            onTextAccumulated(joined)
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
                            onTextAccumulated(joined)
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
                onTextAccumulated(accumulatedText)
                round.text = currentRoundText
            }

            // Build assistant content objects for this round (for next API call)
            var assistantObjects: [MessageParameter.Message.Content.ContentObject] = []

            // Include thinking blocks from this round (required for multi-turn)
            if useThinking && !currentRoundThinking.content.isEmpty,
               let sig = currentRoundThinking.signature {
                assistantObjects.append(.thinking(currentRoundThinking.content, sig))
            }
            // Persist stop reason on this round
            round.stopReason = stopReason
            try? modelContext.save()

            // Drive state machine transition based on stop_reason
            loopCtx.transition(stopReason: stopReason)
            print("[\(loopCtx.phase)] stop_reason=\(stopReason ?? "nil") after round \(roundIdx)")

            switch loopCtx.phase {

            case .awaitingToolResults:
                // Execute all pending tools and feed results back
                guard !pendingTools.isEmpty else {
                    // tool_use stop reason but no tools parsed — treat as error
                    loopCtx.phase = .failed
                    loopCtx.terminationReason = "stop_reason=tool_use but no tool blocks parsed"
                    break
                }
                let sorted = pendingTools.sorted { $0.key < $1.key }.map { $0.value }
                if !currentRoundText.isEmpty { assistantObjects.append(.text(currentRoundText)) }
                var toolResultObjects: [MessageParameter.Message.Content.ContentObject] = []

                for pending in sorted {
                    print("Executing tool \(pending.name) with input: \(pending.partialJson)")
                    let input = pending.parsedInput
                    assistantObjects.append(.toolUse(pending.id, pending.name, input))

                    let record = makeToolCallRecord(
                        toolUseId: pending.id,
                        toolName: pending.name,
                        input: input,
                        message: parentMessage,
                        agentRound: round
                    )
                    modelContext.insert(record)
                    try? modelContext.save()

                    let result: ToolExecutionResult
                    if pending.name == "run_subagent" {
                        result = ToolExecutionResult(await executeRunSubagentTool(
                            input: input,
                            toolCallRecord: record,
                            service: service,
                            modelId: modelId,
                            settings: settings,
                            sessionId: sessionId,
                            modelContext: modelContext
                        ))
                    } else {
                        result = await executeTool(
                            name: pending.name,
                            input: input,
                            settings: settings,
                            sessionId: sessionId
                        )
                    }
                    record.terminalOutput = result.text
                    record.status = result.toolCallStatus
                    record.endTime = Date()
                    try? modelContext.save()

                    toolResultObjects.append(.toolResult(pending.id, result.text, isError: result.isError ? true : nil))
                    toolResultObjects.append(contentsOf: result.mediaContent)
                }

                messages.append(.init(role: .assistant, content: .list(assistantObjects)))
                messages.append(.init(role: .user, content: .list(toolResultObjects)))
                loopCtx.toolResultsAppended()

            case .continuingTruncatedResponse:
                // Model hit token limit; inject a continuation turn without replanning
                print("max_tokens at round \(roundIdx) — injecting continuation turn")
                if !currentRoundText.isEmpty { assistantObjects.append(.text(currentRoundText)) }
                if !assistantObjects.isEmpty {
                    messages.append(.init(role: .assistant, content: .list(assistantObjects)))
                }
                messages.append(.init(
                    role: .user,
                    content: .text("Please continue your previous response exactly where you left off. Do not repeat what you already wrote and do not re-plan — just continue.")
                ))
                loopCtx.continuationInjected()

            case .resumingAfterPause:
                // Server-side sampling pause; resume by feeding partial response back
                print("pause_turn at round \(roundIdx) — resuming server-side sampling")
                if !currentRoundText.isEmpty { assistantObjects.append(.text(currentRoundText)) }
                if !assistantObjects.isEmpty {
                    messages.append(.init(role: .assistant, content: .list(assistantObjects)))
                }
                messages.append(.init(role: .user, content: .text("Continue.")))
                loopCtx.continuationInjected()

            case .finalizing:
                // Normal end_turn — loop exits on next iteration check
                break

            case .failed:
                let reason = loopCtx.terminationReason ?? "stop_reason=\(stopReason ?? "nil")"
                print("Agent loop failed: \(reason)")
                let errorNote = "\n\n⚠️ Agent loop ended unexpectedly (\(reason))."
                accumulatedText += errorNote
                parentMessage?.textContent = (parentMessage?.textContent ?? "") + errorNote

            default:
                break
            }
        }

        // Safety: loop exited because maxRounds was reached (not a natural stop)
        if loopCtx.roundIndex >= maxRounds && loopCtx.shouldContinue {
            print("Agent loop reached maxRounds (\(maxRounds)), terminating")
            let notice = "\n\n⚠️ Agent loop stopped after reaching the maximum of \(maxRounds) rounds."
            accumulatedText += notice
            parentMessage?.textContent = (parentMessage?.textContent ?? "") + notice
        }

        return accumulatedText
    }

    // MARK: - Helpers

    /// Returns true if the model supports Extended Thinking (3.7 Sonnet and all later models)
    func isThinkingCapable(modelId: String) -> Bool {
        // Claude 3.7+ and all Claude 4 series support Extended Thinking
        let thinkingModels = ["claude-3-7", "claude-3.7", "claude-opus-4", "claude-sonnet-4", "claude-haiku-4"]
        return thinkingModels.contains { modelId.contains($0) }
    }

}

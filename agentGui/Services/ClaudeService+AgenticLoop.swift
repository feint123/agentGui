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
        systemPrompt: String = "",
        session: Session,
        settings: AppSettings,
        modelContext: ModelContext,
        maxRounds: Int = 16
    ) async throws {
        var loopMessages = apiMessages
        var accumulatedText = ""
        var continueLoop = true
        var roundIndex = 0

        while continueLoop && roundIndex < maxRounds {
            try Task.checkCancellation()
            print("Starting agentic loop iteration \(roundIndex) with \(loopMessages.count) messages")

            // Context compression: compress if usage exceeds threshold
            await compressIfNeeded(
                messages: &loopMessages,
                service: service,
                modelId: modelId
            )

            currentModelId = modelId
            let useThinking = settings.enableExtendedThinking && isThinkingCapable(modelId: modelId)
            let budget = settings.extendedThinkingBudget
            // thinking budget must be < maxTokens; give at least 4096 for response
            let maxTokens = useThinking ? max(budget + 4096, 16000) : 8192
            print("Using model \(modelId) with maxTokens \(maxTokens)")
            let systemValue: MessageParameter.System? = systemPrompt.isEmpty ? nil : .text(systemPrompt)
            let params = MessageParameter(
                model: .other(modelId),
                messages: loopMessages,
                maxTokens: maxTokens,
                system: systemValue,
                tools: tools.isEmpty ? nil : tools,
                thinking: useThinking ? .init(budgetTokens: budget) : nil
            )
            print("Sending message with \(params.messages.count) messages, system prompt: \(systemPrompt.isEmpty ? "none" : "present")")

            // Count input tokens before streaming (reliable: countTokens API always returns input_tokens)
            if let tokenCount = try? await service.countTokens(
                parameter: MessageTokenCountParameter(
                    model: .other(modelId),
                    messages: loopMessages,
                    system: systemValue,
                    tools: tools.isEmpty ? nil : tools
                )
            ) {
                currentInputTokens = tokenCount.inputTokens
                print("Input tokens: \(tokenCount.inputTokens) (\(Int(contextUsageRatio * 100))%)")
            }

            let stream = try await service.streamMessage(params)
            print("Received stream for loop iteration \(roundIndex)")
            // Create a round record for this iteration
            let round = AgentRound(roundIndex: roundIndex, message: assistantMessage)
            modelContext.insert(round)
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

            // Build assistant content objects for this round (for next API call)
            var assistantObjects: [MessageParameter.Message.Content.ContentObject] = []

            // Include thinking blocks from this round (required for multi-turn)
            if useThinking && !currentRoundThinking.content.isEmpty,
               let sig = currentRoundThinking.signature {
                assistantObjects.append(.thinking(currentRoundThinking.content, sig))
            }
            print("Assistant objects for this round: \(assistantObjects)")
            // Persist stop reason on this round
            round.stopReason = stopReason

            // Execute tools and continue loop, or stop
            if stopReason == "tool_use" && !pendingTools.isEmpty {
                print("Processing tool uses for loop iteration \(roundIndex)")
                let sorted = pendingTools.sorted { $0.key < $1.key }.map { $0.value }

                if !currentRoundText.isEmpty {
                    assistantObjects.append(.text(currentRoundText))
                }
                var toolResultObjects: [MessageParameter.Message.Content.ContentObject] = []

                for pending in sorted {
                    print("Executing tool \(pending.name) with input: \(pending.partialJson)")
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

                    let result: ToolExecutionResult
                    if pending.name == "run_subagent" {
                        result = ToolExecutionResult(await executeRunSubagentTool(
                            input: input,
                            toolCallRecord: record,
                            service: service,
                            modelId: modelId,
                            settings: settings,
                            sessionId: session.sessionId,
                            modelContext: modelContext
                        ))
                    } else {
                        result = await executeTool(
                            name: pending.name,
                            input: input,
                            settings: settings,
                            session: session
                        )
                    }
                    record.terminalOutput = result.text
                    record.status = .success
                    record.endTime = Date()

                    toolResultObjects.append(.toolResult(pending.id, result.text))
                    toolResultObjects.append(contentsOf: result.mediaContent)
                }

                loopMessages.append(MessageParameter.Message(role: .assistant, content: .list(assistantObjects)))
                loopMessages.append(MessageParameter.Message(role: .user, content: .list(toolResultObjects)))

            } else if stopReason == "end_turn" {
                // Normal completion
                continueLoop = false

            } else if stopReason == "max_tokens" {
                // Model hit token limit mid-response; ask it to continue without replanning
                print("max_tokens reached at round \(roundIndex - 1), appending continuation turn")
                if !currentRoundText.isEmpty { assistantObjects.append(.text(currentRoundText)) }
                if !assistantObjects.isEmpty {
                    loopMessages.append(MessageParameter.Message(role: .assistant, content: .list(assistantObjects)))
                }
                loopMessages.append(MessageParameter.Message(
                    role: .user,
                    content: .text("Please continue your previous response exactly where you left off. Do not repeat what you already wrote and do not re-plan — just continue.")
                ))

            } else if stopReason == "pause_turn" {
                // Server-side sampling pause; resume by feeding the partial response back
                print("pause_turn at round \(roundIndex - 1), resuming server-side sampling")
                if !currentRoundText.isEmpty { assistantObjects.append(.text(currentRoundText)) }
                if !assistantObjects.isEmpty {
                    loopMessages.append(MessageParameter.Message(role: .assistant, content: .list(assistantObjects)))
                }
                // No explicit user message; append a minimal turn to maintain role alternation
                loopMessages.append(MessageParameter.Message(
                    role: .user,
                    content: .text("Continue.")
                ))

            } else {
                // nil or unknown stop reason — treat as abnormal termination
                let reason = stopReason ?? "nil"
                print("Unexpected stop reason '\(reason)' at round \(roundIndex - 1), terminating loop")
                let errorNote = "\n\n⚠️ Agent loop ended unexpectedly (stop_reason: \(reason))."
                assistantMessage.textContent = (assistantMessage.textContent ?? "") + errorNote
                continueLoop = false
            }
        }

        // Safety: loop exited because maxRounds was reached (not a natural stop)
        if roundIndex >= maxRounds && continueLoop {
            print("Agent loop reached maxRounds (\(maxRounds)), terminating")
            let notice = "\n\n⚠️ Agent loop stopped after reaching the maximum of \(maxRounds) rounds."
            assistantMessage.textContent = (assistantMessage.textContent ?? "") + notice
        }

        try? modelContext.save()
    }

    // MARK: - Helpers

    /// Returns true if the model supports Extended Thinking (3.7 Sonnet and all later models)
    func isThinkingCapable(modelId: String) -> Bool {
        // Claude 3.7+ and all Claude 4 series support Extended Thinking
        let thinkingModels = ["claude-3-7", "claude-3.7", "claude-opus-4", "claude-sonnet-4", "claude-haiku-4"]
        return thinkingModels.contains { modelId.contains($0) }
    }

    // MARK: - Tool List Builder

    func buildTools(modelId: String, settings: AppSettings, enabledSkills: [Skill] = [], isSubagent: Bool = false) -> [MessageParameter.Tool] {
        var tools: [MessageParameter.Tool] = []

        if settings.enableTextEditorTool {
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

        if settings.enableBashTool {
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

        if !enabledSkills.isEmpty {
            tools.append(.function(
                name: "read_skill",
                description: "Load the full instructions of a skill by name. Use when the user's request matches a skill's purpose.",
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "name": .init(
                            type: .string,
                            description: "The skill name, e.g. 'brainstorming'"
                        )
                    ],
                    required: ["name"]
                )
            ))
        }

        // run_subagent: only available to the main agent (not inside subagent loops)
        if !isSubagent {
            let agentList = SubagentDefinition.all
                .map { "- \($0.name) (\($0.displayName)): \($0.description)" }
                .joined(separator: "\n")
            tools.append(.function(
                name: "run_subagent",
                description: """
                Delegate a focused task to a specialized built-in subagent. The subagent runs \
                its own agentic loop with the appropriate tools and returns a result string.

                WHEN TO USE:
                - Research, exploration, or report writing → use "explorer" to gather information first
                - Writing or modifying code → use "coder"
                - Reviewing code quality or security → use "reviewer"
                - Running shell/build/test commands → use "executor"
                - Summarizing a document → use "summarizer"

                Available agents:
                \(agentList)

                The task string must be self-contained: include all context the subagent needs \
                (file paths, goals, constraints, relevant background). The subagent cannot ask \
                follow-up questions.
                """,
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "agent_name": .init(
                            type: .string,
                            description: "Identifier of the subagent to use. One of: \(SubagentDefinition.all.map(\.name).joined(separator: " | "))"
                        ),
                        "task": .init(
                            type: .string,
                            description: "Detailed, self-contained task description for the subagent."
                        )
                    ],
                    required: ["agent_name", "task"]
                )
            ))
        }

        // update_todo_list: available to all agents (main and subagent)
        tools.append(.function(
            name: "update_todo_list",
            description: """
            Update the current task list shown in the workspace panel. \
            Use this to track progress on complex, multi-step tasks. \
            Each call REPLACES the entire todo list for the current session. \
            Call early to lay out planned steps, and update status as tasks progress.

            Statuses:
            - pending: not yet started
            - in_progress: currently working on it (at most one at a time)
            - done: completed successfully
            - cancelled: skipped or no longer needed
            """,
            inputSchema: .init(
                type: .object,
                properties: [
                    "items": .init(
                        type: .array,
                        description: #"Full list of todo items. Each item: { "id": string, "title": string, "status": "pending"|"in_progress"|"done"|"cancelled", "notes": string (optional) }"#
                    )
                ],
                required: ["items"]
            )
        ))

        // ask_user_question is always available to the main agent only
        tools.append(.function(
            name: "ask_user_question",
            description: """
            Ask the user one or more questions with structured multiple-choice options. \
            Execution pauses until the user submits answers. \
            Use this when you need clarification or a decision before proceeding.

            Each element in `questions` must follow this exact shape:
            {
              "question":   string  — the question sentence shown to the user,
              "header":     string  — short section label displayed above the question (e.g. "Language", "Confirm"),
              "options":    array of { "label": string, "description": string } — the selectable choices,
              "multiSelect": bool  — true to allow multiple selections, false for single choice
            }

            Example call:
            {
              "questions": [
                {
                  "question": "Which programming language should I use?",
                  "header": "Language",
                  "options": [
                    { "label": "Swift",  "description": "Apple platforms, type-safe" },
                    { "label": "Python", "description": "Scripting, data science" },
                    { "label": "Rust",   "description": "Systems, performance" }
                  ],
                  "multiSelect": false
                }
              ]
            }

            The tool returns JSON:
            {
              "answers": [
                { "question": "...", "header": "...", "selected": ["Swift"] }
              ]
            }
            If the user cancels, "selected" will be an empty array [].
            """,
            inputSchema: .init(
                type: .object,
                properties: [
                    "questions": .init(
                        type: .array,
                        description: "Array of question objects. Each must have: question (string), header (string), options (array of {label, description}), multiSelect (bool)."
                    )
                ],
                required: ["questions"]
            )
        ))

        tools.append(.function(
            name: "analyze_image",
            description: """
            Load a local image file and analyze its visual content. \
            Provides the image directly to Claude's vision capabilities. \
            Supports png, jpg, jpeg, gif, webp (max 20 MB). \
            Use this when the user references an image file or you need to understand visual content.
            """,
            inputSchema: .init(
                type: .object,
                properties: [
                    "file_path": .init(type: .string, description: "Absolute path to the image file")
                ],
                required: ["file_path"]
            )
        ))

        tools.append(.function(
            name: "read_pdf",
            description: """
            Extract all text content from a local PDF file using PDFKit. \
            Returns the text page-by-page so you can read, summarize, or answer questions about it. \
            For scanned PDFs without selectable text, use bash with pdftotext or similar. \
            Max 50 MB.
            """,
            inputSchema: .init(
                type: .object,
                properties: [
                    "file_path": .init(type: .string, description: "Absolute path to the PDF file")
                ],
                required: ["file_path"]
            )
        ))

        // memory_write: always available — lets Claude persist facts across sessions
        tools.append(.function(
            name: "memory_write",
            description: """
            Update the long-term memory file (~/.agentgui/memory.md). \
            Memory is injected into the system prompt at the start of every conversation, \
            so anything stored here will be available in future sessions. \
            Use 'overwrite' to replace the full content, 'append' to add new facts at the end. \
            Keep entries concise. Write important facts, preferences, or context the user wants you to remember.
            """,
            inputSchema: .init(
                type: .object,
                properties: [
                    "content": .init(type: .string, description: "The text to write into memory.md"),
                    "mode": .init(type: .string, description: "'overwrite' to replace all content, 'append' to add to the end (default: append)")
                ],
                required: ["content"]
            )
        ))

        return tools
    }
}



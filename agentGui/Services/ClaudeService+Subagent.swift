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

    /// 子代理的嵌套 agentic loop — 通过 runCoreAgentLoop 复用主代理的核心流程
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
        var loopMessages: [MessageParameter.Message] = [.init(role: .user, content: .text(task))]
        let system: MessageParameter.System? = definition.systemPrompt.isEmpty
            ? nil
            : .text(definition.systemPrompt)
        let result = try await runCoreAgentLoop(
            messages: &loopMessages,
            service: service,
            modelId: modelId,
            tools: buildSubagentTools(modelId: modelId, definition: definition, settings: settings),
            system: system,
            settings: settings,
            sessionId: sessionId,
            modelContext: modelContext,
            maxRounds: definition.maxRounds,
            makeRound: { idx in
                let round = AgentRound(roundIndex: idx)
                round.subagentToolCall = toolCallRecord
                return round
            },
            parentMessage: nil,
            onTextAccumulated: { _ in }
        )
        return result.isEmpty ? "(subagent produced no output)" : result
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

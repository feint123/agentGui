//
//  ClaudeService+ToolBuilder.swift
//  agentGui
//

import Foundation
import SwiftAnthropic

// MARK: - Workflow Registry

extension ClaudeService {

    /// All registered workflow definitions, used to populate the start_workflow tool.
    static let availableWorkflows: [(id: String, displayName: String, description: String)] = [
        (
            id: "code_change",
            displayName: "代码变更流程",
            description: "多代理协作完成代码修改：规划 → 探索 → 编码 → 审查 → 验证。适用于需要跨文件实现、大型重构、或需要多轮计划-探索-编码-审查循环的复杂任务。"
        ),
    ]

    /// Returns the `WorkflowDefinition` for the given workflow id, or nil if unknown.
    static func makeWorkflowDefinition(id: String) -> (any WorkflowDefinition)? {
        switch id {
        case "code_change": return CodeChangeWorkflow()
        default:            return nil
        }
    }
}

// MARK: - Tool List Builder

extension ClaudeService {

    func buildTools(modelId: String, settings: AppSettings, enabledSkills: [Skill] = [], isSubagent: Bool = false) -> [MessageParameter.Tool] {
        var tools: [MessageParameter.Tool] = []
        let registry = DefaultToolRegistry()

        if settings.enableTextEditorTool,
           let definition = registry.definition(for: "str_replace_based_edit_tool") {
            tools.append(definition.makeAnthropicTool())
        }

        if settings.enableBashTool,
           let definition = registry.definition(for: "bash") {
            tools.append(definition.makeAnthropicTool())
        }

        if let definition = registry.definition(for: "read_tool_payload") {
            tools.append(definition.makeAnthropicTool())
        }

        if settings.enableWebSearchTool,
           let definition = registry.definition(for: "web_search") {
            tools.append(definition.makeAnthropicTool())
        }

        if settings.enableWebFetchTool,
           let definition = registry.definition(for: "web_fetch") {
            tools.append(definition.makeAnthropicTool())
        }

        if settings.enableLSPTools {
            let lspToolIDs = [
                "lsp_definition",
                "lsp_references",
                "lsp_hover",
                "lsp_document_symbols",
                "lsp_workspace_symbols",
                "lsp_diagnostics",
                "lsp_list_servers",
                "lsp_server_status"
            ]
            for toolID in lspToolIDs {
                if let definition = registry.definition(for: toolID) {
                    tools.append(definition.makeAnthropicTool())
                }
            }
        }

        if !enabledSkills.isEmpty {
            tools.append(makeEphemeralTool(
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
            let context = ToolDefinitionBuildContext.default
            if let definition = registry.definition(for: "run_subagent") {
                tools.append(definition.makeAnthropicTool(context: context))
            }

            // start_workflow: launches a multi-agent workflow (main agent only)
            if let definition = registry.definition(for: "start_workflow") {
                tools.append(definition.makeAnthropicTool(context: context))
            }
        }

        // update_todo_list: available to all agents (main and subagent)
        tools.append(makeEphemeralTool(
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

        // create_execution_plan: records a structured plan before tackling complex tasks
        tools.append(makeEphemeralTool(
            name: "create_execution_plan",
            description: """
            Record a structured execution plan before starting a complex task. \
            Use this when a task requires 3+ distinct steps, touches multiple files or systems, \
            or involves research followed by implementation. \
            The plan is shown in the workspace panel and helps verify completion afterwards.
            """,
            inputSchema: .init(
                type: .object,
                properties: [
                    "goal": .init(type: .string, description: "One-sentence description of what needs to be achieved"),
                    "steps": .init(
                        type: .array,
                        description: #"Ordered list of steps. Each: { "id": string, "title": string } — title must be verb-first and specific"#
                    ),
                    "assumptions": .init(type: .array, description: "Optional list of assumptions, risks, or open questions (strings)"),
                    "success_criteria": .init(type: .array, description: "Optional list of objectively checkable success criteria (strings)")
                ],
                required: ["goal", "steps"]
            )
        ))

        // verify_completion: explicitly states what was and wasn't verified before finishing
        tools.append(makeEphemeralTool(
            name: "verify_completion",
            description: """
            Optionally record explicit completion claims for the host verify state to inspect. \
            Use this when you want to preserve a structured list of what was actually verified, what remains unverified, and the overall conclusion. \
            Do not claim tests or execution results unless they were actually observed.
            """,
            inputSchema: .init(
                type: .object,
                properties: [
                    "verified": .init(type: .array, description: "List of things that were confirmed to work (strings)"),
                    "not_verified": .init(type: .array, description: "List of things that were NOT verified and why (strings)"),
                    "conclusion": .init(type: .string, description: "Optional one-sentence overall verdict")
                ],
                required: ["verified", "not_verified"]
            )
        ))

        // ask_user_question is always available to the main agent only
        tools.append(makeEphemeralTool(
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

        tools.append(makeEphemeralTool(
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

        tools.append(makeEphemeralTool(
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

        // memory_write: always available — lets Claude persist governed long-term facts across sessions
        tools.append(makeEphemeralTool(
            name: "memory_write",
            description: """
            Persist important long-term RMS insights into the unified memory store for future task decisions. \
            Use this for durable constraints, remembered failure modes, and reusable tactics that should affect later action selection. \
            Keep entries concise, factual, and decision-relevant.
            """,
            inputSchema: .init(
                type: .object,
                properties: [
                    "content": .init(type: .string, description: "Concise decision-relevant insight content to persist into RMS long-term memory"),
                    "mode": .init(type: .string, description: "Optional write mode hint. Accepted values: 'overwrite' or 'append'.")
                ],
                required: ["content"]
            )
        ))

        return tools
    }
}

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

                For commands that run indefinitely (servers, watchers, build monitors), set \
                background: true. The process is forked to the background immediately and a \
                log file path is returned — use `cat <logpath>` or `tail -n 50 <logpath>` in \
                a subsequent bash call to inspect output. The log file persists until the \
                session ends or you delete it.

                Use timeout to limit how long to wait for a foreground command (default 300s). \
                If a command exceeds timeout, partial output is returned and the session restarts.
                """,
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "command": .init(type: .string, description: "The bash command to execute"),
                        "restart": .init(type: .boolean, description: "If true, restart the bash session and ignore command"),
                        "timeout": .init(type: .integer, description: "Max seconds to wait for the command to finish (default 300). Ignored when background is true."),
                        "background": .init(type: .boolean, description: "If true, run the command in the background immediately and return PID + log file path. Use for servers/watchers that never exit.")
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
            let agentList = WorkflowRoleDefinition.all
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
                            description: "Identifier of the subagent to use. One of: \(WorkflowRoleDefinition.all.map(\.name).joined(separator: " | "))"
                        ),
                        "task": .init(
                            type: .string,
                            description: "Detailed, self-contained task description for the subagent."
                        )
                    ],
                    required: ["agent_name", "task"]
                )
            ))

            // start_workflow: launches a multi-agent workflow (main agent only)
            let workflowList = ClaudeService.availableWorkflows
                .map { "- \($0.id): \($0.description)" }
                .joined(separator: "\n")
            tools.append(.function(
                name: "start_workflow",
                description: """
                Launch a multi-agent workflow for tasks that require sustained collaboration \
                between specialized agents (planner → explorer → coder → reviewer → executor).

                USE start_workflow WHEN the task:
                - Requires implementing or refactoring code across multiple files
                - Needs a plan-explore-code-review-verify pipeline
                - Is complex enough that a single agent loop would be insufficient

                DO NOT use start_workflow for:
                - Simple Q&A, single-file edits, or quick lookups
                - Tasks that can be completed in a few tool calls
                - Anything already handled well by run_subagent

                The workflow runs synchronously and returns a summary when complete. \
                The task must be self-contained: include file paths, goals, and any constraints.

                Available workflows:
                \(workflowList)
                """,
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "workflow_id": .init(
                            type: .string,
                            description: "ID of the workflow to launch. One of: \(ClaudeService.availableWorkflows.map(\.id).joined(separator: " | "))"
                        ),
                        "task": .init(
                            type: .string,
                            description: "Self-contained task description including all context the workflow agents need."
                        )
                    ],
                    required: ["workflow_id", "task"]
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

        // create_execution_plan: records a structured plan before tackling complex tasks
        tools.append(.function(
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
        tools.append(.function(
            name: "verify_completion",
            description: """
            Record a completion verification just before finishing a task. \
            Explicitly state what was tested/confirmed and what was NOT verified. \
            Call this as the final tool before giving the summary response to the user.
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

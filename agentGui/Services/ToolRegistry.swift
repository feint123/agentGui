import Foundation
import SwiftAnthropic

protocol ToolRegistry {
    func definition(for id: String) -> ToolDefinition?
    func allDefinitions() -> [ToolDefinition]
}

struct DefaultToolRegistry: ToolRegistry {
    private let definitionsByID: [String: ToolDefinition]

    init() {
        let definitions = Self.makeDefinitions()
        self.definitionsByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
    }

    func definition(for id: String) -> ToolDefinition? {
        definitionsByID[id]
    }

    func allDefinitions() -> [ToolDefinition] {
        definitionsByID.values.sorted { $0.id < $1.id }
    }

    private static func makeDefinitions() -> [ToolDefinition] {
        [
            textEditorDefinition(),
            bashDefinition(),
            readToolPayloadDefinition(),
            webSearchDefinition(),
            webFetchDefinition(),
            lspDefinitionToolDefinition(),
            lspReferencesToolDefinition(),
            lspHoverToolDefinition(),
            lspDocumentSymbolsToolDefinition(),
            lspWorkspaceSymbolsToolDefinition(),
            lspDiagnosticsToolDefinition(),
            lspListServersToolDefinition(),
            lspServerStatusToolDefinition(),
            runSubagentDefinition(),
            readSkillDefinition(),
            skillInvokeDefinition(),
            updateTodoListDefinition(),
            createExecutionPlanDefinition(),
            verifyCompletionDefinition(),
            askUserQuestionDefinition(),
            analyzeImageDefinition(),
            readPdfDefinition(),
            memoryWriteDefinition()
        ]
    }

    private static func textEditorDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "str_replace_based_edit_tool",
            displayName: "文本编辑器",
            category: .editor,
            schemaVersion: 1,
            supportedContexts: [.mainAgent, .subagent, .backgroundTask],
            authorization: ToolAuthorizationDescriptor(
                requirements: [ToolCapabilityRequirement(capabilityID: .fileSystem, minimumLevel: .mutate)],
                riskTier: .high
            ),
            executorKey: "builtin.textEditor",
            descriptionBuilder: { _ in
                """
                A text editor for viewing and modifying files. Supported commands:
                - view: Read file contents, optionally with view_range [start, end] (1-based line numbers)
                - str_replace: Replace an exact string in a file: provide old_str and new_str
                - create: Create or overwrite a file with file_text
                - insert: Insert new_str after insert_line (0 = prepend)
                For large files, prefer reading targeted ranges first. If a result references a payload, use read_tool_payload instead of asking for the entire file again.
                Always use absolute file paths.
                """
            },
            inputSchemaBuilder: { _ in
                .init(
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
            }
        )
    }

    private static func bashDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "bash",
            displayName: "Bash",
            category: .shell,
            schemaVersion: 1,
            supportedContexts: [.mainAgent, .subagent, .backgroundTask],
            authorization: ToolAuthorizationDescriptor(
                requirements: [ToolCapabilityRequirement(capabilityID: .shell, minimumLevel: .execute)],
                riskTier: .high
            ),
            executorKey: "builtin.bash",
            descriptionBuilder: { _ in
                """
                Execute shell commands in a persistent PTY-backed bash session. \
                The session preserves working directory and environment variables across calls.

                Preferred PTY runtime contract:
                - `operation: "start"` with `command`, required unique `task_id`, and `execution_mode: attached|detached`
                - `operation: "send_input"` with `task_id` and `input`
                - `operation: "interrupt" | "terminate" | "status" | "read_output" | "cleanup"` with `task_id`
                - `force: true` upgrades terminate to a hard kill
                - `tail_lines` limits `read_output`

                Task ID rules:
                - Choose a unique task_id for every new start within the current session.
                - Reuse the same task_id with `status`, `read_output`, `send_input`, `interrupt`, `terminate`, and `cleanup`.
                - If a start fails because the task_id already exists, inspect it with `status` or `read_output`, then `cleanup` it before starting again with the same ID.
                - If you want a fresh command immediately, choose a different task_id instead of retrying start with the old one.

                For large command output, inspect summary and preview first. When a payload_ref is returned, use read_tool_payload to read further chunks instead of re-requesting the entire transcript.
                Use timeout to limit how long to wait for an attached command (default 300s).
                """
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "operation": .init(type: .string, description: "PTY runtime operation. One of: start, send_input, interrupt, terminate, status, read_output, cleanup."),
                        "command": .init(type: .string, description: "The bash command to execute"),
                        "task_id": .init(type: .string, description: "Managed terminal task ID. Required for every operation, and must be unique for each new start within the current session until cleaned up."),
                        "execution_mode": .init(type: .string, description: "Execution mode for start operations. One of: attached, detached."),
                        "input": .init(type: .string, description: "Text to send for send_input operations."),
                        "force": .init(type: .boolean, description: "When true, terminate uses a hard kill instead of a graceful stop."),
                        "tail_lines": .init(type: .integer, description: "Maximum transcript lines to return for read_output operations."),
                        "timeout": .init(type: .integer, description: "Max seconds to wait for the command to finish (default 300).")
                    ],
                    required: []
                )
            }
        )
    }

    private static func readToolPayloadDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "read_tool_payload",
            displayName: "Read Tool Payload",
            category: .system,
            schemaVersion: 1,
            supportedContexts: [.mainAgent, .subagent, .backgroundTask],
            isConcurrencySafe: true,
            executorKey: "builtin.readToolPayload",
            descriptionBuilder: { _ in
                """
                Read a large tool result incrementally using a payload_ref returned by another tool. \
                Prefer this over requesting the original tool to print the full result again. \
                Check summary, preview, and range_summary first, then read only the next relevant chunk. \
                When a previous read returns next_cursor, pass that cursor back directly; for chars or lines reads, cursor overrides start/end.
                """
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "payload_ref": .init(type: .string, description: "Payload reference returned by a previous tool result."),
                        "read_mode": .init(type: .string, description: "One of: summary, preview, chars, lines, chunk, head, tail."),
                        "start": .init(type: .integer, description: "Optional start offset or line number, depending on read_mode."),
                        "end": .init(type: .integer, description: "Optional end offset or line number, depending on read_mode."),
                        "cursor": .init(type: .string, description: "Optional cursor returned by a previous payload read. For chars, lines, or chunk reads, pass next_cursor back exactly as returned; when cursor is present it overrides start/end."),
                        "max_chars": .init(type: .integer, description: "Optional max characters to return for chunk or preview reads.")
                    ],
                    required: ["payload_ref"]
                )
            }
        )
    }

    private static func webSearchDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "web_search",
            displayName: "Web Search",
            category: .web,
            schemaVersion: 1,
            supportedContexts: [.mainAgent, .subagent, .backgroundTask],
            authorization: ToolAuthorizationDescriptor(
                requirements: [ToolCapabilityRequirement(capabilityID: .network, minimumLevel: .observe)],
                riskTier: .medium
            ),
            isConcurrencySafe: true,
            executorKey: "builtin.webSearch",
            descriptionBuilder: { _ in
                """
                Search the web using Bing and return a list of relevant results (title, URL, snippet). \
                Use when you need up-to-date information, facts, or references not in your training data. \
                For large result sets, inspect summary and preview first, then continue with read_tool_payload if a payload_ref is returned.
                """
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "query": .init(type: .string, description: "The search query string"),
                        "count": .init(type: .integer, description: "Number of results to return (1-10, default 5)")
                    ],
                    required: ["query"]
                )
            }
        )
    }

    private static func webFetchDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "web_fetch",
            displayName: "Web Fetch",
            category: .web,
            schemaVersion: 1,
            supportedContexts: [.mainAgent, .subagent, .backgroundTask],
            authorization: ToolAuthorizationDescriptor(
                requirements: [ToolCapabilityRequirement(capabilityID: .network, minimumLevel: .observe)],
                riskTier: .medium
            ),
            isConcurrencySafe: true,
            executorKey: "builtin.webFetch",
            descriptionBuilder: { _ in
                """
                Fetch a webpage and return its cleaned text content. \
                HTML boilerplate, scripts, styles, and navigation are stripped. \
                Use after web_search to read the full content of a specific page. \
                For long pages, prefer summary and preview first and use read_tool_payload when the result is returned as a payload reference.
                """
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "url": .init(type: .string, description: "The full URL to fetch (http or https)"),
                        "max_chars": .init(type: .integer, description: "Maximum characters to return (default 8000, max 32000)")
                    ],
                    required: ["url"]
                )
            }
        )
    }

    private static func runSubagentDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "run_subagent",
            displayName: "Run Subagent",
            category: .system,
            schemaVersion: 1,
            supportedContexts: [.mainAgent],
            executorKey: "builtin.runSubagent",
            descriptionBuilder: { context in
                """
                Delegate a focused task to a specialized built-in subagent. The subagent runs \
                its own agentic loop with the appropriate tools and returns a result string.

                WHEN TO USE:
                - Local codebase exploration: finding files by pattern, searching symbols, \
                understanding module structure, or answering "how does X work?" → use "explore"
                - External research: reports, comparisons, documentation lookup, current facts → use "explore"
                - Implementing or modifying files, with targeted verification when needed → use "worker"
                - Evidence review, ranking open risks, or final quality gate before finishing → use "verifier"

                When NOT to use:
                - Reading a single known file path — use str_replace_based_edit_tool (view) directly
                - Searching within 1–3 specific files — use bash (grep/find) directly
                - Simple single-step edits — implement directly without delegating

                Available agents:
                \(context.agentListText)

                The task string must be self-contained: include all context the subagent needs \
                (file paths, goals, constraints, relevant background, thoroughness level). \
                The subagent cannot ask follow-up questions.
                """
            },
            inputSchemaBuilder: { context in
                .init(
                    type: .object,
                    properties: [
                        "agent_name": .init(type: .string, description: "Identifier of the subagent to use. One of: \(context.agentNameListText). Omit to trigger an implicit fork: the child inherits the parent's full conversation context and runs the task as a background fork."),
                        "task": .init(type: .string, description: "Detailed, self-contained task description for the subagent."),
                        // S-A3: 可选模型 override，调用方可强制指定子代理使用的模型 ID
                        "model": .init(
                            type: .string,
                            description: """
                                Optional. Override the model used by this specific subagent invocation. \
                                When omitted, the agent uses its configured model-preference \
                                (or inherits the parent model). \
                                Example: "claude-haiku-4-5" for fast/low-cost tasks.
                                """
                        ),
                        // S-C2: 后台执行标志
                        "run_in_background": .init(
                            type: .boolean,
                            description: """
                                Optional. When true, the subagent runs asynchronously in the background. \
                                The tool call returns immediately with a launch receipt \
                                ({"status":"async_launched","agent_id":"...","poll_after":30}). \
                                Use poll_subagent(agent_id:) to check progress or wait for the \
                                task-notification system message. \
                                Default: false (synchronous, blocks until completion).
                                """
                        )
                    ],
                    required: ["task"]
                )
            }
        )
    }

    private static func lspDefinitionToolDefinition() -> ToolDefinition {
        lspLocationToolDefinition(
            id: "lsp_definition",
            displayName: "LSP Definition",
            executorKey: "lsp.definition",
            description: "Query an active language server for the definition location of a symbol at a given position."
        )
    }

    private static func lspReferencesToolDefinition() -> ToolDefinition {
        lspLocationToolDefinition(
            id: "lsp_references",
            displayName: "LSP References",
            executorKey: "lsp.references",
            description: "Query an active language server for symbol references at a given position."
        )
    }

    private static func lspHoverToolDefinition() -> ToolDefinition {
        lspLocationToolDefinition(
            id: "lsp_hover",
            displayName: "LSP Hover",
            executorKey: "lsp.hover",
            description: "Query hover information from an active language server at a given position."
        )
    }

    private static func lspDocumentSymbolsToolDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "lsp_document_symbols",
            displayName: "LSP Document Symbols",
            category: .system,
            schemaVersion: 1,
            supportedContexts: [.mainAgent, .subagent],
            isConcurrencySafe: true,
            executorKey: "lsp.documentSymbols",
            descriptionBuilder: { _ in
                "List document symbols from an active language server session for a file."
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "workspace_root": .init(type: .string, description: "Workspace root bound to the language server session."),
                        "server_id": .init(type: .string, description: "Language server profile ID."),
                        "uri": .init(type: .string, description: "Document URI, for example file:///repo/src/app.ts")
                    ],
                    required: ["workspace_root", "server_id", "uri"]
                )
            }
        )
    }

    private static func lspWorkspaceSymbolsToolDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "lsp_workspace_symbols",
            displayName: "LSP Workspace Symbols",
            category: .system,
            schemaVersion: 1,
            supportedContexts: [.mainAgent, .subagent],
            isConcurrencySafe: true,
            executorKey: "lsp.workspaceSymbols",
            descriptionBuilder: { _ in
                "Search workspace symbols using an active language server session."
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "workspace_root": .init(type: .string, description: "Workspace root bound to the language server session."),
                        "server_id": .init(type: .string, description: "Language server profile ID."),
                        "query": .init(type: .string, description: "Search query string.")
                    ],
                    required: ["workspace_root", "server_id", "query"]
                )
            }
        )
    }

    private static func lspDiagnosticsToolDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "lsp_diagnostics",
            displayName: "LSP Diagnostics",
            category: .system,
            schemaVersion: 1,
            supportedContexts: [.mainAgent, .subagent],
            isConcurrencySafe: true,
            executorKey: "lsp.diagnostics",
            descriptionBuilder: { _ in
                "Read the latest cached diagnostics for a document from the LSP diagnostics store."
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "workspace_root": .init(type: .string, description: "Workspace root bound to the language server session."),
                        "uri": .init(type: .string, description: "Document URI, for example file:///repo/src/app.ts")
                    ],
                    required: ["workspace_root", "uri"]
                )
            }
        )
    }

    private static func lspListServersToolDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "lsp_list_servers",
            displayName: "LSP List Servers",
            category: .system,
            schemaVersion: 1,
            supportedContexts: [.mainAgent, .subagent],
            isConcurrencySafe: true,
            executorKey: "lsp.listServers",
            descriptionBuilder: { _ in
                "List the configured built-in and custom language server profiles."
            },
            inputSchemaBuilder: { _ in
                .init(type: .object, properties: [:], required: [])
            }
        )
    }

    private static func lspServerStatusToolDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "lsp_server_status",
            displayName: "LSP Server Status",
            category: .system,
            schemaVersion: 1,
            supportedContexts: [.mainAgent, .subagent],
            isConcurrencySafe: true,
            executorKey: "lsp.serverStatus",
            descriptionBuilder: { _ in
                "Read runtime status for a language server session bound to a workspace."
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "workspace_root": .init(type: .string, description: "Workspace root bound to the language server session."),
                        "server_id": .init(type: .string, description: "Language server profile ID.")
                    ],
                    required: ["workspace_root", "server_id"]
                )
            }
        )
    }

    private static func lspLocationToolDefinition(
        id: String,
        displayName: String,
        executorKey: String,
        description: String
    ) -> ToolDefinition {
        ToolDefinition(
            id: id,
            displayName: displayName,
            category: .system,
            schemaVersion: 1,
            supportedContexts: [.mainAgent, .subagent],
            isConcurrencySafe: true,
            executorKey: executorKey,
            descriptionBuilder: { _ in description },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "workspace_root": .init(type: .string, description: "Workspace root bound to the language server session."),
                        "server_id": .init(type: .string, description: "Language server profile ID."),
                        "uri": .init(type: .string, description: "Document URI, for example file:///repo/src/app.ts"),
                        "line": .init(type: .integer, description: "Zero-based line number."),
                        "character": .init(type: .integer, description: "Zero-based character offset.")
                    ],
                    required: ["workspace_root", "server_id", "uri", "line", "character"]
                )
            }
        )
    }

    // MARK: - Skill Tools

    private static func readSkillDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "read_skill",
            displayName: "Read Skill",
            category: .system,
            schemaVersion: 1,
            supportedContexts: [.mainAgent],
            isConcurrencySafe: true,
            executorKey: "builtin.readSkill",
            descriptionBuilder: { _ in
                "Load the full instructions of a skill by name. Use when the user's request matches a skill's purpose."
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "name": .init(type: .string, description: "The skill name, e.g. 'brainstorming'")
                    ],
                    required: ["name"]
                )
            }
        )
    }

    private static func skillInvokeDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "skill_invoke",
            displayName: "Skill Invoke",
            category: .system,
            schemaVersion: 1,
            supportedContexts: [.mainAgent],
            executorKey: "builtin.skillInvoke",
            descriptionBuilder: { _ in
                """
                Execute a skill within the main conversation.

                When users ask you to perform tasks, check if any available skill matches. \
                If a skill's purpose matches the user's request, invoke it BEFORE generating \
                any other response about the task.

                How to invoke:
                - skill: the skill's name (e.g. "commit", "review-pr", "pdf")
                - args: optional arguments string (passed to the skill as $ARGUMENTS)

                Available skills are listed in the system prompt under "## Available Skills". \
                Do NOT invoke a skill that is already running. \
                If skill has already been invoked this turn (you see skill instructions in a \
                prior tool_result), follow those instructions directly instead of calling again.
                """
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "skill": .init(type: .string, description: "The skill name. E.g., \"commit\", \"review-pr\", or \"pdf\""),
                        "args": .init(type: .string, description: "Optional arguments for the skill, passed as $ARGUMENTS")
                    ],
                    required: ["skill"]
                )
            }
        )
    }

    // MARK: - Task Management Tools

    private static func updateTodoListDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "update_todo_list",
            displayName: "Update Todo List",
            category: .system,
            schemaVersion: 1,
            supportedContexts: [.mainAgent, .subagent, .backgroundTask],
            executorKey: "builtin.updateTodoList",
            descriptionBuilder: { _ in
                """
                Update the current task list shown in the workspace panel. \
                Use this to track progress on complex, multi-step tasks. \
                Each call REPLACES the entire todo list for the current session. \
                Call early to lay out planned steps, and update status as tasks progress.

                Statuses:
                - pending: not yet started
                - in_progress: currently working on it (at most one at a time)
                - done: completed successfully
                - cancelled: skipped or no longer needed
                """
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "items": .init(
                            type: .array,
                            description: #"Full list of todo items. Each item: { "id": string, "title": string, "status": "pending"|"in_progress"|"done"|"cancelled", "notes": string (optional) }"#
                        )
                    ],
                    required: ["items"]
                )
            }
        )
    }

    private static func createExecutionPlanDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "create_execution_plan",
            displayName: "Create Execution Plan",
            category: .system,
            schemaVersion: 1,
            supportedContexts: [.mainAgent, .subagent],
            executorKey: "builtin.createExecutionPlan",
            descriptionBuilder: { _ in
                """
                Record a structured execution plan before starting a complex task. \
                Use this when a task requires 3+ distinct steps, touches multiple files or systems, \
                or involves research followed by implementation. \
                The plan is shown in the workspace panel and helps verify completion afterwards.
                """
            },
            inputSchemaBuilder: { _ in
                .init(
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
            }
        )
    }

    private static func verifyCompletionDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "verify_completion",
            displayName: "Verify Completion",
            category: .system,
            schemaVersion: 1,
            supportedContexts: [.mainAgent, .subagent],
            executorKey: "builtin.verifyCompletion",
            descriptionBuilder: { _ in
                """
                Optionally record explicit completion claims for the host verify state to inspect. \
                Use this when you want to preserve a structured list of what was actually verified, what remains unverified, and the overall conclusion. \
                Do not claim tests or execution results unless they were actually observed.
                """
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "verified": .init(type: .array, description: "List of things that were confirmed to work (strings)"),
                        "not_verified": .init(type: .array, description: "List of things that were NOT verified and why (strings)"),
                        "conclusion": .init(type: .string, description: "Optional one-sentence overall verdict")
                    ],
                    required: ["verified", "not_verified"]
                )
            }
        )
    }

    // MARK: - Interaction Tools

    private static func askUserQuestionDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "ask_user_question",
            displayName: "Ask User Question",
            category: .system,
            schemaVersion: 1,
            supportedContexts: [.mainAgent],
            executorKey: "builtin.askUserQuestion",
            descriptionBuilder: { _ in
                """
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
                """
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "questions": .init(
                            type: .array,
                            description: "Array of question objects. Each must have: question (string), header (string), options (array of {label, description}), multiSelect (bool)."
                        )
                    ],
                    required: ["questions"]
                )
            }
        )
    }

    // MARK: - Media Tools

    private static func analyzeImageDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "analyze_image",
            displayName: "Analyze Image",
            category: .system,
            schemaVersion: 1,
            supportedContexts: [.mainAgent, .subagent],
            authorization: ToolAuthorizationDescriptor(
                requirements: [ToolCapabilityRequirement(capabilityID: .fileSystem, minimumLevel: .observe)],
                riskTier: .low
            ),
            isConcurrencySafe: true,
            executorKey: "builtin.analyzeImage",
            descriptionBuilder: { _ in
                """
                Load a local image file and analyze its visual content. \
                Provides the image directly to Claude's vision capabilities. \
                Supports png, jpg, jpeg, gif, webp (max 20 MB). \
                Use this when the user references an image file or you need to understand visual content.
                """
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "file_path": .init(type: .string, description: "Absolute path to the image file")
                    ],
                    required: ["file_path"]
                )
            }
        )
    }

    private static func readPdfDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "read_pdf",
            displayName: "Read PDF",
            category: .system,
            schemaVersion: 1,
            supportedContexts: [.mainAgent, .subagent],
            authorization: ToolAuthorizationDescriptor(
                requirements: [ToolCapabilityRequirement(capabilityID: .fileSystem, minimumLevel: .observe)],
                riskTier: .low
            ),
            isConcurrencySafe: true,
            executorKey: "builtin.readPdf",
            descriptionBuilder: { _ in
                """
                Extract all text content from a local PDF file using PDFKit. \
                Returns the text page-by-page so you can read, summarize, or answer questions about it. \
                For scanned PDFs without selectable text, use bash with pdftotext or similar. \
                Max 50 MB.
                """
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "file_path": .init(type: .string, description: "Absolute path to the PDF file")
                    ],
                    required: ["file_path"]
                )
            }
        )
    }

    // MARK: - Memory Tools

    private static func memoryWriteDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "memory_write",
            displayName: "Memory Write",
            category: .memory,
            schemaVersion: 1,
            supportedContexts: [.mainAgent, .subagent],
            authorization: ToolAuthorizationDescriptor(
                requirements: [ToolCapabilityRequirement(capabilityID: .fileSystem, minimumLevel: .mutate)],
                riskTier: .low
            ),
            executorKey: "builtin.memoryWrite",
            descriptionBuilder: { _ in
                """
                Persist an important long-term memory as a Markdown file in your persistent memory directory. \
                Use this for user preferences, project decisions, feedback patterns, and reference information \
                that should be available in future sessions. \
                Keep entries concise, factual, and decision-relevant. \
                Saves to ~/agentgui/memory/<filename>.md and updates the MEMORY.md index automatically.
                """
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "content": .init(
                            type: .string,
                            description: "The memory content to save. Write clear, concise Markdown body text."
                        ),
                        "title": .init(
                            type: .string,
                            description: "Optional short title for this memory (e.g. 'User prefers bun over npm'). Used for filename and MEMORY.md index."
                        ),
                        "type": .init(
                            type: .string,
                            description: "Memory type: 'user' (preferences/profile), 'feedback' (corrections/patterns), 'project' (decisions/context), or 'reference' (external links/docs). Defaults to 'project'."
                        ),
                        "description": .init(
                            type: .string,
                            description: "Optional one-line hook for MEMORY.md index (≤ 150 chars). If omitted, first line of content is used."
                        )
                    ],
                    required: ["content"]
                )
            }
        )
    }
}
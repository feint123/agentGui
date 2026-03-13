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
            storyMemoryUpsertCharacterDefinition(),
            storyMemoryQueryDefinition(),
            storyMemoryVerifyContinuityDefinition(),
            emitWorkflowArtifactDefinition(),
            runSubagentDefinition(),
            startWorkflowDefinition()
        ]
    }

    private static func textEditorDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "str_replace_based_edit_tool",
            displayName: "文本编辑器",
            category: .editor,
            schemaVersion: 1,
            supportedContexts: [.mainAgent, .subagent, .workflowWorker],
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
            supportedContexts: [.mainAgent, .subagent, .workflowWorker],
            executorKey: "builtin.bash",
            descriptionBuilder: { _ in
                """
                Execute shell commands in a persistent bash session. \
                The session preserves working directory and environment variables across calls. \
                Use restart: true to reset the session.

                For interactive commands that prompt for confirmation or input, set \
                interactive: true on the initial command. The tool will return once output \
                becomes idle, even if the command is still running. Then send follow-up input \
                with input: "..." and interactive: true. Use interrupt: true to send Ctrl-C \
                to the currently running foreground command.

                For commands that run indefinitely (servers, watchers, build monitors), set \
                background: true. The process is forked to the background immediately and a \
                log file path is returned — use `cat <logpath>` or `tail -n 50 <logpath>` in \
                a subsequent bash call to inspect output. The log file persists until the \
                session ends or you delete it.

                For large command output, inspect summary and preview first. When a payload_ref is returned, use read_tool_payload to read further chunks instead of re-requesting the entire transcript.

                Use timeout to limit how long to wait for a foreground command (default 300s). \
                If a command exceeds timeout, partial output is returned and the session restarts.
                """
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "command": .init(type: .string, description: "The bash command to execute"),
                        "task_id": .init(type: .string, description: "Optional managed terminal task ID to continue or annotate an existing task."),
                        "execution_mode": .init(type: .string, description: "Execution mode for the managed terminal task. One of: auto, foreground, background, interactive."),
                        "input": .init(type: .string, description: "Text to send to the currently running interactive foreground command"),
                        "signal": .init(type: .string, description: "Signal to send to the currently running foreground command. One of: interrupt, terminate."),
                        "goal_hint": .init(type: .string, description: "Optional goal or intent hint used to classify how the command should run."),
                        "scan_policy": .init(type: .string, description: "How aggressively the runtime should scan task state. One of: adaptive, manual."),
                        "auto_reply_policy": .init(type: .string, description: "Prompt handling policy. One of: safeOnly, disabled."),
                        "restart": .init(type: .boolean, description: "If true, restart the bash session and ignore command"),
                        "interrupt": .init(type: .boolean, description: "If true, send Ctrl-C to the currently running foreground command"),
                        "timeout": .init(type: .integer, description: "Max seconds to wait for the command to finish (default 300). Ignored when background is true."),
                        "background": .init(type: .boolean, description: "If true, run the command in the background immediately and return PID + log file path. Use for servers/watchers that never exit."),
                        "interactive": .init(type: .boolean, description: "If true, treat the command as interactive and return once output becomes idle so you can continue with input.")
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
            supportedContexts: [.mainAgent, .subagent, .workflowWorker],
            executorKey: "builtin.readToolPayload",
            descriptionBuilder: { _ in
                """
                Read a large tool result incrementally using a payload_ref returned by another tool. \
                Prefer this over requesting the original tool to print the full result again. \
                Check summary, preview, and range_summary first, then read only the next relevant chunk.
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
                        "cursor": .init(type: .string, description: "Optional cursor returned by a previous payload read."),
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
            supportedContexts: [.mainAgent, .subagent, .workflowWorker],
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
            supportedContexts: [.mainAgent, .subagent, .workflowWorker],
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
            category: .workflow,
            schemaVersion: 1,
            supportedContexts: [.mainAgent],
            executorKey: "builtin.runSubagent",
            descriptionBuilder: { context in
                """
                Delegate a focused task to a specialized built-in subagent. The subagent runs \
                its own agentic loop with the appropriate tools and returns a result string.

                WHEN TO USE:
                - Research, codebase discovery, or factual investigation → use "explore"
                - Implementing or modifying files, with targeted verification when needed → use "worker"
                - Checking whether claims are actually supported by evidence → use "verifier"

                Available agents:
                \(context.agentListText)

                The task string must be self-contained: include all context the subagent needs \
                (file paths, goals, constraints, relevant background). The subagent cannot ask \
                follow-up questions.
                """
            },
            inputSchemaBuilder: { context in
                .init(
                    type: .object,
                    properties: [
                        "agent_name": .init(type: .string, description: "Identifier of the subagent to use. One of: \(context.agentNameListText)"),
                        "task": .init(type: .string, description: "Detailed, self-contained task description for the subagent.")
                    ],
                    required: ["agent_name", "task"]
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
            supportedContexts: [.mainAgent, .subagent, .workflowWorker],
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
            supportedContexts: [.mainAgent, .subagent, .workflowWorker],
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
            supportedContexts: [.mainAgent, .subagent, .workflowWorker],
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
            supportedContexts: [.mainAgent, .subagent, .workflowWorker],
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
            supportedContexts: [.mainAgent, .subagent, .workflowWorker],
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
            supportedContexts: [.mainAgent, .subagent, .workflowWorker],
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

    private static func startWorkflowDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "start_workflow",
            displayName: "Start Workflow",
            category: .workflow,
            schemaVersion: 1,
            supportedContexts: [.mainAgent],
            executorKey: "builtin.startWorkflow",
            descriptionBuilder: { context in
                """
                Launch a multi-agent workflow for tasks that require sustained collaboration \
                between specialized agents (explore → worker → verifier).

                USE start_workflow WHEN the task:
                - Requires implementing or refactoring code across multiple files
                - Needs a coordinated explore-implement-verify pipeline
                - Is complex enough that a single agent loop would be insufficient

                DO NOT use start_workflow for:
                - Simple Q&A, single-file edits, or quick lookups
                - Tasks that can be completed in a few tool calls
                - Anything already handled well by run_subagent

                The workflow runs synchronously and returns a summary when complete. \
                The task must be self-contained: include file paths, goals, and any constraints.

                Available workflows:
                \(context.workflowListText)
                """
            },
            inputSchemaBuilder: { context in
                .init(
                    type: .object,
                    properties: [
                        "workflow_id": .init(type: .string, description: "ID of the workflow to launch. One of: \(context.workflowIDListText)"),
                        "task": .init(type: .string, description: "Self-contained task description including all context the workflow agents need.")
                    ],
                    required: ["workflow_id", "task"]
                )
            }
        )
    }

    private static func storyMemoryUpsertCharacterDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "story_memory_upsert_character",
            displayName: "Story Memory Upsert Character",
            category: .memory,
            schemaVersion: 1,
            supportedContexts: [.subagent, .workflowWorker],
            executorKey: "builtin.storyMemory.upsertCharacter",
            descriptionBuilder: { _ in
                "Create or update a character profile in the active writing project."
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "project_id": .init(type: .string, description: "Optional UUID string. If omitted, use the session-attached writing project."),
                        "name": .init(type: .string, description: "Character name"),
                        "summary": .init(type: .string, description: "Short character summary"),
                        "traits": .init(type: .array, description: "Optional list of character traits (strings)"),
                        "goals": .init(type: .array, description: "Optional list of current goals (strings)"),
                        "speech_style": .init(type: .string, description: "Dialogue and voice notes"),
                        "relationships": .init(type: .object, description: "Optional map of character name to relationship note"),
                        "arc_stage": .init(type: .string, description: "Current arc stage"),
                        "last_seen_chapter": .init(type: .integer, description: "Most recent chapter the character appeared in"),
                        "last_known_location": .init(type: .string, description: "Most recent known location")
                    ],
                    required: ["name"]
                )
            }
        )
    }

    private static func storyMemoryQueryDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "story_memory_query",
            displayName: "Story Memory Query",
            category: .memory,
            schemaVersion: 1,
            supportedContexts: [.subagent, .workflowWorker],
            executorKey: "builtin.storyMemory.query",
            descriptionBuilder: { _ in
                "Query the active writing project for structured story memory entities."
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "project_id": .init(type: .string, description: "Optional UUID string. If omitted, use the session-attached writing project."),
                        "query_kind": .init(type: .string, description: "One of: characters | events | foreshadows | chapters | scenes | world_rules | locations | style | continuity_issues"),
                        "names": .init(type: .array, description: "For characters: list of character names (strings)"),
                        "involving": .init(type: .array, description: "For events: list of character names used to filter participants (strings)"),
                        "up_to_chapter": .init(type: .integer, description: "For foreshadows: include items introduced up to this chapter"),
                        "limit": .init(type: .integer, description: "For events: maximum number of results to return"),
                        "chapter_number": .init(type: .integer, description: "For scenes: optional chapter number filter"),
                        "resolution_status": .init(type: .string, description: "For continuity issues: optional status filter")
                    ],
                    required: ["query_kind"]
                )
            }
        )
    }

    private static func storyMemoryVerifyContinuityDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "story_memory_verify_continuity",
            displayName: "Story Memory Verify Continuity",
            category: .memory,
            schemaVersion: 1,
            supportedContexts: [.subagent, .workflowWorker],
            executorKey: "builtin.storyMemory.verifyContinuity",
            descriptionBuilder: { _ in
                "Check a draft scene against recent story memory for continuity risks."
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "project_id": .init(type: .string, description: "Optional UUID string. If omitted, use the session-attached writing project."),
                        "chapter_number": .init(type: .integer, description: "Draft chapter number"),
                        "scene_index": .init(type: .integer, description: "Draft scene index"),
                        "title": .init(type: .string, description: "Draft scene title"),
                        "summary": .init(type: .string, description: "Draft scene summary"),
                        "location_name": .init(type: .string, description: "Draft scene location"),
                        "pov_character_name": .init(type: .string, description: "POV character name"),
                        "character_names": .init(type: .array, description: "Characters present in the scene (strings)"),
                        "referenced_foreshadow_tags": .init(type: .array, description: "Foreshadow tags referenced in the draft (strings)"),
                        "text": .init(type: .string, description: "Draft scene text or excerpt")
                    ],
                    required: ["chapter_number", "scene_index", "title"]
                )
            }
        )
    }

    private static func emitWorkflowArtifactDefinition() -> ToolDefinition {
        ToolDefinition(
            id: "emit_workflow_artifact",
            displayName: "Emit Workflow Artifact",
            category: .workflow,
            schemaVersion: 1,
            supportedContexts: [.workflowWorker],
            executorKey: "workflow.emitArtifact",
            descriptionBuilder: { _ in
                """
                Submit the structured artifact that is the primary output of this activation. \
                You MUST call this tool exactly once before finishing. \
                Not calling it means your activation is rejected.
                """
            },
            inputSchemaBuilder: { _ in
                .init(
                    type: .object,
                    properties: [
                        "kind": .init(type: .string, description: "Artifact kind: plan | explorationReport | codePatchSummary | reviewReport | testReport | decisionLog | finalAnswer"),
                        "schemaVersion": .init(type: .integer, description: "Schema version. Use 1."),
                        "contentJson": .init(type: .string, description: "Full artifact payload serialised as a valid JSON string."),
                        "status": .init(type: .string, description: "Artifact status: draft | approved | rejected | superseded (default: draft)")
                    ],
                    required: ["kind", "schemaVersion", "contentJson"]
                )
            }
        )
    }
}
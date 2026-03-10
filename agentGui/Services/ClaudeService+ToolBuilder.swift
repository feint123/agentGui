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

                Use timeout to limit how long to wait for a foreground command (default 300s). \
                If a command exceeds timeout, partial output is returned and the session restarts.
                """,
                inputSchema: .init(
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
                        "interactive": .init(type: .boolean, description: "If true, treat the command as interactive and return once output becomes idle so you can continue with input." )
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

        if settings.enableStoryMemory && isSubagent {
            tools.append(.function(
                name: "story_memory_create_project",
                description: "Create a writing project for story memory, optionally attaching it to the current session.",
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "title": .init(type: .string, description: "Project title"),
                        "synopsis": .init(type: .string, description: "Optional short project synopsis"),
                        "attach_to_session": .init(type: .boolean, description: "If true, bind the created project to the current session. Defaults to true.")
                    ],
                    required: ["title"]
                )
            ))

            tools.append(.function(
                name: "story_memory_attach_project",
                description: "Attach an existing writing project to the current session.",
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "project_id": .init(type: .string, description: "UUID string of the writing project")
                    ],
                    required: ["project_id"]
                )
            ))

            tools.append(.function(
                name: "story_memory_upsert_character",
                description: "Create or update a character profile in the active writing project.",
                inputSchema: .init(
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
            ))

            tools.append(.function(
                name: "story_memory_upsert_chapter",
                description: "Create or update a chapter record in the active writing project.",
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "project_id": .init(type: .string, description: "Optional UUID string. If omitted, use the session-attached writing project."),
                        "chapter_number": .init(type: .integer, description: "Chapter number"),
                        "title": .init(type: .string, description: "Chapter title"),
                        "outline": .init(type: .string, description: "Optional chapter outline"),
                        "summary": .init(type: .string, description: "Optional chapter summary"),
                        "tone_directive": .init(type: .string, description: "Optional tone directive"),
                        "is_locked": .init(type: .boolean, description: "Whether the chapter should be treated as locked canon")
                    ],
                    required: ["chapter_number", "title"]
                )
            ))

            tools.append(.function(
                name: "story_memory_upsert_scene",
                description: "Create or update a scene record under an existing chapter in the active writing project.",
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "project_id": .init(type: .string, description: "Optional UUID string. If omitted, use the session-attached writing project."),
                        "chapter_number": .init(type: .integer, description: "Chapter number containing the scene"),
                        "scene_index": .init(type: .integer, description: "Scene index within the chapter"),
                        "title": .init(type: .string, description: "Scene title"),
                        "content": .init(type: .string, description: "Optional scene content"),
                        "pov_character_name": .init(type: .string, description: "Optional POV character name"),
                        "location_name": .init(type: .string, description: "Optional scene location"),
                        "character_names": .init(type: .array, description: "Optional list of character names present in the scene"),
                        "summary": .init(type: .string, description: "Optional scene summary"),
                        "previous_scene_id": .init(type: .string, description: "Optional UUID string of the previous scene"),
                        "timeline_event_id": .init(type: .string, description: "Optional UUID string of a linked timeline event")
                    ],
                    required: ["chapter_number", "scene_index", "title"]
                )
            ))

            tools.append(.function(
                name: "story_memory_upsert_world_rule",
                description: "Create or update a world rule in the active writing project.",
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "project_id": .init(type: .string, description: "Optional UUID string. If omitted, use the session-attached writing project."),
                        "title": .init(type: .string, description: "Rule title"),
                        "category": .init(type: .string, description: "Optional rule category"),
                        "detail": .init(type: .string, description: "Optional rule detail"),
                        "scope": .init(type: .string, description: "Optional rule scope"),
                        "exceptions": .init(type: .array, description: "Optional list of exception strings"),
                        "established_in_chapter": .init(type: .integer, description: "Optional chapter where the rule was established"),
                        "related_entities": .init(type: .array, description: "Optional list of related entities"),
                        "mutable_policy": .init(type: .string, description: "Optional mutability policy")
                    ],
                    required: ["title"]
                )
            ))

            tools.append(.function(
                name: "story_memory_upsert_location",
                description: "Create or update a location profile in the active writing project.",
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "project_id": .init(type: .string, description: "Optional UUID string. If omitted, use the session-attached writing project."),
                        "name": .init(type: .string, description: "Location name"),
                        "summary": .init(type: .string, description: "Optional location summary"),
                        "traits": .init(type: .array, description: "Optional list of location traits"),
                        "related_rules": .init(type: .array, description: "Optional list of related rule titles"),
                        "occupant_names": .init(type: .array, description: "Optional list of occupant names")
                    ],
                    required: ["name"]
                )
            ))

            tools.append(.function(
                name: "story_memory_upsert_foreshadow",
                description: "Create or update a foreshadow item in the active writing project.",
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "project_id": .init(type: .string, description: "Optional UUID string. If omitted, use the session-attached writing project."),
                        "tag": .init(type: .string, description: "Foreshadow tag"),
                        "introduced_in_chapter": .init(type: .integer, description: "Optional chapter the foreshadow was introduced"),
                        "detail": .init(type: .string, description: "Optional foreshadow detail"),
                        "related_event_ids": .init(type: .array, description: "Optional list of related event UUID strings"),
                        "status": .init(type: .string, description: "Optional foreshadow status"),
                        "resolved_in_chapter": .init(type: .integer, description: "Optional chapter where the foreshadow was resolved")
                    ],
                    required: ["tag"]
                )
            ))

            tools.append(.function(
                name: "story_memory_upsert_style_profile",
                description: "Create or update the singleton style profile for the active writing project.",
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "project_id": .init(type: .string, description: "Optional UUID string. If omitted, use the session-attached writing project."),
                        "author_preferences": .init(type: .string, description: "Optional author preference summary"),
                        "narrative_voice": .init(type: .string, description: "Optional narrative voice directive"),
                        "sentence_length_mean": .init(type: .number, description: "Optional average sentence length target"),
                        "dialogue_ratio": .init(type: .number, description: "Optional dialogue ratio target"),
                        "imagery_density": .init(type: .number, description: "Optional imagery density target"),
                        "sample_passages": .init(type: .array, description: "Optional list of sample passages"),
                        "anti_patterns": .init(type: .array, description: "Optional list of style anti-patterns")
                    ],
                    required: []
                )
            ))

            tools.append(.function(
                name: "story_memory_update_continuity_issue",
                description: "Update the status of an existing continuity issue in the active writing project.",
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "project_id": .init(type: .string, description: "Optional UUID string. If omitted, use the session-attached writing project."),
                        "issue_id": .init(type: .string, description: "UUID string of the continuity issue"),
                        "resolution_status": .init(type: .string, description: "One of: open | accepted | resolved | wont_fix"),
                        "resolution_note": .init(type: .string, description: "Optional note explaining the resolution")
                    ],
                    required: ["issue_id", "resolution_status"]
                )
            ))

            tools.append(.function(
                name: "story_memory_append_event",
                description: "Append a timeline event to the active writing project.",
                inputSchema: .init(
                    type: .object,
                    properties: [
                        "project_id": .init(type: .string, description: "Optional UUID string. If omitted, use the session-attached writing project."),
                        "chapter_number": .init(type: .integer, description: "Chapter number"),
                        "scene_index": .init(type: .integer, description: "Scene index within the chapter"),
                        "title": .init(type: .string, description: "Event title"),
                        "summary": .init(type: .string, description: "Short event summary"),
                        "participants": .init(type: .array, description: "Optional list of participant names (strings)"),
                        "location_name": .init(type: .string, description: "Event location"),
                        "time_marker": .init(type: .string, description: "Optional time marker"),
                        "event_type": .init(type: .string, description: "Optional event type"),
                        "foreshadow_tags": .init(type: .array, description: "Optional list of referenced foreshadow tags (strings)")
                    ],
                    required: ["chapter_number", "scene_index", "title"]
                )
            ))

            tools.append(.function(
                name: "story_memory_query",
                description: "Query the active writing project for structured story memory entities.",
                inputSchema: .init(
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
            ))

            tools.append(.function(
                name: "story_memory_verify_continuity",
                description: "Check a draft scene against recent story memory for continuity risks.",
                inputSchema: .init(
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
            ))
        }

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
            Keep entries concise. Write important facts, preferences, or context the user wants you to remember. \
            During unified memory runtime migration, speculative creative semantic writes may be blocked by governance and require user confirmation.
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

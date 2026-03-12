//
//  ClaudeService+ToolDispatch.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

// MARK: - Tool Dispatch

extension ClaudeService {

    private func wrapLargeTextToolResult(
        rawText: String,
        toolName: String,
        sourceKind: LargeTextPayload.SourceKind,
        sourceDescriptor: String,
        settings: AppSettings
    ) async -> ToolExecutionResult {
        let detected = ToolExecutionResult.detect(rawText, toolName: toolName)
        guard !detected.isError else { return detected }

        let decision = toolResultBudgetController.decide(
            rawText: rawText,
            sourceKind: sourceKind,
            roundInjectedChars: 0,
            reservedResponseTokens: settings.enableExtendedThinking ? max(1024, settings.extendedThinkingBudget / 2) : 4096
        )

        let payloadRef: String?
        if decision.shouldPersistPayload {
            payloadRef = try? await toolPayloadStore.createPayload(
                text: rawText,
                sourceKind: sourceKind,
                sourceDescriptor: sourceDescriptor
            ).payloadID
        } else {
            payloadRef = nil
        }

        let envelope = ToolResultEnvelope(
            summary: decision.summary,
            preview: decision.preview,
            payloadRef: payloadRef,
            isTruncated: decision.mode != .inline,
            estimatedChars: rawText.count,
            estimatedTokens: ToolResultEnvelope.estimateTokens(for: rawText),
            retrievalHint: decision.retrievalHint.isEmpty ? nil : decision.retrievalHint,
            sourceKind: sourceKind,
            injectionMode: decision.mode,
            rawCharCount: decision.rawCharCount,
            injectedCharCount: decision.injectedCharCount
        )

        let modelText = decision.mode == .inline ? rawText : envelope.renderForModel()
        return ToolExecutionResult(
            modelText,
            status: detected.status,
            mediaContent: detected.mediaContent,
            rawOutputText: rawText,
            envelope: envelope
        )
    }

    func wrapLargeTextToolResultForTests(
        rawText: String,
        toolName: String,
        sourceKind: LargeTextPayload.SourceKind,
        sourceDescriptor: String,
        settings: AppSettings
    ) async -> ToolExecutionResult {
        await wrapLargeTextToolResult(
            rawText: rawText,
            toolName: toolName,
            sourceKind: sourceKind,
            sourceDescriptor: sourceDescriptor,
            settings: settings
        )
    }

    // MARK: - Dispatch

    func executeTool(
        name: String,
        input: MessageResponse.Content.Input,
        settings: AppSettings,
        session: Session,
        modelContext: ModelContext
    ) async -> ToolExecutionResult {
        let sessionId = session.sessionId
        switch name {
        case "str_replace_based_edit_tool", "str_replace_editor":
            let raw = await executeTextEditorTool(input: input)
            let descriptor = input["path"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .file, sourceDescriptor: descriptor, settings: settings)
        case "bash":
            let wd = effectiveWorkingDirectory(session: session, settings: settings)
            let bashSess = getBashSession(
                for: sessionId,
                workingDirectory: wd,
                environmentOverrides: settings.proxyConfiguration.bashEnvironmentOverrides
            )
            let raw = await executeBashTool(input: input, session: bashSess, workingDirectory: wd, settings: settings)
            let descriptor = input["command"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .bash, sourceDescriptor: descriptor, settings: settings)
        case "read_tool_payload":
            return .detect(await executeReadToolPayload(input: input), toolName: name)
        case "read_skill":
            guard let skillName = input["name"]?.stringValue else {
                return .missingParameter("name")
            }
            if let content = skillService?.readSkillContent(name: skillName) {
                return .success(content)
            }
            return .failure("Error: skill '\(skillName)' not found")
        case "update_todo_list":
            return .detect(executeUpdateTodoList(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "web_search":
            if settings.enableOllamaWebSearch && !settings.ollamaAPIKey.isEmpty {
                let raw = await executeOllamaWebSearchTool(input: input, apiKey: settings.ollamaAPIKey, settings: settings)
                let descriptor = input["query"]?.stringValue ?? name
                return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .webSearch, sourceDescriptor: descriptor, settings: settings)
            }
            let raw = await executeWebSearchTool(input: input, settings: settings)
            let descriptor = input["query"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .webSearch, sourceDescriptor: descriptor, settings: settings)
        case "web_fetch":
            let raw = await executeWebFetchTool(input: input, settings: settings)
            let descriptor = input["url"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .webFetch, sourceDescriptor: descriptor, settings: settings)
        case "ask_user_question":
            return .detect(await executeAskUserQuestion(input: input), toolName: name)
        case "analyze_image":
            return await executeAnalyzeImageTool(input: input)
        case "read_pdf":
            return await executeReadPDFTool(input: input)
        case "memory_write":
            return .detect(await executeGovernedMemoryWrite(input: input, session: session, modelContext: modelContext), toolName: name)
        case "create_execution_plan":
            return .detect(executeCreateExecutionPlan(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "verify_completion":
            return .detect(await executeVerifyCompletion(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "story_memory_create_project":
            return .detect(executeStoryMemoryCreateProject(input: input, session: session, modelContext: modelContext), toolName: name)
        case "story_memory_attach_project":
            return .detect(executeStoryMemoryAttachProject(input: input, session: session, modelContext: modelContext), toolName: name)
        case "story_memory_upsert_character":
            return .detect(executeStoryMemoryUpsertCharacter(input: input, session: session, modelContext: modelContext), toolName: name)
        case "story_memory_upsert_chapter":
            return .detect(executeStoryMemoryUpsertChapter(input: input, session: session, modelContext: modelContext), toolName: name)
        case "story_memory_upsert_scene":
            return .detect(executeStoryMemoryUpsertScene(input: input, session: session, modelContext: modelContext), toolName: name)
        case "story_memory_upsert_world_rule":
            return .detect(executeStoryMemoryUpsertWorldRule(input: input, session: session, modelContext: modelContext), toolName: name)
        case "story_memory_upsert_location":
            return .detect(executeStoryMemoryUpsertLocation(input: input, session: session, modelContext: modelContext), toolName: name)
        case "story_memory_upsert_foreshadow":
            return .detect(executeStoryMemoryUpsertForeshadow(input: input, session: session, modelContext: modelContext), toolName: name)
        case "story_memory_upsert_style_profile":
            return .detect(executeStoryMemoryUpsertStyleProfile(input: input, session: session, modelContext: modelContext), toolName: name)
        case "story_memory_update_continuity_issue":
            return .detect(executeStoryMemoryUpdateContinuityIssue(input: input, session: session, modelContext: modelContext), toolName: name)
        case "story_memory_append_event":
            return .detect(executeStoryMemoryAppendEvent(input: input, session: session, modelContext: modelContext), toolName: name)
        case "story_memory_query":
            return .detect(executeStoryMemoryQuery(input: input, session: session, modelContext: modelContext), toolName: name)
        case "story_memory_verify_continuity":
            return .detect(executeStoryMemoryVerifyContinuity(input: input, session: session, modelContext: modelContext), toolName: name)
        default:
            return .unknownTool(name)
        }
    }

    // MARK: - Effective Working Directory

    func effectiveWorkingDirectory(session: Session, settings: AppSettings) -> String? {
        if !settings.workingDirectory.isEmpty { return settings.workingDirectory }
        return nil
    }

    /// Convenience overload used by the core agentic loop (and subagents), which carries
    /// a `sessionId` string and `ModelContext` but not a full `Session` object.
    func executeTool(
        name: String,
        input: MessageResponse.Content.Input,
        settings: AppSettings,
        sessionId: String,
        modelContext: ModelContext
    ) async -> ToolExecutionResult {
        let wd = settings.workingDirectory.isEmpty ? nil : settings.workingDirectory
        switch name {
        case "str_replace_based_edit_tool", "str_replace_editor":
            let raw = await executeTextEditorTool(input: input)
            let descriptor = input["path"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .file, sourceDescriptor: descriptor, settings: settings)
        case "bash":
            let bashSess = getBashSession(
                for: sessionId,
                workingDirectory: wd,
                environmentOverrides: settings.proxyConfiguration.bashEnvironmentOverrides
            )
            let raw = await executeBashTool(input: input, session: bashSess, workingDirectory: wd, settings: settings)
            let descriptor = input["command"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .bash, sourceDescriptor: descriptor, settings: settings)
        case "read_tool_payload":
            return .detect(await executeReadToolPayload(input: input), toolName: name)
        case "read_skill":
            guard let skillName = input["name"]?.stringValue else {
                return .missingParameter("name")
            }
            if let content = skillService?.readSkillContent(name: skillName) {
                return .success(content)
            }
            return .failure("Error: skill '\(skillName)' not found")
        case "update_todo_list":
            return .detect(executeUpdateTodoList(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "web_search":
            if settings.enableOllamaWebSearch && !settings.ollamaAPIKey.isEmpty {
                let raw = await executeOllamaWebSearchTool(input: input, apiKey: settings.ollamaAPIKey, settings: settings)
                let descriptor = input["query"]?.stringValue ?? name
                return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .webSearch, sourceDescriptor: descriptor, settings: settings)
            }
            let raw = await executeWebSearchTool(input: input, settings: settings)
            let descriptor = input["query"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .webSearch, sourceDescriptor: descriptor, settings: settings)
        case "web_fetch":
            let raw = await executeWebFetchTool(input: input, settings: settings)
            let descriptor = input["url"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .webFetch, sourceDescriptor: descriptor, settings: settings)
        case "ask_user_question":
            return .detect(await executeAskUserQuestion(input: input), toolName: name)
        case "analyze_image":
            return await executeAnalyzeImageTool(input: input)
        case "read_pdf":
            return await executeReadPDFTool(input: input)
        case "memory_write":
            return .detect(await executeGovernedMemoryWrite(input: input, session: nil, modelContext: modelContext), toolName: name)
        case "create_execution_plan":
            return .detect(executeCreateExecutionPlan(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "verify_completion":
            return .detect(await executeVerifyCompletion(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "story_memory_create_project":
            return .detect(executeStoryMemoryCreateProject(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "story_memory_attach_project":
            return .detect(executeStoryMemoryAttachProject(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "story_memory_upsert_character":
            return .detect(executeStoryMemoryUpsertCharacter(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "story_memory_upsert_chapter":
            return .detect(executeStoryMemoryUpsertChapter(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "story_memory_upsert_scene":
            return .detect(executeStoryMemoryUpsertScene(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "story_memory_upsert_world_rule":
            return .detect(executeStoryMemoryUpsertWorldRule(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "story_memory_upsert_location":
            return .detect(executeStoryMemoryUpsertLocation(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "story_memory_upsert_foreshadow":
            return .detect(executeStoryMemoryUpsertForeshadow(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "story_memory_upsert_style_profile":
            return .detect(executeStoryMemoryUpsertStyleProfile(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "story_memory_update_continuity_issue":
            return .detect(executeStoryMemoryUpdateContinuityIssue(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "story_memory_append_event":
            return .detect(executeStoryMemoryAppendEvent(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "story_memory_query":
            return .detect(executeStoryMemoryQuery(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "story_memory_verify_continuity":
            return .detect(executeStoryMemoryVerifyContinuity(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        default:
            return .unknownTool(name)
        }
    }
}

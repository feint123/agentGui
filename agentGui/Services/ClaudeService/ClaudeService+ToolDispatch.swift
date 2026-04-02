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
        settings: AppSettings,
        baseResult: ToolExecutionResult? = nil
    ) async -> ToolExecutionResult {
        let detected = baseResult ?? ToolExecutionResult.detect(rawText, toolName: toolName)
        guard !detected.isError else { return detected }

        let decision = toolResultBudgetController.decide(
            rawText: rawText,
            sourceKind: sourceKind,
            roundInjectedChars: 0,
            reservedResponseTokens: settings.enableExtendedThinking ? max(1024, settings.extendedThinkingBudget / 2) : 4096
        )

        let payloadRef: String?
        if decision.shouldPersistPayload {
            do {
                payloadRef = try await toolPayloadStore.createPayload(
                    text: rawText,
                    sourceKind: sourceKind,
                    sourceDescriptor: sourceDescriptor
                ).payloadID
            } catch {
                payloadRef = nil
            }
        } else {
            payloadRef = nil
        }

        let effectiveMode: ToolResultEnvelope.InjectionMode
        let effectiveRetrievalHint: String?
        if decision.mode == .referenced, payloadRef == nil {
            effectiveMode = .preview
            effectiveRetrievalHint = "Inspect summary and preview before retrying the original tool. Payload persistence was unavailable for this result."
        } else {
            effectiveMode = decision.mode
            effectiveRetrievalHint = decision.retrievalHint.isEmpty ? nil : decision.retrievalHint
        }

        let envelope = ToolResultEnvelope(
            summary: decision.summary,
            preview: decision.preview,
            payloadRef: payloadRef,
            isTruncated: effectiveMode != .inline,
            estimatedChars: rawText.count,
            estimatedTokens: ToolResultEnvelope.estimateTokens(for: rawText),
            retrievalHint: effectiveRetrievalHint,
            sourceKind: sourceKind,
            injectionMode: effectiveMode,
            rawCharCount: decision.rawCharCount,
            injectedCharCount: decision.injectedCharCount
        )

        let modelText = effectiveMode == .inline ? rawText : envelope.renderForModel()
        return ToolExecutionResult(
            modelText,
            status: detected.status,
            mediaContent: detected.mediaContent,
            rawOutputText: rawText,
            envelope: envelope,
            changeProposalID: detected.changeProposalID,
            changeProposalState: detected.changeProposalState,
            changeProposalSnapshot: detected.changeProposalSnapshot,
            changeProposalDiffContent: detected.changeProposalDiffContent
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
            let raw = await executeTextEditorTool(
                input: input,
                sessionID: sessionId,
                baseWorkspaceRoot: textEditorBaseWorkspaceRoot(
                    forPath: input["path"]?.stringValue,
                    session: session,
                    settings: settings
                ),
                modelContext: modelContext
            )
            let descriptor = input["path"]?.stringValue ?? name
            return await wrapLargeTextToolResult(
                rawText: raw.text,
                toolName: name,
                sourceKind: .file,
                sourceDescriptor: descriptor,
                settings: settings,
                baseResult: raw
            )
        case "bash":
            let wd = effectiveWorkingDirectory(session: session, settings: settings)
            let runtime = getTerminalTaskRuntime(for: sessionId, workingDirectory: wd)
            let raw = await executeBashTool(input: input, runtime: runtime, workingDirectory: wd)
            let descriptor = input["command"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .bash, sourceDescriptor: descriptor, settings: settings)
        case "read_tool_payload":
            return .detect(await executeReadToolPayload(input: input), toolName: name)
        case "read_skill":
            guard let skillName = input["name"]?.stringValue else {
                return .missingParameter("name")
            }
            if let content = await skillService?.readSkillContent(name: skillName) {
                return .success(content)
            }
            return .failure("Error: skill '\(skillName)' not found")
        case "skill_invoke":
            guard let skillName = input["skill"]?.stringValue else {
                return .missingParameter("skill")
            }
            let skillArgs = input["args"]?.stringValue

            // Fork 路由：若 skill 声明了 fork context，走子代理执行路径
            if let skill = skillService?.availableSkills.first(where: {
                $0.name == skillName || $0.directoryName == skillName
            }), skill.executionContext == .fork {
                return await executeSkillInvokeForked(
                    skill: skill,
                    args: skillArgs,
                    settings: settings,
                    sessionId: sessionId,
                    modelContext: modelContext
                )
            }

            // Inline 路径（原有逻辑不变）
            let processor = SkillInvocationProcessor(
                provider: skillService ?? NullSkillContentProvider(),
                sessionId: sessionId
            )
            let outcome = await processor.invoke(skillName: skillName, args: skillArgs)
            return ToolExecutionResult(fromSkillInvocationOutcome: outcome)
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
        case "lsp_definition", "lsp_references", "lsp_hover", "lsp_document_symbols", "lsp_workspace_symbols", "lsp_diagnostics", "lsp_list_servers", "lsp_server_status":
            return .detect(await executeLSPTool(name: name, input: input, settings: settings), toolName: name)
        case "ask_user_question":
            return .detect(await executeAskUserQuestion(input: input), toolName: name)
        case "analyze_image":
            return await executeAnalyzeImageTool(input: input)
        case "read_pdf":
            return await executeReadPDFTool(input: input)
        case "memory_write":
            return .detect(await executeFileMemoryWrite(input: input), toolName: name)
        case "create_execution_plan":
            return .detect(executeCreateExecutionPlan(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "verify_completion":
            return .detect(await executeVerifyCompletion(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        default:
            return .unknownTool(name)
        }
    }

    // MARK: - Skill Invoke Fork Helper

    /// `skill_invoke` 的 fork 执行路径：注入 SkillForkContext 后调用 SkillForkExecutor。
    /// 两个 executeTool 重载均通过此方法执行 fork skill。
    private func executeSkillInvokeForked(
        skill: Skill,
        args: String?,
        settings: AppSettings,
        sessionId: String,
        modelContext: ModelContext
    ) async -> ToolExecutionResult {
        guard let svc = service else {
            return .failure("Error: ClaudeService is not configured. Cannot execute fork skill '\(skill.directoryName)'.")
        }
        let modelId = currentModelID(for: sessionId)

        // 读取并替换 skill 内容
        guard let rawContent = await skillService?.readSkillContent(name: skill.directoryName) else {
            return .failure("Error: skill '\(skill.directoryName)' content could not be loaded for fork execution.")
        }
        let processedContent = SkillArgumentSubstitution.substitute(
            content: rawContent,
            args: args,
            skillDirectory: skill.path,
            sessionId: sessionId
        )

        // 注入 fork context 供 runSkillSubagent 使用
        currentSkillForkContext = SkillForkContext(
            service: svc,
            modelId: modelId,
            settings: settings,
            sessionId: sessionId,
            modelContext: modelContext
        )
        defer { currentSkillForkContext = nil }

        let executor = SkillForkExecutor(runner: self, defaultModelId: modelId)
        do {
            return try await executor.execute(
                skill: skill,
                processedContent: processedContent,
                parentModelId: modelId
            )
        } catch {
            return .failure("Fork skill '\(skill.directoryName)' failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Effective Working Directory

    func effectiveWorkingDirectory(session: Session, settings: AppSettings) -> String? {
        if !session.workingDirectory.isEmpty { return session.workingDirectory }
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
        let session = sessionForTextEditorExecution(sessionId: sessionId, modelContext: modelContext)
        let wd = settings.workingDirectory.isEmpty ? nil : settings.workingDirectory
        switch name {
        case "str_replace_based_edit_tool", "str_replace_editor":
            let raw = await executeTextEditorTool(
                input: input,
                sessionID: sessionId,
                baseWorkspaceRoot: textEditorBaseWorkspaceRoot(
                    forPath: input["path"]?.stringValue,
                    session: session,
                    settings: settings
                ),
                modelContext: modelContext
            )
            let descriptor = input["path"]?.stringValue ?? name
            return await wrapLargeTextToolResult(
                rawText: raw.text,
                toolName: name,
                sourceKind: .file,
                sourceDescriptor: descriptor,
                settings: settings,
                baseResult: raw
            )
        case "bash":
            let runtime = getTerminalTaskRuntime(for: sessionId, workingDirectory: wd)
            let raw = await executeBashTool(input: input, runtime: runtime, workingDirectory: wd)
            let descriptor = input["command"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .bash, sourceDescriptor: descriptor, settings: settings)
        case "read_tool_payload":
            return .detect(await executeReadToolPayload(input: input), toolName: name)
        case "read_skill":
            guard let skillName = input["name"]?.stringValue else {
                return .missingParameter("name")
            }
            if let content = await skillService?.readSkillContent(name: skillName) {
                return .success(content)
            }
            return .failure("Error: skill '\(skillName)' not found")
        case "skill_invoke":
            guard let skillName = input["skill"]?.stringValue else {
                return .missingParameter("skill")
            }
            let skillArgs = input["args"]?.stringValue

            // Fork 路由：若 skill 声明了 fork context，走子代理执行路径
            if let skill = skillService?.availableSkills.first(where: {
                $0.name == skillName || $0.directoryName == skillName
            }), skill.executionContext == .fork {
                return await executeSkillInvokeForked(
                    skill: skill,
                    args: skillArgs,
                    settings: settings,
                    sessionId: sessionId,
                    modelContext: modelContext
                )
            }

            // Inline 路径（原有逻辑不变）
            let processor = SkillInvocationProcessor(
                provider: skillService ?? NullSkillContentProvider(),
                sessionId: sessionId
            )
            let outcome = await processor.invoke(skillName: skillName, args: skillArgs)
            return ToolExecutionResult(fromSkillInvocationOutcome: outcome)
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
        case "lsp_definition", "lsp_references", "lsp_hover", "lsp_document_symbols", "lsp_workspace_symbols", "lsp_diagnostics", "lsp_list_servers", "lsp_server_status":
            return .detect(await executeLSPTool(name: name, input: input, settings: settings), toolName: name)
        case "ask_user_question":
            return .detect(await executeAskUserQuestion(input: input), toolName: name)
        case "analyze_image":
            return await executeAnalyzeImageTool(input: input)
        case "read_pdf":
            return await executeReadPDFTool(input: input)
        case "memory_write":
            return .detect(await executeFileMemoryWrite(input: input), toolName: name)
        case "create_execution_plan":
            return .detect(executeCreateExecutionPlan(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "verify_completion":
            return .detect(await executeVerifyCompletion(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        default:
            return .unknownTool(name)
        }
    }

    private func sessionForTextEditorExecution(sessionId: String, modelContext: ModelContext) -> Session? {
        let targetSessionID = sessionId
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == targetSessionID }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func textEditorBaseWorkspaceRoot(
        forPath path: String?,
        session: Session?,
        settings: AppSettings
    ) -> String? {
        if let session, let workingDirectory = effectiveWorkingDirectory(session: session, settings: settings) {
            return workingDirectory
        }
        if !settings.workingDirectory.isEmpty {
            return settings.workingDirectory
        }
        guard let path else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    private func executeLSPTool(
        name: String,
        input: MessageResponse.Content.Input,
        settings: AppSettings
    ) async -> String {
        guard settings.enableLSPTools else {
            return "Error: LSP tools are disabled in settings"
        }
        guard let facade = makeLSPToolFacade(settings: settings) else {
            return "Error: unable to configure LSP tools"
        }

        switch name {
        case "lsp_list_servers":
            return facade.listServers()
        case "lsp_server_status":
            guard let workspaceRoot = input["workspace_root"]?.stringValue else {
                return "Error: missing parameter 'workspace_root'"
            }
            guard let serverID = input["server_id"]?.stringValue else {
                return "Error: missing parameter 'server_id'"
            }
            return facade.serverStatus(workspaceRoot: workspaceRoot, serverID: serverID)
        case "lsp_diagnostics":
            guard let workspaceRoot = input["workspace_root"]?.stringValue else {
                return "Error: missing parameter 'workspace_root'"
            }
            guard let uri = input["uri"]?.stringValue else {
                return "Error: missing parameter 'uri'"
            }
            return facade.diagnostics(workspaceRoot: workspaceRoot, uri: uri)
        case "lsp_definition", "lsp_references", "lsp_hover":
            guard let workspaceRoot = input["workspace_root"]?.stringValue else {
                return "Error: missing parameter 'workspace_root'"
            }
            guard let serverID = input["server_id"]?.stringValue else {
                return "Error: missing parameter 'server_id'"
            }
            guard let uri = input["uri"]?.stringValue else {
                return "Error: missing parameter 'uri'"
            }
            guard let line = input["line"]?.intValue else {
                return "Error: missing parameter 'line'"
            }
            guard let character = input["character"]?.intValue else {
                return "Error: missing parameter 'character'"
            }

            if let startError = await ensureLSPToolSessionIfNeeded(
                workspaceRoot: workspaceRoot,
                serverID: serverID,
                settings: settings
            ) {
                return startError
            }

            switch name {
            case "lsp_definition":
                return (try? await facade.definition(workspaceRoot: workspaceRoot, serverID: serverID, uri: uri, line: line, character: character))
                    ?? "Error: LSP definition request failed"
            case "lsp_references":
                return (try? await facade.references(workspaceRoot: workspaceRoot, serverID: serverID, uri: uri, line: line, character: character))
                    ?? "Error: LSP references request failed"
            default:
                return (try? await facade.hover(workspaceRoot: workspaceRoot, serverID: serverID, uri: uri, line: line, character: character))
                    ?? "Error: LSP hover request failed"
            }
        case "lsp_document_symbols":
            guard let workspaceRoot = input["workspace_root"]?.stringValue else {
                return "Error: missing parameter 'workspace_root'"
            }
            guard let serverID = input["server_id"]?.stringValue else {
                return "Error: missing parameter 'server_id'"
            }
            guard let uri = input["uri"]?.stringValue else {
                return "Error: missing parameter 'uri'"
            }
            if let startError = await ensureLSPToolSessionIfNeeded(
                workspaceRoot: workspaceRoot,
                serverID: serverID,
                settings: settings
            ) {
                return startError
            }
            return (try? await facade.documentSymbols(workspaceRoot: workspaceRoot, serverID: serverID, uri: uri))
                ?? "Error: LSP document symbols request failed"
        case "lsp_workspace_symbols":
            guard let workspaceRoot = input["workspace_root"]?.stringValue else {
                return "Error: missing parameter 'workspace_root'"
            }
            guard let serverID = input["server_id"]?.stringValue else {
                return "Error: missing parameter 'server_id'"
            }
            guard let query = input["query"]?.stringValue else {
                return "Error: missing parameter 'query'"
            }
            if let startError = await ensureLSPToolSessionIfNeeded(
                workspaceRoot: workspaceRoot,
                serverID: serverID,
                settings: settings
            ) {
                return startError
            }
            return facade.workspaceSymbols(workspaceRoot: workspaceRoot, serverID: serverID, query: query)
        default:
            return "Error: unsupported LSP tool '\(name)'"
        }
    }

    // MARK: - Memory Write (Stub)

    /// M-04 占位实现。
    /// Feature M-04 将替换此方法为直接写 .md 文件的实现。
    private func executeFileMemoryWrite(
        input: MessageResponse.Content.Input
    ) async -> String {
        guard let content = input["content"]?.stringValue, !content.isEmpty else {
            return "Error: missing parameter 'content'"
        }
        // TODO: M-04 将在此实现写 memoryDir/<topic>.md + 重建 MEMORY.md
        return "⚠️ Memory write stub (M-04 not yet implemented). Content received: \(content.prefix(80))..."
    }

    func ensureLSPServerStartedIfNeeded(
        workspaceRoot: String,
        serverID: String,
        settings: AppSettings
    ) async throws -> Bool {
        guard settings.isLSPAutoStartEffective,
              let manager = lspServerManager else {
            return false
        }

        if let state = manager.state(for: workspaceRoot, serverID: serverID) {
            switch state {
            case .crashed, .failedToLaunch, .stopped:
                _ = try await manager.recoverSessionIfNeeded(workspaceRoot: workspaceRoot, serverID: serverID)
                return true
            case .idle, .starting, .running:
                return false
            }
        }

        _ = try await manager.startSession(workspaceRoot: workspaceRoot, serverID: serverID)
        return true
    }

    func autoStartLSPServerForSelectedFileIfNeeded(
        workingDirectory: String,
        selectedFilePath: String?,
        settings: AppSettings
    ) async {
        _ = try? await ensureWorkspaceLSPState(
            workingDirectory: workingDirectory,
            selectedFilePath: selectedFilePath,
            settings: settings
        )
    }

    func ensureWorkspaceLSPState(
        workingDirectory: String,
        selectedFilePath: String?,
        settings: AppSettings
    ) async throws -> LSPWorkspaceBootstrapResult {
        guard let coordinator = makeLSPWorkspaceCoordinator(settings: settings) else {
            return .empty
        }

        return try await coordinator.bootstrapWorkspace(
            workingDirectory: workingDirectory,
            selectedFilePath: selectedFilePath,
            settings: settings
        )
    }

    private func ensureLSPToolSessionIfNeeded(
        workspaceRoot: String,
        serverID: String,
        settings: AppSettings
    ) async -> String? {
        do {
            _ = try await ensureLSPServerStartedIfNeeded(
                workspaceRoot: workspaceRoot,
                serverID: serverID,
                settings: settings
            )
            return nil
        } catch {
            return "Error: unable to start LSP server '\(serverID)': \(error.localizedDescription)"
        }
    }

    private func makeLSPToolFacade(settings: AppSettings) -> LSPToolFacade? {
        guard let registry = try? LSPServerRegistry(settings: settings) else {
            return nil
        }

        _ = makeOrReuseLSPServerManager(registry: registry)

        return LSPToolFacade(registry: registry, serverManager: lspServerManager)
    }

    func makeLSPWorkspaceCoordinator(settings: AppSettings) -> LSPWorkspaceCoordinator? {
        guard let registry = try? LSPServerRegistry(settings: settings),
              let manager = makeOrReuseLSPServerManager(registry: registry) else {
            return nil
        }

        return LSPWorkspaceCoordinator(
            registry: registry,
            serverManager: manager,
            fileIndexer: LSPProjectFileIndexer()
        )
    }

    @discardableResult
    private func makeOrReuseLSPServerManager(registry: LSPServerRegistry) -> LSPServerManager? {
        if lspServerManager == nil {
            let diagnosticsStore = LSPDiagnosticsStore()
            lspServerManager = LSPServerManager(
                registry: registry,
                diagnosticsStore: diagnosticsStore,
                makeClient: {
                    LSPClient(
                        transport: LSPJSONRPCTransport(),
                        documentStore: LSPDocumentStore(),
                        diagnosticsStore: diagnosticsStore,
                        adapter: GenericLSPServerAdapter()
                    )
                },
                makeSupervisor: {
                    LSPProcessSupervisor(processLauncher: ProcessLSPProcessLauncher())
                }
            )
        } else {
            lspServerManager?.updateRegistry(registry)
        }

        return lspServerManager
    }
}
